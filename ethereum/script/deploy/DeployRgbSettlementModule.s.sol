// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";

/// @title DeployRgbSettlementModule
/// @notice Deploys the canonical RGB ledger paired with ROUTE_REGISTRY_ADDRESS.
/// @dev A replacement starts empty. Plan access to older records before rotating a module
///      or registry. Route registration is separate.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `ROUTE_REGISTRY_ADDRESS`.
contract DeployRgbSettlementModuleScript is Script {
    function run() external returns (RgbSettlementModule module) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address routeRegistry = vm.envAddress("ROUTE_REGISTRY_ADDRESS");

        vm.startBroadcast(pk);
        module = new RgbSettlementModule(routeRegistry);
        vm.stopBroadcast();

        console2.log("RgbSettlementModule deployed at:", address(module));
        console2.log("RouteRegistry (immutable):      ", module.routeRegistry());
    }
}
