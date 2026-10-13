// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BridgeBaseUpgradeable} from "../../src/BridgeBaseUpgradeable.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {IRouteRegistry} from "../../src/interfaces/IRouteRegistry.sol";
import {OutflowRateLimiter} from "../../src/libraries/OutflowRateLimiter.sol";
import {RgbOutboundSettlementModule} from "../../src/settlement/RgbOutboundSettlementModule.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {BridgeRebalanceTestBase} from "./BridgeRebalanceTestBase.sol";

/// @notice Rebalance authorization, payload bounds and route checks.
contract BridgeRebalanceValidationTest is BridgeRebalanceTestBase {
    /// @dev `len` bytes of 0x61: non-zero, so a 32-byte prefix decodes as a
    ///      non-zero word.
    function _filledBytes(uint256 len) private pure returns (bytes memory b) {
        b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = 0x61;
        }
    }

    function test_rebalanceLiquidity_revertsNotOwner() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_revertsInvalidBurnId() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        uint256 expected = p.burnId;
        p.burnId = expected + 1;
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, expected + 1, expected));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_revertsInsufficientChainLiquidity() public {
        uint256 available = bridge.lockedLiquidity(ARCH_CHAIN_ID);
        IBridge.RebalanceParams memory p = _archToRgbParams(available + 1, RGB_OP_ID + 1);
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.InsufficientChainLiquidity.selector, ARCH_CHAIN_ID, available + 1, available)
        );
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_revertsZeroAmount() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.amount = 0;
        vm.prank(multisig);
        vm.expectRevert(IBridge.ZeroAmount.selector);
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_revertsSameChain() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.destinationChainId = ARCH_CHAIN_ID;
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.RebalanceSameChain.selector, ARCH_CHAIN_ID));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_revertsZeroChainIds() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.sourceChainId = 0;
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidSourceChainId.selector);
        bridge.rebalanceLiquidity(p);

        p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.destinationChainId = 0;
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidDestinationChainId.selector);
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_revertsSettlementDataOutTooLong() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        uint256 max = bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH();
        p.settlementDataOut = _filledBytes(max + 1);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.SettlementDataTooLong.selector, max + 1, max));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_settlementDataOutAtMaxLengthPassesLengthGuard() public {
        IBridge.RebalanceParams memory params = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        bytes memory settlementData = _emptySettlement();
        params.settlementDataOut =
            bytes.concat(settlementData, new bytes(bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH() - settlementData.length));
        _rebalance(params);
        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), AMOUNT * 9);
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT * 11);
        assertTrue(bridge.consumedBurnIds(params.burnId));
    }

    function test_rebalanceLiquidity_revertsSettlementDataInTooLong() public {
        // The credit leg shares the outbound cap, not the deposit one.
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        uint256 max = bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH();
        p.settlementDataIn = _filledBytes(max + 1);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.SettlementDataTooLong.selector, max + 1, max));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_acceptsSettlementDataInAtMaxLength() public {
        // A max-length blob still decodes as a non-zero RGB OpId (its first
        // 32 bytes), so the credit leg records normally. The length is far
        // above the deposit cap: the rebalance credit leg is not bound by it.
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.settlementDataIn = _filledBytes(bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH());
        assertGt(p.settlementDataIn.length, bridge.MAX_SETTLEMENT_DATA_IN_LENGTH());
        bytes32 expectedOperationId = _deriveRebalanceOpId(p);

        _rebalance(p);

        assertEq(rgbModule.fundsInRecords(expectedOperationId), AMOUNT, "credit at the outbound cap is recorded");
    }

    function test_rebalanceLiquidity_rgbCreditAcceptsEmptyDestinationAddress() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.destinationAddress = "";
        bytes32 expectedOperationId = _deriveRebalanceOpId(p);

        _rebalance(p);

        assertEq(rgbModule.fundsInRecords(expectedOperationId), AMOUNT, "empty-address RGB credit recorded");
        assertEq(
            rgbModule.fundsInRecordChainIds(expectedOperationId), RGB_CHAIN_ID, "record tagged with RGB destination"
        );
    }

    function test_rebalanceLiquidity_revertsRouteNotEnabled() public {
        // (ARCH → SOURCE) was never registered as a route.
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.destinationChainId = SOURCE_CHAIN_ID;
        p.burnId = _deriveRebalanceBurnId(p);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IRouteRegistry.RouteNotEnabled.selector, ARCH_CHAIN_ID, SOURCE_CHAIN_ID));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_revertsWhenOutflowPaused() public {
        vm.prank(multisig);
        bridge.emergencyPauseAll();
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        vm.prank(multisig);
        vm.expectRevert(BridgeBaseUpgradeable.OutflowEnforcedPause.selector);
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_revertsChainBucketThrottled() public {
        // ARCH holds AMOUNT * 10, so a 500 bps burst is AMOUNT / 2 — less than
        // the AMOUNT being migrated. The rebalance must hit the same per-chain
        // outflow throttle a release would.
        vm.prank(multisig);
        bridge.setOutflowLimit(ARCH_CHAIN_ID, 500, 1);

        uint256 shareUnit = bridge.SHARE_UNIT();
        uint256 capacityShares = 500 * shareUnit / bridge.BPS_DENOMINATOR();
        uint256 requestedShares = AMOUNT * shareUnit / bridge.lockedLiquidity(ARCH_CHAIN_ID);

        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.TokenRequestAboveCapacity.selector, capacityShares, requestedShares, address(usdt0)
            )
        );
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_revertsVerifierRejectsBadProof() public {
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        p.proof = abi.encode(BLOCK_HEIGHT + 1, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT); // unknown block
        p.burnId = _deriveRebalanceBurnId(p);
        vm.prank(multisig);
        vm.expectRevert("verify: block commitment");
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_secondaryRgbToRgbRevertsOnCrossNetworkRecord() public {
        // A secondary-network burn cannot cite a primary-network mint record.
        // The shared canonical ledger must enforce the source network tag.
        uint256 destinationOpId = RGB_OP_ID + 201;
        IBridge.RebalanceParams memory p = _secondaryRgbToRgbParams(AMOUNT, rgbSeedOpId, destinationOpId);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbSettlementModule.FundsInRecordChainMismatch.selector,
                rgbSeedOpId,
                SECONDARY_RGB_CHAIN_ID,
                RGB_CHAIN_ID
            )
        );
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalanceLiquidity_rgbToArchRevertsOnCrossNetworkRecord() public {
        // The outbound module rejects a primary-network burn citing a record
        // from the secondary RGB mint/burn network.
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, secondaryRgbSeedOpId);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbOutboundSettlementModule.FundsInRecordChainMismatch.selector,
                secondaryRgbSeedOpId,
                RGB_CHAIN_ID,
                SECONDARY_RGB_CHAIN_ID
            )
        );
        bridge.rebalanceLiquidity(p);
    }
}
