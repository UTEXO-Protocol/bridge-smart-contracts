// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {FundsOutContext} from "../../src/interfaces/RouteTypes.sol";
import {NullSettlementModule} from "../../src/settlement/NullSettlementModule.sol";
import {NullVerifier} from "../../src/verifiers/NullVerifier.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Explicit null routes still enforce Bridge accounting and burn replay protection.
contract BridgeNullRoutesTest is BridgeTestBase {
    function test_fundsOut_dispatchesRealNullHooksAndPreservesCommonGuards() public {
        _seedRGB(AMOUNT);
        NullVerifier verifier = new NullVerifier();
        NullSettlementModule module = new NullSettlementModule();
        vm.prank(deployer);
        routeRegistry.setRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID, true, address(verifier), address(module));
        IBridge.FundsOutParams memory params = IBridge.FundsOutParams({
            recipient: recipient,
            amount: AMOUNT,
            burnId: _deriveBurnId(AMOUNT, RGB_CHAIN_ID, SRC_ADDR, SRC_BURN_TX_ID),
            sourceChainId: RGB_CHAIN_ID,
            destinationChainId: SOURCE_CHAIN_ID,
            sourceAddress: SRC_ADDR,
            proof: hex"deadbeef",
            settlementData: hex"cafe",
            sourceBurnTxId: SRC_BURN_TX_ID
        });
        FundsOutContext memory context = FundsOutContext({
            token: address(usdt0),
            recipient: recipient,
            amount: AMOUNT,
            burnId: params.burnId,
            sourceChainId: RGB_CHAIN_ID,
            destChainId: SOURCE_CHAIN_ID,
            sourceAddress: SRC_ADDR,
            isRebalance: false,
            sourceBurnTxId: SRC_BURN_TX_ID
        });
        vm.expectCall(address(verifier), abi.encodeCall(NullVerifier.verify, (context, params.proof)), uint64(1));
        vm.expectCall(
            address(module),
            abi.encodeCall(NullSettlementModule.beforeFundsOut, (context, params.settlementData)),
            uint64(1)
        );
        vm.prank(multisig);
        bridge.fundsOut(params);
        assertEq(usdt0.balanceOf(recipient), AMOUNT, "attested release pays the recipient");
        assertEq(bridge.getContractBalance(), AMOUNT * 9, "attested release debits custody");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT * 9, "attested release debits chain liquidity");
        assertEq(bridge.totalLockedLiquidity(), AMOUNT * 9, "attested release debits total liquidity");
        assertTrue(bridge.consumedBurnIds(params.burnId), "null hooks retain the common burn guard");
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, params.burnId));
        vm.prank(multisig);
        bridge.fundsOut(params);
        assertEq(usdt0.balanceOf(recipient), AMOUNT, "replay pays no second release");
        assertEq(bridge.totalLockedLiquidity(), AMOUNT * 9, "replay debits no second release");
    }
}
