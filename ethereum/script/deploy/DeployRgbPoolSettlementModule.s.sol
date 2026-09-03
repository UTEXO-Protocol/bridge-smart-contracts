// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {RgbPoolSettlementModule} from "../../src/settlement/RgbPoolSettlementModule.sol";

/// @title DeployRgbPoolSettlementModuleScript
/// @notice Deploys the settlement adapter for the RGB liquidity-pool network.
///         Pool credits create no canonical record; pool debits verify Bridge
///         operation ids against the configured mint/burn ledger.
///
/// Env:
///   PRIVATE_KEY
///   ROUTE_REGISTRY_ADDRESS
///   RGB_SETTLEMENT_MODULE_ADDRESS
///   RGB_POOL_CHAIN_ID
///   RGB_MINT_BURN_CHAIN_ID
contract DeployRgbPoolSettlementModuleScript is Script {
    function run() external returns (RgbPoolSettlementModule module) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address routeRegistry = vm.envAddress("ROUTE_REGISTRY_ADDRESS");
        address rgbModule = vm.envAddress("RGB_SETTLEMENT_MODULE_ADDRESS");
        uint256 poolChainId = vm.envUint("RGB_POOL_CHAIN_ID");
        uint256 mintBurnChainId = vm.envUint("RGB_MINT_BURN_CHAIN_ID");

        vm.startBroadcast(pk);
        module = new RgbPoolSettlementModule(routeRegistry, rgbModule, poolChainId, mintBurnChainId);
        vm.stopBroadcast();

        console2.log("RgbPoolSettlementModule deployed at:", address(module));
        console2.log("RouteRegistry (immutable):           ", module.routeRegistry());
        console2.log("RgbSettlementModule (immutable):     ", address(module.rgbModule()));
        console2.log("RGB pool chain id:                   ", module.poolChainId());
        console2.log("Backing mint/burn chain id:          ", module.backingRecordChainId());
    }
}
