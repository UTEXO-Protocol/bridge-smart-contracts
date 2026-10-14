// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "forge-std/Test.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {BridgeRebalanceTestBase} from "./BridgeRebalanceTestBase.sol";

/// @notice Rebalances and releases share one source-burn replay namespace.
contract BridgeRebalanceReplayTest is BridgeRebalanceTestBase {
    address internal recipient = makeAddr("recipient");

    /// @dev One 96 burn described twice: as a 96 -> Arch rebalance and as a
    ///      96 -> EVM release. Every key field matches; only the destination
    ///      differs, and both carry the rebalance-derived `burnId`.
    function _seedMintBurnBurnOnBothPaths()
        private
        returns (IBridge.RebalanceParams memory p, IBridge.FundsOutParams memory release)
    {
        usdt0.mint(user, AMOUNT * 19);
        vm.prank(user);
        bytes32 backingOperationId =
            bridge.fundsIn(AMOUNT, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 3_000));
        // Headroom under the 10% bucket burst; each deposit stays within uint64.
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 9, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 3_001));
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 9, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 3_002));

        p = _productionRgbToArchParams(AMOUNT, backingOperationId);
        release = IBridge.FundsOutParams({
            recipient: recipient,
            amount: p.amount,
            burnId: p.burnId,
            sourceChainId: p.sourceChainId,
            destinationChainId: SOURCE_CHAIN_ID,
            sourceAddress: p.sourceAddress,
            proof: p.proof,
            settlementData: p.settlementDataOut,
            sourceBurnTxId: p.sourceBurnTxId
        });
        assertTrue(release.destinationChainId != p.destinationChainId, "paths credit different destinations");
    }

    function test_rebalanceLiquidity_revertsIdenticalIntentReplay() public {
        // An identical rebalance intent derives the SAME burnId (no nonce), so
        // the second attempt is rejected as a consumed replay — matching
        // fundsOut's replay model exactly.
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        _rebalance(p);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_revertsBurnBackedIdenticalIntentReplay() public {
        // Same on-chain replay protection as fundsOut: an identical canonical
        // debit intent derives the same burnId, regardless of the moving proof,
        // so the consumed guard rejects the second attempt. Enclaves own the
        // trust assumption that all included fields are reconstructed
        // canonically from the validated consignment.
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        _rebalance(p);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_operationIdUniquePerBurnEvenWithEmptySettlementIn() public {
        // Two RGB→Arch rebalances identical on the credit side (same source,
        // amount, destination, empty settlementDataIn) but backed by DIFFERENT
        // burns (different sourceBurnTxId + referenced records) must NOT collide on
        // operationId — the event that drives the Arch destination flow.
        // operationId folds in burnId, so debit-side differences propagate.

        // Second RGB deposit → a distinct record to reference for the 2nd burn.
        usdt0.mint(user, AMOUNT);
        vm.prank(user);
        bytes32 secondSeedOpId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 50));

        IBridge.RebalanceParams memory first = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        IBridge.RebalanceParams memory second = _rgbToArchParams(AMOUNT, secondSeedOpId);
        // These helpers name distinct sourceBurnTxIds. The burn identifier,
        // rather than the referenced backing records, separates the keys.
        assertTrue(first.burnId != second.burnId, "distinct burnId per referenced burn");
        assertTrue(
            _deriveRebalanceOpId(first) != _deriveRebalanceOpId(second),
            "operationId must differ when only the debit side differs"
        );

        // Capture the emitted operationIds and assert they are distinct.
        vm.recordLogs();
        _rebalance(first);
        vm.warp(vm.getBlockTimestamp() + bridge.BUCKET_REFILL_WINDOW() + 1);
        _rebalance(second);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 rebalanceTopic =
            keccak256("BridgeRebalance(bytes32,uint256,uint256,uint256,uint256,string,string,bytes,bytes)");
        bytes32 firstOpId;
        bytes32 secondOpId;
        bool haveFirst;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == rebalanceTopic) {
                if (!haveFirst) {
                    firstOpId = logs[i].topics[1];
                    haveFirst = true;
                } else {
                    secondOpId = logs[i].topics[1];
                }
            }
        }
        assertTrue(haveFirst && secondOpId != bytes32(0), "two BridgeRebalance events captured");
        assertTrue(firstOpId != secondOpId, "emitted operationIds distinct");
    }

    // ========================================================================
    // shared replay namespace across fundsOut and rebalanceLiquidity
    // Both paths derive `burnId` under the same `BURN_TYPEHASH` from the same
    // fields, so one source-chain burn settles at most once no matter which
    // path is used. Both entrypoints must preserve this shared replay namespace.
    // ========================================================================

    /// @notice A rebalance and a release describing the same burn derive the
    ///         same `burnId`, so the second one is rejected as a replay.
    function test_replayProtection_sameBurnCannotUseBothReleaseAndRebalance() public {
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        _rebalance(p);
        assertTrue(bridge.consumedBurnIds(p.burnId), "rebalance consumed the id");

        // Same burn, same amount, same route — now as a physical release.
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        vm.prank(multisig);
        bridge.fundsOut(
            IBridge.FundsOutParams({
                recipient: recipient,
                amount: p.amount,
                burnId: p.burnId,
                sourceChainId: p.sourceChainId,
                destinationChainId: p.destinationChainId,
                sourceAddress: p.sourceAddress,
                proof: p.proof,
                settlementData: bytes.concat(p.settlementDataOut, hex"00"),
                sourceBurnTxId: p.sourceBurnTxId
            })
        );
    }

    /// @notice One RGB mint/burn-network burn, migrated to Arch (96 -> Arch)
    ///         and then released to EVM (96 -> EVM). The two
    ///         paths carry different `destinationChainId`s, so the key must not
    ///         include it — otherwise the same burn settles once on each path.
    function test_replayProtection_rebalancedBurnCannotReleaseToAnotherDestination() public {
        (IBridge.RebalanceParams memory p, IBridge.FundsOutParams memory release) = _seedMintBurnBurnOnBothPaths();

        _rebalance(p);
        assertTrue(bridge.consumedBurnIds(p.burnId), "rebalance consumed the id");
        release.settlementData = bytes.concat(release.settlementData, hex"00");

        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        vm.prank(multisig);
        bridge.fundsOut(release);
    }

    /// @notice A physical release prevents rebalance of the same burn toward
    ///         a different destination bucket.
    function test_replayProtection_releasedBurnCannotRebalanceToAnotherDestination() public {
        (IBridge.RebalanceParams memory p, IBridge.FundsOutParams memory release) = _seedMintBurnBurnOnBothPaths();

        vm.prank(multisig);
        bridge.fundsOut(release);
        assertTrue(bridge.consumedBurnIds(release.burnId), "fundsOut consumed the id");
        p.settlementDataOut = bytes.concat(p.settlementDataOut, hex"00");
        assertEq(_deriveRebalanceBurnId(p), release.burnId);

        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        _rebalance(p);
    }

    function test_rebalanceLiquidity_changedBackingRecordsCannotReplaySameBurn() public {
        usdt0.mint(user, AMOUNT);
        vm.prank(user);
        bytes32 otherRecord = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 51));
        IBridge.RebalanceParams memory first = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        IBridge.RebalanceParams memory second = _rgbToArchParams(AMOUNT, otherRecord);
        second.sourceBurnTxId = first.sourceBurnTxId;
        second.burnId = _deriveRebalanceBurnId(second);
        assertEq(second.burnId, first.burnId, "backing records do not change burn identity");

        _rebalance(first);
        uint256 sourceLiquidity = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 destinationLiquidity = bridge.lockedLiquidity(ARCH_CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, first.burnId));
        _rebalance(second);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), sourceLiquidity);
        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), destinationLiquidity);
        assertEq(rgbModule.fundsInRecords(otherRecord), AMOUNT);
    }

    /// @dev Credit-leg data can change without changing the source-burn identity.
    function test_rebalanceLiquidity_changedCreditDataPreservesBurnAndReplayProtection() public {
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        p.settlementDataIn = abi.encode(uint256(0xFEED));
        uint256 sourceBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 destinationBefore = bridge.lockedLiquidity(ARCH_CHAIN_ID);
        uint256 totalBefore = bridge.totalLockedLiquidity();
        _rebalance(p);
        assertTrue(bridge.consumedBurnIds(p.burnId), "modified credit data accepts the original burn key");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), sourceBefore - AMOUNT, "source is debited once");
        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), destinationBefore + AMOUNT, "destination is credited once");
        assertEq(bridge.totalLockedLiquidity(), totalBefore, "rebalance conserves total liquidity");
        p.settlementDataIn = abi.encode(uint256(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        _rebalance(p);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), sourceBefore - AMOUNT, "replay cannot debit twice");
        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), destinationBefore + AMOUNT, "replay cannot credit twice");
        assertEq(bridge.totalLockedLiquidity(), totalBefore, "replay preserves total liquidity");
        assertEq(rgbModule.fundsInRecords(rgbSeedOpId), AMOUNT * 10, "backing record remains permanent");
    }

    /// @dev Two source transactions can reuse the same permanent backing record.
    function test_rebalanceLiquidity_acceptsDistinctBurnsAgainstSameRecord() public {
        IBridge.RebalanceParams memory first = _rgbToArchParams(AMOUNT / 4, rgbSeedOpId);
        IBridge.RebalanceParams memory second = _rgbToArchParams(AMOUNT / 4, rgbSeedOpId);
        second.sourceBurnTxId = keccak256("another-source-burn");
        second.burnId = _deriveRebalanceBurnId(second);
        assertNotEq(first.burnId, second.burnId, "distinct source transactions have distinct keys");
        uint256 sourceBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 destinationBefore = bridge.lockedLiquidity(ARCH_CHAIN_ID);
        _rebalance(first);
        _rebalance(second);
        assertTrue(bridge.consumedBurnIds(first.burnId), "first burn consumed");
        assertTrue(bridge.consumedBurnIds(second.burnId), "second burn consumed");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), sourceBefore - AMOUNT / 2, "both releases debit source");
        assertEq(
            bridge.lockedLiquidity(ARCH_CHAIN_ID), destinationBefore + AMOUNT / 2, "both releases credit destination"
        );
        assertEq(rgbModule.fundsInRecords(rgbSeedOpId), AMOUNT * 10, "shared backing record remains permanent");
    }

    /// @notice Bridge refuses a settlement that does not name its source burn.
    ///         The guard is route-agnostic on purpose: every chain supplies a
    ///         burn id, and it is the only field that keeps `burnId` distinct on
    ///         routes whose `settlementData` is empty.
    function test_rebalanceLiquidity_revertsOnZeroSourceBurnTxId() public {
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        p.sourceBurnTxId = bytes32(0);
        p.burnId = _deriveRebalanceBurnId(p);

        vm.expectRevert(IBridge.ZeroSourceBurnTxId.selector);
        _rebalance(p);
    }

    /// @notice An empty `sourceAddress` hashes to keccak256 of the empty byte
    ///         string, not to zero. Pinned so an off-chain signer that encodes it
    ///         differently fails here rather than on-chain with InvalidBurnId.
    function test_burnIdentity_emptySourceAddressUsesKnownHash() public pure {
        assertEq(
            keccak256(bytes("")),
            bytes32(0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470),
            "empty string hash"
        );
    }

    function test_rebalanceLiquidity_duplicateRgbMintAfterDepositRestoresDebitAndReplayState() public {
        uint256 mintOpId = RGB_OP_ID + 500;
        usdt0.mint(user, AMOUNT);
        vm.prank(user);
        bytes32 depositId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, RGB_DST_ADDR, abi.encode(mintOpId));
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, mintOpId);
        assertEq(_deriveRebalanceOpId(p), depositId, "deposit and credit leg share the identity");
        uint256 sourceBefore = bridge.lockedLiquidity(ARCH_CHAIN_ID);
        uint256 destinationBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 totalBefore = bridge.totalLockedLiquidity();
        uint256 allowanceBefore = bridge.availableOutflow(ARCH_CHAIN_ID);
        uint256 safetyBefore = bridge.availableChainSafetyOutflow(ARCH_CHAIN_ID);

        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), sourceBefore);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), destinationBefore);
        assertEq(bridge.totalLockedLiquidity(), totalBefore);
        assertEq(bridge.availableOutflow(ARCH_CHAIN_ID), allowanceBefore);
        assertEq(bridge.availableChainSafetyOutflow(ARCH_CHAIN_ID), safetyBefore);
        assertEq(rgbModule.fundsInRecords(depositId), AMOUNT);
        assertFalse(bridge.consumedBurnIds(p.burnId), "failed credit does not consume burn");
    }

    function test_fundsIn_duplicateRgbMintAfterRebalanceReverts() public {
        uint256 mintOpId = RGB_OP_ID + 501;
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, mintOpId);
        _rebalance(p);
        usdt0.mint(user, AMOUNT);
        uint256 balanceBefore = usdt0.balanceOf(user);
        uint256 totalBefore = bridge.totalLockedLiquidity();
        uint256 nonceBefore = bridge.sourceSenderNonces(SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))));
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, RGB_DST_ADDR, abi.encode(mintOpId));
        assertEq(usdt0.balanceOf(user), balanceBefore);
        assertEq(bridge.totalLockedLiquidity(), totalBefore);
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, bytes32(uint256(uint160(user)))), nonceBefore);
        assertEq(rgbModule.fundsInRecords(_deriveRebalanceOpId(p)), AMOUNT);
    }

    function test_rebalanceLiquidity_distinctBurnCannotBackTheSameRgbMintTwice() public {
        // Keep room for both debit attempts under the source bucket limit.
        IBridge.RebalanceParams memory first = _archToRgbParams(AMOUNT / 4, RGB_OP_ID + 502);
        _rebalance(first);
        IBridge.RebalanceParams memory second = first;
        second.sourceBurnTxId = keccak256("different-debit-burn-same-credit-mint");
        second.burnId = _deriveRebalanceBurnId(second);
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        _rebalance(second);
        assertFalse(bridge.consumedBurnIds(second.burnId));
    }
}
