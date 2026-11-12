// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager,
    WitnessFeeConfig
} from "../../src/interfaces/ICommissionManager.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

contract BridgeWitnessFeesTest is BridgeTestBase {
    uint256 private constant BASE_FEE = 125;
    uint256 private constant WITNESS_FEE = 1_500;

    function _configure(uint256 sourceChainId) private {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(10_000);
        vm.startPrank(deployer);
        cm.setCommissionRule(
            sourceChainId,
            RGB_CHAIN_ID,
            address(usdt0),
            CommissionConfig(100, BASE_FEE, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN, true)
        );
        cm.setWitnessFee(
            sourceChainId, RGB_CHAIN_ID, address(usdt0), WitnessFeeConfig({witnessFee: WITNESS_FEE, isSet: true})
        );
        vm.stopPrank();
    }

    function _rgbDataWithType(uint256 rgbOpId, uint8 feeType) private pure returns (bytes memory) {
        return bytes.concat(abi.encode(rgbOpId, RGB_BEFORE_BLOCK), bytes1(feeType));
    }

    function test_directRgbDepositSelectsWitnessFee() public {
        _configure(SOURCE_CHAIN_ID);
        uint256 expectedFee = AMOUNT / 100 + WITNESS_FEE;

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbDataWithType(RGB_OP_ID, 1));

        assertEq(usdt0.balanceOf(address(cm)), expectedFee);
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT - expectedFee);
    }

    function test_baseSelectorUsesBaseFee() public {
        _configure(SOURCE_CHAIN_ID);
        uint256 expectedFee = AMOUNT / 100 + BASE_FEE;

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbDataWithType(RGB_OP_ID, 0));
        assertEq(usdt0.balanceOf(address(cm)), expectedFee);
    }

    function test_witnessSelectorWithoutConfigRevertsBeforeTokenMovement() public {
        bytes32 routeKey = cm.buildRouteKey(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0));
        vm.expectRevert(abi.encodeWithSelector(ICommissionManager.WitnessFeeNotConfigured.selector, routeKey));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbDataWithType(RGB_OP_ID, 1));
        assertEq(usdt0.balanceOf(user), AMOUNT * 10);
        assertEq(usdt0.balanceOf(address(bridge)), 0);
    }

    function test_adapterRgbDepositSelectsWitnessFee() public {
        uint256 sourceChainId = 137;
        address adapter = makeAddr("witness-adapter");
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        vm.prank(deployer);
        routeRegistry.setRoute(sourceChainId, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        _configure(sourceChainId);
        usdt0.mint(adapter, AMOUNT);
        vm.prank(adapter);
        usdt0.approve(address(bridge), AMOUNT);

        vm.prank(adapter);
        bridge.fundsIn(AMOUNT, sourceChainId, sourceSender, RGB_CHAIN_ID, DST_ADDR, _rgbDataWithType(RGB_OP_ID, 1));
        assertEq(usdt0.balanceOf(address(cm)), AMOUNT / 100 + WITNESS_FEE);
    }

    function test_rgbDepositRejectsMissingExtraAndUnknownSelector() public {
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidRgbSettlementDataLength.selector, 64));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, abi.encode(RGB_OP_ID, RGB_BEFORE_BLOCK));

        bytes memory extra = bytes.concat(_rgbDataWithType(RGB_OP_ID, 0), hex"00");
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidRgbSettlementDataLength.selector, 66));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, extra);

        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidFlatFeeType.selector, uint8(2)));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbDataWithType(RGB_OP_ID, 2));
    }
}
