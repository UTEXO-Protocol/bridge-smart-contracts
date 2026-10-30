// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {OutflowRateLimiter} from "../../src/libraries/OutflowRateLimiter.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Rolling outflow allowances track releases and current liquidity.
contract BridgeRollingOutflowTest is BridgeTestBase {
    function test_outflowAccounting_usageCannotExpireBefore24HoursAndNewLimitUsesLowerTvl() public {
        // Align to a ring slot boundary so expiry happens exactly at H+25.
        vm.warp((vm.getBlockTimestamp() / 1 hours + 1) * 1 hours);
        uint256 bucketBurst = 100e6;
        _seedRGB(bucketBurst); // deposits 1000e6; bucket 10%, hard limit 20%

        assertEq(bridge.totalLockedLiquidity(), 1_000e6);
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 200e6);
        assertEq(bridge.availableGlobalSafetyOutflow(), 200e6);

        _releaseRGBTo(makeAddr("rolling-window-first"), bucketBurst, keccak256("RollingOutflow.t-release-10"));
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 100e6);
        assertEq(bridge.availableGlobalSafetyOutflow(), 100e6);

        // Hour-slot rounding is deliberately conservative: usage is still
        // counted at exactly 24 hours, preventing a boundary double-spend.
        vm.warp(vm.getBlockTimestamp() + bridge.OUTFLOW_SAFETY_WINDOW());
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 100e6);
        assertEq(bridge.availableGlobalSafetyOutflow(), 100e6);

        // One extra second fully restores the slightly conservative, integer-
        // rounded bucket refill while the first rolling-window spend remains.
        // The bucket is now 10% of the actual 900 liquidity, so the next tranche
        // is 90 rather than 100; rolling usage affects only the safety limiter.
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 secondTranche = 90e6;
        _releaseRGBTo(makeAddr("rolling-window-second"), secondTranche, keccak256("RollingOutflow.t-release-9"));
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 10e6);
        assertEq(bridge.availableGlobalSafetyOutflow(), 10e6);

        // At H+25 the first spend expires but the second remains. The bucket
        // reference stays at actual locked liquidity (810). The independent
        // safety reference is 810 + 90 = 900, so its 20% limit is 180 with 90
        // still consumed: 90 remains.
        vm.warp(vm.getBlockTimestamp() + 1 hours - 1);
        uint256 nextWindowSafetyLimit = 90e6;
        assertEq(bridge.chainOutflowReference(RGB_CHAIN_ID), 810e6, "bucket reference is actual liquidity");
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), nextWindowSafetyLimit);
        assertEq(bridge.availableGlobalSafetyOutflow(), nextWindowSafetyLimit);

        // Liveness: after the second spend also expires, the bucket has refilled
        // and a new 10%-of-current-liquidity tranche can leave.
        vm.warp(vm.getBlockTimestamp() + bridge.OUTFLOW_SAFETY_WINDOW());
        uint256 thirdTranche = 81e6;
        assertEq(bridge.chainOutflowReference(RGB_CHAIN_ID), 810e6);
        assertEq(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), thirdTranche);
        _releaseRGBTo(makeAddr("rolling-window-third"), thirdTranche, keccak256("RollingOutflow.t-release-8"));
        assertEq(bridge.totalLockedLiquidity(), 729e6);
    }

    /// @dev After an earlier release has reduced actual liquidity, the bucket prices
    ///      every later request against that lower liquidity immediately. The
    ///      rolling slot can expire and change the safety allowance, but cannot
    ///      make the bucket's reference or full allowance step down again.
    function test_outflowAccounting_bucketCapacityDoesNotDecayWhenRollingUsageExpires() public {
        vm.warp((vm.getBlockTimestamp() / 1 hours + 1) * 1 hours);
        uint256 startedAt = vm.getBlockTimestamp();
        _seedRGB(100e6); // 1,000 liquidity, 10% bucket

        _releaseRGBTo(makeAddr("first"), 100e6, keccak256("RollingOutflow.t-release-7"));
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 900e6);

        vm.warp(startedAt + 24 hours + 1 minutes);
        assertEq(bridge.chainOutflowReference(RGB_CHAIN_ID), 900e6, "pre-expiry bucket reference");
        assertEq(bridge.globalOutflowReference(), 900e6, "pre-expiry global reference");
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 90e6, "pre-expiry chain capacity");
        assertEq(bridge.availableGlobalOutflow(), 90e6, "pre-expiry global capacity");

        uint256 snapshot = vm.snapshotState();
        _releaseRGBTo(makeAddr("before-expiry"), 90e6, keccak256("RollingOutflow.t-release-6"));
        assertTrue(vm.revertToState(snapshot));

        vm.warp(startedAt + 25 hours);
        assertEq(bridge.chainOutflowReference(RGB_CHAIN_ID), 900e6, "post-expiry bucket reference");
        assertEq(bridge.globalOutflowReference(), 900e6, "post-expiry global reference");
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 90e6, "post-expiry chain capacity");
        assertEq(bridge.availableGlobalOutflow(), 90e6, "post-expiry global capacity");
        assertEq(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), 90e6, "effective allowance is stable");

        _releaseRGBTo(makeAddr("after-expiry"), 90e6, keccak256("RollingOutflow.t-release-5"));
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 810e6, "same tranche remains executable");
    }

    function test_outflowAccounting_directTokenDonationCannotInflateGlobalSafetyAllowance() public {
        _seedRGB(100e6); // accounted TVL 1000e6; global hard limit 200
        uint256 beforeAllowance = bridge.availableGlobalSafetyOutflow();

        usdt0.mint(address(bridge), 10_000e6);

        assertEq(bridge.totalLockedLiquidity(), 1_000e6, "donation excluded from accounted TVL");
        assertEq(
            bridge.availableGlobalSafetyOutflow(),
            beforeAllowance,
            "unaccounted token donation cannot increase the security allowance"
        );
    }

    /// @dev However the attacker splits the drain, the total leaving inside one
    ///      rolling window never exceeds 20% of the window's reference. The two
    ///      parts are not required to sum to exactly the cap: converting each
    ///      release into shares rounds up, so splitting can cost a sub-share more
    ///      than one combined release. That is the conservative direction, and
    ///      the aggregate bound is what this asserts.
    function testFuzz_rollingOutflow_arbitrarySplitCannotExceedRollingLimit(uint96 firstPartSeed) public {
        vm.warp((vm.getBlockTimestamp() / 1 hours + 1) * 1 hours);
        _seedRGB(100e6); // chain liquidity 1000; bucket burst 100; hard limit 200
        uint256 poolBefore = usdt0.balanceOf(address(bridge));
        uint256 hardLimit = bridge.availableChainSafetyOutflow(RGB_CHAIN_ID); // 20% of reference
        uint256 initialBucketAllowance = bridge.effectiveAvailableOutflow(RGB_CHAIN_ID);

        uint256 firstPart = bound(uint256(firstPartSeed), 1, initialBucketAllowance);

        // Distinct source burn transaction IDs keep releases independent,
        // even when two fuzzed amounts happen to be equal.
        _releaseRGBTo(makeAddr("rolling-limit-first"), firstPart, keccak256("RollingOutflow.t-release-4"));

        // The reference does not move inside the window, so the remaining
        // immutable allowance is exactly the complement of the first part.
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), hardLimit - firstPart, "complement remains");
        assertEq(bridge.availableGlobalSafetyOutflow(), hardLimit - firstPart, "global complement remains");

        // Refill the configurable bucket while the first spend is still inside
        // the conservative rolling window, then take everything still permitted.
        vm.warp(vm.getBlockTimestamp() + bridge.BUCKET_REFILL_WINDOW() + 1);
        uint256 secondPart = bridge.effectiveAvailableOutflow(RGB_CHAIN_ID);
        if (secondPart != 0) {
            _releaseRGBTo(makeAddr("rolling-limit-second"), secondPart, keccak256("RollingOutflow.t-release-3"));
        }

        // However the drain is split, the pool never loses more than 20% of the
        // window's reference, and nothing further may leave.
        assertLe(firstPart + secondPart, hardLimit, "rolling cap never exceeded");
        assertEq(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), 0, "allowance exhausted");
        assertGe(usdt0.balanceOf(address(bridge)), poolBefore - hardLimit, "at least 80% of the pool remains");

        // This property checks the aggregate bound. Deterministic split-release
        // cases in ReplayProtection and OutflowSafety assert the exact
        // immutable-limiter rejection.
    }

    /// @dev The global rolling window aggregates physical outflow from every
    ///      source chain. Two chains may each consume their own allowance, but
    ///      splitting a drain across chains cannot bypass the global accounting.
    function test_outflowAccounting_globalRollingUsageAggregatesAcrossSourceChains() public {
        vm.warp((vm.getBlockTimestamp() / 1 hours + 1) * 1 hours);

        uint256 otherChain = 888;
        vm.startPrank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, otherChain, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(otherChain, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        vm.stopPrank();

        usdt0.mint(user, 1_000e6);
        vm.prank(user);
        bytes32 otherOpId = bridge.fundsIn(1_000e6, otherChain, DST_ADDR, _rgbData(RGB_OP_ID + otherChain));

        _seedRGB(100e6); // 1000 RGB + 1000 other; 10% bucket bursts
        vm.prank(multisig);
        bridge.setOutflowLimit(otherChain, MAX_BURST_BPS, MAX_REFILL_BPS);

        assertEq(bridge.availableGlobalOutflow(), 200e6, "global bucket is 10% of aggregate TVL");
        assertEq(bridge.availableGlobalSafetyOutflow(), 400e6, "global hard cap is 20% of aggregate TVL");

        bytes32[] memory otherIds = _ids(otherOpId);
        bytes memory otherSettlement = _settlement(otherIds);

        uint256 firstRgb = 100e6;
        uint256 firstOther = 95e6;
        _releaseRGBTo(makeAddr("aggregate-rgb-1"), firstRgb, keccak256("RollingOutflow.t-release-2"));
        vm.prank(multisig);
        _fundsOut(
            makeAddr("aggregate-other-1"),
            firstOther,
            otherChain,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            otherSettlement,
            SRC_BURN_TX_ID
        );

        assertEq(bridge.availableGlobalOutflow(), 0, "both chains consume one global bucket");
        assertEq(bridge.availableGlobalSafetyOutflow(), 400e6 - firstRgb - firstOther, "hard allowance aggregates");

        // Buckets refill after 24h, but the aligned rolling window retains both
        // first releases until H+25. Current-liquidity pricing makes each later
        // tranche slightly smaller; rolling safety accounting still aggregates
        // both source chains independently of that pricing.
        vm.warp(vm.getBlockTimestamp() + bridge.BUCKET_REFILL_WINDOW() + 1);
        uint256 secondRgb = 90e6;
        _releaseRGBTo(makeAddr("aggregate-rgb-2"), secondRgb, keccak256("RollingOutflow.t-release-1"));
        uint256 secondOther = bridge.effectiveAvailableOutflow(otherChain) - 1;
        vm.prank(multisig);
        _fundsOut(
            makeAddr("aggregate-other-2"),
            secondOther,
            otherChain,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            otherSettlement,
            SRC_BURN_TX_ID
        );

        uint256 totalReleased = firstRgb + firstOther + secondRgb + secondOther;
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 200e6 - firstRgb - secondRgb);
        assertEq(bridge.availableChainSafetyOutflow(otherChain), 200e6 - firstOther - secondOther);
        assertEq(bridge.availableGlobalSafetyOutflow(), 400e6 - totalReleased, "aggregate usage includes both chains");
        assertEq(bridge.totalLockedLiquidity(), 2_000e6 - totalReleased);

        vm.warp(vm.getBlockTimestamp() + 1);
        assertLe(
            bridge.effectiveAvailableOutflow(RGB_CHAIN_ID),
            bridge.availableGlobalSafetyOutflow(),
            "global rolling ceiling cannot be bypassed by chain splitting"
        );
    }

    function test_outflowAccounting_crossChainOutflowRepricesGlobalAllowanceAgainstCurrentLiquidity() public {
        vm.warp((vm.getBlockTimestamp() / 1 hours + 1) * 1 hours);

        uint256 otherChain = 888;
        vm.startPrank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, otherChain, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(otherChain, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        vm.stopPrank();

        usdt0.mint(user, 1_000e6);
        vm.prank(user);
        bytes32 otherOpId = bridge.fundsIn(1_000e6, otherChain, DST_ADDR, _rgbData(RGB_OP_ID + otherChain));

        _seedRGB(100e6); // 1,000 RGB + 1,000 other
        vm.startPrank(multisig);
        bridge.setOutflowLimit(otherChain, 1_000, 1_000); // 10% chain burst
        bridge.setGlobalOutflowLimit(500, 1_500); // intentionally stricter 5% global burst
        vm.stopPrank();

        uint256 quotedForOther = bridge.effectiveAvailableOutflow(otherChain);
        assertEq(quotedForOther, 100e6, "initial global capacity is 5% of 2,000");

        // A release from RGB consumes the global bucket and reduces actual
        // aggregate liquidity, without changing the other chain's liquidity.
        _releaseRGBTo(makeAddr("cross-chain-rgb"), 100e6, keccak256("RollingOutflow.t-release-0"));
        assertEq(bridge.lockedLiquidity(otherChain), 1_000e6, "other chain liquidity unchanged");
        assertEq(bridge.globalOutflowReference(), 1_900e6, "real outflow reprices global reference");
        assertEq(bridge.effectiveAvailableOutflow(otherChain), 0, "spent global bucket blocks other chain");

        // Once the bucket refills, the old 100-token quote is above the new 5%
        // capacity. This is expected stale-state handling: the current getter
        // reports 95, which remains executable and respects aggregate policy.
        vm.warp(vm.getBlockTimestamp() + bridge.BUCKET_REFILL_WINDOW() + 1);
        uint256 currentAllowance = bridge.effectiveAvailableOutflow(otherChain);
        assertEq(currentAllowance, 95e6, "fresh quote follows current aggregate liquidity");

        uint256 capacityShares = 500 * bridge.SHARE_UNIT() / bridge.BPS_DENOMINATOR();
        uint256 requestedShares = (quotedForOther * bridge.SHARE_UNIT() + bridge.globalOutflowReference() - 1)
            / bridge.globalOutflowReference();
        bytes memory otherSettlement = _settlement(_ids(otherOpId));

        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.AggregateRequestAboveCapacity.selector, capacityShares, requestedShares
            )
        );
        vm.prank(multisig);
        _fundsOut(
            makeAddr("stale-other"),
            quotedForOther,
            otherChain,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            otherSettlement,
            SRC_BURN_TX_ID
        );

        vm.prank(multisig);
        _fundsOut(
            makeAddr("fresh-other"),
            currentAllowance,
            otherChain,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            otherSettlement,
            SRC_BURN_TX_ID
        );

        assertEq(bridge.totalLockedLiquidity(), 1_805e6, "aggregate accounting includes both releases");
        assertEq(bridge.availableGlobalOutflow(), 0, "fresh release consumes the refilled global burst");
        assertEq(bridge.availableGlobalSafetyOutflow(), 205e6, "immutable aggregate safety remains enforced");
    }
}
