// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OutflowRateLimiter} from "../src/libraries/OutflowRateLimiter.sol";
import {OutflowRateLimiterHarness} from "./mocks/OutflowRateLimiterHarness.sol";

/// @title OutflowRateLimiterTest
/// @notice Standalone unit tests for the `OutflowRateLimiter` token-bucket
///         library, driven through `OutflowRateLimiterHarness` — no `Bridge`.
///
/// @dev    Bridge integration tests prove the limiter is wired correctly; these
///         tests prove the library's own arithmetic in isolation: refill
///         accrual, capacity clamping, throttle `retryAfter`, the config
///         validation rules, and the defensive narrowing/stored-state guards.
contract OutflowRateLimiterTest is Test {
    OutflowRateLimiterHarness harness;

    address constant TOKEN = address(0xBEEF);
    address constant AGGREGATE = address(0); // sentinel selecting aggregate-scope errors

    uint128 constant CAP = 1_000;
    uint128 constant RATE = 10;

    function setUp() public {
        harness = new OutflowRateLimiterHarness();
        // Start at a non-zero timestamp so `lastUpdated` casts are meaningful.
        vm.warp(1_000_000);
    }

    // -------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------

    function _enabled(uint128 capacity, uint128 rate) internal pure returns (OutflowRateLimiter.Settings memory) {
        return OutflowRateLimiter.Settings({isEnabled: true, capacity: capacity, rate: rate});
    }

    function _disabled() internal pure returns (OutflowRateLimiter.Settings memory) {
        return OutflowRateLimiter.Settings({isEnabled: false, capacity: 0, rate: 0});
    }

    function _prime(uint128 capacity, uint128 rate) internal {
        harness.configurePrimed(_enabled(capacity, rate));
    }

    // =========================================================================
    // validate
    // =========================================================================

    function test_validate_enabled_validConfig_passes() public view {
        harness.validate(_enabled(CAP, RATE), false); // no revert
    }

    function test_validate_enabled_zeroCapacity_reverts() public {
        OutflowRateLimiter.Settings memory s = _enabled(0, RATE);
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.InvalidLimitConfig.selector, s));
        harness.validate(s, false);
    }

    function test_validate_enabled_zeroRate_reverts() public {
        OutflowRateLimiter.Settings memory s = _enabled(CAP, 0);
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.InvalidLimitConfig.selector, s));
        harness.validate(s, false);
    }

    function test_validate_enabled_rateGteCapacity_reverts() public {
        OutflowRateLimiter.Settings memory s = _enabled(CAP, CAP); // rate >= capacity
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.InvalidLimitConfig.selector, s));
        harness.validate(s, false);
    }

    function test_validate_disabled_clean_passes() public view {
        harness.validate(_disabled(), false); // no revert
    }

    /// @dev Covers `DisabledLimitHasValues`: disabled flag but non-zero fields.
    function test_validate_disabled_withValues_reverts() public {
        OutflowRateLimiter.Settings memory s = OutflowRateLimiter.Settings({isEnabled: false, capacity: 5, rate: 0});
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.DisabledLimitHasValues.selector, s));
        harness.validate(s, false);
    }

    /// @dev Covers `LimitMustStayDisabled`: `mustBeDisabled` set while enabled.
    function test_validate_mustBeDisabled_butEnabled_reverts() public {
        vm.expectRevert(OutflowRateLimiter.LimitMustStayDisabled.selector);
        harness.validate(_enabled(CAP, RATE), true);
    }

    function test_validate_mustBeDisabled_andDisabled_passes() public view {
        harness.validate(_disabled(), true); // no revert
    }

    // =========================================================================
    // configurePrimed / configure
    // =========================================================================

    function test_configurePrimed_firstEnable_fillsToCapacity() public {
        _prime(CAP, RATE);
        assertEq(harness.read().tokens, CAP, "first enable should fill to capacity");
        assertTrue(harness.read().isEnabled);
    }

    /// @dev Re-priming an already-enabled bucket must NOT refill to capacity.
    function test_configurePrimed_alreadyEnabled_doesNotRefill() public {
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

    // =========================================================================
    // spend — guards
    // =========================================================================

    function test_spend_disabledBucket_reverts() public {
        vm.expectRevert(OutflowRateLimiter.LimitNotConfigured.selector);
        harness.spend(1, TOKEN);
    }

    /// @dev Covers the `amount == 0` early return: no state change, no event.
    function test_spend_zeroAmount_isNoop() public {
        _prime(CAP, RATE);
        uint32 lastUpdatedBefore = harness.read().lastUpdated;

        vm.recordLogs();
        harness.spend(0, TOKEN);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "zero-amount spend must emit nothing");
        assertEq(harness.read().tokens, CAP, "tokens unchanged");
        assertEq(harness.read().lastUpdated, lastUpdatedBefore, "lastUpdated unchanged");
    }

    function test_spend_amountAboveCapacity_token_reverts() public {
        _prime(CAP, RATE);
        vm.expectRevert(
            abi.encodeWithSelector(OutflowRateLimiter.TokenRequestAboveCapacity.selector, CAP, CAP + 1, TOKEN)
        );
        harness.spend(CAP + 1, TOKEN);
    }

    /// @dev Covers the aggregate-scope (`token == address(0)`) above-capacity arm.
    function test_spend_amountAboveCapacity_aggregate_reverts() public {
        _prime(CAP, RATE);
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.AggregateRequestAboveCapacity.selector, CAP, CAP + 1));
        harness.spend(CAP + 1, AGGREGATE);
    }

    function test_spend_throttled_token_reportsRetryAfter() public {
        _prime(CAP, RATE);
        harness.spend(400, TOKEN); // available -> 600, same block (no refill)

        // request 800 > available 600; retryAfter = ceil((800-600)/10) = 20
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.TokenOutflowThrottled.selector, 20, 600, TOKEN));
        harness.spend(800, TOKEN);
    }

    function test_spend_throttled_aggregate_reportsRetryAfter() public {
        _prime(CAP, RATE);
        harness.spend(400, AGGREGATE); // available -> 600

        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.AggregateOutflowThrottled.selector, 20, 600));
        harness.spend(800, AGGREGATE);
    }

    // =========================================================================
    // spend — happy path & refill
    // =========================================================================

    function test_spend_happyPath_debitsAndEmits() public {
        _prime(CAP, RATE);

        vm.expectEmit(false, false, false, true, address(harness));
        emit OutflowRateLimiter.AllowanceSpent(400);
        harness.spend(400, TOKEN);

        assertEq(harness.read().tokens, 600, "debited");
        assertEq(harness.read().lastUpdated, uint32(block.timestamp), "timestamp persisted");
    }

    /// @dev Partial refill: available grows by `elapsed * rate` below capacity.
    function test_spend_usesPartialRefill() public {
        _prime(CAP, RATE);
        harness.spend(CAP, TOKEN); // drain to 0
        assertEq(harness.read().tokens, 0);

        vm.warp(block.timestamp + 50); // +50s -> +500 available (still < capacity)
        harness.spend(500, TOKEN); // exactly the refilled amount
        assertEq(harness.read().tokens, 0, "spent all refilled allowance");
    }

    /// @dev Refill caps at capacity once enough time elapses.
    function test_refill_capsAtCapacity() public {
        _prime(CAP, RATE);
        harness.spend(CAP, TOKEN); // drain to 0

        vm.warp(block.timestamp + 10_000); // far beyond full-refill horizon
        assertEq(harness.currentState().tokens, CAP, "refill must cap at capacity");
        harness.spend(CAP, TOKEN); // a full-capacity spend now succeeds
        assertEq(harness.read().tokens, 0);
    }

    // =========================================================================
    // currentState / _preview
    // =========================================================================

    /// @dev `currentState` returns the refill-adjusted view WITHOUT persisting,
    ///      and exercises the explicit `return` of the view helper.
    function test_currentState_returnsPreviewWithoutPersisting() public {
        _prime(CAP, RATE);
        harness.spend(400, TOKEN); // tokens -> 600
        uint32 persistedTs = harness.read().lastUpdated;

        vm.warp(block.timestamp + 5); // +5s -> +50 available
        OutflowRateLimiter.Bucket memory preview = harness.currentState();

        assertEq(preview.tokens, 650, "preview reflects accrued refill");
        assertEq(preview.lastUpdated, uint32(block.timestamp), "preview stamps now");
        // storage is untouched by the view call
        assertEq(harness.read().tokens, 600, "storage tokens not mutated");
        assertEq(harness.read().lastUpdated, persistedTs, "storage timestamp not mutated");
    }

    function test_preview_elapsedZero_returnsAvailable() public {
        _prime(CAP, RATE);
        harness.spend(400, TOKEN); // tokens -> 600, same block
        assertEq(harness.currentState().tokens, 600, "no elapsed time -> no refill");
    }

    function test_preview_atCapacity_noRefill() public {
        _prime(CAP, RATE); // full at capacity
        vm.warp(block.timestamp + 100);
        assertEq(harness.currentState().tokens, CAP, "already full stays at capacity");
    }

    /// @dev Covers `StoredAllowanceAboveCapacity`: a persisted allowance above
    ///      capacity (only constructable via raw setup) must revert on read.
    function test_preview_storedAllowanceAboveCapacity_reverts() public {
        harness.setRaw(2_000, uint32(block.timestamp), true, CAP, RATE); // tokens 2000 > cap 1000
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.StoredAllowanceAboveCapacity.selector, 2_000, CAP));
        harness.currentState();
    }

    // =========================================================================
    // _asUint128 narrowing guard
    // =========================================================================

    function test_asUint128_atMax_passes() public view {
        assertEq(harness.asUint128(uint256(type(uint128).max)), type(uint128).max);
    }

    /// @dev Covers the defensive `AmountExceedsUint128` guard. Unreachable via
    ///      the public API (all inputs are `uint128`-bounded); driven directly.
    function test_asUint128_aboveMax_reverts() public {
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.AmountExceedsUint128.selector, tooBig));
        harness.asUint128(tooBig);
    }

    // =========================================================================
    // fuzz invariants
    // =========================================================================

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

    /// @dev Refill is monotonic in elapsed time and clamps at capacity.
    function testFuzz_refill_monotonicAndCapped(uint32 elapsed) public {
        _prime(CAP, RATE);
        harness.spend(CAP, TOKEN); // drain to 0
        uint256 ts = block.timestamp;
        vm.warp(ts + uint256(elapsed));

        uint256 available = harness.currentState().tokens;
        assertLe(available, CAP, "refill capped at capacity");
        // expected = min(elapsed * rate, capacity)
        uint256 expected = uint256(elapsed) * RATE;
        if (expected > CAP) expected = CAP;
        assertEq(available, expected, "refill equals elapsed * rate, capped");
    }
}
