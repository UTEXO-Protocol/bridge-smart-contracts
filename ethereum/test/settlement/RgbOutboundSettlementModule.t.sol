// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {FundsInContext, FundsOutContext} from "../../src/interfaces/RouteTypes.sol";
import {RgbOutboundSettlementModule} from "../../src/settlement/RgbOutboundSettlementModule.sol";
import {BridgeRebalanceTestBase} from "../bridge/BridgeRebalanceTestBase.sol";

/// @notice Outbound RGB settlement validates permanent mint records and registry access.
contract RgbOutboundSettlementModuleTest is BridgeRebalanceTestBase {
    bytes32 internal constant SRC_BURN_TX_ID = keccak256("rebalance-burn-tx-default");

    function test_outboundModule_revertsOnEmptyArrays() public {
        FundsOutContext memory ctx = FundsOutContext({
            token: address(usdt0),
            recipient: address(bridge),
            amount: AMOUNT,
            burnId: 1,
            sourceChainId: RGB_CHAIN_ID,
            destChainId: CHAIN_A_ID,
            sourceAddress: RGB_SRC_ADDR,
            isRebalance: true,
            sourceBurnTxId: SRC_BURN_TX_ID
        });

        vm.prank(address(routeRegistry));
        vm.expectRevert(RgbOutboundSettlementModule.EmptySettlementRecords.selector);
        outboundModule.beforeFundsOut(ctx, _emptySettlement());
    }

    function test_outboundModule_revertsUnknownRecord() public {
        bytes32 bogus = keccak256("no-such-record");
        IBridge.RebalanceParams memory p = _rgbToChainAParams(AMOUNT, rgbSeedOpId);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bogus;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;
        p.settlementDataOut = abi.encode(ids, amounts);
        p.burnId = _deriveRebalanceBurnId(p);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(RgbOutboundSettlementModule.FundsInNotFound.selector, bogus));
        bridge.rebalanceLiquidity(p);
    }

    function test_outboundModule_revertsAmountMismatch() public {
        uint256 recorded = rgbModule.fundsInRecords(rgbSeedOpId);
        IBridge.RebalanceParams memory p = _rgbToChainAParams(AMOUNT, rgbSeedOpId);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = rgbSeedOpId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = recorded - 1;
        p.settlementDataOut = abi.encode(ids, amounts);
        p.burnId = _deriveRebalanceBurnId(p);
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbOutboundSettlementModule.AmountMismatch.selector, rgbSeedOpId, recorded - 1, recorded
            )
        );
        bridge.rebalanceLiquidity(p);
    }

    function test_outboundModule_revertsLengthMismatch() public {
        IBridge.RebalanceParams memory p = _rgbToChainAParams(AMOUNT, rgbSeedOpId);
        p.settlementDataOut = abi.encode(new bytes32[](2), new uint256[](1));
        p.burnId = _deriveRebalanceBurnId(p);
        vm.prank(multisig);
        vm.expectRevert(RgbOutboundSettlementModule.SettlementDataLengthMismatch.selector);
        bridge.rebalanceLiquidity(p);
    }

    function test_outboundModule_revertsNotRouteRegistry() public {
        vm.expectRevert(RgbOutboundSettlementModule.NotRouteRegistry.selector);
        outboundModule.beforeFundsOut(
            FundsOutContext({
                token: address(usdt0),
                recipient: address(bridge),
                amount: AMOUNT,
                burnId: 1,
                sourceChainId: RGB_CHAIN_ID,
                destChainId: CHAIN_A_ID,
                sourceAddress: RGB_SRC_ADDR,
                isRebalance: true,
                sourceBurnTxId: SRC_BURN_TX_ID
            }),
            _emptySettlement()
        );

        vm.expectRevert(RgbOutboundSettlementModule.NotRouteRegistry.selector);
        outboundModule.onFundsIn(
            FundsInContext({
                token: address(usdt0),
                sender: address(this),
                sourceSender: bytes32(0),
                grossAmount: AMOUNT,
                netAmount: AMOUNT,
                operationId: bytes32(0),
                senderNonce: 0,
                sourceChainId: RGB_CHAIN_ID,
                destChainId: CHAIN_A_ID,
                destAddress: CHAIN_A_DST_ADDR
            }),
            ""
        );
    }

    function test_outboundModule_constructorRejectsZeroArgs() public {
        vm.expectRevert(RgbOutboundSettlementModule.InvalidRouteRegistry.selector);
        new RgbOutboundSettlementModule(address(0), address(rgbModule));
        vm.expectRevert(RgbOutboundSettlementModule.InvalidRgbModule.selector);
        new RgbOutboundSettlementModule(address(routeRegistry), address(0));
    }
}
