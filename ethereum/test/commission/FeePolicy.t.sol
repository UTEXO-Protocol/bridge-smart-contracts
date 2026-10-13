// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager
} from "../../src/interfaces/ICommissionManager.sol";
import {CommissionManagerTestBase} from "./CommissionManagerTestBase.sol";

/// @notice Fee configuration respects positive-net and effective-rate bounds.
contract CommissionManagerFeePolicyTest is CommissionManagerTestBase {
    // The fee fraction is stablePercent / multiplier². A fraction at or
    // above one cannot leave a positive nominal net, so setters reject
    // stablePercent >= multiplier².
    function test_setGlobalDefaults_revertsWhenStablePercentExceedsMultiplierSquared() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, uint256(9000), uint8(1)));
        cm.setGlobalDefaults(9000, 0, 1, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev Boundary just above the invariant: `multiplier = 10` → `multiplier^2 = 100`,
    ///      so `stablePercent = 101` exceeds the 100% fee-shape boundary.
    function test_setGlobalDefaults_revertsJustAboveFeeShapeBoundary() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, uint256(101), uint8(10)));
        cm.setGlobalDefaults(101, 0, 10, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev The exact boundary is a 100% fee and must be rejected too.
    function test_setGlobalDefaults_revertsFeeShapeAtExactBoundary() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, uint256(100), uint8(10)));
        cm.setGlobalDefaults(100, 0, 10, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev Squaring the multiplier must use uint256 arithmetic. With the default
    ///      `multiplier = 100`, `multiplier^2 = 10000`, so `stablePercent = 9000`
    ///      is a valid 90% fee and must be accepted. The expression
    ///      `multiplier * multiplier` evaluates in uint8 and overflows at
    ///      `100 * 100 = 10000 > 255`, which would wrongly revert this valid config;
    ///      widening before squaring preserves this valid configuration.
    function test_setGlobalDefaults_acceptsHighPercentWithDefaultMultiplier() public {
        vm.prank(owner);
        cm.setGlobalDefaults(9000, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        (uint256 sp,, uint8 m,,) = cm.getGlobalDefaults();
        assertEq(sp, 9000);
        assertEq(m, 100);
    }

    /// @dev Same invariant on the per-route setter: `(9000, 1)` must revert.
    function test_setCommissionRule_revertsWhenStablePercentExceedsMultiplierSquared() public {
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 9000,
            baseFee: 0,
            multiplier: 1,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, uint256(9000), uint8(1)));
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), cfg);
    }

    /// @dev Per-route rules also reject the exact 100% boundary.
    function test_setCommissionRule_revertsFeeShapeAtExactBoundary() public {
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 100,
            baseFee: 0,
            multiplier: 10,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, uint256(100), uint8(10)));
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), cfg);
    }

    /// @dev uint8-widening regression on the per-route setter: `(9000, 100)` is valid.
    function test_setCommissionRule_acceptsHighPercentWithDefaultMultiplier() public {
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 9000,
            baseFee: 0,
            multiplier: 100,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), cfg);
        CommissionConfig memory stored = cm.getCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token));
        assertEq(stored.stablePercent, 9000);
        assertEq(stored.multiplier, 100);
    }

    /// @dev The 8100 / 90² configuration charges exactly 100% and violates fee shape.
    function test_feePolicy_rejectsHundredPercentFeeConfiguration() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, uint256(8100), uint8(90)));
        cm.setGlobalDefaults(8100, 0, 90, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev A non-zero inbound fee policy cannot silently round to zero.
    function test_fundsIn_activeFeeRejectsCommissionFreeDust() public {
        vm.prank(owner);
        cm.setGlobalDefaults(400, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICommissionManager.CommissionRoundsToZero.selector, uint256(24), uint256(400), uint8(100)
            )
        );
        cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 24);
    }

    /// @dev The same runtime invariant applies to outbound fee rules.
    function test_fundsOut_activeFeeRejectsCommissionFreeDust() public {
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 400,
            baseFee: 0,
            multiplier: 100,
            side: CommissionSide.FUNDS_OUT,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });
        vm.prank(owner);
        cm.setCommissionRule(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), cfg);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICommissionManager.CommissionRoundsToZero.selector, uint256(24), uint256(400), uint8(100)
            )
        );
        cm.calculateFundsOutCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 24);
    }

    /// @dev A deliberately disabled fee remains valid; only active policies
    ///      promise a non-zero commission.
    function test_feePolicy_zeroFeePolicyStillAllowsSmallAmount() public view {
        (uint256 tokenFee, uint256 nativeFee, uint256 netAmount) =
            cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1);
        assertEq(tokenFee, 0);
        assertEq(nativeFee, 0);
        assertEq(netAmount, 1);
    }

    // =========================================================================
    // Effective-rate ceiling (90%)
    // The charged fraction is `stablePercent / multiplier^2`, so bounding
    // `stablePercent` alone only caps the rate at `multiplier == 100`. These
    // cover the ceiling on the rate itself.
    // =========================================================================

    /// @dev The canonical bypass: 99 / 10^2 = 99%, with both `stablePercent` and
    ///      the "below 100%" shape bound individually satisfied.
    function test_feeRate_rejectsSmallMultiplierBypass() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.FeeRateTooHigh.selector, 99, uint8(10)));
        cm.setGlobalDefaults(99, 0, 10, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev The 8999 / 95² configuration charges about 99.7%, exceeding the rate ceiling.
    function test_feeRate_rejectsNearHundredPercentBypass() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.FeeRateTooHigh.selector, 8999, uint8(95)));
        cm.setGlobalDefaults(8999, 0, 95, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    function test_feeRate_acceptsExactlyNinetyPercentAtSmallMultiplier() public {
        // 90 / 10^2 = 90% — exactly the ceiling.
        vm.prank(owner);
        cm.setGlobalDefaults(90, 0, 10, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);

        (uint256 tok,,) = cm.calculateFundsInCommission(SRC_CHAIN_ID, DST_CHAIN_ID, address(token), 1_000_000);
        assertEq(tok, 900_000, "90% charged");
    }

    function test_feeRate_rejectsOneUnitAboveCeilingAtSmallMultiplier() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.FeeRateTooHigh.selector, 91, uint8(10)));
        cm.setGlobalDefaults(91, 0, 10, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev With multiplier 100, 9000 quotes exactly 90%. The raw numerator
    ///      guard rejects 9001 before checking the effective rate.
    function test_feeRate_acceptsCeilingAndRejectsNextNumeratorAtDefaultMultiplier() public {
        vm.prank(owner);
        cm.setGlobalDefaults(9000, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        assertEq(cm.globalStablePercent(), 9000);

        // The raw numerator guard precedes the effective-rate guard.
        vm.prank(owner);
        vm.expectRevert(ICommissionManager.StablePercentTooHigh.selector);
        cm.setGlobalDefaults(9001, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    function test_feeRate_ceilingAppliesToPerRouteRuleToo() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.FeeRateTooHigh.selector, 99, uint8(10)));
        cm.setCommissionRule(
            SRC_CHAIN_ID,
            DST_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: 99,
                baseFee: 0,
                multiplier: 10,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );
    }

    /// @dev Every generated valid configuration is accepted and quotes a fee
    ///      within the effective-rate ceiling, with a positive net amount.
    function testFuzz_feeRate_acceptedConfigNeverChargesAboveCeiling(
        uint256 stablePercent,
        uint8 multiplier,
        uint256 amount
    ) public {
        multiplier = uint8(bound(uint256(multiplier), 1, type(uint8).max));
        uint256 denominator = uint256(multiplier) * uint256(multiplier);
        uint256 maximumPercent = denominator * 9_000 / 10_000;
        maximumPercent = maximumPercent < 9_000 ? maximumPercent : 9_000;
        stablePercent = bound(stablePercent, 0, maximumPercent);
        amount = bound(amount, 1, 1e30);
        vm.prank(owner);
        cm.setGlobalDefaults(stablePercent, 0, multiplier, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
        uint256 fee = cm.calculateStableFee(amount, stablePercent, multiplier);
        assertLe(fee * 10_000, amount * 9_000, "accepted config charges at most 90%");
        assertLt(fee, amount, "accepted config leaves a positive net amount");
    }

    /// @dev Rates above 90% but below 100% fail with the rate-specific error.
    function testFuzz_setGlobalDefaults_revertsOnRateAboveCeiling(uint8 multiplier, uint256 percentSeed) public {
        multiplier = uint8(bound(uint256(multiplier), 4, 99));
        uint256 denominator = uint256(multiplier) * uint256(multiplier);
        uint256 lower = denominator * 9 / 10 + 1;
        uint256 upper = denominator - 1;
        if (upper > 9_000) upper = 9_000;
        uint256 stablePercent = bound(percentSeed, lower, upper);

        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.FeeRateTooHigh.selector, stablePercent, multiplier));
        vm.prank(owner);
        cm.setGlobalDefaults(stablePercent, 0, multiplier, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev Fee shapes at or above 100% are rejected before the rate ceiling.
    function testFuzz_setGlobalDefaults_revertsOnFeeShapeAtOrAboveHundredPercent(uint8 multiplier, uint256 percentSeed)
        public
    {
        multiplier = uint8(bound(uint256(multiplier), 1, 94));
        uint256 denominator = uint256(multiplier) * uint256(multiplier);
        uint256 stablePercent = bound(percentSeed, denominator, 9_000);

        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, stablePercent, multiplier));
        vm.prank(owner);
        cm.setGlobalDefaults(stablePercent, 0, multiplier, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }

    /// @dev The numerator bound applies before multiplier or fee-shape validation.
    function testFuzz_setGlobalDefaults_revertsOnPercentAboveMaximum(uint256 percentSeed, uint8 multiplier) public {
        uint256 stablePercent = bound(percentSeed, 9_001, 20_000);
        vm.expectRevert(ICommissionManager.StablePercentTooHigh.selector);
        vm.prank(owner);
        cm.setGlobalDefaults(stablePercent, 0, multiplier, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN);
    }
}
