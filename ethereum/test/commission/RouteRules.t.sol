// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "forge-std/Test.sol";
import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager
} from "../../src/interfaces/ICommissionManager.sol";
import {CommissionManagerTestBase} from "./CommissionManagerTestBase.sol";

/// @notice Per-route commission rules override and fall back to global defaults.
contract CommissionManagerRouteRulesTest is CommissionManagerTestBase {
    function test_setCommissionRule_overridesGlobal() public {
        address t = address(token);
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 1000,
            baseFee: 0,
            multiplier: 100,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t, cfg);

        (uint256 tok,, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 50_000);
        assertEq(tok, 5000); // 10%
        assertEq(net, 45_000);

        CommissionConfig memory stored = cm.getCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t);
        assertTrue(stored.isSet);
        assertEq(stored.stablePercent, 1000);
    }

    function test_clearCommissionRule_fallsBackToGlobal() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        address t = address(token);
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 1000,
            baseFee: 0,
            multiplier: 100,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t, cfg);
        vm.prank(owner);
        cm.clearCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t);

        CommissionConfig memory stored = cm.getCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t);
        assertFalse(stored.isSet);

        (uint256 tok,,) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, t, 50_000);
        assertEq(tok, 2000); // back to global 4%
    }

    function test_setCommissionRule_revertsInvalidPercent() public {
        address t = address(token);
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 9001,
            baseFee: 0,
            multiplier: 100,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.StablePercentTooHigh.selector);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t, cfg);
    }

    /// @dev setCommissionRule rejects the NATIVE + FUNDS_OUT shape.
    function test_setCommissionRule_revertsNativeFundsOut() public {
        address t = address(token);
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 100,
            baseFee: 0,
            multiplier: 100,
            side: CommissionSide.FUNDS_OUT,
            currency: CommissionCurrency.NATIVE,
            isSet: true
        });
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.NativeCommissionNotAllowedOnFundsOut.selector);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t, cfg);
    }

    /// @dev FUNDS_OUT + TOKEN stays valid (the fee is deducted from the release).
    function test_setCommissionRule_acceptsFundsOutToken() public {
        address t = address(token);
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 100,
            baseFee: 0,
            multiplier: 100,
            side: CommissionSide.FUNDS_OUT,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t, cfg);

        CommissionConfig memory stored = cm.getCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, t);
        assertEq(uint8(stored.side), uint8(CommissionSide.FUNDS_OUT));
        assertEq(uint8(stored.currency), uint8(CommissionCurrency.TOKEN));
    }

    /// @dev `setCommissionRule` forces `isSet` true in storage; the log must say
    ///      the same, even when the caller passed `isSet: false`.
    function test_setCommissionRule_logsStoredConfigNotCallerStruct() public {
        CommissionConfig memory passed = CommissionConfig({
            stablePercent: 1000,
            baseFee: 0,
            multiplier: 100,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: false
        });

        vm.recordLogs();
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), passed);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one rule event");
        // `token` is indexed, so the data carries (sourceChainId, destChainId, config).
        (,, CommissionConfig memory logged) = abi.decode(logs[0].data, (uint256, uint256, CommissionConfig));
        assertTrue(logged.isSet, "logged config reflects stored isSet");
        assertEq(logged.stablePercent, 1000);
        assertTrue(cm.getCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token)).isSet);
    }

    function test_commissionRules_revertOnZeroTokenForSetAndClear() public {
        CommissionConfig memory config = CommissionConfig({
            stablePercent: 0,
            baseFee: 0,
            multiplier: 100,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.expectRevert(ICommissionManager.InvalidToken.selector);
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(0), config);
        vm.expectRevert(ICommissionManager.InvalidToken.selector);
        vm.prank(owner);
        cm.clearCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(0));
    }
}
