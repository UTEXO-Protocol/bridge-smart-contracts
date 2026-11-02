// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {CommissionConfig, CommissionCurrency, CommissionSide} from "../../src/interfaces/ICommissionManager.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

contract BridgeClientTiersTest is BridgeTestBase {
    uint256 private constant DEFAULT_PERCENT = 100;
    uint256 private constant CLIENT_PERCENT = 70;
    uint256 private constant ADAPTER_SOURCE_CHAIN_ID = 137;

    function test_directFundsInUsesCallerTier() public {
        _setFundsInTokenRule(DEFAULT_PERCENT);
        vm.prank(deployer);
        cm.setPayerTier(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), bytes32(uint256(uint160(user))), CLIENT_PERCENT);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        uint256 expectedFee = AMOUNT * CLIENT_PERCENT / 10_000;
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedFee);
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT - expectedFee);
    }

    function test_adapterFundsInUsesAuthenticatedSourceSenderNotAdapter() public {
        address adapter = makeAddr("tier-adapter");
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        vm.startPrank(deployer);
        routeRegistry.setRoute(ADAPTER_SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        cm.setCommissionRule(
            ADAPTER_SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            address(usdt0),
            CommissionConfig(DEFAULT_PERCENT, 0, 100, CommissionSide.FUNDS_IN, CommissionCurrency.TOKEN, true)
        );
        cm.setPayerTier(ADAPTER_SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), sourceSender, CLIENT_PERCENT);
        cm.setPayerTier(ADAPTER_SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), bytes32(uint256(uint160(adapter))), 0);
        vm.stopPrank();

        usdt0.mint(adapter, AMOUNT);
        vm.prank(adapter);
        usdt0.approve(address(bridge), AMOUNT);
        vm.prank(adapter);
        bytes32 opId =
            bridge.fundsIn(AMOUNT, ADAPTER_SOURCE_CHAIN_ID, sourceSender, RGB_CHAIN_ID, DST_ADDR, _rgbData(0xA11CE));

        uint256 expectedFee = AMOUNT * CLIENT_PERCENT / 10_000;
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedFee);
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT - expectedFee);
    }

    function test_directFundsOutUsesDestinationTier() public {
        _seedRGB(AMOUNT);
        _setFundsOutTokenRule(DEFAULT_PERCENT);
        vm.prank(deployer);
        cm.setPayerTier(
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(usdt0), bytes32(uint256(uint160(recipient))), CLIENT_PERCENT
        );

        uint256 recipientBefore = usdt0.balanceOf(recipient);
        _releaseRGB(AMOUNT, keccak256("tier-release"));
        uint256 expectedFee = AMOUNT * CLIENT_PERCENT / 10_000;
        assertEq(usdt0.balanceOf(recipient) - recipientBefore, AMOUNT - expectedFee);
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedFee);
    }
}
