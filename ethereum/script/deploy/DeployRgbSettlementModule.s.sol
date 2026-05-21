// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script, console2 } from 'forge-std/Script.sol';
import { RgbSettlementModule } from '../../src/settlement/RgbSettlementModule.sol';

/// @title DeployRgbSettlementModule
/// @notice Deploys the RGB-route settlement module. Holds the `fundsInRecords`
///         ledger and the partial-consumption loop that used to live inside
///         Bridge. Paired with one specific `RouteRegistry` instance via the
///         immutable `routeRegistry` field — auth on `onFundsIn` /
///         `beforeFundsOut` is `onlyRouteRegistry`.
///
///         Re-pointing at a different registry = redeploy + federation
///         `proposeSetRoute(RGB → SOURCE, …, newModule)` (and the reverse
///         direction). The legacy module retains its ledger but never gets
///         called again.
///
/// Env:
///   PRIVATE_KEY            — deployer private key
///   ROUTE_REGISTRY_ADDRESS — `RouteRegistry` deployment that will drive
///                            this module
///
/// Usage:
///   forge script script/deploy/DeployRgbSettlementModule.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployRgbSettlementModuleScript is Script {
    function run() external returns (RgbSettlementModule module) {
        uint256 pk            = vm.envUint('PRIVATE_KEY');
        address routeRegistry = vm.envAddress('ROUTE_REGISTRY_ADDRESS');

        vm.startBroadcast(pk);
        module = new RgbSettlementModule(routeRegistry);
        vm.stopBroadcast();

        console2.log('RgbSettlementModule deployed at:', address(module));
        console2.log('RouteRegistry (immutable):      ', module.routeRegistry());
    }
}
