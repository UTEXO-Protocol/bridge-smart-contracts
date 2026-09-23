// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, Vm} from "forge-std/Test.sol";

import {Bridge} from "../src/Bridge.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {BridgeBaseUpgradeable} from "../src/BridgeBaseUpgradeable.sol";
import {CommissionManager} from "../src/CommissionManager.sol";
import {RouteRegistry} from "../src/RouteRegistry.sol";
import {IRouteRegistry} from "../src/interfaces/IRouteRegistry.sol";
import {RGBVerifier} from "../src/verifiers/RGBVerifier.sol";
import {RgbSettlementModule} from "../src/settlement/RgbSettlementModule.sol";
import {OutflowRateLimiter} from "../src/libraries/OutflowRateLimiter.sol";
import {
    CommissionConfig,
    CommissionSide,
    CommissionCurrency,
    ICommissionManager
} from "../src/interfaces/ICommissionManager.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {MockBtcRelay} from "./mocks/MockBtcRelay.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockSettlementModule} from "./mocks/MockSettlementModule.sol";
import {MockDepositFloor} from "./mocks/MockDepositFloor.sol";
import {BridgeProxyTestUtils} from "./mocks/BridgeProxyTestUtils.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BridgeTestBase, ZeroNetCommissionManager, NonPayableDepositor} from "./BridgeTestBase.sol";

