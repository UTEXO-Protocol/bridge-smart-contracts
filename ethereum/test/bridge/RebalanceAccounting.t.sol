// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "forge-std/Test.sol";
import {BridgeBaseUpgradeable} from "../../src/BridgeBaseUpgradeable.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {OutflowRateLimiter} from "../../src/libraries/OutflowRateLimiter.sol";
import {BridgeRebalanceTestBase} from "./BridgeRebalanceTestBase.sol";

/// @notice Rebalances migrate release capacity without moving custody.
contract BridgeRebalanceAccountingTest is BridgeRebalanceTestBase {
    /// @dev Reverse mint/burn rebalance, with a burn-backed primary-network debit.
    function _rgbToSecondaryRgbParams(uint256 amount, uint256 rgbOpId)
        private
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: RGB_CHAIN_ID,
            destinationChainId: SECONDARY_RGB_CHAIN_ID,
            sourceAddress: RGB_SRC_ADDR,
            destinationAddress: RGB_DST_ADDR,
            proof: _proof(),
            settlementDataOut: _settlementFromRecord(rgbSeedOpId),
            settlementDataIn: abi.encode(rgbOpId),
            sourceBurnTxId: rgbSeedOpId
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    function test_rebalanceLiquidity_revertsLocalDestinationWithoutChangingAccounting() public {
        uint256 backingMint = RGB_OP_ID + 600;
        usdt0.mint(user, AMOUNT * 10);
        vm.prank(user);
        bytes32 backing =
            bridge.fundsIn(AMOUNT * 10, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, RGB_DST_ADDR, abi.encode(backingMint));
        IBridge.RebalanceParams memory p = _productionRgbToArchParams(AMOUNT, backing);
        p.destinationChainId = SOURCE_CHAIN_ID;
        p.destinationAddress = "";
        p.settlementDataIn = abi.encode(RGB_OP_ID + 601);
        bytes32 operationId = _deriveRebalanceOpId(p);
        uint256 sourceBefore = bridge.lockedLiquidity(p.sourceChainId);
        uint256 destinationBefore = bridge.lockedLiquidity(p.destinationChainId);
        uint256 totalBefore = bridge.totalLockedLiquidity();
        uint256 bridgeBalanceBefore = usdt0.balanceOf(address(bridge));

        vm.expectRevert(IBridge.InvalidDestinationChainId.selector);
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(p.sourceChainId), sourceBefore, "source bucket unchanged");
        assertEq(bridge.lockedLiquidity(p.destinationChainId), destinationBefore, "local bucket unchanged");
        assertEq(bridge.totalLockedLiquidity(), totalBefore, "total liquidity unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBalanceBefore, "custody unchanged");
        assertEq(rgbModule.fundsInRecords(operationId), 0, "no RGB credit record");
        assertFalse(bridge.consumedBurnIds(p.burnId), "burn id remains unused");
    }

    function test_rebalanceLiquidity_archToRgbMovesBucketsAndWritesRecord() public {
        uint256 srcBefore = bridge.lockedLiquidity(ARCH_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 mintOpId = RGB_OP_ID + 1;

        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, mintOpId);
        bytes32 expectedOpId = _deriveRebalanceOpId(p);

        // Credit-RGB rebalance emits the standard FundsIn (the RGB side needs
        // no rebalance awareness) plus the canonical BridgeRebalance.
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(multisig, mintOpId, uint64(AMOUNT));
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.BridgeRebalance(
            expectedOpId,
            p.burnId,
            ARCH_CHAIN_ID,
            RGB_CHAIN_ID,
            AMOUNT,
            ARCH_SRC_ADDR,
            RGB_DST_ADDR,
            p.settlementDataOut,
            p.settlementDataIn
        );

        _rebalance(p);

        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), srcBefore - AMOUNT, "source bucket debited");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), dstBefore + AMOUNT, "destination bucket credited");
        assertEq(rgbModule.fundsInRecords(expectedOpId), AMOUNT, "mint record written for the credit leg");
        assertTrue(bridge.consumedBurnIds(p.burnId), "replay key consumed");
    }

    function test_rebalanceLiquidity_rgbCreditRejectsAmountAboveUint64WithoutChangingAccounting() public {
        uint256 amount = uint256(type(uint64).max) + 1;
        uint256 additionalLiquidity = amount * 10;

        // The non-RGB deposit leg may hold a uint256 amount. It provides enough
        // source liquidity and bucket capacity to reach the RGB event boundary.
        usdt0.mint(user, additionalLiquidity);
        vm.prank(user);
        bridge.fundsIn(additionalLiquidity, ARCH_CHAIN_ID, ARCH_DST_ADDR, "");

        IBridge.RebalanceParams memory p = _archToRgbParams(amount, RGB_OP_ID + 9_000);
        bytes32 operationId = _deriveRebalanceOpId(p);
        uint256 sourceBefore = bridge.lockedLiquidity(ARCH_CHAIN_ID);
        uint256 destinationBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);

        vm.expectRevert(abi.encodeWithSelector(BridgeBaseUpgradeable.AmountExceedsUint64.selector, amount));
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), sourceBefore, "source debit rolled back");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), destinationBefore, "destination credit rolled back");
        assertEq(rgbModule.fundsInRecords(operationId), 0, "RGB settlement write rolled back");
        assertFalse(bridge.consumedBurnIds(p.burnId), "burn id remains unused");
    }

    function test_rebalanceLiquidity_rgbToArchBurnBackedNoFundsInEvent() public {
        uint256 srcBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(ARCH_CHAIN_ID);

        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);

        vm.recordLogs();
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), srcBefore - AMOUNT, "source bucket debited");
        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), dstBefore + AMOUNT, "destination bucket credited");

        // The credit leg wrote nothing and returned 0, so no RGB-only FundsIn
        // event may appear — only BridgeRebalance.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 fundsInTopic = keccak256("FundsIn(address,uint256,uint64)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != fundsInTopic, "no FundsIn event on a non-RGB credit leg");
        }
    }

    function test_rebalanceLiquidity_movesNoTokens() public {
        uint256 bridgeBalanceBefore = usdt0.balanceOf(address(bridge));
        _rebalance(_archToRgbParams(AMOUNT, RGB_OP_ID + 1));
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBalanceBefore, "custody unchanged");
    }

    function test_rebalanceLiquidity_secondaryRgbToRgbChecksSourceLedgerWritesDestLedger() public {
        uint256 srcBefore = bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 destinationOpId = RGB_OP_ID + 200;

        IBridge.RebalanceParams memory p = _secondaryRgbToRgbParams(AMOUNT, secondaryRgbSeedOpId, destinationOpId);
        bytes32 expectedOpId = _deriveRebalanceOpId(p);

        // Both sides are RGB: the debit leg verifies the mint/burn record and the
        // credit leg writes a NEW destination record + emits FundsIn — all on the one
        // shared module, no composite module or privileged writer.
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(multisig, destinationOpId, uint64(AMOUNT));
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID), srcBefore - AMOUNT, "secondary RGB bucket debited");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), dstBefore + AMOUNT, "primary RGB bucket credited");
        assertEq(rgbModule.fundsInRecords(expectedOpId), AMOUNT, "destination mint record written by credit leg");
        assertEq(rgbModule.fundsInRecordChainIds(expectedOpId), RGB_CHAIN_ID, "record tagged with primary RGB network");
    }

    function test_rebalanceLiquidity_rgbToSecondaryRgbBurnBacked() public {
        uint256 srcBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID);
        uint256 inflateOpId = RGB_OP_ID + 300;

        IBridge.RebalanceParams memory p = _rgbToSecondaryRgbParams(AMOUNT, inflateOpId);
        bytes32 expectedOpId = _deriveRebalanceOpId(p);

        // Both sides use mint/burn: the source burn is verified and the credit
        // creates a new record tagged with the secondary RGB network.
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(multisig, inflateOpId, uint64(AMOUNT));
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), srcBefore - AMOUNT, "primary RGB bucket debited");
        assertEq(bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID), dstBefore + AMOUNT, "secondary RGB bucket credited");
        assertEq(rgbModule.fundsInRecords(expectedOpId), AMOUNT, "mint/burn record written by credit leg");
        assertEq(
            rgbModule.fundsInRecordChainIds(expectedOpId),
            SECONDARY_RGB_CHAIN_ID,
            "record tagged with the mint/burn network"
        );
    }

    function test_rebalanceLiquidity_preservesTotalLockedLiquidity() public {
        uint256 totalBefore = bridge.lockedLiquidity(RGB_CHAIN_ID) + bridge.lockedLiquidity(ARCH_CHAIN_ID)
            + bridge.lockedLiquidity(SOURCE_CHAIN_ID) + bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID);
        uint256 accountedTotalBefore = bridge.totalLockedLiquidity();

        _rebalance(_archToRgbParams(AMOUNT, RGB_OP_ID + 1));

        uint256 totalAfter = bridge.lockedLiquidity(RGB_CHAIN_ID) + bridge.lockedLiquidity(ARCH_CHAIN_ID)
            + bridge.lockedLiquidity(SOURCE_CHAIN_ID) + bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID);
        assertEq(totalAfter, totalBefore, "sum(lockedLiquidity) preserved exactly");
        assertEq(bridge.totalLockedLiquidity(), accountedTotalBefore, "accounted global TVL preserved exactly");
        assertEq(bridge.totalLockedLiquidity(), totalAfter, "global TVL matches isolated liquidity sum");
    }

    function test_rebalanceLiquidity_spendsChainBucketNotGlobal() public {
        uint256 chainBefore = bridge.availableOutflow(ARCH_CHAIN_ID);
        uint256 globalBefore = bridge.availableGlobalOutflow();

        _rebalance(_archToRgbParams(AMOUNT, RGB_OP_ID + 1));

        assertEq(bridge.availableOutflow(ARCH_CHAIN_ID), chainBefore - AMOUNT, "source chain bucket spent");
        assertEq(bridge.availableGlobalOutflow(), globalBefore, "global bucket untouched (no token egress)");
    }

    function test_rebalanceLiquidity_bucketCapacityDoesNotDecayWhenRollingUsageExpires() public {
        vm.warp((vm.getBlockTimestamp() / 1 hours + 1) * 1 hours);
        uint256 startedAt = vm.getBlockTimestamp();

        _rebalance(_archToRgbParams(AMOUNT, RGB_OP_ID + 1));
        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), AMOUNT * 9, "actual source liquidity debited");

        vm.warp(startedAt + 24 hours + 1 minutes);
        assertEq(bridge.chainOutflowReference(ARCH_CHAIN_ID), AMOUNT * 9, "pre-expiry bucket reference");
        assertEq(bridge.availableOutflow(ARCH_CHAIN_ID), AMOUNT * 9 / 10, "pre-expiry full bucket");

        // AMOUNT exceeds capacity priced against the remaining 9 × AMOUNT
        // liquidity, so it is rejected before rolling usage expires.
        IBridge.RebalanceParams memory oversized = _archToRgbParams(AMOUNT, RGB_OP_ID + 2);
        uint256 capacityShares = MAX_BURST_BPS * bridge.SHARE_UNIT() / bridge.BPS_DENOMINATOR();
        uint256 requestedShares = (AMOUNT * bridge.SHARE_UNIT() + AMOUNT * 9 - 1) / (AMOUNT * 9);
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.TokenRequestAboveCapacity.selector, capacityShares, requestedShares, address(usdt0)
            )
        );
        bridge.rebalanceLiquidity(oversized);

        vm.warp(startedAt + 25 hours);
        uint256 validAmount = AMOUNT * 9 / 10;
        assertEq(bridge.chainOutflowReference(ARCH_CHAIN_ID), AMOUNT * 9, "post-expiry bucket reference");
        assertEq(bridge.availableOutflow(ARCH_CHAIN_ID), validAmount, "post-expiry full bucket unchanged");

        _rebalance(_archToRgbParams(validAmount, RGB_OP_ID + 3));
        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), AMOUNT * 81 / 10, "valid tranche executes after expiry");
    }

    function test_rebalanceLiquidity_distinctMintsDifferInDestinationOpId() public {
        // Legitimately distinct credit-side rebalances differ in the destination
        // RGB OpId (settlementDataIn), which makes their credit ids distinct.
        // The fixture also assigns distinct source burn ids. Both execute.
        IBridge.RebalanceParams memory first = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        bytes32 firstOpId = _deriveRebalanceOpId(first);
        _rebalance(first);

        IBridge.RebalanceParams memory second = _archToRgbParams(AMOUNT, RGB_OP_ID + 2);
        bytes32 secondOpId = _deriveRebalanceOpId(second);
        assertTrue(first.burnId != second.burnId, "distinct burnId per destination OpId");
        assertTrue(firstOpId != secondOpId, "distinct operationId per destination OpId");

        // Restore the source liquidity so the same absolute amount remains 10%
        // of the live bucket reference. This test isolates destination OpId as
        // the only intent difference rather than relying on rolling usage to
        // preserve a stale, higher reference.
        usdt0.mint(user, AMOUNT);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, ARCH_CHAIN_ID, ARCH_DST_ADDR, "");
        vm.warp(vm.getBlockTimestamp() + bridge.BUCKET_REFILL_WINDOW() + 1);
        _rebalance(second);

        assertEq(rgbModule.fundsInRecords(firstOpId), AMOUNT);
        assertEq(rgbModule.fundsInRecords(secondOpId), AMOUNT);
    }

    function test_rebalanceLiquidity_succeedsDuringInflowOnlyPause() public {
        // Inflow-only pause is documented as "withdrawals stay open for
        // liquidity migration" — rebalance IS a liquidity migration.
        vm.prank(multisig);
        bridge.pauseInflow();
        uint256 destinationBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        _rebalance(_archToRgbParams(AMOUNT, RGB_OP_ID + 1));
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), destinationBefore + AMOUNT);
    }
}
