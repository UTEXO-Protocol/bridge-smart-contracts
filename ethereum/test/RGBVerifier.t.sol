// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

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

    uint256 constant LOW_CONFIRMATION_HEIGHT = 850_000;
    bytes32 constant LOW_CONFIRMATION_COMMITMENT = keccak256('low-confirmation-block');
    uint256 constant HIGH_CONFIRMATION_HEIGHT = 860_000;
    bytes32 constant HIGH_CONFIRMATION_COMMITMENT = keccak256('high-confirmation-block');

    function setUp() public {
        btcRelay = new MockBtcRelay();
        verifier = new RGBVerifier(address(btcRelay));
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

    function _proof(uint256 blockHeight, bytes32 commitmentHash) internal pure returns (bytes memory) {
        return abi.encode(blockHeight, commitmentHash);
    }

    // =========================================================================
    // Current behavior reproduction
    // =========================================================================

    function test_confirmationsReturnedByRelayAreIgnored_currentBehavior() public {
        btcRelay.setBlock(LOW_CONFIRMATION_HEIGHT, LOW_CONFIRMATION_COMMITMENT, 1);
        btcRelay.setBlock(HIGH_CONFIRMATION_HEIGHT, HIGH_CONFIRMATION_COMMITMENT, 100);

        // Current behavior: RGBVerifier only requires the relay call to succeed;
        // it does not enforce a minimum confirmation count from the returned value.
        verifier.verify(_ctx(), _proof(LOW_CONFIRMATION_HEIGHT, LOW_CONFIRMATION_COMMITMENT));
        verifier.verify(_ctx(), _proof(HIGH_CONFIRMATION_HEIGHT, HIGH_CONFIRMATION_COMMITMENT));
    }
}
