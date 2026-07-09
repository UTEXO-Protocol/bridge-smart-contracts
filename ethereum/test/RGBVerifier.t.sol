// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from 'forge-std/Test.sol';

import { RGBVerifier } from '../src/verifiers/RGBVerifier.sol';
import { FundsOutContext } from '../src/interfaces/RouteTypes.sol';
import { MockBtcRelay } from './mocks/MockBtcRelay.sol';

contract RGBVerifierTest is Test {
    MockBtcRelay btcRelay;
    RGBVerifier verifier;

    address token = makeAddr('token');
    address recipient = makeAddr('recipient');

    uint256 constant SOURCE_CHAIN_ID = 1_000_001;
    uint256 constant DEST_CHAIN_ID = 42161;
    uint256 constant AMOUNT = 100e18;
    uint256 constant BURN_ID = 9_001;

    // Default verifier thresholds (audit R-W-06 production values).
    uint256 constant MIN_SOURCE_CONF = 6;
    uint256 constant MAX_LATEST_CONF = 1;
    uint256 constant MIN_GAP         = 5;

    // Source block (RGB burn/lock): buried deep. Latest block: fresh, at the
    // relay head. gap = 6 - 1 = 5 (== MIN_GAP), so the default proof is valid.
    uint256 constant SOURCE_HEIGHT = 850_000;
    bytes32 constant SOURCE_COMMIT = keccak256('rgb-source-block');
    uint256 constant SOURCE_CONF   = 6;
    uint256 constant LATEST_HEIGHT = 850_005;
    bytes32 constant LATEST_COMMIT = keccak256('rgb-latest-block');
    uint256 constant LATEST_CONF   = 1;

    function setUp() public {
        btcRelay = new MockBtcRelay();
        btcRelay.setBlock(SOURCE_HEIGHT, SOURCE_COMMIT, SOURCE_CONF);
        btcRelay.setBlock(LATEST_HEIGHT, LATEST_COMMIT, LATEST_CONF);
        verifier = new RGBVerifier(address(btcRelay), MIN_SOURCE_CONF, MAX_LATEST_CONF, MIN_GAP);
    }

    function _ctx() internal view returns (FundsOutContext memory) {
        return FundsOutContext({
            token:         token,
            recipient:     recipient,
            amount:        AMOUNT,
            burnId:        BURN_ID,
            sourceChainId: SOURCE_CHAIN_ID,
            destChainId:   DEST_CHAIN_ID,
            sourceAddress: 'rgb:sender/utxo1src'
        });
    }

    function _proof(uint256 sourceHeight, bytes32 sourceCommit, uint256 latestHeight, bytes32 latestCommit)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(sourceHeight, sourceCommit, latestHeight, latestCommit);
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_constructor_storesImmutables() public view {
        assertEq(verifier.btcRelay(), address(btcRelay));
        assertEq(verifier.minSourceConfirmations(), MIN_SOURCE_CONF);
        assertEq(verifier.maxLatestConfirmations(), MAX_LATEST_CONF);
        assertEq(verifier.minConfirmationGap(), MIN_GAP);
    }

    function test_constructor_revertsOnZeroRelay() public {
        vm.expectRevert(RGBVerifier.InvalidBtcRelayAddress.selector);
        new RGBVerifier(address(0), MIN_SOURCE_CONF, MAX_LATEST_CONF, MIN_GAP);
    }

    function test_constructor_revertsOnZeroMaxLatest() public {
        // maxLatestConfirmations == 0 could never accept a proof (a known block
        // always has >= 1 confirmation), so the constructor rejects it.
        vm.expectRevert(RGBVerifier.InvalidThresholds.selector);
        new RGBVerifier(address(btcRelay), MIN_SOURCE_CONF, 0, MIN_GAP);
    }

    // =========================================================================
    // verify — happy path
    // =========================================================================

    function test_verify_acceptsDeepSourceWithFreshLatest() public view {
        // Does not revert.
        verifier.verify(_ctx(), _proof(SOURCE_HEIGHT, SOURCE_COMMIT, LATEST_HEIGHT, LATEST_COMMIT));
    }

    // =========================================================================
    // verify — confirmation-depth invariants (the R-W-06 fix)
    // =========================================================================

    function test_verify_revertsWhenSourceTooShallow() public {
        // A source block only 5 deep is below the 6-confirmation floor.
        uint256 shallowHeight = 851_000;
        bytes32 shallowCommit = keccak256('shallow-source');
        btcRelay.setBlock(shallowHeight, shallowCommit, 5);

        vm.expectRevert(
            abi.encodeWithSelector(RGBVerifier.InsufficientSourceConfirmations.selector, 5, MIN_SOURCE_CONF)
        );
        verifier.verify(_ctx(), _proof(shallowHeight, shallowCommit, LATEST_HEIGHT, LATEST_COMMIT));
    }

    function test_verify_revertsWhenLatestNotFresh() public {
        // A "latest" block 2 deep means the relay head has moved on — stale.
        uint256 staleHeight = 850_004;
        bytes32 staleCommit = keccak256('stale-latest');
        btcRelay.setBlock(staleHeight, staleCommit, 2);

        vm.expectRevert(
            abi.encodeWithSelector(RGBVerifier.RelayNotFresh.selector, 2, MAX_LATEST_CONF)
        );
        verifier.verify(_ctx(), _proof(SOURCE_HEIGHT, SOURCE_COMMIT, staleHeight, staleCommit));
    }

    function test_verify_revertsWhenGapTooSmall() public {
        // Thresholds chosen so source and latest each pass their own bound, but
        // the source is not buried MIN_GAP beneath the fresh latest:
        //   min source = 2, max latest = 10, gap = 5.
        RGBVerifier gapVerifier = new RGBVerifier(address(btcRelay), 2, 10, 5);

        uint256 srcHeight = 852_000;
        bytes32 srcCommit = keccak256('gap-source');
        uint256 latHeight = 852_002;
        bytes32 latCommit = keccak256('gap-latest');
        btcRelay.setBlock(srcHeight, srcCommit, 6); // >= 2, <= no upper bound
        btcRelay.setBlock(latHeight, latCommit, 4); // <= 10 (fresh)
        // gap: 6 < 4 + 5 == 9 -> revert.

        vm.expectRevert(
            abi.encodeWithSelector(RGBVerifier.InsufficientConfirmationGap.selector, 6, 4, 5)
        );
        gapVerifier.verify(_ctx(), _proof(srcHeight, srcCommit, latHeight, latCommit));
    }

    // =========================================================================
    // verify — relay-level failures propagate
    // =========================================================================

    function test_verify_revertsOnUnknownSourceBlock() public {
        // Unconfigured source height -> the relay itself reverts.
        vm.expectRevert(bytes('verify: block commitment'));
        verifier.verify(_ctx(), _proof(999_999, keccak256('unknown-source'), LATEST_HEIGHT, LATEST_COMMIT));
    }

    function test_verify_revertsOnUnknownLatestBlock() public {
        vm.expectRevert(bytes('verify: block commitment'));
        verifier.verify(_ctx(), _proof(SOURCE_HEIGHT, SOURCE_COMMIT, 999_999, keccak256('unknown-latest')));
    }
}
