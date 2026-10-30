// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {OutflowRateLimiter} from "../../src/libraries/OutflowRateLimiter.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Outflow policy configuration, bucket refill and aggregate limits.
contract BridgeOutflowPolicyTest is BridgeTestBase {
    /// @dev Convert an absolute token amount into bps of a chain's reference
    ///      liquidity, so bucket tests can keep expressing intent in amounts.
    function _bpsOfChain(uint256 chainId, uint256 amount) private view returns (uint256) {
        return amount * bridge.BPS_DENOMINATOR() / bridge.lockedLiquidity(chainId);
    }

    /// @dev Same conversion against aggregate liquidity, for the global bucket.
    function _bpsOfGlobal(uint256 amount) private view returns (uint256) {
        return amount * bridge.BPS_DENOMINATOR() / bridge.totalLockedLiquidity();
    }

    /// @dev Configure the RGB bucket from absolute token amounts, converted to
    ///      bps of the chain's current reference liquidity: `burstAmount` is the
    ///      instant allowance, `refillAmountPerWindow` the amount restored over
    ///      one `BUCKET_REFILL_WINDOW`.
    function _setRGBBucket(uint256 burstAmount, uint256 refillAmountPerWindow) private {
        // Resolve the bps values first: each `_bpsOfChain` makes an external view
        // call, which would consume a pending `vm.prank`.
        uint256 burstBps = _bpsOfChain(RGB_CHAIN_ID, burstAmount);
        uint256 refillBps = _bpsOfChain(RGB_CHAIN_ID, refillAmountPerWindow);
        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, refillBps);
    }

    function test_outflow_fullBucketAllowsCapacityRejectsOverByOne() public {
        _seedRGB(1000e6);
        uint256 cap = 100e6;
        _setRGBBucket(cap, cap); // reconfig down → available == cap

        _releaseRGB(cap, keccak256("chain-capacity-first-burst"));
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "capacity fully spent");

        // One unit over the (now empty) bucket but still within capacity → rate-limited.
        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.TokenOutflowThrottled.selector, uint256(1), uint256(0), address(usdt0)
            )
        );
        _releaseRGB(1, keccak256("chain-capacity-next-unit"));
    }

    function test_outflow_releaseAboveCapacityReverts() public {
        _seedRGB(1000e6);
        uint256 cap = 100e6;
        _setRGBBucket(cap, cap);

        // Full bucket, but the request exceeds capacity entirely → a different,
        // more-specific error than the rate-limit one.
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 10_000e6, "fixture liquidity fixes the share conversion");
        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.TokenRequestAboveCapacity.selector,
                uint128(10_000_000_000_000_000),
                uint256(10_000_000_100_000_000),
                address(usdt0)
            )
        );
        _releaseRGB(cap + 1, keccak256("chain-above-capacity-request"));
    }

    function test_outflow_refillAccruesOverTime() public {
        _seedRGB(1000e6);
        uint256 cap = 100e6;
        _setRGBBucket(cap, cap);

        _releaseRGB(cap, keccak256("partial-refill-first-burst"));
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "drained");

        // Half the share capacity is restored. Its token value is calculated
        // against the current 9,900 liquidity after the first release.
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        uint256 refilled = bridge.availableOutflow(RGB_CHAIN_ID);
        uint256 expectedRefill = bridge.lockedLiquidity(RGB_CHAIN_ID) * 50 / bridge.BPS_DENOMINATOR();
        assertApproxEqRel(refilled, expectedRefill, 1e12, "partial linear refill"); // 1e-6 relative

        _releaseRGB(refilled - 1, keccak256("partial-refill-second-burst")); // the refilled allowance is spendable
    }

    function test_outflow_noDoubleCapBurstOverShortGap() public {
        _seedRGB(1000e6);
        uint256 cap = 100e6;
        _setRGBBucket(cap, cap);

        _releaseRGB(cap, keccak256("short-gap-first-burst"));
        vm.warp(vm.getBlockTimestamp() + 1); // one second later

        uint256 accrued = bridge.availableOutflow(RGB_CHAIN_ID);
        uint256 policyBps = 100;
        uint256 expectedAccrued =
            bridge.lockedLiquidity(RGB_CHAIN_ID) * policyBps / bridge.BPS_DENOMINATOR() / bridge.BUCKET_REFILL_WINDOW();
        assertApproxEqRel(accrued, expectedAccrued, 1e12, "only one second of refill accrued");
        assertLt(accrued, cap, "not a fresh cap");
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = _seedOpId;

        uint256 currentCapacity = bridge.lockedLiquidity(RGB_CHAIN_ID) * policyBps / bridge.BPS_DENOMINATOR();
        uint256 expectedRefillShares =
            bridge.SHARE_UNIT() * policyBps / bridge.BPS_DENOMINATOR() / bridge.BUCKET_REFILL_WINDOW();
        // The error reports shares rather than token units. The 1% share budget
        // refills over one window, with its per-second rate rounded down.
        // Rounded-down accrual leaves a full day of retry time for the whole cap.
        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.TokenOutflowThrottled.selector, uint256(1 days), expectedRefillShares, address(usdt0)
            )
        );
        vm.prank(multisig);
        _fundsOut(
            recipient,
            currentCapacity,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(ids),
            SRC_BURN_TX_ID
        );
    }

    function test_outflow_perChainIsolation() public {
        uint256 other = 888;
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, other, true, address(rgbVerifier), address(rgbModule));
        vm.prank(deployer);
        routeRegistry.setRoute(other, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        usdt0.mint(user, 500e6);
        vm.prank(user);
        bridge.fundsIn(500e6, other, DST_ADDR, _rgbData(RGB_OP_ID + 888));

        uint256 otherBps = _bpsOfChain(other, 50e6);
        vm.prank(multisig);
        bridge.setOutflowLimit(other, otherBps, otherBps);

        _seedRGB(1000e6);
        _setRGBBucket(100e6, 100e6);
        _releaseRGB(100e6, keccak256("isolated-rgb-bucket-drain")); // drain RGB bucket to 0

        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "RGB drained");
        assertEq(bridge.availableOutflow(other), 50e6, "other chain bucket untouched");
    }

    function test_outflow_globalBucketBoundsAggregate() public {
        _seedRGB(1000e6);
        // Keep the per-chain bucket large; tighten only the global bucket.
        uint256 globalBps = _bpsOfGlobal(100e6);
        vm.prank(multisig);
        bridge.setGlobalOutflowLimit(globalBps, globalBps);

        _releaseRGB(100e6, keccak256("global-bucket-first-burst")); // consumes the whole global allowance
        assertEq(bridge.availableGlobalOutflow(), 0, "global drained");

        // The per-chain bucket still has room, but the global aggregate trips.
        vm.expectRevert(
            abi.encodeWithSelector(OutflowRateLimiter.AggregateOutflowThrottled.selector, uint256(1), uint256(0))
        );
        _releaseRGB(1, keccak256("global-bucket-next-unit"));
    }

    function test_outflow_reconfigPreservesAvailableNoGift() public {
        _seedRGB(1000e6);
        _setRGBBucket(100e6, 100e6);
        _releaseRGB(60e6, keccak256("carry-over-bucket-debit")); // 40 bps of shares remain
        uint256 availableBefore = bridge.availableOutflow(RGB_CHAIN_ID);
        assertEq(availableBefore, 39.76e6, "pre");

        // Raising capacity must NOT gift a fresh full bucket.
        _setRGBBucket(200e6, 200e6);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), availableBefore, "available preserved, not gifted");
    }

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

        vm.prank(multisig);
        bridge.setGlobalOutflowLimit(MAX_BURST_BPS, MAX_REFILL_BPS);
        assertGt(bridge.availableGlobalOutflow(), 0, "global bucket is configured independently");
        bytes32[] memory ids = _ids(opId);
        vm.expectRevert(OutflowRateLimiter.LimitNotConfigured.selector);
        vm.prank(multisig);
        _fundsOut(recipient, 100e6, unconfigured, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(ids), SRC_BURN_TX_ID);
    }

    function test_outflow_downstreamRevertRestoresBuckets() public {
        _seedRGB(1000e6);
        _setRGBBucket(100e6, 100e6);

        uint256 globalBefore = bridge.availableGlobalOutflow();
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown"), LATEST_HEIGHT, LATEST_COMMIT);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = _seedOpId;

        vm.expectRevert("verify: block commitment");
        vm.prank(multisig);
        _fundsOut(recipient, 50e6, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, badProof, _settlement(ids), SRC_BURN_TX_ID);

        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 100e6, "per-chain restored");
        assertEq(bridge.availableGlobalOutflow(), globalBefore, "global restored");
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
    ///      `MAX_CHAIN_OUTFLOW_BPS`, so no policy authorizes more than 20% of
    ///      reference liquidity in one release — at any liquidity level.
    function test_setOutflowLimit_rejectsBurstAboveImmutableCeiling() public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, maxBps + 1, uint256(1), maxBps));
        bridge.setOutflowLimit(RGB_CHAIN_ID, maxBps + 1, 1);
    }

    function test_setOutflowLimit_rejectsRefillAboveImmutableCeiling() public {
        uint256 maximum = bridge.MAX_CHAIN_OUTFLOW_BPS();
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, uint256(1), maximum + 1, maximum));
        bridge.setOutflowLimit(RGB_CHAIN_ID, 1, maximum + 1);
    }

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
    function test_setOutflowLimit_acceptsValidPolicyAtZeroLiquidity() public {
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
    function test_availableOutflow_scalesWithAccountedLiquidity() public {
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

    function test_setOutflowLimits_revertsForNonOwner() public {
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
        emit IBridge.OutflowLimitUpdated(RGB_CHAIN_ID, burstBps, refillBps, expectedShares);
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
        _releaseRGB(drain, keccak256("fuzz-share-space-debit"));

        vm.warp(vm.getBlockTimestamp() + elapsed);

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

        (uint128 sharesBefore,,,,) = bridge.chainBuckets(RGB_CHAIN_ID);
        _releaseRGB(amount, keccak256("combined-policy-capacity-debit"));

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
}
