// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {RouteRegistry} from "../../src/RouteRegistry.sol";

/// @title DeployRouteRegistry
/// @notice Deploys a registry bound to BRIDGE_ADDRESS and owned by OWNER_ADDRESS.
/// @dev The Bridge binding is immutable. Use DeployAll for a new stack; governance connects
///      a replacement registry to an existing Bridge.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `BRIDGE_ADDRESS`, `OWNER_ADDRESS`.
contract DeployRouteRegistry is Script {
    function run() external returns (RouteRegistry registry) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address bridge = vm.envAddress("BRIDGE_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");

        vm.startBroadcast(pk);
        registry = new RouteRegistry(bridge, owner);
        vm.stopBroadcast();

        console2.log("RouteRegistry deployed at:", address(registry));
        console2.log("Bridge (immutable):       ", registry.bridge());
        console2.log("Owner:                    ", registry.owner());
    }
}
