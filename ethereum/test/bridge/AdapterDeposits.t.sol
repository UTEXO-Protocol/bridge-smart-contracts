// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IBridge} from "../../src/interfaces/IBridge.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Authenticated adapter deposits and source-chain identities.
contract BridgeAdapterDepositsTest is BridgeTestBase {
    uint256 private constant ADAPTER_SOURCE_CHAIN_ID = 137;

    function test_fundsInFromAdapter_revertsIfCallerIsNotLZAdapter() public {
        // No adapter set in setUp — caller is `user`.
        vm.prank(user);
        vm.expectRevert(IBridge.NotLZAdapter.selector);
        _authorizedAdapterFundsIn(
            bridge, AMOUNT, 1, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
    }

    function test_fundsInFromAdapter_acceptsCustomSourceChainId() public {
        address mockAdapter = makeAddr("mock-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(mockAdapter);

        usdt0.mint(mockAdapter, AMOUNT);
        vm.prank(mockAdapter);
        usdt0.approve(address(bridge), AMOUNT);

        uint256 customSrc = ADAPTER_SOURCE_CHAIN_ID;
        bytes32 sourceSender = bytes32(uint256(uint160(user))); // authenticated far-chain sender

        // Register the inbound adapter-source -> RGB route selected by sourceChainId.
        vm.prank(deployer);
        routeRegistry.setRoute(customSrc, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // The nonce for this (sourceChainId, sourceSender) starts at 0.
        bytes32 expectedOpId = _deriveRgbMintDepositId(RGB_CHAIN_ID, RGB_LOCK_ID, AMOUNT);
        bytes32 authorizationNonce = _nextFundsInAuthorizationNonce();

        // RGB deposits emit FundsIn with the adapter as sender, followed by
        // BridgeFundsIn with the authenticated source sender.
        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.FundsIn(mockAdapter, RGB_LOCK_ID, uint64(AMOUNT));
        vm.expectEmit(true, true, true, true, address(bridge));
        emit IBridge.BridgeFundsIn(
            expectedOpId,
            sourceSender,
            mockAdapter,
            authorizationNonce,
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
        bytes32 opId =
            _authorizedAdapterFundsIn(bridge, AMOUNT, customSrc, sourceSender, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(opId, expectedOpId, "returned id matches derivation");
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "record stored on module");
    }

    function test_fundsInFromAdapter_revertsWhenCumulativeRgbSupplyExceedsUint64() public {
        uint256 maxSupply = type(uint64).max;
        usdt0.mint(user, maxSupply);
        vm.prank(user);
        _authorizedFundsIn(bridge, maxSupply, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        address adapter = makeAddr("supply-cap-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        vm.prank(deployer);
        routeRegistry.setRoute(ADAPTER_SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        usdt0.mint(adapter, 1);
        vm.prank(adapter);
        usdt0.approve(address(bridge), 1);

        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        bytes32 secondOpId = _deriveRgbMintDepositId(RGB_CHAIN_ID, RGB_LOCK_ID + 1, 1);
        vm.expectRevert(abi.encodeWithSelector(IBridge.CirculatingSupplyOverflow.selector, maxSupply, uint256(1)));
        vm.prank(adapter);
        bytes32 authorizationNonce = _nextFundsInAuthorizationNonce();
        _authorizedAdapterFundsIn(
            bridge, 1, ADAPTER_SOURCE_CHAIN_ID, sourceSender, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_LOCK_ID + 1)
        );

        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), maxSupply, "RGB supply unchanged");
        assertEq(bridge.totalLockedLiquidity(), maxSupply, "total liquidity unchanged");
        assertEq(rgbModule.fundsInRecords(secondOpId), 0, "settlement record rolled back");
        assertEq(usdt0.balanceOf(adapter), 1, "adapter token pull rolled back");
        assertFalse(bridge.usedFundsInAuthorizationNonces(authorizationNonce), "authorization rolled back");
    }

    function test_fundsInFromAdapter_sameRgbMintAcrossSourceRoutesReverts() public {
        vm.prank(user);
        bytes32 original = _authorizedFundsIn(bridge, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        address adapter = makeAddr("shadowAdapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        uint256 customSource = ADAPTER_SOURCE_CHAIN_ID;
        vm.prank(deployer);
        routeRegistry.setRoute(customSource, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        usdt0.mint(adapter, AMOUNT);
        vm.prank(adapter);
        usdt0.approve(address(bridge), AMOUNT);
        bytes32 sourceSender = bytes32(uint256(uint160(makeAddr("otherSourceSender"))));
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        vm.prank(adapter);
        bytes32 authorizationNonce = _nextFundsInAuthorizationNonce();
        _authorizedAdapterFundsIn(bridge, AMOUNT, customSource, sourceSender, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(original), AMOUNT);
        assertEq(usdt0.balanceOf(adapter), AMOUNT);
        assertEq(bridge.totalLockedLiquidity(), AMOUNT);
        assertFalse(bridge.usedFundsInAuthorizationNonces(authorizationNonce));
    }

    function test_fundsInFromAdapter_expiredRgbMintRollsBackDeposit() public {
        address adapter = makeAddr("expired-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        vm.prank(deployer);
        routeRegistry.setRoute(ADAPTER_SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        usdt0.mint(adapter, AMOUNT);
        vm.prank(adapter);
        usdt0.approve(address(bridge), AMOUNT);
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        bytes32 operationId = _deriveRgbMintDepositId(RGB_CHAIN_ID, RGB_LOCK_ID, AMOUNT);
        _setArbitrumL2Block(RGB_BEFORE_BLOCK);

        vm.expectRevert(
            abi.encodeWithSelector(RgbSettlementModule.LockWindowExpired.selector, RGB_BEFORE_BLOCK, RGB_BEFORE_BLOCK)
        );
        vm.prank(adapter);
        bytes32 authorizationNonce = _nextFundsInAuthorizationNonce();
        _authorizedAdapterFundsIn(
            bridge,
            AMOUNT,
            ADAPTER_SOURCE_CHAIN_ID,
            sourceSender,
            RGB_CHAIN_ID,
            DST_ADDR,
            _rgbData(RGB_LOCK_ID, RGB_BEFORE_BLOCK)
        );

        assertEq(usdt0.balanceOf(adapter), AMOUNT, "adapter token pull rolled back");
        assertEq(usdt0.balanceOf(address(bridge)), 0, "bridge custody unchanged");
        assertFalse(bridge.usedFundsInAuthorizationNonces(authorizationNonce), "authorization rolled back");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 0, "liquidity unchanged");
        assertEq(bridge.totalLockedLiquidity(), 0, "total liquidity unchanged");
        assertEq(rgbModule.fundsInRecords(operationId), 0, "amount record absent");
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
        _authorizedAdapterFundsIn(
            bridge, AMOUNT, 0, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        assertEq(usdt0.balanceOf(adapter), AMOUNT, "invalid source does not pull tokens");
        assertEq(bridge.totalLockedLiquidity(), 0, "invalid source creates no liquidity");
    }
}
