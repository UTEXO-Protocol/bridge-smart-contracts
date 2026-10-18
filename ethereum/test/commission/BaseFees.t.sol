// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager
} from "../../src/interfaces/ICommissionManager.sol";
import {MockDepositFloor} from "../mocks/MockDepositFloor.sol";
import {CommissionManagerTestBase} from "./CommissionManagerTestBase.sol";

/// @notice Flat-fee validation against deposit and release minimum amounts.
contract CommissionManagerBaseFeesTest is CommissionManagerTestBase {
    function _cfg(uint256 stablePercent, uint256 baseFee, CommissionSide side, CommissionCurrency currency)
        private
        pure
        returns (CommissionConfig memory)
    {
        return CommissionConfig({
            stablePercent: stablePercent, baseFee: baseFee, multiplier: 100, side: side, currency: currency, isSet: true
        });
    }

    /// @dev The flat part is ADDED to the proportional one, not multiplied into it.
    function test_baseFee_addsOnTopOfPercentage() public {
        vm.prank(owner);
        cm.setGlobalDefaults(200, 50_000, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        // 2% of 10_000_000 = 200_000, plus the flat 50_000.
        (uint256 tok,, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 10_000_000);
        assertEq(tok, 250_000, "percentage + flat");
        assertEq(net, 9_750_000, "net is gross minus total");
    }

    /// @dev A route may charge a flat fee only, with no proportional part.
    function test_baseFee_aloneWithZeroPercent() public {
        vm.prank(owner);
        cm.setGlobalDefaults(0, 50_000, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        (uint256 tok,, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 10_000_000);
        assertEq(tok, 50_000);
        assertEq(net, 9_950_000);
    }

    /// @dev Both parts zero still means "fee disabled for this route".
    function test_baseFee_zeroBothKeepsFeeDisabled() public {
        vm.prank(owner);
        cm.setGlobalDefaults(0, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        (uint256 tok,, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1234);
        assertEq(tok, 0);
        assertEq(net, 1234);
    }

    /// @dev A flat fee never rounds away, so it also removes the
    ///      `CommissionRoundsToZero` dust revert an amount-only fee has.
    function test_baseFee_preventsCommissionRoundingToZero() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 10, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        // 4% of 24 rounds to 0, but the flat 10 keeps the total non-zero.
        (uint256 tok,, uint256 net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 24);
        assertEq(tok, 10);
        assertEq(net, 14);
    }

    /// @dev The NATIVE path converts the FULL fee (proportional + flat).
    function test_baseFee_includedInNativeConversion() public {
        vm.prank(owner);
        cm.setGlobalDefaults(200, 50_000, 100, CommissionSide.FUNDS_IN, CommissionCurrency.NATIVE);

        (uint256 tok, uint256 nativeFee, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 10_000_000);
        assertEq(tok, 0, "native route takes no token fee");
        assertEq(net, 10_000_000, "full amount bridges");
        // 250_000 token units at 18 decimals, $2000/ETH.
        assertEq(nativeFee, 125, "250000 token base units at 2000 USD per ETH quote 125 wei");
    }

    /// @dev Per-route override carries its own flat fee.
    function test_baseFee_perRouteOverride() public {
        vm.prank(owner);
        cm.setGlobalDefaults(0, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        vm.prank(owner);
        cm.setCommissionRule(
            SRC_CHAIN_ID,
            DST_CHAIN_ID,
            address(token),
            _cfg(100, 7_000, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN)
        );

        (uint256 tok,,) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000);
        assertEq(tok, 10_000 + 7_000);

        // Clearing it falls back to the (fee-free) globals.
        vm.prank(owner);
        cm.clearCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token));
        (uint256 tokAfter,,) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000);
        assertEq(tokAfter, 0);
    }

    /// @dev Global fallback carries `globalBaseFee` into the effective config.
    function test_baseFee_globalFallbackCarriesBaseFee() public {
        vm.prank(owner);
        cm.setGlobalDefaults(0, 12_345, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        assertEq(cm.globalBaseFee(), 12_345);
        assertEq(cm.globalStablePercent(), 0);

        // No per-route override exists, so the quote resolves through the
        // global fallback and must include the flat part.
        assertEq(cm.calculateTotalFee(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000), 12_345);
    }

    function test_baseFee_appliesOnFundsOut() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 50_000, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);

        (uint256 tok,, uint256 net) =
            cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 10_000_000);
        assertEq(tok, 400_000 + 50_000, "percentage + flat on release");
        assertEq(net, 9_550_000);
    }

    function test_baseFee_zeroStillAllowedOnFundsOut() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);
        (uint256 tok,,) = cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000);
        assertEq(tok, 40_000);
    }

    /// @dev The release side is bounded by `minFundsOutAmount`, NOT by the
    ///      deposit floor. A flat fee between the two floors proves which one is
    ///      actually consulted.
    function test_baseFee_fundsOutBoundedByReleaseFloorNotDepositFloor() public {
        // 1_500_000 sits above DEPOSIT_FLOOR (1e6) but below RELEASE_FLOOR (2e6),
        // so it is valid on the release side and invalid on the deposit side.
        vm.prank(owner);
        cm.setGlobalDefaults(0, 1_500_000, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);
        assertEq(cm.globalBaseFee(), 1_500_000);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionManager.FeeAboveAmountFloor.selector, 1_500_000, DEPOSIT_FLOOR)
        );
        cm.setGlobalDefaults(0, 1_500_000, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    function test_baseFee_rejectedWhenItConsumesTheWholeReleaseFloor() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionManager.FeeAboveAmountFloor.selector, RELEASE_FLOOR, RELEASE_FLOOR)
        );
        cm.setGlobalDefaults(0, RELEASE_FLOOR, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);
    }

    /// @dev Same live re-check as the deposit side: lowering `minFundsOutAmount`
    ///      under a stored rule must stop it quoting.
    function test_baseFee_fundsOutQuoteRevertsAfterReleaseFloorLowered() public {
        vm.prank(owner);
        cm.setGlobalDefaults(0, 1_800_000, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.TOKEN);

        (uint256 tok,,) = cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 5_000_000);
        assertEq(tok, 1_800_000);

        MockDepositFloor(BRIDGE).setMinFundsOutAmount(1_000_000);

        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.FeeAboveAmountFloor.selector, 1_800_000, 1_000_000));
        cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 5_000_000);
    }

    /// @dev NATIVE is still unrepresentable on a release, flat fee or not.
    function test_baseFee_doesNotUnblockNativeOnFundsOut() public {
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.NativeCommissionNotAllowedOnFundsOut.selector);
        cm.setGlobalDefaults(100, 1000, 100, CommissionSide.FUNDS_OUT, CommissionCurrency.NATIVE);
    }

    function test_releaseFloor_readsBridge() public view {
        assertEq(cm.releaseFloor(), RELEASE_FLOOR);
    }

    function test_depositFloor_readsBridge() public view {
        assertEq(cm.depositFloor(), DEPOSIT_FLOOR);
    }

    function test_baseFee_rejectedWhenItConsumesTheWholeFloor() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ICommissionManager.FeeAboveAmountFloor.selector, DEPOSIT_FLOOR, DEPOSIT_FLOOR)
        );
        cm.setGlobalDefaults(0, DEPOSIT_FLOOR, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    function test_baseFee_acceptedJustBelowTheFloor() public {
        vm.prank(owner);
        cm.setGlobalDefaults(0, DEPOSIT_FLOOR - 1, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        assertEq(cm.globalBaseFee(), DEPOSIT_FLOOR - 1);
    }

    /// @dev `baseFee < depositFloor` is NECESSARY but NOT SUFFICIENT: the
    ///      proportional part consumes some of the floor too, so the bound must
    ///      be checked on the combined fee.
    function test_baseFee_belowFloorStillRejectedWhenCombinedFeeExceedsIt() public {
        // 10% of the floor = 100_000, and a flat fee 1 below the floor.
        // Individually fine, together 1_099_999 >= 1_000_000.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICommissionManager.FeeAboveAmountFloor.selector, DEPOSIT_FLOOR - 1 + 100_000, DEPOSIT_FLOOR
            )
        );
        cm.setGlobalDefaults(1000, DEPOSIT_FLOOR - 1, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev The whole point of re-reading the floor on every quote: a rule that
    ///      was valid when written must stop quoting once the Bridge lowers the
    ///      floor beneath it.
    function test_baseFee_quoteRevertsAfterFloorIsLowered() public {
        vm.prank(owner);
        cm.setGlobalDefaults(0, 900_000, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        // Valid at the original floor.
        (uint256 tok,,) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 5_000_000);
        assertEq(tok, 900_000);

        // Bridge governance lowers the floor under the already-stored rule.
        MockDepositFloor(BRIDGE).setMinFundsInAmount(500_000);

        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.FeeAboveAmountFloor.selector, 900_000, 500_000));
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 5_000_000);
    }

    /// @dev A zero-fee quote stays unchanged when the mock floor exceeds the
    ///      quoted amount or becomes unavailable.
    function test_calculateFundsInCommission_zeroFeeRouteIgnoresFloorChanges() public {
        vm.prank(owner);
        cm.setGlobalDefaults(0, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        (uint256 beforeFee,, uint256 beforeNet) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), DEPOSIT_FLOOR);
        MockDepositFloor(BRIDGE).setMinFundsInAmount(DEPOSIT_FLOOR * 2);

        (uint256 tok,, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), DEPOSIT_FLOOR);
        assertEq(tok, 0);
        assertEq(tok, beforeFee, "zero fee is unchanged by the higher floor");
        assertEq(net, beforeNet, "net quote is unchanged by the higher floor");
        assertEq(net, DEPOSIT_FLOOR, "zero-fee amount bridges in full");

        MockDepositFloor(BRIDGE).setMinFundsInAmount(0);
        vm.expectRevert(ICommissionManager.AmountFloorUnavailable.selector);
        cm.depositFloor();

        (tok,, net) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), DEPOSIT_FLOOR);
        assertEq(tok, beforeFee, "zero fee does not require a readable floor");
        assertEq(net, beforeNet, "unavailable floor preserves the full net quote");
    }

    /// @dev The Bridge read is scoped to routes that actually charge a flat fee.
    ///      A percentage-only route keeps quoting even with the floor
    ///      unreadable.
    function test_calculateFundsInCommission_percentageOnlyQuoteDoesNotReadFloor() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        vm.prank(owner);
        cm.setBridgeAddress(makeAddr("floorless-bridge"));

        (uint256 tok,, uint256 net) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 10_000_000);
        assertEq(tok, 400_000, "percentage still quoted");
        assertEq(net, 9_600_000);
    }

    function test_setGlobalDefaults_percentageOnlyRuleDoesNotReadFloor() public {
        vm.prank(owner);
        cm.setBridgeAddress(makeAddr("floorless-bridge-2"));

        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        assertEq(cm.globalStablePercent(), 400);
    }

    function test_depositFloor_revertsWhenBridgeHasNoCode() public {
        vm.prank(owner);
        cm.setBridgeAddress(makeAddr("not-a-contract"));

        vm.expectRevert(ICommissionManager.AmountFloorUnavailable.selector);
        cm.depositFloor();
    }

    function test_depositFloor_revertsWhenFloorIsZero() public {
        MockDepositFloor(BRIDGE).setMinFundsInAmount(0);

        vm.expectRevert(ICommissionManager.AmountFloorUnavailable.selector);
        cm.depositFloor();
    }

    /// @dev Fail-closed: with the floor unreadable, a fee-bearing quote must not
    ///      fall through to an unbounded flat fee.
    function test_calculateFundsInCommission_revertsWhenRequiredFloorCannotBeRead() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 1000, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        vm.prank(owner);
        cm.setBridgeAddress(makeAddr("not-a-contract-either"));

        vm.expectRevert(ICommissionManager.AmountFloorUnavailable.selector);
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 10_000_000);
    }

    function test_amountFloor_revertsWhenBridgeGetterFails() public {
        vm.mockCallRevert(BRIDGE, abi.encodeWithSignature("minFundsInAmount()"), bytes("inbound floor unavailable"));
        vm.mockCallRevert(BRIDGE, abi.encodeWithSignature("minFundsOutAmount()"), bytes("outbound floor unavailable"));
        vm.expectRevert(ICommissionManager.AmountFloorUnavailable.selector);
        cm.depositFloor();
        vm.expectRevert(ICommissionManager.AmountFloorUnavailable.selector);
        cm.releaseFloor();
    }
}
