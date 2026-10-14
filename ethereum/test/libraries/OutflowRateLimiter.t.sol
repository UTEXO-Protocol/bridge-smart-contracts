// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OutflowRateLimiter} from "../../src/libraries/OutflowRateLimiter.sol";
import {OutflowRateLimiterHarness} from "../helpers/OutflowRateLimiterHarness.sol";

/// @notice Isolated bucket refill, clamping, retryAfter and configuration arithmetic.
/// @dev The harness also exercises defensive checks against invalid stored allowances.
contract OutflowRateLimiterTest is Test {
    OutflowRateLimiterHarness internal harness;

    address internal constant TOKEN = address(0xBEEF);

    address internal constant AGGREGATE = address(0); // sentinel selecting aggregate-scope errors

    uint128 internal constant CAP = 1_000;

    uint128 internal constant RATE = 10;

    function setUp() public {
        harness = new OutflowRateLimiterHarness();
        // Start at a non-zero timestamp so `lastUpdated` casts are meaningful.
        vm.warp(1_000_000);
    }

    function _enabled(uint128 capacity, uint128 rate) private pure returns (OutflowRateLimiter.Settings memory) {
        return OutflowRateLimiter.Settings({isEnabled: true, capacity: capacity, rate: rate});
    }

    function _disabled() private pure returns (OutflowRateLimiter.Settings memory) {
        return OutflowRateLimiter.Settings({isEnabled: false, capacity: 0, rate: 0});
    }

    function _prime(uint128 capacity, uint128 rate) private {
        harness.configurePrimed(_enabled(capacity, rate));
    }

    function test_validate_enabledValidConfigPasses() public view {
        harness.validate(_enabled(CAP, RATE), false); // no revert
    }

    function test_validate_enabledZeroCapacityReverts() public {
        OutflowRateLimiter.Settings memory s = _enabled(0, RATE);
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.InvalidLimitConfig.selector, s));
        harness.validate(s, false);
    }

    function test_validate_enabledZeroRateReverts() public {
        OutflowRateLimiter.Settings memory s = _enabled(CAP, 0);
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.InvalidLimitConfig.selector, s));
        harness.validate(s, false);
    }

    function test_validate_enabledRateGteCapacityReverts() public {
        OutflowRateLimiter.Settings memory s = _enabled(CAP, CAP); // rate >= capacity
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.InvalidLimitConfig.selector, s));
        harness.validate(s, false);
    }

    function test_validate_disabledCleanPasses() public view {
        harness.validate(_disabled(), false); // no revert
    }

    /// @dev Covers `DisabledLimitHasValues`: disabled flag but non-zero fields.
    function test_validate_disabledWithValuesReverts() public {
        OutflowRateLimiter.Settings memory s = OutflowRateLimiter.Settings({isEnabled: false, capacity: 5, rate: 0});
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.DisabledLimitHasValues.selector, s));
        harness.validate(s, false);
    }

    /// @dev Covers `LimitMustStayDisabled`: `mustBeDisabled` set while enabled.
    function test_validate_mustBeDisabledButEnabledReverts() public {
        vm.expectRevert(OutflowRateLimiter.LimitMustStayDisabled.selector);
        harness.validate(_enabled(CAP, RATE), true);
    }

    function test_validate_mustBeDisabledAndDisabledPasses() public view {
        harness.validate(_disabled(), true); // no revert
    }

    function test_configurePrimed_firstEnableFillsToCapacity() public {
        _prime(CAP, RATE);
        assertEq(harness.read().tokens, CAP, "first enable should fill to capacity");
        assertTrue(harness.read().isEnabled);
    }

    /// @dev Re-priming an already-enabled bucket must NOT refill to capacity.
    function test_configurePrimed_alreadyEnabledDoesNotRefill() public {
        _prime(CAP, RATE);
        harness.spend(400, TOKEN); // tokens -> 600
        harness.configurePrimed(_enabled(CAP, RATE)); // already enabled -> no refill
        assertEq(harness.read().tokens, 600, "second prime must carry over, not refill");
    }

    /// @dev Lowering capacity clamps carried allowance (covers the `_min` clamp).
    function test_configure_clampsCarriedAllowanceToNewCapacity() public {
        _prime(CAP, RATE);
        harness.spend(400, TOKEN); // tokens -> 600
        harness.configure(_enabled(500, RATE)); // new cap 500 < carried 600
        assertEq(harness.read().tokens, 500, "carried allowance clamped to new capacity");
        assertEq(harness.read().capacity, 500);
    }

    /// @dev Raising capacity keeps carried allowance unchanged (other `_min` arm).
    function test_configure_keepsCarriedWhenBelowNewCapacity() public {
        _prime(CAP, RATE);
        harness.spend(400, TOKEN); // tokens -> 600
        harness.configure(_enabled(2_000, RATE)); // new cap 2000 > carried 600
        assertEq(harness.read().tokens, 600, "carried allowance preserved below new capacity");
        assertEq(harness.read().capacity, 2_000);
    }

    function test_configure_emitsSettingsChanged() public {
        OutflowRateLimiter.Settings memory s = _enabled(CAP, RATE);
        vm.expectEmit(false, false, false, true, address(harness));
        emit OutflowRateLimiter.LimitSettingsChanged(s);
        harness.configure(s);
    }

    function test_spend_disabledBucketReverts() public {
        vm.expectRevert(OutflowRateLimiter.LimitNotConfigured.selector);
        harness.spend(1, TOKEN);
    }

    /// @dev Covers the `amount == 0` early return: no state change, no event.
    function test_spend_zeroAmountIsNoop() public {
        _prime(CAP, RATE);
        uint32 lastUpdatedBefore = harness.read().lastUpdated;

        vm.recordLogs();
        harness.spend(0, TOKEN);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "zero-amount spend must emit nothing");
        assertEq(harness.read().tokens, CAP, "tokens unchanged");
        assertEq(harness.read().lastUpdated, lastUpdatedBefore, "lastUpdated unchanged");
    }

    function test_spend_amountAboveCapacityTokenReverts() public {
        _prime(CAP, RATE);
        vm.expectRevert(
            abi.encodeWithSelector(OutflowRateLimiter.TokenRequestAboveCapacity.selector, CAP, CAP + 1, TOKEN)
        );
        harness.spend(CAP + 1, TOKEN);
    }

    /// @dev Covers the aggregate-scope (`token == address(0)`) above-capacity arm.
    function test_spend_amountAboveCapacityAggregateReverts() public {
        _prime(CAP, RATE);
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.AggregateRequestAboveCapacity.selector, CAP, CAP + 1));
        harness.spend(CAP + 1, AGGREGATE);
    }

    function test_spend_throttledTokenReportsRetryAfter() public {
        _prime(CAP, RATE);
        harness.spend(400, TOKEN); // available -> 600, same block (no refill)

        // request 800 > available 600; retryAfter = ceil((800-600)/10) = 20
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.TokenOutflowThrottled.selector, 20, 600, TOKEN));
        harness.spend(800, TOKEN);
    }

    function test_spend_throttledAggregateReportsRetryAfter() public {
        _prime(CAP, RATE);
        harness.spend(400, AGGREGATE); // available -> 600

        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.AggregateOutflowThrottled.selector, 20, 600));
        harness.spend(800, AGGREGATE);
    }

    function test_spend_debitsAllowanceAndEmits() public {
        _prime(CAP, RATE);

        vm.expectEmit(false, false, false, true, address(harness));
        emit OutflowRateLimiter.AllowanceSpent(400);
        harness.spend(400, TOKEN);

        assertEq(harness.read().tokens, 600, "debited");
        assertEq(harness.read().lastUpdated, uint32(vm.getBlockTimestamp()), "timestamp persisted");
    }

    /// @dev Partial refill: available grows by `elapsed * rate` below capacity.
    function test_spend_usesPartialRefill() public {
        _prime(CAP, RATE);
        harness.spend(CAP, TOKEN); // drain to 0
        assertEq(harness.read().tokens, 0);

        vm.warp(vm.getBlockTimestamp() + 50); // +50s -> +500 available (still < capacity)
        harness.spend(500, TOKEN); // exactly the refilled amount
        assertEq(harness.read().tokens, 0, "spent all refilled allowance");
    }

    /// @dev Refill caps at capacity once enough time elapses.
    function test_refill_capsAtCapacity() public {
        _prime(CAP, RATE);
        harness.spend(CAP, TOKEN); // drain to 0

        vm.warp(vm.getBlockTimestamp() + 10_000); // far beyond full-refill horizon
        assertEq(harness.currentState().tokens, CAP, "refill must cap at capacity");
        harness.spend(CAP, TOKEN); // a full-capacity spend now succeeds
        assertEq(harness.read().tokens, 0);
    }

    /// @dev `currentState` returns the refill-adjusted view WITHOUT persisting,
    ///      and exercises the explicit `return` of the view helper.
    function test_currentState_returnsPreviewWithoutPersisting() public {
        _prime(CAP, RATE);
        harness.spend(400, TOKEN); // tokens -> 600
        uint32 persistedTs = harness.read().lastUpdated;

        vm.warp(vm.getBlockTimestamp() + 5); // +5s -> +50 available
        OutflowRateLimiter.Bucket memory preview = harness.currentState();

        assertEq(preview.tokens, 650, "preview reflects accrued refill");
        assertEq(preview.lastUpdated, uint32(vm.getBlockTimestamp()), "preview stamps now");
        // storage is untouched by the view call
        assertEq(harness.read().tokens, 600, "storage tokens not mutated");
        assertEq(harness.read().lastUpdated, persistedTs, "storage timestamp not mutated");
    }

    function test_preview_elapsedZeroReturnsAvailable() public {
        _prime(CAP, RATE);
        harness.spend(400, TOKEN); // tokens -> 600, same block
        assertEq(harness.currentState().tokens, 600, "no elapsed time -> no refill");
    }

    function test_preview_atCapacityNoRefill() public {
        _prime(CAP, RATE); // full at capacity
        vm.warp(vm.getBlockTimestamp() + 100);
        assertEq(harness.currentState().tokens, CAP, "already full stays at capacity");
    }

    /// @dev Covers `StoredAllowanceAboveCapacity`: a persisted allowance above
    ///      capacity (only constructable via raw setup) must revert on read.
    function test_preview_storedAllowanceAboveCapacityReverts() public {
        harness.setRaw(2_000, uint32(vm.getBlockTimestamp()), true, CAP, RATE); // tokens 2000 > cap 1000
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.StoredAllowanceAboveCapacity.selector, 2_000, CAP));
        harness.currentState();
    }

    function test_asUint128_atMaxPasses() public view {
        assertEq(harness.asUint128(uint256(type(uint128).max)), type(uint128).max);
    }

    /// @dev Covers the defensive `AmountExceedsUint128` guard. Unreachable via
    ///      the public API (all inputs are `uint128`-bounded); driven directly.
    function test_asUint128_aboveMaxReverts() public {
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.AmountExceedsUint128.selector, tooBig));
        harness.asUint128(tooBig);
    }

    /// @dev A successful spend never pushes stored tokens above capacity and
    ///      never debits more than was available.
    function testFuzz_spend_withinBounds(uint128 capacity, uint128 rate, uint256 amount) public {
        capacity = uint128(bound(capacity, 2, type(uint128).max));
        rate = uint128(bound(rate, 1, capacity - 1)); // satisfy validate(): 0 < rate < capacity
        amount = bound(amount, 1, capacity); // within capacity so it cannot exceed-capacity revert

        _prime(capacity, rate); // primed full -> available == capacity >= amount
        harness.spend(amount, TOKEN);

        OutflowRateLimiter.Bucket memory b = harness.read();
        assertLe(b.tokens, capacity, "tokens never exceed capacity");
        assertEq(b.tokens, capacity - uint128(amount), "debit is exact");
    }

    /// @dev Both previews equal min(elapsed * RATE, CAP), remain monotonic and
    ///      grow while unsaturated. Sampling mixes short and full uint32 spans.
    function testFuzz_refill_isMonotonicAndCapped(uint32 earlySeed, uint32 laterSeed) public {
        _prime(CAP, RATE);
        harness.spend(CAP, TOKEN);
        uint256 start = vm.getBlockTimestamp();
        uint256 earlyElapsed = earlySeed % 2 == 0 ? bound(uint256(earlySeed), 0, CAP / RATE) : uint256(earlySeed);
        uint256 shortHorizon = earlyElapsed + CAP / RATE;
        if (shortHorizon > type(uint32).max) shortHorizon = type(uint32).max;
        uint256 laterElapsed = laterSeed % 2 == 0
            ? bound(uint256(laterSeed), earlyElapsed, shortHorizon)
            : bound(uint256(laterSeed), earlyElapsed, type(uint32).max);
        vm.warp(start + earlyElapsed);
        uint256 earlyAvailable = harness.currentState().tokens;
        vm.warp(start + laterElapsed);
        uint256 laterAvailable = harness.currentState().tokens;
        uint256 earlyExpected = earlyElapsed * RATE;
        uint256 laterExpected = laterElapsed * RATE;
        assertEq(earlyAvailable, earlyExpected < CAP ? earlyExpected : CAP, "early refill has the configured rate");
        assertEq(laterAvailable, laterExpected < CAP ? laterExpected : CAP, "later refill has the configured rate");
        assertLe(earlyAvailable, CAP, "early refill remains capped");
        assertLe(laterAvailable, CAP, "later refill remains capped");
        assertGe(laterAvailable, earlyAvailable, "time cannot reduce allowance");
        if (laterElapsed > earlyElapsed && earlyAvailable < CAP) {
            assertGt(laterAvailable, earlyAvailable, "positive elapsed time refills an unsaturated bucket");
        }
    }
}