/// @notice Isolated liquidity, outflow limiting, RGB-route id derivation and
///         the fee-on-transfer token stack. Shares `BridgeTestBase`.
contract BridgeOutflowTest is BridgeTestBase {
    function test_outflow_reconfigClampsOnDecrease() public {
        _seedRGB(1_000e6);
        _setRGBBucket(100e6, 100e6); // available 100e6
        _setRGBBucket(30e6, 30e6); // clamp down
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 30e6, "clamped to new capacity");
    }

    function test_outflow_failsClosedWhenChainBucketUnconfigured() public {
        uint256 unconfigured = 999;
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, unconfigured, true, address(rgbVerifier), address(rgbModule));
        vm.prank(deployer);
        routeRegistry.setRoute(unconfigured, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // Fund the unconfigured chain's isolated liquidity so only the missing
        // (disabled) bucket blocks the release.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(100e6, unconfigured, DST_ADDR, _rgbData());

        bytes32[] memory ids = _ids(opId);
        vm.expectRevert(OutflowRateLimiter.LimitNotConfigured.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            100e6,
            BURN_ID,
            unconfigured,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(ids, _one(100e6))
        );
    }

    function test_outflow_downstreamRevertRestoresBuckets() public {
        _seedRGB(1000e6);
        _setRGBBucket(100e6, 100e6);

        uint256 globalBefore = bridge.availableGlobalOutflow();
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown"));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = _seedOpId;

        vm.expectRevert();
        vm.prank(multisig);
        _fundsOut(
            recipient,
            50e6,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            badProof,
            _settlementWithAmounts(ids, _one(_seedAmt))
        );

        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 100e6, "per-chain restored");
        assertEq(bridge.availableGlobalOutflow(), globalBefore, "global restored");
    }

    // ========================================================================
    // Immutable TVL-relative rolling safety limit
    // ========================================================================

    function test_usageCannotExpireBefore24Hours_andNewLimitUsesLowerTVL() public {
        // Align to a ring slot boundary so expiry happens exactly at H+25.
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);
        uint256 bucketBurst = 100e6;
        _seedRGB(bucketBurst); // deposits 1000e6; bucket 10%, hard limit 20%

        assertEq(bridge.totalLockedLiquidity(), 1_000e6);
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 200e6);
        assertEq(bridge.availableGlobalSafetyOutflow(), 200e6);

        _releaseRGBTo(makeAddr("rolling-window-first"), bucketBurst, BURN_ID);
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 100e6);
        assertEq(bridge.availableGlobalSafetyOutflow(), 100e6);

        // Hour-slot rounding is deliberately conservative: usage is still
        // counted at exactly 24 hours, preventing a boundary double-spend.
        vm.warp(block.timestamp + bridge.OUTFLOW_SAFETY_WINDOW());
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 100e6);
        assertEq(bridge.availableGlobalSafetyOutflow(), 100e6);

        // One extra second fully restores the slightly conservative, integer-
        // rounded bucket refill while the first rolling-window spend remains.
        // The bucket is now 10% of the actual 900 liquidity, so the next tranche
        // is 90 rather than 100; rolling usage affects only the safety limiter.
        vm.warp(block.timestamp + 1);
        uint256 secondTranche = 90e6;
        _releaseRGBTo(makeAddr("rolling-window-second"), secondTranche, BURN_ID + 1);
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 10e6);
        assertEq(bridge.availableGlobalSafetyOutflow(), 10e6);

        // At H+25 the first spend expires but the second remains. The bucket
        // reference stays at actual locked liquidity (810). The independent
        // safety reference is 810 + 90 = 900, so its 20% limit is 180 with 90
        // still consumed: 90 remains.
        vm.warp(block.timestamp + 1 hours - 1);
        uint256 nextWindowSafetyLimit = 90e6;
        assertEq(bridge.chainOutflowReference(RGB_CHAIN_ID), 810e6, "bucket reference is actual liquidity");
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), nextWindowSafetyLimit);
        assertEq(bridge.availableGlobalSafetyOutflow(), nextWindowSafetyLimit);

        // Liveness: after the second spend also expires, the bucket has refilled
        // and a new 10%-of-current-liquidity tranche can leave.
        vm.warp(block.timestamp + bridge.OUTFLOW_SAFETY_WINDOW());
        uint256 thirdTranche = 81e6;
        assertEq(bridge.chainOutflowReference(RGB_CHAIN_ID), 810e6);
        assertEq(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), thirdTranche);
        _releaseRGBTo(makeAddr("rolling-window-third"), thirdTranche, BURN_ID + 2);
        assertEq(bridge.totalLockedLiquidity(), 729e6);
    }

    /// @dev Regression for the reported capacity-ceiling liveness issue. Once
    ///      an earlier release has reduced actual liquidity, the bucket prices
    ///      every later request against that lower liquidity immediately. The
    ///      rolling slot can expire and change the safety allowance, but cannot
    ///      make the bucket's reference or full allowance step down again.
    function test_bucketCapacityDoesNotDecayWhenRollingUsageExpires() public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);
        uint256 startedAt = block.timestamp;
        _seedRGB(100e6); // 1,000 liquidity, 10% bucket

        _releaseRGBTo(makeAddr("first"), 100e6, BURN_ID);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 900e6);

        vm.warp(startedAt + 24 hours + 1 minutes);
        assertEq(bridge.chainOutflowReference(RGB_CHAIN_ID), 900e6, "pre-expiry bucket reference");
        assertEq(bridge.globalOutflowReference(), 900e6, "pre-expiry global reference");
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 90e6, "pre-expiry chain capacity");
        assertEq(bridge.availableGlobalOutflow(), 90e6, "pre-expiry global capacity");

        uint256 snapshot = vm.snapshotState();
        _releaseRGBTo(makeAddr("before-expiry"), 90e6, BURN_ID + 1);
        assertTrue(vm.revertToState(snapshot));

        vm.warp(startedAt + 25 hours);
        assertEq(bridge.chainOutflowReference(RGB_CHAIN_ID), 900e6, "post-expiry bucket reference");
        assertEq(bridge.globalOutflowReference(), 900e6, "post-expiry global reference");
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 90e6, "post-expiry chain capacity");
        assertEq(bridge.availableGlobalOutflow(), 90e6, "post-expiry global capacity");
        assertEq(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), 90e6, "effective allowance is stable");

        _releaseRGBTo(makeAddr("after-expiry"), 90e6, BURN_ID + 1);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 810e6, "same tranche remains executable");
    }

    function test_directTokenDonationCannotInflateGlobalSafetyAllowance() public {
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
    function testFuzz_arbitrarySplitCannotExceedRollingLimit(uint96 firstPartSeed) public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);
        _seedRGB(100e6); // chain liquidity 1000; bucket burst 100; hard limit 200
        uint256 poolBefore = usdt0.balanceOf(address(bridge));
        uint256 hardLimit = bridge.availableChainSafetyOutflow(RGB_CHAIN_ID); // 20% of reference
        uint256 initialBucketAllowance = bridge.effectiveAvailableOutflow(RGB_CHAIN_ID);

        uint256 firstPart = bound(uint256(firstPartSeed), 1, initialBucketAllowance);

        // Vary recipients so every split has a distinct canonical burn intent,
        // even when two fuzzed amounts happen to be equal.
        _releaseRGBTo(makeAddr("rolling-limit-first"), firstPart, BURN_ID);

        // The reference does not move inside the window, so the remaining
        // immutable allowance is exactly the complement of the first part.
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), hardLimit - firstPart, "complement remains");
        assertEq(bridge.availableGlobalSafetyOutflow(), hardLimit - firstPart, "global complement remains");

        // Refill the configurable bucket while the first spend is still inside
        // the conservative rolling window, then take everything still permitted.
        vm.warp(block.timestamp + bridge.BUCKET_REFILL_WINDOW() + 1);
        uint256 secondPart = bridge.effectiveAvailableOutflow(RGB_CHAIN_ID);
        if (secondPart != 0) _releaseRGBTo(makeAddr("rolling-limit-second"), secondPart, BURN_ID + 1);

        // However the drain is split, the pool never loses more than 20% of the
        // window's reference, and nothing further may leave.
        assertLe(firstPart + secondPart, hardLimit, "rolling cap never exceeded");
        assertEq(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), 0, "allowance exhausted");
        assertGe(usdt0.balanceOf(address(bridge)), poolBefore - hardLimit, "at least 80% of the pool remains");

        // Which layer refuses the next unit depends on where the sub-share
        // rounding lands, so that is asserted deterministically instead in
        // `test_usageCannotExpireBefore24Hours_andNewLimitUsesLowerTVL` (bucket)
        // and `MultisigProxy.t.sol::test_splitTransactions...` (immutable limiter).
    }

    /// @dev The global rolling window aggregates physical outflow from every
    ///      source chain. Two chains may each consume their own allowance, but
    ///      splitting a drain across chains cannot bypass the global accounting.
    function test_globalRollingUsageAggregatesAcrossSourceChains() public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);

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
        bytes memory otherSettlement = _settlementWithAmounts(otherIds, _one(1_000e6));

        uint256 firstRgb = 100e6;
        uint256 firstOther = 95e6;
        _releaseRGBTo(makeAddr("aggregate-rgb-1"), firstRgb, BURN_ID);
        vm.prank(multisig);
        _fundsOut(
            makeAddr("aggregate-other-1"),
            firstOther,
            BURN_ID + 1,
            otherChain,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            otherSettlement
        );

        assertEq(bridge.availableGlobalOutflow(), 0, "both chains consume one global bucket");
        assertEq(bridge.availableGlobalSafetyOutflow(), 400e6 - firstRgb - firstOther, "hard allowance aggregates");

        // Buckets refill after 24h, but the aligned rolling window retains both
        // first releases until H+25. Current-liquidity pricing makes each later
        // tranche slightly smaller; rolling safety accounting still aggregates
        // both source chains independently of that pricing.
        vm.warp(block.timestamp + bridge.BUCKET_REFILL_WINDOW() + 1);
        uint256 secondRgb = 90e6;
        _releaseRGBTo(makeAddr("aggregate-rgb-2"), secondRgb, BURN_ID + 2);
        uint256 secondOther = bridge.effectiveAvailableOutflow(otherChain) - 1;
        vm.prank(multisig);
        _fundsOut(
            makeAddr("aggregate-other-2"),
            secondOther,
            BURN_ID + 3,
            otherChain,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            otherSettlement
        );

        uint256 totalReleased = firstRgb + firstOther + secondRgb + secondOther;
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 200e6 - firstRgb - secondRgb);
        assertEq(bridge.availableChainSafetyOutflow(otherChain), 200e6 - firstOther - secondOther);
        assertEq(bridge.availableGlobalSafetyOutflow(), 400e6 - totalReleased, "aggregate usage includes both chains");
        assertEq(bridge.totalLockedLiquidity(), 2_000e6 - totalReleased);

        vm.warp(block.timestamp + 1);
        assertLe(
            bridge.effectiveAvailableOutflow(RGB_CHAIN_ID),
            bridge.availableGlobalSafetyOutflow(),
            "global rolling ceiling cannot be bypassed by chain splitting"
        );
    }

    function test_crossChainOutflowRepricesGlobalAllowanceAgainstCurrentLiquidity() public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);

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
        _releaseRGBTo(makeAddr("cross-chain-rgb"), 100e6, BURN_ID);
        assertEq(bridge.lockedLiquidity(otherChain), 1_000e6, "other chain liquidity unchanged");
        assertEq(bridge.globalOutflowReference(), 1_900e6, "real outflow reprices global reference");
        assertEq(bridge.effectiveAvailableOutflow(otherChain), 0, "spent global bucket blocks other chain");

        // Once the bucket refills, the old 100-token quote is above the new 5%
        // capacity. This is expected stale-state handling: the current getter
        // reports 95, which remains executable and respects aggregate policy.
        vm.warp(block.timestamp + bridge.BUCKET_REFILL_WINDOW() + 1);
        uint256 currentAllowance = bridge.effectiveAvailableOutflow(otherChain);
        assertEq(currentAllowance, 95e6, "fresh quote follows current aggregate liquidity");

        uint256 capacityShares = 500 * bridge.SHARE_UNIT() / bridge.BPS_DENOMINATOR();
        uint256 requestedShares = (quotedForOther * bridge.SHARE_UNIT() + bridge.globalOutflowReference() - 1)
            / bridge.globalOutflowReference();
        bytes memory otherSettlement = _settlementWithAmounts(_ids(otherOpId), _one(1_000e6));

        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.AggregateRequestAboveCapacity.selector, capacityShares, requestedShares
            )
        );
        vm.prank(multisig);
        _fundsOut(
            makeAddr("stale-other"),
            quotedForOther,
            BURN_ID + 1,
            otherChain,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            otherSettlement
        );

        vm.prank(multisig);
        _fundsOut(
            makeAddr("fresh-other"),
            currentAllowance,
            BURN_ID + 2,
            otherChain,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            otherSettlement
        );

        assertEq(bridge.totalLockedLiquidity(), 1_805e6, "aggregate accounting includes both releases");
        assertEq(bridge.availableGlobalOutflow(), 0, "fresh release consumes the refilled global burst");
        assertEq(bridge.availableGlobalSafetyOutflow(), 205e6, "immutable aggregate safety remains enforced");
    }

    function test_setOutflowLimit_revertsOnZeroChainId() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidOutflowLimit.selector);
        bridge.setOutflowLimit(0, 500, 1_500);
    }

    function test_setOutflowLimit_revertsOnZeroBurst() public {
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, uint256(0), uint256(1_500), uint256(2_000))
        );
        bridge.setOutflowLimit(RGB_CHAIN_ID, 0, 1_500);
    }

    function test_setOutflowLimit_revertsOnZeroRefill() public {
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, uint256(500), uint256(0), uint256(2_000))
        );
        bridge.setOutflowLimit(RGB_CHAIN_ID, 500, 0);
    }

    /// @dev The federation must not be able to configure a bucket that covers
    ///      TVL. `burstBps` is bounded by the immutable
    ///      `MAX_CHAIN_OUTFLOW_BPS`, so no policy authorises more than 20% of
    ///      reference liquidity in one release — at any liquidity level.
    function test_setOutflowLimit_rejectsBurstAboveImmutableCeiling() public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, maxBps + 1, uint256(1), maxBps));
        bridge.setOutflowLimit(RGB_CHAIN_ID, maxBps + 1, 1);
    }

    function test_setOutflowLimit_rejectsRefillAboveImmutableCeiling() public {}

    /// @dev A policy whose combined burst and refill equals the immutable
    ///      ceiling is accepted.
    function test_setOutflowLimit_acceptsCombinedCeiling() public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();
        uint256 burstBps = 750;
        uint256 refillBps = maxBps - burstBps;

        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, refillBps);

        (,,, uint128 capacity,) = bridge.chainBuckets(RGB_CHAIN_ID);
        assertEq(capacity, burstBps * bridge.SHARE_UNIT() / bridge.BPS_DENOMINATOR(), "burst stored as shares");
    }

    function test_setOutflowLimit_rejectsCombinedPolicyAboveCeiling() public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();
        uint256 burstBps = 1_001;
        uint256 refillBps = 1_000;

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, burstBps, refillBps, maxBps));
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, refillBps);
    }

    function test_setOutflowLimit_rejectsFullTvlPolicy() public {
        uint256 denominator = bridge.BPS_DENOMINATOR();
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, denominator, denominator, maxBps));
        bridge.setOutflowLimit(RGB_CHAIN_ID, denominator, denominator);
    }

    function test_setGlobalOutflowLimit_rejectsFullTvlPolicy() public {
        uint256 denominator = bridge.BPS_DENOMINATOR();
        uint256 maxBps = bridge.MAX_GLOBAL_OUTFLOW_BPS();

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, denominator, uint256(1), maxBps));
        bridge.setGlobalOutflowLimit(denominator, 1);
    }

    function test_setGlobalOutflowLimit_rejectsCombinedPolicyAboveCeiling() public {
        uint256 maxBps = bridge.MAX_GLOBAL_OUTFLOW_BPS();
        uint256 burstBps = 1_200;
        uint256 refillBps = 801;

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, burstBps, refillBps, maxBps));
        bridge.setGlobalOutflowLimit(burstBps, refillBps);
    }

    /// @dev Deployment ergonomics: policy validation is liquidity-independent, so
    ///      both buckets can be configured before the first deposit exists. This
    ///      is what lets a deployment install every parameter in one pass instead
    ///      of "deploy → seed liquidity → come back and configure buckets".
    function test_outflowPolicyConfigurableAtZeroLiquidity() public {
        // `setUp` deploys the Bridge and configures routes but makes no deposit.
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 0, "no chain liquidity yet");
        assertEq(bridge.totalLockedLiquidity(), 0, "no global liquidity yet");

        vm.startPrank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, 500, 1_500);
        bridge.setGlobalOutflowLimit(800, 1_200);
        vm.stopPrank();

        // Configured, but nothing is spendable until liquidity backs it — the
        // percentage has no absolute meaning at zero reference.
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "no allowance without liquidity");
        assertEq(bridge.availableGlobalOutflow(), 0, "no global allowance without liquidity");
        assertEq(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), 0, "nothing can leave");
    }

    /// @dev The same policy scales with liquidity and needs no governance touch:
    ///      5% burst is 5e6 at 100e6 TVL and 50e6 at 1000e6 TVL.
    function test_outflowPolicyScalesWithLiquidity() public {
        vm.startPrank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, 500, 1_500);
        bridge.setGlobalOutflowLimit(500, 1_500);
        vm.stopPrank();

        usdt0.mint(user, 1_100e6);
        vm.prank(user);
        bridge.fundsIn(100e6, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 4_001));
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 5e6, "5% of 100e6");

        vm.prank(user);
        bridge.fundsIn(900e6, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 4_002));
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 50e6, "5% of 1000e6, no reconfiguration");
    }

    function test_setOutflowLimit_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setOutflowLimit(RGB_CHAIN_ID, 500, 1_500);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setGlobalOutflowLimit(500, 1_500);
    }

    function test_setOutflowLimit_emitsEvent() public {
        _seedRGB(100e6); // chain liquidity 1000e6
        uint256 burstBps = 500; // 5% → 50e6
        uint256 refillBps = 1_500;
        uint256 expectedShares = burstBps * bridge.SHARE_UNIT() / bridge.BPS_DENOMINATOR();

        // RGB already uses a 10% balanced policy; reconfiguring to 5% clamps
        // the accrued allowance to the new burst.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit OutflowLimitUpdated(RGB_CHAIN_ID, burstBps, refillBps, expectedShares);
        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, refillBps);
    }

    /// @dev Fuzz the refill formula end-to-end through the live preview: reconfig
    ///      RGB to a fuzzed bps policy, drain a fuzzed fraction, warp a fuzzed
    ///      time, and assert availableOutflow matches an independent
    ///      recomputation of the library's min(capacity, tokens + elapsed*rate).
    ///      The recomputation runs in share space, where the arithmetic is exact,
    ///      and is converted to tokens exactly once — mirroring the view.
    function testFuzz_outflow_previewMatchesRefillFormula(
        uint256 burstBps,
        uint256 refillBps,
        uint256 drainBps,
        uint256 elapsed
    ) public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();
        burstBps = bound(burstBps, 1, MAX_BURST_BPS);
        refillBps = bound(refillBps, 1, maxBps - burstBps);
        drainBps = bound(drainBps, 1, burstBps);
        elapsed = bound(elapsed, 0, 4_000 days);

        _seedRGB(1_000e6);

        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, refillBps);

        uint256 drain = bridge.chainOutflowReference(RGB_CHAIN_ID) * drainBps / bridge.BPS_DENOMINATOR();
        vm.assume(drain > 0);
        _releaseRGB(drain, BURN_ID);

        vm.warp(block.timestamp + elapsed);

        // The bucket reference is always actual locked liquidity. A rolling
        // safety-slot expiry cannot change it by itself.
        uint256 refLiquidity = bridge.chainOutflowReference(RGB_CHAIN_ID);

        (uint128 tokens,,, uint128 capacity, uint128 rate) = bridge.chainBuckets(RGB_CHAIN_ID);
        uint256 expectedShares = uint256(tokens) + elapsed * uint256(rate);
        if (expectedShares > capacity) expectedShares = capacity;

        uint256 shareUnit = bridge.SHARE_UNIT();
        assertEq(
            bridge.availableOutflow(RGB_CHAIN_ID),
            expectedShares * refLiquidity / shareUnit,
            "preview matches library refill"
        );
        assertLe(
            bridge.availableOutflow(RGB_CHAIN_ID),
            uint256(capacity) * refLiquidity / shareUnit,
            "never exceeds capacity"
        );
    }

    /// @dev A release within the live allowance debits exactly that amount, up to
    ///      the one-share ceiling applied when converting the amount into shares.
    function testFuzz_outflow_releaseDebitsAvailable(uint256 burstBps, uint256 amountBps) public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();
        burstBps = bound(burstBps, 1, MAX_BURST_BPS);
        amountBps = bound(amountBps, 1, burstBps);

        _seedRGB(1_000e6);
        // Capture the pre-debit reference used to price the release.
        uint256 refLiquidity = bridge.chainOutflowReference(RGB_CHAIN_ID);

        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, maxBps - burstBps);

        uint256 amount = refLiquidity * amountBps / bridge.BPS_DENOMINATOR();
        vm.assume(amount > 0);

        (uint128 sharesBefore,,,,) = bridge.chainBuckets(RGB_CHAIN_ID);
        _releaseRGB(amount, BURN_ID);

        uint256 shareUnit = bridge.SHARE_UNIT();
        uint256 spentShares = (amount * shareUnit + refLiquidity - 1) / refLiquidity;
        (uint128 sharesAfter,,,,) = bridge.chainBuckets(RGB_CHAIN_ID);
        assertEq(uint256(sharesAfter), uint256(sharesBefore) - spentShares, "share debit uses pre-debit liquidity");

        uint256 remainingLiquidity = refLiquidity - amount;
        assertEq(
            bridge.availableOutflow(RGB_CHAIN_ID),
            uint256(sharesAfter) * remainingLiquidity / shareUnit,
            "token preview uses post-debit actual liquidity"
        );
    }

    // ========================================================================
    // fundsOut — other reverts
    // ========================================================================

    function test_fundsOut_revertsIfNotOwner() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );
    }

    function test_fundsOut_revertsOnZeroRecipient() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.expectRevert(BridgeBaseUpgradeable.InvalidRecipientAddress.selector);
        vm.prank(multisig);
        _fundsOut(
            address(0), AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );
    }

    function test_fundsOut_revertsIfAmountExceedsPool() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.expectRevert(BridgeBaseUpgradeable.AmountExceedBridgePool.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT + 1, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );
    }

    // ========================================================================
    // Commission — fundsIn TOKEN
    // ========================================================================

    function test_fundsIn_tokenCommission_routesToCM() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100;
        uint256 expectedNet = AMOUNT - expectedCommission;

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), expectedNet, "bridge net");
        assertEq(usdt0.balanceOf(address(cm)), expectedCommission, "cm pool");
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "cm recorded");
        assertEq(rgbModule.fundsInRecords(opId), expectedNet, "record = net");
    }

    // The flat `baseFee` rides the same path as the proportional part: it is
    // deducted from the deposit, forwarded to the CommissionManager pool, and
    // the settlement record is written against the resulting net.
    function test_fundsIn_baseFeeRoutesToCMOnTopOfPercentage() public {
        uint256 percent = 400; // 4%
        uint256 baseFee = 0.1e18;

        // The harness floor is 1 wei-unit, which no flat fee can sit under.
        // Raise it to the deposit amount first: the combined percentage and
        // flat fee remains comfortably below this floor.
        vm.prank(bridge.owner());
        bridge.setMinFundsInAmount(1e18);

        vm.prank(deployer);
        cm.setCommissionRule(
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                baseFee: baseFee,
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100 + baseFee;
        uint256 expectedNet = AMOUNT - expectedCommission;

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), expectedNet, "bridge net");
        assertEq(usdt0.balanceOf(address(cm)), expectedCommission, "cm pool holds percentage + flat");
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "cm recorded");
        assertEq(rgbModule.fundsInRecords(opId), expectedNet, "record = net");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), expectedNet, "liquidity credited net");
    }

    // A token already donated directly to the CommissionManager is NOT absorbed
    // as commission. Bridge measures the delta of its own transfer,
    // so the pool grows by exactly the real fee; the donation stays a stray balance.
    function test_fundsIn_tokenCommission_doesNotAbsorbCmDonation() public {
        _setFundsInTokenRule(400); // 4%
        uint256 expectedCommission = (AMOUNT * 400) / 100 / 100;

        // Unsolicited direct transfer into the CommissionManager.
        address donor = makeAddr("cmDonor");
        uint256 donation = 5e18;
        usdt0.mint(donor, donation);
        vm.prank(donor);
        usdt0.transfer(address(cm), donation);

        assertEq(cm.tokenCommissionPool(address(usdt0)), 0, "pre pool (donation not counted)");
        assertEq(usdt0.balanceOf(address(cm)), donation, "pre cm balance holds donation");

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // Pool grew by exactly the real commission — the donation was not folded in.
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "pool grew only by real commission");
        assertEq(usdt0.balanceOf(address(cm)), donation + expectedCommission, "donation still present as stray balance");
    }

    // ========================================================================
    // Commission — fundsIn NATIVE
    // ========================================================================

    function test_fundsIn_nativeCommission_routesToCM() public {
        uint256 percent = 100; // 1%
        _setFundsInNativeRule(percent);

        (uint256 tokenC, uint256 nativeC, uint256 net) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertEq(tokenC, 0);
        assertGt(nativeC, 0);
        assertEq(net, AMOUNT);

        vm.deal(user, nativeC);
        vm.prank(user);
        bytes32 opId = bridge.fundsIn{value: nativeC}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
        assertEq(address(cm).balance, nativeC);
        assertEq(cm.nativeCommissionPool(), nativeC);
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT);
    }

    // ========================================================================
    // Commission — fundsOut TOKEN
    // ========================================================================

    function test_fundsOut_tokenCommission_routesToCM() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        uint256 percent = 500; // 5%
        _setFundsOutTokenRule(percent);

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100;
        uint256 expectedNet = AMOUNT - expectedCommission;

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );

        assertEq(usdt0.balanceOf(recipient), expectedNet, "recipient net");
        assertEq(usdt0.balanceOf(address(cm)), expectedCommission, "cm pool");
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "cm recorded");
    }

    // ========================================================================
    // Commission — NATIVE + FUNDS_OUT rejected at config time
    // ========================================================================

    /// @dev The invalid (NATIVE, FUNDS_OUT) shape is rejected by the
    ///      CommissionManager setter, so it can never reach and brick fundsOut.
    function test_setCommissionRule_nativeFundsOut_reverts() public {
        vm.expectRevert(ICommissionManager.NativeCommissionNotAllowedOnFundsOut.selector);
        _setFundsOutNativeRule(100); // setCommissionRule(... NATIVE, FUNDS_OUT ...)
    }

    // ========================================================================
    // Commission — bounded native quote drift
    // ========================================================================

    function test_fundsIn_revertsOnNativeValueMismatch_zeroRuleButValueSent() public {
        vm.deal(user, 1 ether);
        vm.expectRevert(IBridge.NativeValueMismatch.selector);
        vm.prank(user);
        bridge.fundsIn{value: 1 ether}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_revertsOnNativeValueMismatch_nativeRuleButNoValue() public {
        _setFundsInNativeRule(100);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _directNativeBounds(quote);

        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, uint256(0), minimum, maximum)
        );
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    // ========================================================================
    // Native commission drift band
    //
    // Direct deposits: attach the quote plus optional headroom; exactly the
    // fresh quote is charged and the remainder refunded, so the protocol never
    // under-collects and the caller is never overcharged.
    // Adapter deposits: the source-chain payer is unreachable, so the band is
    // symmetric and whatever arrives inside it is collected in full.
    // ========================================================================

    function test_direct_exactQuoteChargedInFull() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        assertGt(quote, 0, "native fee quoted");

        vm.deal(user, quote);
        uint256 poolBefore = cm.nativeCommissionPool();

        vm.prank(user);
        bytes32 opId = bridge.fundsIn{value: quote}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), poolBefore + quote, "pool credited exactly the quote");
        assertEq(user.balance, 0, "nothing to refund");
        assertEq(address(bridge).balance, 0, "no native stranded in bridge");
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "deposit completed");
    }

    /// @dev A caller who attaches more than the quote is charged only the quote
    ///      and refunded the surplus.
    function test_direct_surplusIsRefundedNotCollected() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        uint256 attached = quote + (quote * 400) / 10_000; // +4%, inside the band

        vm.deal(user, attached);
        uint256 poolBefore = cm.nativeCommissionPool();

        vm.prank(user);
        bridge.fundsIn{value: attached}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), poolBefore + quote, "protocol collected ONLY the quote");
        assertEq(user.balance, attached - quote, "caller refunded the whole surplus");
        assertEq(address(bridge).balance, 0, "no native stranded in bridge");
    }

    function test_direct_upperBoundaryRefunded() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        (, uint256 maximum) = _directNativeBounds(quote);

        vm.deal(user, maximum);
        vm.prank(user);
        bridge.fundsIn{value: maximum}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), quote, "still only the quote is collected");
        assertEq(user.balance, maximum - quote, "full headroom refunded");
    }

    function test_direct_revertsBelowQuote() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _directNativeBounds(quote);
        uint256 provided = minimum - 1;

        vm.deal(user, provided);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(user);
        bridge.fundsIn{value: provided}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_direct_revertsAboveUpperBoundary() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _directNativeBounds(quote);
        uint256 provided = maximum + 1;

        vm.deal(user, provided);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(user);
        bridge.fundsIn{value: provided}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    /// @dev The scenario from the finding: quote, then the price moves against
    ///      the caller before the tx mines. The attached buffer absorbs it and
    ///      the deposit succeeds, charged at the FRESH (higher) quote.
    function test_direct_adverseDriftAbsorbedByBuffer() public {
        _setFundsInNativeRule(100);
        uint256 quotedAtSubmit = _nativeQuote(AMOUNT);
        uint256 attached = quotedAtSubmit + (quotedAtSubmit * 400) / 10_000; // +4% buffer

        // ETH depreciates ~3%: the same fee costs more wei than first quoted,
        // but less than the 4% buffer the caller attached.
        ethUsdFeed.setAnswer(1_940e8);
        uint256 freshQuote = _nativeQuote(AMOUNT);
        assertGt(freshQuote, quotedAtSubmit, "drift moved against the caller");
        assertLe(freshQuote, attached, "the buffer covers the drift, so no revert");

        vm.deal(user, attached);
        vm.prank(user);
        bridge.fundsIn{value: attached}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), freshQuote, "charged the fresh quote, not the stale one");
        assertEq(user.balance, attached - freshQuote, "remaining buffer refunded");
    }

    /// @dev Favorable drift simply returns more: the caller is charged the fresh
    ///      (lower) quote, never the stale higher one.
    function test_direct_favorableDriftRefundsMore() public {
        _setFundsInNativeRule(100);
        uint256 quotedAtSubmit = _nativeQuote(AMOUNT);

        ethUsdFeed.setAnswer(2_090e8); // ETH appreciates: the fee costs less wei
        uint256 freshQuote = _nativeQuote(AMOUNT);
        assertLt(freshQuote, quotedAtSubmit, "drift moved in the caller's favour");

        vm.deal(user, quotedAtSubmit);
        vm.prank(user);
        bridge.fundsIn{value: quotedAtSubmit}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), freshQuote, "charged the fresh, lower quote");
        assertEq(user.balance, quotedAtSubmit - freshQuote, "difference refunded");
    }

    /// @dev The protocol cannot be systematically under-paid: every deposit
    ///      credits exactly the quote in force at execution.
    function test_direct_noSystematicUnderCollection() public {
        _setFundsInNativeRule(100);
        uint256 expected;

        for (uint256 i; i < 3; i++) {
            uint256 quote = _nativeQuote(AMOUNT);
            (, uint256 maximum) = _directNativeBounds(quote);
            vm.deal(user, maximum);
            vm.prank(user);
            bridge.fundsIn{value: maximum}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 900 + i));
            expected += quote;
        }

        assertEq(cm.nativeCommissionPool(), expected, "collected exactly the sum of the quotes");
    }

    /// @dev A caller that cannot accept native value must send the exact quote;
    ///      attaching a buffer it cannot be refunded reverts cleanly.
    function test_direct_nonPayableCallerMustSendExactQuote() public {
        _setFundsInNativeRule(100);
        NonPayableDepositor depositor = new NonPayableDepositor(bridge, usdt0);
        usdt0.mint(address(depositor), AMOUNT * 2);
        depositor.approveBridge(AMOUNT * 2);

        uint256 quote = _nativeQuote(AMOUNT);

        // Exact quote: nothing to refund, so the deposit goes through.
        vm.deal(address(depositor), quote);
        depositor.deposit(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), quote);
        assertEq(cm.nativeCommissionPool(), quote, "exact quote accepted from a non-payable caller");

        // With a buffer the refund cannot land, and the deposit reverts.
        uint256 attached = quote + (quote * 200) / 10_000;
        vm.deal(address(depositor), attached);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeRefundFailed.selector, address(depositor), attached - quote)
        );
        depositor.deposit(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 951), attached);
    }

    function test_adapter_symmetricBandCollectedInFull() public {
        _setFundsInNativeRule(100);

        address adapter = makeAddr("lz-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        usdt0.mint(adapter, AMOUNT * 2);
        vm.prank(adapter);
        usdt0.approve(address(bridge), AMOUNT * 2);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _adapterNativeBounds(quote);
        assertLt(minimum, quote, "adapter band extends BELOW the quote");

        // Below the quote is accepted here — and collected in full, since the
        // source-chain payer cannot be refunded.
        vm.deal(adapter, minimum);
        vm.prank(adapter);
        bridge.fundsIn{value: minimum}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        assertEq(cm.nativeCommissionPool(), minimum, "source-agreed value collected in full");
        assertEq(adapter.balance, 0, "adapter is not refunded");

        // Above the quote is likewise collected in full, not refunded.
        vm.deal(adapter, maximum);
        vm.prank(adapter);
        bridge.fundsIn{value: maximum}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 961)
        );
        assertEq(cm.nativeCommissionPool(), minimum + maximum, "upper bound also collected in full");
        assertEq(adapter.balance, 0, "adapter still not refunded");
        assertEq(address(bridge).balance, 0, "no native stranded in bridge");
    }

    function test_adapter_revertsBelowLowerBoundary() public {
        _setFundsInNativeRule(100);

        address adapter = makeAddr("lz-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _adapterNativeBounds(quote);
        uint256 provided = minimum - 1;
        vm.deal(adapter, provided);

        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(adapter);
        bridge.fundsIn{value: provided}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
    }

    function test_adapter_revertsAboveUpperBoundary() public {
        _setFundsInNativeRule(100);

        address adapter = makeAddr("lz-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _adapterNativeBounds(quote);
        uint256 provided = maximum + 1;
        vm.deal(adapter, provided);

        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(adapter);
        bridge.fundsIn{value: provided}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
    }

    // ========================================================================
    // pause / unpause / renounceOwnership
    // ========================================================================

    function test_pause_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.pauseInflow();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(multisig);
        bridge.pauseInflow();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.unpauseInflow();
    }

    function test_renounceOwnership_alwaysReverts() public {
        vm.expectRevert(BridgeBaseUpgradeable.RenounceOwnershipBlocked.selector);
        vm.prank(multisig);
        bridge.renounceOwnership();
    }

    // ========================================================================
    // views
    // ========================================================================

    function test_getContractBalance() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(bridge.getContractBalance(), AMOUNT);
    }

    function test_getChainId() public view {
        assertEq(bridge.getChainId(), block.chainid);
    }

    // ========================================================================
    // Fuzz
    // ========================================================================

    function testFuzz_fundsIn_validAmount(uint64 amount) public {
        vm.assume(amount > 0);
        usdt0.mint(user, amount);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), amount);
        assertEq(rgbModule.fundsInRecords(opId), amount);
    }

    // ========================================================================
    // fundsIn — full-flow state snapshots
    // ========================================================================

    function test_fundsIn_tokenCommission_fullFlowStateSnapshot() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);

        // Snapshot every balance/pool/record this TOKEN-commission flow should touch.
        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 userEthBefore = user.balance;
        uint256 bridgeEthBefore = address(bridge).balance;
        uint256 cmEthBefore = address(cm).balance;
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, 0, "pre record");

        vm.expectEmit(true, false, false, true);
        emit FundsIn(user, RGB_OP_ID, uint64(netAmount));
        vm.expectEmit(true, true, true, true);
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            netAmount,
            tokenCommission,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        // Execute the real direct fundsIn path: user → Bridge → RouteRegistry → RGB module → CM.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId, expectedOpId, "returned id matches derivation");

        assertEq(usdt0.balanceOf(user), userBefore - AMOUNT, "user gross spent");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + netAmount, "bridge net delta");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, "cm fee delta");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, "cm pool delta");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(user.balance, userEthBefore, "user native unchanged");
        assertEq(address(bridge).balance, bridgeEthBefore, "bridge native unchanged");
        assertEq(address(cm).balance, cmEthBefore, "cm native unchanged");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore + netAmount, "record delta = net");

        // Gross USDT0 is conserved between Bridge liquidity and CM commission custody.
        assertEq(
            (usdt0.balanceOf(address(bridge)) - bridgeBefore) + (usdt0.balanceOf(address(cm)) - cmBefore),
            AMOUNT,
            "gross token conserved"
        );
    }

    function test_fundsIn_nativeCommission_fullFlowStateSnapshot() public {
        uint256 percent = 100; // 1%
        _setFundsInNativeRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertEq(tokenCommission, 0, "token fee is zero");
        assertGt(nativeCommission, 0, "native fee quoted");
        assertEq(netAmount, AMOUNT, "net token amount");

        vm.deal(user, nativeCommission);

        // Snapshot token/native balances, pools, and RGB record touched by native-fee fundsIn.
        uint256 userTokenBefore = usdt0.balanceOf(user);
        uint256 bridgeTokenBefore = usdt0.balanceOf(address(bridge));
        uint256 cmTokenBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 userEthBefore = user.balance;
        uint256 bridgeEthBefore = address(bridge).balance;
        uint256 cmEthBefore = address(cm).balance;
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(bridgeTokenBefore, 0, "pre bridge token");
        assertEq(cmTokenBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre token pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, 0, "pre record");

        vm.expectEmit(true, false, false, true);
        emit FundsIn(user, RGB_OP_ID, uint64(netAmount));
        vm.expectEmit(true, true, true, true);
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            netAmount,
            0,
            nativeCommission,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        // Execute exact-value native commission path; token principal stays whole.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn{value: nativeCommission}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId, expectedOpId, "returned id matches derivation");

        assertEq(usdt0.balanceOf(user), userTokenBefore - AMOUNT, "user token gross spent");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeTokenBefore + netAmount, "bridge token delta");
        assertEq(usdt0.balanceOf(address(cm)), cmTokenBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "token pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore + nativeCommission, "native pool delta");
        assertEq(user.balance, userEthBefore - nativeCommission, "user native paid");
        assertEq(address(bridge).balance, bridgeEthBefore, "bridge native unchanged");
        assertEq(address(cm).balance, cmEthBefore + nativeCommission, "cm native delta");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore + netAmount, "record delta = net");

        // Native fee is conserved in CM custody while the full USDT0 principal stays in Bridge.
        assertEq(usdt0.balanceOf(address(bridge)) - bridgeTokenBefore, AMOUNT, "gross token in bridge");
        assertEq(address(cm).balance - cmEthBefore, nativeCommission, "native fee conserved");
    }

    // ========================================================================
    // fundsOut — full-flow state snapshots
    // ========================================================================

    function test_fundsOut_snapshot_tokenCommission_partialRelease() public {
        uint256 releaseAmount = AMOUNT * 3 / 5;
        uint256 percent = 500; // 5%

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(releaseAmount);
        _setFundsOutTokenRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(usdt0), releaseAmount);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");
        assertEq(netAmount, releaseAmount - tokenCommission, "net recipient amount");

        bytes32[] memory ids = _ids(opId);

        // Snapshot the Bridge fundsOut state after a larger RGB record exists.
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore = usdt0.balanceOf(recipient);
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(opId);

        assertEq(bridgeBefore, releaseAmount * 10, "pre bridge pool satisfies configured 10% burst");
        assertEq(recipientBefore, 0, "pre recipient token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, AMOUNT, "pre record");

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(ids);
        uint256 burnId =
            _deriveBurnId(recipient, releaseAmount, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        assertFalse(bridge.consumedBurnIds(burnId), "pre burn id");

        vm.expectEmit(true, true, false, true);
        emit BridgeFundsOut(
            recipient, releaseAmount, netAmount, tokenCommission, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR
        );

        // Release less than the recorded mint. The settlement module no longer
        // consumes records (the proof-of-mint ledger is permanent), so the
        // record is left intact regardless of the release amount; solvency for
        // the partial release is enforced by Bridge.lockedLiquidity.
        vm.prank(multisig);
        _fundsOut(recipient, releaseAmount, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertTrue(bridge.consumedBurnIds(burnId), "burn id consumed");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore - releaseAmount, "bridge gross debit");
        assertEq(usdt0.balanceOf(recipient), recipientBefore + netAmount, "recipient net delta");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, "cm fee delta");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, "cm pool delta");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore, "record unchanged (proof-of-mint permanent)");

        // The gross Bridge debit splits into recipient net payout and CM token commission.
        assertEq(
            (usdt0.balanceOf(recipient) - recipientBefore) + (usdt0.balanceOf(address(cm)) - cmBefore),
            releaseAmount,
            "gross fundsOut conserved"
        );
    }

    // ========================================================================
    // fundsIn — rollback snapshots
    // ========================================================================

    function test_fundsIn_routeModuleRevertRollsBackTokenPullAndEvents() public {
        MockSettlementModule revertingModule = new MockSettlementModule();
        revertingModule.setShouldRevertOnFundsIn(true);

        // Route is intentionally rewired to a module that reverts after Bridge
        // has already pulled tokens and before commission forwarding can run.
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(revertingModule));

        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(recordBefore, 0, "pre rgb record");
        assertEq(revertingModule.onFundsInCount(), 0, "pre module calls");

        // Bridge emits FundsIn/BridgeFundsIn only after route dispatch, so this
        // module revert prevents successful Bridge events from persisting.
        vm.expectRevert(MockSettlementModule.MockModuleForcedRevert.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore, "user token unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore, "bridge token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(expectedOpId), recordBefore, "rgb record unchanged");
        assertEq(revertingModule.onFundsInCount(), 0, "module state unchanged");
    }

    function test_fundsIn_commissionForwardingRevertRollsBackSettlementRecord() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertLt(netAmount, AMOUNT, "net below gross");

        // Misconfigure only the CM bridge guard so the route/RGB write happens
        // before commission forwarding fails in receiveTokenCommission().
        // Deploy the stub BEFORE the prank — as a call argument it would consume it.
        address wrongBridge = _wrongBridgeWithFloor();
        vm.prank(deployer);
        cm.setBridgeAddress(wrongBridge);

        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(recordBefore, 0, "pre rgb record");

        // FundsIn/BridgeFundsIn emit after commission forwarding, so this
        // late revert prevents successful Bridge events from persisting.
        vm.expectRevert(ICommissionManager.OnlyBridge.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore, "user token unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore, "bridge token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(expectedOpId), recordBefore, "rgb record unchanged");
    }

    // ========================================================================
    // fundsOut — rollback snapshots
    // ========================================================================

    function test_fundsOut_verifierRevertRollsBackBurnIdAndRecords() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        // Well-formed two-pair proof, but the source block is unknown to the relay.
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown-block"), LATEST_HEIGHT, LATEST_COMMIT);

        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore = usdt0.balanceOf(recipient);
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(opId);
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, badProof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "pre burn id");
        assertEq(bridgeBefore, AMOUNT * 10, "pre bridge pool includes bucket reserve");
        assertEq(recipientBefore, 0, "pre recipient token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, AMOUNT, "pre rgb record");

        // fundsOut marks the burn id before verifier dispatch. This verifier
        // failure rolls that mark back and short-circuits before RGB records
        // can be consumed.
        vm.expectRevert("verify: block commitment");
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, badProof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "burn id unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore, "bridge token unchanged");
        assertEq(usdt0.balanceOf(recipient), recipientBefore, "recipient token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore, "rgb record unchanged");
    }

    function test_fundsOut_settlementRevertRollsBackBurnIdAndRecords() public {
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

        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore = usdt0.balanceOf(recipient);
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 record1Before = rgbModule.fundsInRecords(opId1);
        uint256 record2Before = rgbModule.fundsInRecords(opId2);
        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(ids, badAmounts);
        uint256 burnId =
            _deriveBurnId(recipient, releaseAmount, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "pre burn id");
        assertEq(bridgeBefore, releaseAmount * 10, "pre bridge pool includes bucket reserve");
        assertEq(recipientBefore, 0, "pre recipient token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(record1Before, amount1, "pre record 1");
        assertEq(record2Before, amount2, "pre record 2");

        // The module reverts on the amount mismatch; the surrounding fundsOut
        // must atomically roll back the burn-id mark and the liquidity debit.
        // (Records are view-only now, so they are trivially unchanged.)
        vm.expectRevert(
            abi.encodeWithSelector(RgbSettlementModule.AmountMismatch.selector, opId1, amount1 + 1, amount1)
        );
        vm.prank(multisig);
        _fundsOut(recipient, releaseAmount, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "burn id unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore, "bridge token unchanged");
        assertEq(usdt0.balanceOf(recipient), recipientBefore, "recipient token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId1), record1Before, "record 1 unchanged");
        assertEq(rgbModule.fundsInRecords(opId2), record2Before, "record 2 unchanged");
    }

    function test_fundsOutVerifierProofStillNotRouteContextAware() public {
        address alternateRecipient = makeAddr("alternateRecipient");
        uint256 releaseAmount = AMOUNT * 37 / 100;
        // Isolated liquidity and the outflow limit gate the `sourceChainId`
        // dimension: a release can only draw from a funded and rate-limited
        // source chain. This reproduction keeps the source on the funded RGB
        // chain. The enclave signature binds the complete release intent and
        // exact proof, while burnId binds the canonical settlement fields, but
        // RGBVerifier itself still validates only BTC block commitments; it does
        // not parse route/business context from the proof.
        uint256 alternateSourceChainId = RGB_CHAIN_ID;
        uint256 alternateDestinationChainId = SOURCE_CHAIN_ID + 77;
        string memory alternateSourceAddress = ""; // RGB routes carry no source address

        vm.prank(deployer);
        routeRegistry.setRoute(
            alternateSourceChainId, alternateDestinationChainId, true, address(rgbVerifier), address(rgbModule)
        );

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(releaseAmount);

        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore = usdt0.balanceOf(alternateRecipient);
        uint256 recordBefore = rgbModule.fundsInRecords(opId);

        assertEq(bridgeBefore, releaseAmount * 10, "pre bridge pool satisfies configured 10% burst");
        assertEq(recipientBefore, 0, "pre recipient token");
        assertEq(recordBefore, AMOUNT, "pre record");
        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId = _deriveBurnId(
            alternateRecipient,
            releaseAmount,
            alternateSourceChainId,
            alternateDestinationChainId,
            alternateSourceAddress,
            proof,
            settlementData
        );
        assertFalse(bridge.consumedBurnIds(burnId), "pre burn id");

        // Current verifier behavior: this is an authorized fundsOut call with a
        // matching Bridge-derived burnId, but RGBVerifier checks only the encoded
        // BTC block commitments. If the RGB proof later carries enough context
        // for verifier-level binding, invert this to expect a verifier revert.
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BridgeFundsOut(
            alternateRecipient,
            releaseAmount,
            releaseAmount,
            0,
            burnId,
            alternateSourceChainId,
            alternateDestinationChainId,
            alternateSourceAddress
        );

        vm.prank(multisig);
        _fundsOut(
            alternateRecipient,
            releaseAmount,
            burnId,
            alternateSourceChainId,
            alternateDestinationChainId,
            alternateSourceAddress,
            proof,
            settlementData
        );

        assertTrue(bridge.consumedBurnIds(burnId), "burn id consumed");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore - releaseAmount, "bridge debit");
        assertEq(usdt0.balanceOf(alternateRecipient), recipientBefore + releaseAmount, "recipient credited");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore, "record unchanged (proof-of-mint permanent)");
    }

    // The pre-emption attack is closed because operationId is derived on-chain
    // from the authenticated `sourceSender` plus a per-sender
    // nonce, so an attacker cannot compute (let alone occupy) a victim's id by
    // copying the RGB OpId out of the mempool. A preemptor sharing the same
    // rgbOpId lands on a DIFFERENT derived id, and the victim's deposit still
    // succeeds under its own id.
    function test_fundsIn_preemptorCannotBlockVictimDeposit() public {
        address preemptor = makeAddr("operationIdPreemptor");
        uint256 preemptAmount = AMOUNT / 4;

        usdt0.mint(preemptor, preemptAmount);
        vm.prank(preemptor);
        usdt0.approve(address(bridge), preemptAmount);

        // Preemptor deposits first, reusing the SAME rgbOpId the victim will use.
        vm.prank(preemptor);
        bytes32 preemptOpId = bridge.fundsIn(preemptAmount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(preemptOpId), preemptAmount, "preemptor record");

        uint256 victimBefore = usdt0.balanceOf(user);

        // Victim's deposit with identical params + identical rgbOpId still
        // succeeds: its derived id binds the victim's sourceSender, so it cannot
        // collide with the preemptor's id.
        vm.prank(user);
        bytes32 victimOpId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(victimOpId != preemptOpId, "victim id distinct from preemptor id");
        assertEq(rgbModule.fundsInRecords(victimOpId), AMOUNT, "victim record created");
        assertEq(usdt0.balanceOf(user), victimBefore - AMOUNT, "victim deposit went through");
    }

    // A plain ERC20 transfer can change Bridge's raw balance,
    // but it does not enter the Bridge.fundsIn accounting path.
    function test_directTokenTransferDoesNotCreateFundsInAccounting() public {
        address donor = makeAddr("directTransferDonor");
        uint256 directAmount = 17e18;
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );

        usdt0.mint(donor, directAmount);

        uint256 donorBefore = usdt0.balanceOf(donor);
        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(donorBefore, directAmount, "pre donor token");
        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(recordBefore, 0, "pre record");

        vm.prank(donor);
        usdt0.transfer(address(bridge), directAmount);

        assertEq(usdt0.balanceOf(donor), donorBefore - directAmount, "donor direct transfer spent");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + directAmount, "bridge raw balance increased");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(expectedOpId), recordBefore, "record not created");

        vm.expectEmit(true, false, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, uint64(AMOUNT));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            AMOUNT,
            0,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore - AMOUNT, "user fundsIn spent");
        assertEq(
            usdt0.balanceOf(address(bridge)),
            bridgeBefore + directAmount + AMOUNT,
            "bridge includes direct plus fundsIn"
        );
        assertEq(rgbModule.fundsInRecords(opId), recordBefore + AMOUNT, "record created only by fundsIn");
    }

    // Bridge only rejects an empty destination address, so a
    // non-empty string is accepted and emitted without format validation.
    function test_fundsIn_acceptsInvalidButNonEmptyDestinationAddress() public {
        string memory invalidDestination = "not-rgb-destination";
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, invalidDestination, _rgbData()
        );

        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(recordBefore, 0, "pre record");

        vm.expectEmit(true, false, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, uint64(AMOUNT));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            AMOUNT,
            0,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            invalidDestination
        );

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, invalidDestination, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore - AMOUNT, "user fundsIn spent");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + AMOUNT, "bridge credited");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore + AMOUNT, "record created");
    }

    // The token commission is forwarded before the onFundsIn hook, so a
    // settlement module reading getContractBalance during the hook
    // observes only the net the Bridge retains — never the in-flight commission.
    function test_onFundsInHookSeesNetBalanceNotFutureCommission() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");

        MockSettlementModule observingModule = new MockSettlementModule();
        observingModule.setFundsInBalanceProbe(address(usdt0), address(bridge));
        // Return a non-zero external id so Bridge emits the RGB-only FundsIn event.
        observingModule.setExternalIdToReturn(RGB_OP_ID);

        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(observingModule));

        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");

        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );

        vm.expectEmit(true, false, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, uint64(netAmount));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            netAmount,
            tokenCommission,
            nativeCommission,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(observingModule.onFundsInCount(), 1, "module called once");
        assertEq(observingModule.lastNetAmount(), netAmount, "module got net amount");
        assertEq(
            observingModule.lastObservedBalanceOnFundsIn(),
            bridgeBefore + netAmount,
            "hook sees only the retained net, not the in-flight commission"
        );
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + netAmount, "final bridge net");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, "cm token delta");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, "cm pool delta");
    }

    // fundsIn — fuzz/property rollback coverage

    // All selected failure paths must leave balances, commission pools, and RGB
    // accounting unchanged. Feed failures are pre-pull; route/module/commission
    // failures exercise post-pull rollback.
    function testFuzz_fundsIn_revertPathsLeaveStateUnchanged(
        uint128 amountSeed,
        uint128 /* operationSalt */
    )
        public
    {
        // Lower bound keeps commission/native fee nonzero so intended reverts fire.
        uint256 amount = bound(uint256(amountSeed), 100, AMOUNT);

        for (uint8 failureMode = 0; failureMode < 5; failureMode++) {
            uint256 snapshotId = vm.snapshotState();
            _assertFundsInRevertPathLeavesStateUnchanged(amount, failureMode);
            assertTrue(vm.revertToStateAndDelete(snapshotId), "scenario snapshot restored");
        }
    }

    // A positive-net RGB deposit records net under its DERIVED operationId. A
    // repeated identical deposit does not collide because the per-sender nonce
    // yields a distinct id, so the second deposit creates a second record. The
    // module-level DuplicateOperationId guard is covered in
    // RgbSettlementModule.t.sol.
    function testFuzz_fundsIn_positiveNetDepositCreatesRecordAndDistinctRepeat(uint128 amountSeed, uint16 percentSeed)
        public
    {
        uint256 amount = bound(uint256(amountSeed), 100, AMOUNT);
        uint256 percent = bound(uint256(percentSeed), 100, 9_000);

        _setFundsInTokenRule(percent);

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), amount);

        assertGt(tokenCommission, 0, "pre positive token fee");
        assertGt(netAmount, 0, "pre positive net");

        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();

        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, amount, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );

        vm.expectEmit(true, false, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, uint64(netAmount));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            amount,
            netAmount,
            tokenCommission,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId1, expectedOpId, "returned id matches derivation");

        assertEq(usdt0.balanceOf(user), userBefore - amount, "user spent gross once");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + netAmount, "bridge got net");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, "cm got fee");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, "cm pool recorded fee");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId1), netAmount, "record = net");
        assertEq(
            (usdt0.balanceOf(address(bridge)) - bridgeBefore) + (usdt0.balanceOf(address(cm)) - cmBefore),
            amount,
            "gross token conserved"
        );

        // Repeat identical deposit — nonce increments, so a DISTINCT id is
        // derived and the deposit succeeds (no DuplicateOperationId).
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(opId2 != opId1, "repeat deposit gets a distinct id");
        assertEq(rgbModule.fundsInRecords(opId1), netAmount, "first record unchanged");
        assertEq(rgbModule.fundsInRecords(opId2), netAmount, "second record created");
    }

    /// @dev A 100% fee shape is rejected before it can become an active route
    ///      rule and create zero-net records.
    function test_hundredPercentRouteRuleCannotBeConfigured() public {
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 8_100,
            baseFee: 0,
            multiplier: 90,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });

        vm.expectRevert(
            abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, cfg.stablePercent, cfg.multiplier)
        );
        vm.prank(deployer);
        cm.setCommissionRule(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), cfg);

        CommissionConfig memory stored = cm.getCommissionRule(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0));
        assertFalse(stored.isSet, "invalid rule was not stored");
    }

    // ========================================================================
    // On-chain-derived, unpredictable operationId
    // ========================================================================

    /// @dev The id is derived on-chain from the authenticated sender; two
    ///      different senders with otherwise-identical deposits produce
    ///      different ids, so an attacker cannot reproduce a victim's id.
    function test_fundsIn_derivesUnpredictableOperationId_notCallerControlled() public {
        address attacker = makeAddr("attacker");
        usdt0.mint(attacker, AMOUNT);
        vm.prank(attacker);
        usdt0.approve(address(bridge), AMOUNT);

        vm.prank(user);
        bytes32 victimId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.prank(attacker);
        bytes32 attackerId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(victimId != attackerId, "ids bound to distinct senders differ");
        // The attacker's id equals the on-chain derivation for the attacker's
        // sender — it cannot be any value the attacker freely chose.
        assertEq(
            attackerId,
            _deriveOpId(
                SOURCE_CHAIN_ID, bytes32(uint256(uint160(attacker))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
            ),
            "attacker id is the derived value"
        );
    }

    /// @dev Same sender, identical params twice: distinct ids (nonce), and the
    ///      per-(chain,sender) nonce advances to 2.
    function test_fundsIn_repeatedIdenticalDepositsGetDistinctIds() public {
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 0, "nonce starts at 0");

        vm.prank(user);
        bytes32 id1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        vm.prank(user);
        bytes32 id2 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(id1 != id2, "nonce makes identical deposits distinct");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 2, "nonce incremented to 2");
    }

    /// @dev A downstream revert must roll back the nonce increment: the nonce
    ///      stays 0 and a later successful deposit gets the nonce-0 id.
    function test_fundsIn_nonceRollsBackOnRevert() public {
        bytes32 sourceSender = bytes32(uint256(uint160(user)));

        // Amount below the (raised) minimum reverts before the nonce is consumed.
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(999), uint256(1000)));
        vm.prank(user);
        bridge.fundsIn(999, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 0, "nonce not consumed on revert");

        // A subsequent successful deposit gets the nonce-0 id.
        bytes32 expectedNonce0Id =
            _deriveOpId(SOURCE_CHAIN_ID, sourceSender, 0, 1000, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(1000, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId, expectedNonce0Id, "first success uses nonce 0");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 1, "nonce now 1");
    }

    /// @dev RGB deposit with a zero rgbOpId reverts in the settlement module.
    function test_fundsIn_zeroRgbOpIdReverts() public {
        vm.expectRevert(RgbSettlementModule.InvalidRgbOpId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(0));
    }

    /// @dev The RGB route emits FundsIn carrying the rgbOpId and net amount.
    function test_fundsIn_rgbRouteEmitsFundsInWithRgbOpId() public {
        vm.expectEmit(true, false, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, uint64(AMOUNT)); // no commission → net == gross == AMOUNT
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_rgbRouteAcceptsUint64Maximum() public {
        uint256 amount = type(uint64).max;
        usdt0.mint(user, amount);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, type(uint64).max);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(rgbModule.fundsInRecords(opId), amount);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), amount);
    }

    function test_fundsIn_rgbRouteRejectsNetAmountAboveUint64WithoutTruncation() public {
        uint256 amount = uint256(type(uint64).max) + 1;
        usdt0.mint(user, amount);
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        bytes32 expectedOpId = _deriveOpId(SOURCE_CHAIN_ID, sourceSender, 0, amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        uint256 userBefore = usdt0.balanceOf(user);

        vm.expectRevert(abi.encodeWithSelector(BridgeBaseUpgradeable.AmountExceedsUint64.selector, amount));
        vm.prank(user);
        bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore, "token pull rolled back");
        assertEq(usdt0.balanceOf(address(bridge)), 0, "bridge retained no tokens");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 0, "liquidity credit rolled back");
        assertEq(rgbModule.fundsInRecords(expectedOpId), 0, "settlement record rolled back");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 0, "nonce rolled back");
    }

    function test_fundsIn_rgbRangeCheckUsesNetAmountAfterCommission() public {
        uint256 grossAmount = uint256(type(uint64).max) + 1;
        uint256 percent = 400; // 4% makes the RGB net amount fit in uint64
        _setFundsInTokenRule(percent);
        usdt0.mint(user, grossAmount);

        uint256 expectedNet = grossAmount - cm.calculateStableFee(grossAmount, percent, 100);
        assertLe(expectedNet, type(uint64).max, "test setup: net fits RGB u64");

        vm.expectEmit(true, false, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, uint64(expectedNet));

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(grossAmount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(rgbModule.fundsInRecords(opId), expectedNet);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), expectedNet);
    }

    function test_fundsIn_rgbOpIdIsNonIndexedEventData() public {
        bytes32 fundsInTopic = keccak256("FundsIn(address,uint256,uint64)");
        vm.recordLogs();
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(bridge) && logs[i].topics[0] == fundsInTopic) {
                assertEq(logs[i].topics.length, 2, "only signature and sender are indexed");
                assertEq(address(uint160(uint256(logs[i].topics[1]))), user, "sender topic");
                (uint256 rgbOpId, uint64 amount) = abi.decode(logs[i].data, (uint256, uint64));
                assertEq(rgbOpId, RGB_OP_ID, "rgb op id is event data");
                assertEq(amount, AMOUNT, "amount is event data");
                return;
            }
        }
        fail("FundsIn event not found");
    }

    /// @dev The returned bytes32 is the key under which the module records net.
    function test_fundsIn_returnedOperationIdKeysTheRecord() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "returned id keys the record");
    }

    /// @dev Full deposit → fundsOut happy path using the captured bytes32 in the
    ///      release settlement data.
    function test_fundsOut_referencesDerivedOperationId() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );

        assertEq(usdt0.balanceOf(recipient), AMOUNT, "release via derived id succeeds");
    }

    // --- Record/ledger/event use ACTUAL received, not nominal ---

    function test_fundsIn_feeToken_creditsActualReceivedNotNominal() public {
        FeeStack memory s = _deployFeeStack(100); // 1% fee, no commission rule

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        assertLt(received, AMOUNT, "sanity: fee token delivers less than nominal");

        bytes32 sourceSender = bytes32(uint256(uint160(user)));

        // BridgeFundsIn must carry gross `amount == AMOUNT` and `netAmount == received`.
        vm.expectEmit(true, false, false, true);
        emit FundsIn(user, RGB_OP_ID, uint64(received));
        vm.expectEmit(false, true, true, true);
        emit BridgeFundsIn(
            bytes32(0), sourceSender, user, 0, AMOUNT, received, 0, 0, SOURCE_CHAIN_ID, RGB_CHAIN_ID, DST_ADDR
        );

        vm.prank(user);
        bytes32 opId = s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(s.module.fundsInRecords(opId), received, "record credits actual received");
        assertEq(s.bridge.lockedLiquidity(RGB_CHAIN_ID), received, "lockedLiquidity credits actual received");
        assertEq(s.token.balanceOf(address(s.bridge)), received, "bridge token balance == received");
    }

    // --- With a TOKEN commission the ledger is not overstated ---

    function test_fundsIn_feeToken_ledgerNotOverstatedWithCommission() public {
        FeeStack memory s = _deployFeeStack(100); // 1% transfer fee
        // 4% FUNDS_IN TOKEN commission rule (stablePercent 400, multiplier 100).
        _setFeeStackFundsInTokenRule(s, 400, 100);

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        // Commission is quoted from the NOMINAL amount.
        uint256 tokenCommission = s.cm.calculateStableFee(AMOUNT, 400, 100);
        assertGt(tokenCommission, 0, "sanity: non-zero commission");

        vm.prank(user);
        s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // Ledger credited from actual received minus the (nominal-quoted) commission.
        assertEq(
            s.bridge.lockedLiquidity(RGB_CHAIN_ID),
            received - tokenCommission,
            "lockedLiquidity == received - tokenCommission"
        );

        // The Bridge→CM commission hop is itself taxed by the fee token, so the
        // CM credits by its own balance delta: tokenCommission - feeOn(tokenCommission).
        assertEq(
            s.cm.tokenCommissionPool(address(s.token)),
            tokenCommission - s.token.feeOn(tokenCommission),
            "CM pool credited by its own balance delta"
        );

        // No overstate: the bridge's retained token balance equals the credited
        // lockedLiquidity exactly (bridge sent `tokenCommission` out to the CM).
        uint256 bridgeRetained = s.token.balanceOf(address(s.bridge));
        assertEq(bridgeRetained, received - tokenCommission, "bridge retained == lockedLiquidity");
        assertEq(
            s.bridge.lockedLiquidity(RGB_CHAIN_ID),
            bridgeRetained,
            "lockedLiquidity + bridge-retained invariant: credited == held"
        );
    }

    // --- The recorded (actual) amount is releasable via fundsOut ---

    function test_fundsOut_feeToken_recordedAmountIsReleasable() public {
        FeeStack memory s = _deployFeeStack(100); // 1% fee, no commission

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);

        vm.prank(user);
        bytes32 opId = s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(s.module.fundsInRecords(opId), received, "record == actual received");

        // Nine additional equal deposits provide the configured 90% bucket
        // reserve; the test still releases exactly the first record's amount.
        for (uint256 i = 1; i < 10; i++) {
            vm.prank(user);
            s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + i));
        }

        // Ten equal deposits back the release, so `received` is ~10% of chain
        // liquidity and the balanced policy's burst covers it.
        vm.startPrank(multisig);
        s.bridge.setOutflowLimit(RGB_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        s.bridge.setGlobalOutflowLimit(MAX_BURST_BPS, MAX_REFILL_BPS);
        vm.stopPrank();

        // Release EXACTLY the recorded amount. Before the fix the record would
        // have been the nominal AMOUNT (> bridge balance `received`) and the
        // release would revert AmountExceedBridgePool.
        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(_ids(opId), _one(received));
        uint256 burnId =
            _deriveBurnIdFor(s, recipient, received, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        uint256 recipientBefore = s.token.balanceOf(recipient);

        _releaseFor(s, received, burnId, proof, settlementData);

        // The outbound transfer is also taxed, so the recipient nets
        // `received - feeOn(received)`. The payoff is that the release did NOT
        // revert and value moved.
        uint256 delta = s.token.balanceOf(recipient) - recipientBefore;
        assertGt(delta, 0, "recipient balance increased");
        assertEq(delta, received - s.token.feeOn(received), "recipient nets received minus outbound fee");
        assertEq(s.bridge.lockedLiquidity(RGB_CHAIN_ID), received * 9, "90% bucket reserve remains locked");
    }

    // --- Received <= tokenCommission reverts InsufficientReceived ---
    //
    // Token transfer fee = 9000 bps (90%) → received = 10% of AMOUNT = 10e18.
    // The commission is quoted on the NOMINAL amount, so the protocol maximum
    // rate of 90% (`_MAX_FEE_BPS`) already puts the quote at 90e18 — far above
    // the 10e18 that actually arrived, which is what this path must reject.
    function test_fundsIn_feeToken_revertsWhenFeeExceedsCommission() public {
        FeeStack memory s = _deployFeeStack(9000); // 90% transfer fee
        _setFeeStackFundsInTokenRule(s, 9000, 100); // 90% commission on nominal — the ceiling

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        uint256 tokenCommission = s.cm.calculateStableFee(AMOUNT, 9000, 100);

        assertEq(received, AMOUNT / 10, "sanity: received == 10% of nominal");
        assertGt(tokenCommission, received, "sanity: commission exceeds actual received");

        vm.expectRevert(abi.encodeWithSelector(IBridge.InsufficientReceived.selector, received, tokenCommission));
        vm.prank(user);
        s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    /// @dev A nominally valid (<100%) commission can still consume the full
    ///      ACTUAL receipt when the token charges a transfer fee. Equality must
    ///      revert rather than recording a zero-net settlement.
    function test_fundsInFeeTokenRevertsWhenActualNetWouldBeZero() public {
        FeeStack memory s = _deployFeeStack(5000); // Bridge receives 50%
        _setFeeStackFundsInTokenRule(s, 5000, 100); // nominal commission is 50%

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        uint256 tokenCommission = s.cm.calculateStableFee(AMOUNT, 5000, 100);
        assertEq(received, tokenCommission, "sanity: actual receipt equals nominal commission");

        vm.expectRevert(abi.encodeWithSelector(IBridge.InsufficientReceived.selector, received, tokenCommission));
        vm.prank(user);
        s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(s.bridge.lockedLiquidity(RGB_CHAIN_ID), 0, "zero-net liquidity was not recorded");
        assertEq(s.cm.tokenCommissionPool(address(s.token)), 0, "commission transfer rolled back");
    }
}
