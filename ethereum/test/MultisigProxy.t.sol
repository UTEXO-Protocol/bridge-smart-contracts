// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test } from 'forge-std/Test.sol';
import { MultisigProxy } from '../src/MultisigProxy.sol';
import { IMultisigProxy } from '../src/interfaces/IMultisigProxy.sol';
import { Bridge }    from '../src/Bridge.sol';
import { CommissionManager } from '../src/CommissionManager.sol';
import {
    CommissionConfig,
    CommissionSide,
    CommissionCurrency,
    ICommissionManager
} from '../src/interfaces/ICommissionManager.sol';
import { MockERC20 } from './mocks/MockERC20.sol';
import { MockBtcRelay } from './mocks/MockBtcRelay.sol';
import { MultisigHelper } from './mocks/MultisigHelper.sol';

contract MultisigProxyTest is Test {
    using MultisigHelper for bytes32;

    // Re-declared events
    event Executed(bytes4 indexed selector, uint256 nonce, uint256 enclaveBitmap);
    event EmergencyPaused(uint256 nonce, uint256 fedBitmap);
    event EmergencyUnpaused(uint256 nonce, uint256 fedBitmap);
    event ProposalCreated(
        bytes32 indexed proposalId,
        IMultisigProxy.OperationType indexed opType,
        bytes operationData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap
    );
    event ProposalCancelled(bytes32 indexed proposalId);
    event ProposalExecuted(bytes32 indexed proposalId, IMultisigProxy.OperationType indexed opType);
    event EnclaveSignersUpdated(address[] newSigners, uint256 newThreshold);
    event FederationSignersUpdated(address[] newSigners, uint256 newThreshold);
    event BridgeAddressUpdated(address indexed oldBridge, address indexed newBridge);
    event CommissionManagerUpdated(address indexed oldCm, address indexed newCm);
    event TeeAllowedCallUpdated(address indexed target, bytes4 indexed selector, bool allowed);
    event TimelockDurationUpdated(uint256 newDuration);
    event CommissionWithdrawn(address indexed token, uint256 amount, address indexed recipient);
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    MultisigProxy     proxy;
    Bridge            bridge;
    CommissionManager cm;
    MockERC20         token;
    MockBtcRelay      btcRelay;

    // Enclave signers (3-of-N with threshold 2)
    uint256 encPk1 = 0xE1;
    uint256 encPk2 = 0xE2;
    uint256 encPk3 = 0xE3;
    address encA1;
    address encA2;
    address encA3;

    // Federation signers (3-of-N with threshold 2)
    uint256 fedPk1 = 0xF1;
    uint256 fedPk2 = 0xF2;
    uint256 fedPk3 = 0xF3;
    address fedA1;
    address fedA2;
    address fedA3;

    address deployer           = makeAddr('deployer');
    address user               = makeAddr('user');
    address recipient          = makeAddr('recipient');
    address commissionReceiver = makeAddr('commissionReceiver');

    uint256 constant TIMELOCK = 1 hours;

    bytes32 domainSep;

    // Canonical constants for Bridge calls
    // Chain identifiers are uint256: foundry tests run with block.chainid = 31337.
    uint256 constant SOURCE_CHAIN_ID = 31337;
    uint256 constant RGB_CHAIN_ID    = 1_000_001;
    string  constant DST_ADDR        = 'rgb:asset/utxo1abc';
    string  constant SRC_ADDR        = 'rgb:sender/utxo1src';
    uint256 constant AMOUNT    = 100e18;
    uint256 constant TX_ID     = 42;
    uint256 constant BURN_ID   = 9_001;

    // BtcRelay test data
    uint256 constant BLOCK_HEIGHT    = 850_000;
    bytes32 constant COMMITMENT_HASH = keccak256('test-btc-block-commitment');
    uint256 constant BTC_CONFIRMATIONS = 6;

    bytes4  constant FUNDS_OUT_SELECTOR = bytes4(keccak256(
        'fundsOut(address,uint256,uint256,uint256,uint256,uint256,string,uint256,bytes32,uint256[])'
    ));

    function setUp() public {
        encA1 = vm.addr(encPk1);
        encA2 = vm.addr(encPk2);
        encA3 = vm.addr(encPk3);
        fedA1 = vm.addr(fedPk1);
        fedA2 = vm.addr(fedPk2);
        fedA3 = vm.addr(fedPk3);

        token = new MockERC20('Mock USDT0', 'USDT0');
        btcRelay = new MockBtcRelay();
        btcRelay.setBlock(BLOCK_HEIGHT, COMMITMENT_HASH, BTC_CONFIRMATIONS);

        // Deploy CommissionManager with deployer as temp bridge.
        vm.prank(deployer);
        cm = new CommissionManager(deployer);

        vm.prank(deployer);
        bridge = new Bridge(address(token), address(btcRelay), payable(address(cm)), address(0));

        vm.prank(deployer);
        cm.setBridgeAddress(address(bridge));

        address[] memory enc = new address[](3);
        enc[0] = encA1; enc[1] = encA2; enc[2] = encA3;

        address[] memory fed = new address[](3);
        fed[0] = fedA1; fed[1] = fedA2; fed[2] = fedA3;

        proxy = new MultisigProxy(
            address(bridge),
            address(cm),
            enc, 2,
            fed, 2,
            commissionReceiver,
            TIMELOCK
        );

        // Transfer ownership of Bridge and CM to proxy (production flow)
        vm.prank(deployer);
        bridge.transferOwnership(address(proxy));
        vm.prank(deployer);
        cm.transferOwnership(address(proxy));

        domainSep = proxy.DOMAIN_SEPARATOR();

        // Fund user, lock tokens into the bridge so fundsOut has a pool
        token.mint(user, AMOUNT * 10);
        vm.prank(user);
        token.approve(address(bridge), type(uint256).max);
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 5, RGB_CHAIN_ID, DST_ADDR, TX_ID);
    }

    // ========================================================================
    // helpers
    // ========================================================================

    function _encSigSet2of3() internal pure returns (uint256[] memory pks, uint256 bitmap) {
        pks = new uint256[](2);
        pks[0] = 0xE1;
        pks[1] = 0xE2;
        bitmap = 0x3;
    }

    function _fedSigSet2of3() internal pure returns (uint256[] memory pks, uint256 bitmap) {
        pks = new uint256[](2);
        pks[0] = 0xF1;
        pks[1] = 0xF2;
        bitmap = 0x3;
    }

    function _fundsInIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = TX_ID;
    }

    function _fundsOutCalldata() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            FUNDS_OUT_SELECTOR,
            recipient, AMOUNT, TX_ID, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, BLOCK_HEIGHT, COMMITMENT_HASH, _fundsInIds()
        );
    }

    // ========================================================================
    // Constructor
    // ========================================================================

    function test_constructor_setsState() public view {
        assertEq(proxy.bridge(), address(bridge));
        assertEq(proxy.commissionManager(), address(cm));
        assertEq(proxy.enclaveThreshold(), 2);
        assertEq(proxy.federationThreshold(), 2);
        assertEq(proxy.commissionRecipient(), commissionReceiver);
        assertEq(proxy.timelockDuration(), TIMELOCK);
        assertEq(proxy.proposalNonce(), 0);
        assertTrue(proxy.teeAllowedCalls(address(bridge), FUNDS_OUT_SELECTOR));

        address[] memory enc = proxy.getEnclaveSigners();
        assertEq(enc.length, 3);
        assertEq(enc[0], encA1);

        address[] memory fed = proxy.getFederationSigners();
        assertEq(fed.length, 3);
    }

    function test_constructor_revertsOnZeroBridge() public {
        address[] memory enc = new address[](1); enc[0] = encA1;
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.ZeroBridge.selector);
        new MultisigProxy(address(0), address(cm), enc, 1, fed, 1, commissionReceiver, TIMELOCK);
    }

    function test_constructor_revertsOnZeroCommissionManager() public {
        address[] memory enc = new address[](1); enc[0] = encA1;
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.ZeroCommissionManager.selector);
        new MultisigProxy(address(bridge), address(0), enc, 1, fed, 1, commissionReceiver, TIMELOCK);
    }

    function test_constructor_revertsOnNoEnclaveSigners() public {
        address[] memory enc = new address[](0);
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.NoSigners.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 1, fed, 1, commissionReceiver, TIMELOCK);
    }

    function test_constructor_revertsOnBadEnclaveThreshold() public {
        address[] memory enc = new address[](2); enc[0] = encA1; enc[1] = encA2;
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 3, fed, 1, commissionReceiver, TIMELOCK);
    }

    function test_constructor_revertsOnZeroCommission() public {
        address[] memory enc = new address[](1); enc[0] = encA1;
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.ZeroCommissionRecipient.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 1, fed, 1, address(0), TIMELOCK);
    }

    function test_constructor_revertsOnTimelockTooLong() public {
        address[] memory enc = new address[](1); enc[0] = encA1;
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.TimelockTooLong.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 1, fed, 1, commissionReceiver, 30 days);
    }

    function test_constructor_revertsOnDuplicateSigner() public {
        address[] memory enc = new address[](2); enc[0] = encA1; enc[1] = encA1;
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.DuplicateSigner.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 1, fed, 1, commissionReceiver, TIMELOCK);
    }

    function test_constructor_revertsOnZeroAddressSigner() public {
        address[] memory enc = new address[](1); enc[0] = address(0);
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.ZeroAddressSigner.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 1, fed, 1, commissionReceiver, TIMELOCK);
    }

    // ========================================================================
    // TEE execute — happy path
    // ========================================================================

    function test_execute_fundsOutViaBridge() public {
        bytes memory callData = _fundsOutCalldata();
        uint256 nonce = proxy.getNonce(FUNDS_OUT_SELECTOR);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestBridgeOp(domainSep, FUNDS_OUT_SELECTOR, callData, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(true, false, false, true);
        emit Executed(FUNDS_OUT_SELECTOR, nonce, bitmap);

        proxy.execute(callData, nonce, deadline, bitmap, sigs);

        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(proxy.getNonce(FUNDS_OUT_SELECTOR), nonce + 1);
    }

    function test_execute_revertsOnExpired() public {
        bytes memory callData = _fundsOutCalldata();
        uint256 nonce = proxy.getNonce(FUNDS_OUT_SELECTOR);
        uint256 deadline = block.timestamp - 1;

        bytes32 digest = MultisigHelper.digestBridgeOp(domainSep, FUNDS_OUT_SELECTOR, callData, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.execute(callData, nonce, deadline, bitmap, sigs);
    }

    function test_execute_revertsOnWrongNonce() public {
        bytes memory callData = _fundsOutCalldata();
        uint256 nonce = 99;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestBridgeOp(domainSep, FUNDS_OUT_SELECTOR, callData, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.execute(callData, nonce, deadline, bitmap, sigs);
    }

    function test_execute_revertsOnDisallowedSelector() public {
        bytes memory callData = abi.encodeWithSignature('pause()');
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestBridgeOp(domainSep, bytes4(callData), callData, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(abi.encodeWithSelector(
            IMultisigProxy.CallNotAllowed.selector, address(bridge), bytes4(callData)
        ));
        proxy.execute(callData, nonce, deadline, bitmap, sigs);
    }

    // ========================================================================
    // executeBatch
    // ========================================================================

    /// @dev Helper: build a single-element batch around the standard fundsOut call.
    function _singleFundsOutBatch() internal view returns (
        address[] memory targets,
        bytes[]   memory callDatas,
        uint256[] memory values
    ) {
        targets = new address[](1);
        callDatas = new bytes[](1);
        values = new uint256[](1);
        targets[0]   = address(bridge);
        callDatas[0] = _fundsOutCalldata();
        values[0]    = 0;
    }

    function test_executeBatch_singleFundsOut_happyPath() public {
        (address[] memory targets, bytes[] memory callDatas, uint256[] memory values) = _singleFundsOutBatch();

        uint256 nonce    = proxy.batchNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestBridgeBatchOp(
            domainSep, targets, callDatas, values, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        proxy.executeBatch(targets, callDatas, values, nonce, deadline, bitmap, sigs);

        assertEq(token.balanceOf(recipient), AMOUNT,    'fundsOut delivered');
        assertEq(proxy.batchNonce(),         nonce + 1, 'batchNonce incremented');
    }

    function test_executeBatch_revertsOnEmpty() public {
        address[] memory targets = new address[](0);
        bytes[]   memory callDatas = new bytes[](0);
        uint256[] memory values = new uint256[](0);

        bytes[] memory sigs = new bytes[](2);

        vm.expectRevert(IMultisigProxy.BatchEmpty.selector);
        proxy.executeBatch(targets, callDatas, values, 0, block.timestamp + 1 hours, 0x3, sigs);
    }

    function test_executeBatch_revertsOnLengthMismatch() public {
        address[] memory targets   = new address[](2);
        bytes[]   memory callDatas = new bytes[](1);
        uint256[] memory values    = new uint256[](2);
        targets[0] = address(bridge); targets[1] = address(bridge);
        callDatas[0] = _fundsOutCalldata();

        bytes[] memory sigs = new bytes[](2);

        vm.expectRevert(IMultisigProxy.BatchLengthMismatch.selector);
        proxy.executeBatch(targets, callDatas, values, 0, block.timestamp + 1 hours, 0x3, sigs);
    }

    function test_executeBatch_revertsOnDisallowedTargetSelector() public {
        // Disallowed target/selector pair: proxy.pause() (no allowlist entry).
        address[] memory targets   = new address[](1);
        bytes[]   memory callDatas = new bytes[](1);
        uint256[] memory values    = new uint256[](1);
        targets[0]   = makeAddr('random-target');
        callDatas[0] = abi.encodeWithSignature('pause()');

        uint256 nonce    = proxy.batchNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestBridgeBatchOp(
            domainSep, targets, callDatas, values, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(abi.encodeWithSelector(
            IMultisigProxy.CallNotAllowed.selector, targets[0], bytes4(callDatas[0])
        ));
        proxy.executeBatch(targets, callDatas, values, nonce, deadline, bitmap, sigs);
    }

    function test_executeBatch_revertsOnValueMismatch() public {
        (address[] memory targets, bytes[] memory callDatas, uint256[] memory values) = _singleFundsOutBatch();
        values[0] = 1 ether; // sum != msg.value (we pass 0)

        uint256 nonce    = proxy.batchNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestBridgeBatchOp(
            domainSep, targets, callDatas, values, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.BatchValueMismatch.selector);
        proxy.executeBatch{ value: 0 }(targets, callDatas, values, nonce, deadline, bitmap, sigs);
    }

    function test_executeBatch_revertsOnTooLarge() public {
        uint256 size = proxy.MAX_BATCH_SIZE() + 1;
        address[] memory targets   = new address[](size);
        bytes[]   memory callDatas = new bytes[](size);
        uint256[] memory values    = new uint256[](size);

        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(IMultisigProxy.BatchTooLarge.selector);
        proxy.executeBatch(targets, callDatas, values, 0, block.timestamp + 1 hours, 0x3, sigs);
    }

    function test_executeBatch_revertsOnExpired() public {
        (address[] memory targets, bytes[] memory callDatas, uint256[] memory values) = _singleFundsOutBatch();

        bytes[] memory sigs = new bytes[](2);
        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.executeBatch(targets, callDatas, values, 0, block.timestamp - 1, 0x3, sigs);
    }

    function test_executeBatch_revertsOnWrongNonce() public {
        (address[] memory targets, bytes[] memory callDatas, uint256[] memory values) = _singleFundsOutBatch();

        uint256 wrongNonce = 99;
        uint256 deadline   = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestBridgeBatchOp(
            domainSep, targets, callDatas, values, wrongNonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.executeBatch(targets, callDatas, values, wrongNonce, deadline, bitmap, sigs);
    }

    function test_execute_revertsOnCallDataTooShort() public {
        bytes memory callData = hex'aabb';
        vm.expectRevert(IMultisigProxy.CallDataTooShort.selector);
        proxy.execute(callData, 0, block.timestamp + 1 hours, 0x3, new bytes[](2));
    }

    function test_execute_revertsOnBelowThreshold() public {
        bytes memory callData = _fundsOutCalldata();
        uint256 nonce = proxy.getNonce(FUNDS_OUT_SELECTOR);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestBridgeOp(domainSep, FUNDS_OUT_SELECTOR, callData, nonce, deadline);
        uint256[] memory pks = new uint256[](1); pks[0] = encPk1;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.BelowThreshold.selector);
        proxy.execute(callData, nonce, deadline, 0x1, sigs);
    }

    function test_execute_revertsOnBadSignature() public {
        bytes memory callData = _fundsOutCalldata();
        uint256 nonce = proxy.getNonce(FUNDS_OUT_SELECTOR);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestBridgeOp(domainSep, FUNDS_OUT_SELECTOR, callData, nonce, deadline);
        uint256[] memory pks = new uint256[](2);
        pks[0] = encPk1;
        pks[1] = 0xBADBAD;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.execute(callData, nonce, deadline, 0x3, sigs);
    }

    function test_execute_revertsOnSigCountMismatch() public {
        bytes memory callData = _fundsOutCalldata();
        uint256 nonce = proxy.getNonce(FUNDS_OUT_SELECTOR);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestBridgeOp(domainSep, FUNDS_OUT_SELECTOR, callData, nonce, deadline);
        uint256[] memory pks = new uint256[](3);
        pks[0] = encPk1; pks[1] = encPk2; pks[2] = encPk3;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.SigCountMismatch.selector);
        proxy.execute(callData, nonce, deadline, 0x3, sigs);
    }

    function test_execute_revertsOnBitmapOutOfRange() public {
        bytes memory callData = _fundsOutCalldata();
        uint256 nonce = proxy.getNonce(FUNDS_OUT_SELECTOR);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestBridgeOp(domainSep, FUNDS_OUT_SELECTOR, callData, nonce, deadline);
        (uint256[] memory pks,) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.BitmapOutOfRange.selector);
        proxy.execute(callData, nonce, deadline, 0x100, sigs);
    }

    // ========================================================================
    // Emergency pause / unpause
    // ========================================================================

    function test_emergencyPause_works() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(false, false, false, true);
        emit EmergencyPaused(nonce, bitmap);

        proxy.emergencyPause(nonce, deadline, bitmap, sigs);

        assertTrue(bridge.paused());
        assertEq(proxy.proposalNonce(), nonce + 1);
    }

    function test_emergencyPause_revertsOnExpired() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp - 1;

        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.emergencyPause(nonce, deadline, bitmap, sigs);
    }

    function test_emergencyPause_revertsOnWrongNonce() public {
        uint256 nonce = 99;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.emergencyPause(nonce, deadline, bitmap, sigs);
    }

    function test_emergencyUnpause_works() public {
        test_emergencyPause_works();

        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestEmergencyUnpause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(false, false, false, true);
        emit EmergencyUnpaused(nonce, bitmap);

        proxy.emergencyUnpause(nonce, deadline, bitmap, sigs);
        assertFalse(bridge.paused());
    }

    // ========================================================================
    // Propose + Execute — UpdateBridge
    // ========================================================================

    function test_proposeUpdateBridge_andExecuteAfterTimelock() public {
        address newBridge = makeAddr('newBridge');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 proposalId = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        vm.expectRevert(IMultisigProxy.TimelockActive.selector);
        proxy.executeProposal(proposalId, abi.encode(newBridge));

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, false);
        emit BridgeAddressUpdated(address(bridge), newBridge);

        proxy.executeProposal(proposalId, abi.encode(newBridge));
        assertEq(proxy.bridge(), newBridge);
    }

    function test_proposeUpdateBridge_revertsOnExpired() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp - 1;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr('nb'), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.proposeUpdateBridge(makeAddr('nb'), nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateBridge_revertsOnDeadlineTooFar() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 31 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr('nb'), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
        proxy.proposeUpdateBridge(makeAddr('nb'), nonce, deadline, bitmap, sigs);
    }

    // ========================================================================
    // Propose + Execute — UpdateEnclaveSigners
    // ========================================================================

    function test_proposeUpdateEnclaveSigners_execute() public {
        address newSigner = makeAddr('newEncSigner');
        address[] memory newSigners = new address[](2);
        newSigners[0] = encA1; newSigners[1] = newSigner;
        uint256 newThreshold = 2;

        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateEnclaveSigners(newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(newSigners, newThreshold));

        address[] memory after_ = proxy.getEnclaveSigners();
        assertEq(after_.length, 2);
        assertEq(after_[1], newSigner);
        assertEq(proxy.enclaveThreshold(), newThreshold);
    }

    // ========================================================================
    // Propose + Execute — SetTeeAllowedCall
    // ========================================================================

    function test_proposeSetTeeAllowedCall_execute() public {
        address target = makeAddr('lzAdapter');
        bytes4  sel    = bytes4(0xdeadbeef);
        uint256 nonce  = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeSetTeeAllowedCall(
            domainSep, target, sel, true, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeSetTeeAllowedCall(target, sel, true, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, true);
        emit TeeAllowedCallUpdated(target, sel, true);

        proxy.executeProposal(id, abi.encode(target, sel, true));
        assertTrue(proxy.teeAllowedCalls(target, sel));
    }

    // ========================================================================
    // Propose + Execute — SetTimelockDuration
    // ========================================================================

    function test_proposeSetTimelockDuration_execute() public {
        uint256 newDuration = 2 hours;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeSetTimelockDuration(domainSep, newDuration, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeSetTimelockDuration(newDuration, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(false, false, false, true);
        emit TimelockDurationUpdated(newDuration);
        proxy.executeProposal(id, abi.encode(newDuration));

        assertEq(proxy.timelockDuration(), newDuration);
    }

    // ========================================================================
    // Propose + Execute — AdminExecute
    // ========================================================================

    function test_proposeAdminExecute_canCallBridge() public {
        bytes memory callData = abi.encodeWithSignature('pause()');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecute(
            domainSep, bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecute(callData, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, callData);

        assertTrue(bridge.paused());
    }

    // ========================================================================
    // Propose + Execute — UpdateCommissionManager
    // ========================================================================

    function test_proposeUpdateCommissionManager_execute() public {
        address newCm = makeAddr('newCm');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateCommissionManager(domainSep, newCm, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateCommissionManager(newCm, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, false);
        emit CommissionManagerUpdated(address(cm), newCm);

        proxy.executeProposal(id, abi.encode(newCm));
        assertEq(proxy.commissionManager(), newCm);
    }

    // ========================================================================
    // Propose + Execute — WithdrawTokenCommissionCM
    // ========================================================================

    function test_proposeWithdrawTokenCommissionCM_execute() public {
        // Seed commission by setting a fundsIn TOKEN rule and doing a deposit.
        vm.prank(address(proxy));
        cm.setCommissionRule(
            SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(token),
            CommissionConfig({
                stablePercent: 400, // 4%
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        uint256 depositAmount = 100e18;
        vm.prank(user);
        bridge.fundsIn(depositAmount, RGB_CHAIN_ID, DST_ADDR, TX_ID + 1);

        uint256 expectedCommission = (depositAmount * 400) / 100 / 100;
        assertEq(cm.tokenCommissionPool(address(token)), expectedCommission);

        // Propose withdrawal.
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeWithdrawTokenCommissionCM(
            domainSep, address(token), expectedCommission, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeWithdrawTokenCommissionCM(
            address(token), expectedCommission, nonce, deadline, bitmap, sigs
        );

        vm.warp(block.timestamp + TIMELOCK + 1);

        uint256 recipientBefore = token.balanceOf(commissionReceiver);

        vm.expectEmit(true, true, false, true);
        emit CommissionWithdrawn(address(token), expectedCommission, commissionReceiver);

        proxy.executeProposal(id, abi.encode(address(token), expectedCommission));

        assertEq(token.balanceOf(commissionReceiver), recipientBefore + expectedCommission);
        assertEq(cm.tokenCommissionPool(address(token)), 0);
    }

    // ========================================================================
    // Cancel
    // ========================================================================

    function test_cancelProposal_cancels() public {
        address newBridge = makeAddr('newBridge');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        uint256 cNonce = proxy.proposalNonce();
        uint256 cDeadline = block.timestamp + 1 hours;
        bytes32 cDigest = MultisigHelper.digestCancelProposal(domainSep, id, cNonce, cDeadline);
        bytes[] memory cSigs = MultisigHelper.signAll(vm, cDigest, pks);

        vm.expectEmit(true, false, false, false);
        emit ProposalCancelled(id);
        proxy.cancelProposal(id, cNonce, cDeadline, bitmap, cSigs);

        IMultisigProxy.Proposal memory p = proxy.getProposal(id);
        assertEq(uint8(p.status), uint8(IMultisigProxy.ProposalStatus.Cancelled));

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.executeProposal(id, abi.encode(newBridge));
    }

    function test_cancelProposal_revertsOnNotPending() public {
        bytes32 id = keccak256('ghost');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestCancelProposal(domainSep, id, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.cancelProposal(id, nonce, deadline, bitmap, sigs);
    }

    // ========================================================================
    // executeProposal reverts
    // ========================================================================

    function test_executeProposal_revertsOnDataMismatch() public {
        address newBridge = makeAddr('newBridge');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        proxy.executeProposal(id, abi.encode(makeAddr('different')));
    }

    function test_executeProposal_revertsOnExpiredDeadline() public {
        address newBridge = makeAddr('newBridge');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 2 hours;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        vm.warp(deadline + 1);
        vm.expectRevert(IMultisigProxy.ProposalExpired.selector);
        proxy.executeProposal(id, abi.encode(newBridge));
    }

    // ========================================================================
    // View
    // ========================================================================

    function test_verifyEnclaveSignature() public view {
        bytes32 digest = keccak256('msg');
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(encPk1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertTrue(proxy.verifyEnclaveSignature(digest, sig, 0));
        assertFalse(proxy.verifyEnclaveSignature(digest, sig, 1));
    }

    function test_verifyEnclaveSignature_revertsOutOfRange() public {
        bytes32 digest = keccak256('msg');
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(encPk1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(IMultisigProxy.IndexOutOfRange.selector);
        proxy.verifyEnclaveSignature(digest, sig, 99);
    }

    // ========================================================================
    // Propose + Execute — UpdateLZAdapter
    // ========================================================================

    function _proposeUpdateLZAdapter(address newAdapter) internal returns (bytes32 id) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateLZAdapter(domainSep, newAdapter, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        id = proxy.proposeUpdateLZAdapter(newAdapter, nonce, deadline, bitmap, sigs);
    }

    function test_lzAdapter_defaultsToZero() public view {
        assertEq(proxy.lzAdapter(), address(0));
    }

    function test_proposeUpdateLZAdapter_executeSetsAdapter() public {
        address newAdapter = makeAddr('lzAdapter');
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, false);
        emit LZAdapterUpdated(address(0), newAdapter);

        proxy.executeProposal(id, abi.encode(newAdapter));
        assertEq(proxy.lzAdapter(), newAdapter);
    }

    function test_proposeUpdateLZAdapter_canRotateToZero() public {
        address newAdapter = makeAddr('lzAdapter');
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);
        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(newAdapter));
        assertEq(proxy.lzAdapter(), newAdapter);

        // Rotate back to zero — closes AdminExecuteAdapter path.
        // proposalNonce auto-increments, so the second proposal lives at a different id.
        bytes32 id2 = _proposeUpdateLZAdapter(address(0));
        // Fresh timelock from the *second* proposal's proposedAt. Use a large
        // absolute warp so the timelock check passes regardless of foundry's
        // current block.timestamp evaluation quirks.
        vm.warp(block.timestamp + 2 * TIMELOCK + 2);

        proxy.executeProposal(id2, abi.encode(address(0)));
        assertEq(proxy.lzAdapter(), address(0));
    }

    function test_proposeUpdateLZAdapter_revertsOnDataMismatch() public {
        address newAdapter = makeAddr('lzAdapter');
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        proxy.executeProposal(id, abi.encode(makeAddr('different')));
    }

    function test_proposeUpdateLZAdapter_canBeCancelled() public {
        address newAdapter = makeAddr('lzAdapter');
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        uint256 cNonce = proxy.proposalNonce();
        uint256 cDeadline = block.timestamp + 1 hours;
        bytes32 cDigest = MultisigHelper.digestCancelProposal(domainSep, id, cNonce, cDeadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory cSigs = MultisigHelper.signAll(vm, cDigest, pks);

        vm.expectEmit(true, false, false, false);
        emit ProposalCancelled(id);
        proxy.cancelProposal(id, cNonce, cDeadline, bitmap, cSigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.executeProposal(id, abi.encode(newAdapter));
        assertEq(proxy.lzAdapter(), address(0));
    }

    // ========================================================================
    // Propose + Execute — AdminExecuteAdapter
    // ========================================================================

    function test_proposeAdminExecuteAdapter_revertsIfAdapterUnset() public {
        // Register an arbitrary adapter call; lzAdapter is still address(0).
        bytes memory callData = abi.encodeWithSignature('mint(address,uint256)', user, 1e18);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteAdapter(
            domainSep, bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.ZeroTarget.selector);
        proxy.executeProposal(id, callData);
    }

    function test_proposeAdminExecuteAdapter_executesCallOnAdapter() public {
        // 1. Set lzAdapter to a MockERC20 (its `mint(address,uint256)` is public).
        MockERC20 adapter = new MockERC20('LZ Stub', 'LZS');
        bytes32 idSet = _proposeUpdateLZAdapter(address(adapter));
        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(idSet, abi.encode(address(adapter)));
        assertEq(proxy.lzAdapter(), address(adapter));

        // 2. Propose an AdminExecuteAdapter call: mint 1e18 to `recipient`.
        bytes memory callData = abi.encodeWithSignature('mint(address,uint256)', recipient, 1e18);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteAdapter(
            domainSep, bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, callData);

        assertEq(adapter.balanceOf(recipient), 1e18);
    }

    function test_proposeAdminExecuteAdapter_revertsOnEmptyCallData() public {
        bytes memory callData = '';
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        // We can't really build a valid digest for empty calldata via the proxy's
        // assembly-based selector load — just confirm the explicit guard fires.
        bytes[] memory sigs = new bytes[](pks.length);
        for (uint256 i = 0; i < pks.length; i++) sigs[i] = new bytes(65);

        vm.expectRevert(IMultisigProxy.CallDataTooShort.selector);
        proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);
    }

    function test_proposeAdminExecuteAdapter_propagatesAdapterRevert() public {
        // Adapter = MockERC20. Call a non-existent function so the fallback reverts.
        MockERC20 adapter = new MockERC20('LZ Stub', 'LZS');
        bytes32 idSet = _proposeUpdateLZAdapter(address(adapter));
        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(idSet, abi.encode(address(adapter)));

        bytes memory callData = abi.encodeWithSignature('nonExistent()');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteAdapter(
            domainSep, bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        // MockERC20 has no fallback — call returns false and _propagateRevert bubbles up.
        vm.expectRevert();
        proxy.executeProposal(id, callData);
    }

    function test_domainSeparator_matchesHelper() public view {
        assertEq(proxy.DOMAIN_SEPARATOR(), MultisigHelper.domainSeparator(address(proxy), block.chainid));
    }
}
