// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICommissionManager} from "../../src/interfaces/ICommissionManager.sol";
import {IRouteRegistry} from "../../src/interfaces/IRouteRegistry.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {MockDepositFloor} from "../mocks/MockDepositFloor.sol";
import {MockSettlementModule} from "../mocks/MockSettlementModule.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Failed hooks and fee forwarding restore custody and accounting.
contract BridgeRollbackTest is BridgeTestBase {
    uint8 private constant MODE_ROUTE_DISABLED = 0;

    uint8 private constant MODE_SETTLEMENT_MODULE_REVERT = 1;

    uint8 private constant MODE_COMMISSION_FORWARDING_REVERT = 2;

    uint8 private constant MODE_STALE_PRICE = 3;

    uint8 private constant MODE_INVALID_PRICE = 4;

    uint8 private constant FAILURE_MODE_COUNT = MODE_INVALID_PRICE + 1;

    struct ReleaseRollbackSnapshot {
        uint256 bridgeBalance;
        uint256 recipientBalance;
        uint256 commissionBalance;
        uint256 tokenPool;
        uint256 nativePool;
        uint256 recordAmount;
        uint256 firstRecord;
        uint256 secondRecord;
        uint256 chainLiquidity;
        uint256 totalLiquidity;
        uint256 chainAllowance;
        uint256 globalAllowance;
    }

    /// @dev A contract that is NOT the Bridge but still answers the deposit-floor
    ///      query the CommissionManager makes while quoting. Pointing CM's
    ///      `bridgeAddress` here isolates the failure to `receiveTokenCommission`
    ///      (`OnlyBridge`) — a codeless address would instead fail earlier, at the
    ///      quote, with `AmountFloorUnavailable`.
    function _wrongBridgeWithFloor() private returns (address) {
        MockDepositFloor stub = new MockDepositFloor();
        stub.setMinFundsInAmount(bridge.minFundsInAmount());
        return address(stub);
    }

    function _assertFundsInRevertPathLeavesStateUnchanged(uint256 amount, uint8 failureMode) private {
        bytes memory expectedRevert;
        MockSettlementModule revertingModule;

        if (failureMode == MODE_ROUTE_DISABLED) {
            vm.prank(deployer);
            routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, false, address(rgbVerifier), address(rgbModule));
            expectedRevert =
                abi.encodeWithSelector(IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, RGB_CHAIN_ID);
        } else if (failureMode == MODE_SETTLEMENT_MODULE_REVERT) {
            revertingModule = new MockSettlementModule();
            revertingModule.setShouldRevertOnFundsIn(true);

            vm.prank(deployer);
            routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(revertingModule));
            expectedRevert = abi.encodeWithSelector(MockSettlementModule.MockModuleForcedRevert.selector);
        } else if (failureMode == MODE_COMMISSION_FORWARDING_REVERT) {
            _setFundsInTokenRule(400); // 4%, positive for the fuzzed amount range.
            // Deploy the stub BEFORE the prank — as a call argument it would consume it.
            address wrongBridge = _wrongBridgeWithFloor();
            vm.prank(deployer);
            cm.setBridgeAddress(wrongBridge);
            expectedRevert = abi.encodeWithSelector(ICommissionManager.OnlyBridge.selector);
        } else if (failureMode == MODE_STALE_PRICE) {
            _setFundsInNativeRule(100); // Positive native quote for the fuzzed amount range.
            vm.warp(vm.getBlockTimestamp() + 2 hours);
            ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp() - 2 hours);
            expectedRevert = abi.encodeWithSelector(ICommissionManager.StalePrice.selector);
        } else {
            // MODE_INVALID_PRICE: the round is fresh but its answer is nonpositive.
            _setFundsInNativeRule(100); // Positive native quote for the fuzzed amount range.
            ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp());
            ethUsdFeed.setAnswer(0);
            expectedRevert = abi.encodeWithSelector(ICommissionManager.InvalidPrice.selector);
        }

        uint256 expectedNet = amount;
        if (failureMode == MODE_COMMISSION_FORWARDING_REVERT) {
            (,, expectedNet) = cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), amount);
        }
        bytes32 expectedOpId = failureMode == MODE_SETTLEMENT_MODULE_REVERT
            ? _deriveOpId(
                SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, amount, RGB_CHAIN_ID, DST_ADDR, _rgbData()
            )
            : _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, expectedNet);
        LedgerSnapshot memory before = _snapshotLedger(expectedOpId);

        vm.expectRevert(expectedRevert);
        vm.prank(user);
        bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        _assertLedgerUnchanged(before, expectedOpId);

        if (failureMode == MODE_SETTLEMENT_MODULE_REVERT) {
            assertEq(revertingModule.onFundsInCount(), 0, "module state unchanged");
        }
    }

    function test_fundsIn_routeModuleRevertRollsBackTokenPullAndEvents() public {
        MockSettlementModule revertingModule = new MockSettlementModule();
        revertingModule.setShouldRevertOnFundsIn(true);

        // Route is intentionally rewired to a module that reverts after Bridge
        // has pulled tokens and forwarded any token commission.
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(revertingModule));

        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        LedgerSnapshot memory beforeState = _snapshotLedger(expectedOpId);

        assertEq(beforeState.bridgeToken, 0, "pre bridge token");
        assertEq(beforeState.cmToken, 0, "pre cm token");
        assertEq(beforeState.cmPool, 0, "pre cm pool");
        assertEq(beforeState.record, 0, "pre rgb record");
        assertEq(revertingModule.onFundsInCount(), 0, "pre module calls");

        // Bridge emits FundsIn/BridgeFundsIn only after route dispatch, so this
        // module revert prevents successful Bridge events from persisting.
        vm.expectRevert(MockSettlementModule.MockModuleForcedRevert.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        _assertLedgerUnchanged(beforeState, expectedOpId);
        assertEq(revertingModule.onFundsInCount(), 0, "module state unchanged");
    }

    function test_fundsIn_commissionForwardingRevertRollsBackTokenPull() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertLt(netAmount, AMOUNT, "net below gross");

        // Misconfigure the manager binding so commission forwarding fails
        // after token receipt and before the settlement hook.
        // Deploy the stub BEFORE the prank — as a call argument it would consume it.
        address wrongBridge = _wrongBridgeWithFloor();
        vm.prank(deployer);
        cm.setBridgeAddress(wrongBridge);

        bytes32 expectedOpId = _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, netAmount);
        LedgerSnapshot memory beforeState = _snapshotLedger(expectedOpId);

        assertEq(beforeState.bridgeToken, 0, "pre bridge token");
        assertEq(beforeState.cmToken, 0, "pre cm token");
        assertEq(beforeState.cmPool, 0, "pre cm pool");
        assertEq(beforeState.record, 0, "pre rgb record");

        // FundsIn/BridgeFundsIn emit after commission forwarding, so this
        // late revert prevents successful Bridge events from persisting.
        vm.expectRevert(ICommissionManager.OnlyBridge.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        _assertLedgerUnchanged(beforeState, expectedOpId);
    }

    function test_fundsOut_verifierRevertRollsBackBurnIdAndRecords() public {
        ReleaseRollbackSnapshot memory beforeState;
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        // Well-formed two-pair proof, but the source block is unknown to the relay.
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown-block"), LATEST_HEIGHT, LATEST_COMMIT);

        beforeState.bridgeBalance = usdt0.balanceOf(address(bridge));
        beforeState.recipientBalance = usdt0.balanceOf(recipient);
        beforeState.commissionBalance = usdt0.balanceOf(address(cm));
        beforeState.tokenPool = cm.tokenCommissionPool(address(usdt0));
        beforeState.nativePool = cm.nativeCommissionPool();
        beforeState.recordAmount = rgbModule.fundsInRecords(opId);
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId = _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);

        beforeState.chainLiquidity = bridge.lockedLiquidity(RGB_CHAIN_ID);
        beforeState.totalLiquidity = bridge.totalLockedLiquidity();
        beforeState.chainAllowance = bridge.availableOutflow(RGB_CHAIN_ID);
        beforeState.globalAllowance = bridge.availableGlobalOutflow();

        assertFalse(bridge.consumedBurnIds(burnId), "pre burn id");
        assertEq(beforeState.bridgeBalance, AMOUNT * 10, "pre bridge pool includes bucket reserve");
        assertEq(beforeState.recipientBalance, 0, "pre recipient token");
        assertEq(beforeState.commissionBalance, 0, "pre cm token");
        assertEq(beforeState.tokenPool, 0, "pre cm pool");
        assertEq(beforeState.nativePool, 0, "pre native pool");
        assertEq(beforeState.recordAmount, AMOUNT, "pre rgb record");

        // fundsOut marks the burn id before verifier dispatch. This verifier
        // failure rolls that mark back and short-circuits before the permanent RGB records are
        // checked.
        vm.expectRevert("verify: block commitment");
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, badProof, settlementData, SRC_BURN_TX_ID);

        assertFalse(bridge.consumedBurnIds(burnId), "burn id unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), beforeState.bridgeBalance, "bridge token unchanged");
        assertEq(usdt0.balanceOf(recipient), beforeState.recipientBalance, "recipient token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), beforeState.commissionBalance, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), beforeState.tokenPool, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), beforeState.nativePool, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId), beforeState.recordAmount, "rgb record unchanged");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), beforeState.chainLiquidity, "source liquidity unchanged");
        assertEq(bridge.totalLockedLiquidity(), beforeState.totalLiquidity, "total liquidity unchanged");
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), beforeState.chainAllowance, "chain bucket unchanged");
        assertEq(bridge.availableGlobalOutflow(), beforeState.globalAllowance, "global bucket unchanged");
    }

    function test_fundsOut_settlementRevertRollsBackBurnIdAndRecords() public {
        ReleaseRollbackSnapshot memory beforeState;
        uint256 amount1 = AMOUNT / 2;
        uint256 amount2 = AMOUNT / 2;
        uint256 releaseAmount = AMOUNT / 2;

        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(amount1, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(amount2, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));
        _ensureRgbSafetyCapacity(releaseAmount);

        // Reference opId1 with a deliberately wrong amount so the settlement
        // module reverts (AmountMismatch) after the Bridge has already marked
        // the burn id and debited liquidity — exercising the rollback.
        bytes32[] memory ids = _ids(opId1);
        uint256[] memory badAmounts = _one(amount1 + 1);

        beforeState.bridgeBalance = usdt0.balanceOf(address(bridge));
        beforeState.recipientBalance = usdt0.balanceOf(recipient);
        beforeState.commissionBalance = usdt0.balanceOf(address(cm));
        beforeState.tokenPool = cm.tokenCommissionPool(address(usdt0));
        beforeState.nativePool = cm.nativeCommissionPool();
        beforeState.firstRecord = rgbModule.fundsInRecords(opId1);
        beforeState.secondRecord = rgbModule.fundsInRecords(opId2);
        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(ids, badAmounts);
        uint256 burnId = _deriveBurnId(releaseAmount, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID);

        beforeState.chainLiquidity = bridge.lockedLiquidity(RGB_CHAIN_ID);
        beforeState.totalLiquidity = bridge.totalLockedLiquidity();
        beforeState.chainAllowance = bridge.availableOutflow(RGB_CHAIN_ID);
        beforeState.globalAllowance = bridge.availableGlobalOutflow();

        assertFalse(bridge.consumedBurnIds(burnId), "pre burn id");
        assertEq(beforeState.bridgeBalance, releaseAmount * 10, "pre bridge pool includes bucket reserve");
        assertEq(beforeState.recipientBalance, 0, "pre recipient token");
        assertEq(beforeState.commissionBalance, 0, "pre cm token");
        assertEq(beforeState.tokenPool, 0, "pre cm pool");
        assertEq(beforeState.nativePool, 0, "pre native pool");
        assertEq(beforeState.firstRecord, amount1, "pre record 1");
        assertEq(beforeState.secondRecord, amount2, "pre record 2");

        // The module reverts on the amount mismatch; the surrounding fundsOut
        // must atomically roll back the burn-id mark and the liquidity debit.
        // Records are permanent and queried without consumption.
        vm.expectRevert(
            abi.encodeWithSelector(RgbSettlementModule.AmountMismatch.selector, opId1, amount1 + 1, amount1)
        );
        vm.prank(multisig);
        _fundsOut(
            recipient, releaseAmount, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData, SRC_BURN_TX_ID
        );

        assertFalse(bridge.consumedBurnIds(burnId), "burn id unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), beforeState.bridgeBalance, "bridge token unchanged");
        assertEq(usdt0.balanceOf(recipient), beforeState.recipientBalance, "recipient token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), beforeState.commissionBalance, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), beforeState.tokenPool, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), beforeState.nativePool, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId1), beforeState.firstRecord, "record 1 unchanged");
        assertEq(rgbModule.fundsInRecords(opId2), beforeState.secondRecord, "record 2 unchanged");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), beforeState.chainLiquidity, "source liquidity unchanged");
        assertEq(bridge.totalLockedLiquidity(), beforeState.totalLiquidity, "total liquidity unchanged");
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), beforeState.chainAllowance, "chain bucket unchanged");
        assertEq(bridge.availableGlobalOutflow(), beforeState.globalAllowance, "global bucket unchanged");
    }

    // fundsIn — fuzz/property rollback coverage

    // All selected failure paths must leave balances, commission pools, and RGB
    // accounting unchanged. Feed failures are pre-pull; route/module/commission
    // failures exercise post-pull rollback.
    function testFuzz_fundsIn_failurePathsPreserveAccounting(uint128 amountSeed) public {
        // Lower bound keeps commission/native fee non-zero so intended reverts fire.
        uint256 amount = bound(uint256(amountSeed), 100, AMOUNT);

        for (uint8 failureMode = 0; failureMode < FAILURE_MODE_COUNT; failureMode++) {
            uint256 snapshotId = vm.snapshotState();
            _assertFundsInRevertPathLeavesStateUnchanged(amount, failureMode);
            assertTrue(vm.revertToStateAndDelete(snapshotId), "scenario snapshot restored");
        }
    }
}
