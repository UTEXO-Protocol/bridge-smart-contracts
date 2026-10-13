// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BridgeBaseUpgradeable} from "../../src/BridgeBaseUpgradeable.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {RouteRegistry} from "../../src/RouteRegistry.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager
} from "../../src/interfaces/ICommissionManager.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Owner-controlled adapter, registry and commission-manager configuration.
contract BridgeConfigurationTest is BridgeTestBase {
    function test_setLZAdapter_rotatesToNonZero() public {
        address adapter = makeAddr("adapter");

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.LZAdapterUpdated(address(0), adapter);

        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        assertEq(bridge.lzAdapter(), adapter, "rotated");
    }

    function test_setLZAdapter_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidLZAdapter.selector);
        bridge.setLZAdapter(address(0));
    }

    function test_disableLZAdapter_clearsAndEmits() public {
        address adapter = makeAddr("adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit IBridge.LZAdapterDisabled(adapter);

        vm.prank(multisig);
        bridge.disableLZAdapter();
        assertEq(bridge.lzAdapter(), address(0), "disabled");
    }

    function test_disableLZAdapter_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.disableLZAdapter();
    }

    function test_setLZAdapter_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setLZAdapter(makeAddr("adapter"));
    }

    function test_setRouteRegistry_ownerCanRotate() public {
        // Deploy a NEW registry paired with the same Bridge (the documented
        // invariant). In production the new registry must already be wired
        // with this Bridge as its `bridge_` immutable.
        RouteRegistry newReg = new RouteRegistry(address(bridge), multisig);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.RouteRegistryUpdated(address(routeRegistry), address(newReg));

        vm.prank(multisig);
        bridge.setRouteRegistry(address(newReg));
        assertEq(bridge.routeRegistry(), address(newReg));
    }

    function test_setRouteRegistry_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidRouteRegistryAddress.selector);
        bridge.setRouteRegistry(address(0));
    }

    function test_setRouteRegistry_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setRouteRegistry(makeAddr("newReg"));
    }

    function test_setCommissionManager_ownerCanRotate() public {
        CommissionManager newCm = new CommissionManager(address(bridge), recipient);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.CommissionManagerUpdated(address(cm), address(newCm));

        vm.prank(multisig);
        bridge.setCommissionManager(address(newCm));
        assertEq(address(bridge.commissionManager()), address(newCm));
    }

    function test_setCommissionManager_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidCommissionManagerAddress.selector);
        bridge.setCommissionManager(address(0));
    }

    function test_setCommissionManager_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setCommissionManager(makeAddr("newCm"));
    }

    function test_setCommissionManager_revertsOnCodelessAddress() public {
        address candidate = makeAddr("codeless-manager");
        vm.expectRevert(IBridge.InvalidCommissionManagerAddress.selector);
        vm.prank(multisig);
        bridge.setCommissionManager(candidate);
        assertEq(address(bridge.commissionManager()), address(cm));
    }

    function test_setCommissionManager_revertsOnWrongBridgeBinding() public {
        CommissionManager candidate = new CommissionManager(makeAddr("other-bridge"), recipient);
        vm.expectRevert(IBridge.InvalidCommissionManagerAddress.selector);
        vm.prank(multisig);
        bridge.setCommissionManager(address(candidate));
        assertEq(address(bridge.commissionManager()), address(cm));
    }

    function test_setCommissionManager_revertsOnMissingOrRevertingBindingGetter() public {
        // The token has code but does not implement bridgeAddress().
        vm.expectRevert(bytes(""));
        vm.prank(multisig);
        bridge.setCommissionManager(address(usdt0));
        assertEq(address(bridge.commissionManager()), address(cm));

        CommissionManager candidate = new CommissionManager(address(bridge), recipient);
        vm.mockCallRevert(address(candidate), abi.encodeCall(ICommissionManager.bridgeAddress, ()), bytes("bad getter"));
        vm.expectRevert(bytes("bad getter"));
        vm.prank(multisig);
        bridge.setCommissionManager(address(candidate));
        assertEq(address(bridge.commissionManager()), address(cm));
    }

    function test_setCommissionManager_routesNewFeesToReplacement() public {
        CommissionManager newCm = new CommissionManager(address(bridge), recipient);
        uint256 percent = 400; // 4%
        newCm.setCommissionRule(
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        vm.prank(multisig);
        bridge.setCommissionManager(address(newCm));

        uint256 oldPoolBefore = cm.tokenCommissionPool(address(usdt0));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 expectedCommission = AMOUNT * percent / 100 / 100;
        assertEq(newCm.tokenCommissionPool(address(usdt0)), expectedCommission, "replacement receives fees");
        assertEq(cm.tokenCommissionPool(address(usdt0)), oldPoolBefore, "old manager receives nothing");
    }

    function test_pauseInflow_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.pauseInflow();
    }

    function test_unpauseInflow_revertsForNonOwner() public {
        vm.prank(multisig);
        bridge.pauseInflow();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.unpauseInflow();
    }

    function test_renounceOwnership_alwaysReverts() public {
        vm.expectRevert(BridgeBaseUpgradeable.RenounceOwnershipBlocked.selector);
        vm.prank(multisig);
        bridge.renounceOwnership();
    }

    function test_getContractBalance_returnsCustodiedBalance() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(bridge.getContractBalance(), AMOUNT);
    }

    function test_getChainId_returnsCurrentChain() public view {
        assertEq(bridge.getChainId(), block.chainid);
    }
}
