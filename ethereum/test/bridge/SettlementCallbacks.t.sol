// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {SettlementCallbackObserver} from "../mocks/SettlementCallbackObserver.sol";
import {BridgeRebalanceTestBase} from "./BridgeRebalanceTestBase.sol";

/// @notice Hooks expose intermediate state while transfer reentry is rejected.
contract BridgeSettlementCallbacksTest is BridgeRebalanceTestBase {
    function _installCallbackObserver(uint256 sourceChainId, uint256 destinationChainId)
        private
        returns (SettlementCallbackObserver observer)
    {
        observer = new SettlementCallbackObserver(bridge, address(routeRegistry));
        vm.prank(deployer);
        routeRegistry.setRoute(sourceChainId, destinationChainId, true, address(nullVerifier), address(observer));
    }

    function _assertCallbackSnapshot(
        SettlementCallbackObserver.Snapshot memory observed,
        uint256 expectedSource,
        uint256 expectedDestination,
        uint256 expectedTotal,
        uint256 expectedCustody
    ) private pure {
        assertEq(observed.sourceLiquidity, expectedSource);
        assertEq(observed.destinationLiquidity, expectedDestination);
        assertEq(observed.totalLiquidity, expectedTotal);
        assertEq(observed.custody, expectedCustody);
        assertEq(observed.reentryError, abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function test_fundsIn_callbackSeesCustodyBeforeCreditAndCannotReenter() public {
        SettlementCallbackObserver observer = _installCallbackObserver(SOURCE_CHAIN_ID, CHAIN_A_ID);
        usdt0.mint(user, AMOUNT);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, CHAIN_A_ID, CHAIN_A_DST_ADDR, "");

        _assertCallbackSnapshot(observer.snapshot(true), 0, AMOUNT * 10, AMOUNT * 30, AMOUNT * 31);
        assertEq(bridge.lockedLiquidity(CHAIN_A_ID), AMOUNT * 11);
        assertEq(bridge.totalLockedLiquidity(), AMOUNT * 31);
        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT * 31);
    }

    function test_rebalanceLiquidity_callbacksSeeDebitBeforeCreditAndRejectReentry() public {
        SettlementCallbackObserver observer = _installCallbackObserver(CHAIN_A_ID, RGB_CHAIN_ID);
        IBridge.RebalanceParams memory params = _chainAToRgbParams(AMOUNT, RGB_OP_ID + 1);
        vm.prank(multisig);
        bridge.rebalanceLiquidity(params);

        _assertCallbackSnapshot(observer.snapshot(false), AMOUNT * 9, AMOUNT * 10, AMOUNT * 30, AMOUNT * 30);
        _assertCallbackSnapshot(observer.snapshot(true), AMOUNT * 9, AMOUNT * 10, AMOUNT * 30, AMOUNT * 30);
        assertTrue(observer.snapshot(false).burnConsumed);
        assertTrue(observer.snapshot(true).burnConsumed);
        assertEq(bridge.lockedLiquidity(CHAIN_A_ID), AMOUNT * 9);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT * 11);
        assertEq(bridge.totalLockedLiquidity(), AMOUNT * 30);
        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT * 30);
        assertTrue(bridge.consumedBurnIds(params.burnId));
    }

    function test_fundsIn_callbackFailureRestoresCustodyAccountingAndNonce() public {
        SettlementCallbackObserver observer = _installCallbackObserver(SOURCE_CHAIN_ID, CHAIN_A_ID);
        observer.setFailOnInbound(true);
        usdt0.mint(user, AMOUNT);
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        uint256 nonceBefore = bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender);
        vm.prank(user);
        vm.expectRevert(SettlementCallbackObserver.HookFailed.selector);
        bridge.fundsIn(AMOUNT, CHAIN_A_ID, CHAIN_A_DST_ADDR, "");
        assertEq(usdt0.balanceOf(user), AMOUNT);
        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT * 30);
        assertEq(bridge.lockedLiquidity(CHAIN_A_ID), AMOUNT * 10);
        assertEq(bridge.totalLockedLiquidity(), AMOUNT * 30);
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), nonceBefore);
        assertEq(observer.snapshot(true).custody, 0);

        observer.setFailOnInbound(false);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, CHAIN_A_ID, CHAIN_A_DST_ADDR, "");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), nonceBefore + 1);
    }

    function test_rebalanceLiquidity_creditHookFailureRollsBackDebitReplayAndRateLimit() public {
        SettlementCallbackObserver observer = _installCallbackObserver(CHAIN_A_ID, RGB_CHAIN_ID);
        observer.setFailOnInbound(true);
        IBridge.RebalanceParams memory params = _chainAToRgbParams(AMOUNT, RGB_OP_ID + 1);
        uint256 availableBefore = bridge.availableOutflow(CHAIN_A_ID);
        vm.prank(multisig);
        vm.expectRevert(SettlementCallbackObserver.HookFailed.selector);
        bridge.rebalanceLiquidity(params);
        assertEq(bridge.lockedLiquidity(CHAIN_A_ID), AMOUNT * 10);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT * 10);
        assertEq(bridge.totalLockedLiquidity(), AMOUNT * 30);
        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT * 30);
        assertFalse(bridge.consumedBurnIds(params.burnId));
        assertEq(bridge.availableOutflow(CHAIN_A_ID), availableBefore);
        assertEq(observer.snapshot(false).custody, 0);
        assertEq(observer.snapshot(true).custody, 0);

        observer.setFailOnInbound(false);
        vm.prank(multisig);
        bridge.rebalanceLiquidity(params);
        assertTrue(bridge.consumedBurnIds(params.burnId));
    }
}
