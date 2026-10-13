// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Bridge} from "../../src/Bridge.sol";
import {BridgeBaseUpgradeable} from "../../src/BridgeBaseUpgradeable.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {BridgeTestBase} from "./BridgeTestBase.sol";

/// @notice Proxy initialization binds the token, owner, plugins and amount floors.
contract BridgeInitializationTest is BridgeTestBase {
    function test_initialize_setsTokenOwnerAndRouteRegistry() public view {
        assertEq(bridge.TOKEN(), address(usdt0));
        assertEq(bridge.owner(), multisig);
        assertEq(bridge.routeRegistry(), address(routeRegistry));
        assertEq(address(bridge.commissionManager()), address(cm));
    }

    function test_initialize_revertsOnZeroToken() public {
        Bridge implementation = new Bridge();
        vm.expectRevert(BridgeBaseUpgradeable.InvalidTokenAddress.selector);
        _deployBridgeFromImplementation(
            implementation, address(0), address(routeRegistry), payable(address(cm)), address(0), 1, 1, deployer
        );
    }

    function test_initialize_revertsOnZeroRouteRegistry() public {
        Bridge implementation = new Bridge();
        vm.expectRevert(IBridge.InvalidRouteRegistryAddress.selector);
        _deployBridgeFromImplementation(
            implementation, address(usdt0), address(0), payable(address(cm)), address(0), 1, 1, deployer
        );
    }

    function test_initialize_revertsOnZeroCommissionManager() public {
        Bridge implementation = new Bridge();
        vm.expectRevert(IBridge.InvalidCommissionManagerAddress.selector);
        _deployBridgeFromImplementation(
            implementation, address(usdt0), address(routeRegistry), payable(address(0)), address(0), 1, 1, deployer
        );
    }

    function test_initialize_storesInitialLZAdapter() public {
        address initialAdapter = makeAddr("initial-adapter");
        vm.prank(deployer);
        Bridge b =
            _deployBridge(address(usdt0), address(routeRegistry), payable(address(cm)), initialAdapter, 1, 1, deployer);
        assertEq(b.lzAdapter(), initialAdapter, "lzAdapter set in initializer");
    }

    function test_initialize_storesMinFundsInAmount() public {
        vm.prank(deployer);
        Bridge b =
            _deployBridge(address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1234, 1, deployer);
        assertEq(b.minFundsInAmount(), 1234, "minFundsInAmount stored from initializer");
    }

    function test_initialize_revertsOnZeroMinFundsInAmount() public {
        Bridge implementation = new Bridge();
        vm.expectRevert(IBridge.InvalidMinFundsInAmount.selector);
        _deployBridgeFromImplementation(
            implementation, address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 0, 1, deployer
        );
    }

    function test_initialize_storesMinFundsOutAmount() public {
        vm.prank(deployer);
        Bridge b = _deployBridge(
            address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 9000, 4321, deployer
        );
        assertEq(b.minFundsOutAmount(), 4321, "minFundsOutAmount stored from initializer");
    }

    function test_initialize_revertsOnZeroMinFundsOutAmount() public {
        Bridge implementation = new Bridge();
        vm.expectRevert(IBridge.InvalidMinFundsOutAmount.selector);
        _deployBridgeFromImplementation(
            implementation, address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1, 0, deployer
        );
    }

    function test_initialize_revertsOnInvertedMinimums() public {
        Bridge implementation = new Bridge();
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidAmountFloors.selector, uint256(1), uint256(2)));
        _deployBridgeFromImplementation(
            implementation, address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1, 2, deployer
        );
    }
}
