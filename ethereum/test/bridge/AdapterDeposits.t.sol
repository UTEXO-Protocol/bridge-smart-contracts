// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Authenticated adapter deposits and source-chain identities.
contract BridgeAdapterDepositsTest is BridgeTestBase {
    function test_fundsInFromAdapter_revertsIfCallerIsNotLZAdapter() public {
        // No adapter set in setUp — caller is `user`.
        vm.prank(user);
        vm.expectRevert(IBridge.NotLZAdapter.selector);
        bridge.fundsIn(AMOUNT, 1, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsInFromAdapter_acceptsCustomSourceChainId() public {
        address mockAdapter = makeAddr("mock-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(mockAdapter);

        usdt0.mint(mockAdapter, AMOUNT);
        vm.prank(mockAdapter);
        usdt0.approve(address(bridge), AMOUNT);

        uint256 customSrc = 137; // pretend Polygon
        bytes32 sourceSender = bytes32(uint256(uint160(user))); // authenticated far-chain sender

        // Register the inbound Polygon -> RGB route selected by sourceChainId.
        vm.prank(deployer);
        routeRegistry.setRoute(customSrc, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // The nonce for this (sourceChainId, sourceSender) starts at 0.
        bytes32 expectedOpId = _deriveRgbOpId(RGB_CHAIN_ID, RGB_OP_ID, AMOUNT);

        // RGB deposits emit FundsIn with the adapter as sender, followed by
        // BridgeFundsIn with the authenticated source sender.
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(mockAdapter, RGB_OP_ID, uint64(AMOUNT));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit IBridge.BridgeFundsIn(
            expectedOpId,
            sourceSender,
            mockAdapter,
            0,
            AMOUNT,
            AMOUNT,
            0,
            0,
            customSrc,
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData()
        );

        vm.prank(mockAdapter);
        bytes32 opId = bridge.fundsIn(AMOUNT, customSrc, sourceSender, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(opId, expectedOpId, "returned id matches derivation");
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "record stored on module");
    }

    function test_fundsInFromAdapter_sameRgbMintAcrossSourceRoutesReverts() public {
        vm.prank(user);
        bytes32 original = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        address adapter = makeAddr("shadowAdapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        uint256 customSource = 137;
        vm.prank(deployer);
        routeRegistry.setRoute(customSource, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        usdt0.mint(adapter, AMOUNT);
        vm.prank(adapter);
        usdt0.approve(address(bridge), AMOUNT);
        bytes32 sourceSender = bytes32(uint256(uint160(makeAddr("otherSourceSender"))));
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        vm.prank(adapter);
        bridge.fundsIn(AMOUNT, customSource, sourceSender, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(original), AMOUNT);
        assertEq(usdt0.balanceOf(adapter), AMOUNT);
        assertEq(bridge.totalLockedLiquidity(), AMOUNT);
        assertEq(bridge.sourceSenderNonces(customSource, sourceSender), 0);
    }

    function test_fundsInFromAdapter_revertsOnZeroSourceChain() public {
        address adapter = makeAddr("zero-source-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        usdt0.mint(adapter, AMOUNT);
        vm.prank(adapter);
        usdt0.approve(address(bridge), AMOUNT);
        vm.expectRevert(IBridge.InvalidSourceChainId.selector);
        vm.prank(adapter);
        bridge.fundsIn(AMOUNT, 0, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(usdt0.balanceOf(adapter), AMOUNT, "invalid source does not pull tokens");
        assertEq(bridge.totalLockedLiquidity(), 0, "invalid source creates no liquidity");
    }
}
