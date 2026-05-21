// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script, console2 } from 'forge-std/Script.sol';
import { RouteRegistry } from '../../src/RouteRegistry.sol';

/// @title DeployRouteRegistry
/// @notice Standalone deployment of `RouteRegistry`. Used when adding a new
///         registry to an existing Bridge (followed by federation governance:
///         `proposeUpdateRouteRegistry(newRegistry)` on MultisigProxy).
///
///         For a fresh stack use `DeployAll.s.sol` — it predicts Bridge's
///         CREATE address and wires the registry's `bridge_` immutable to it
///         in the same transaction batch.
///
/// Env:
///   PRIVATE_KEY    — deployer private key
///   BRIDGE_ADDRESS — Bridge instance this registry will serve. The registry
///                    stores it as `immutable`, so it MUST already exist and
///                    match the Bridge that will hold this registry as its
///                    `routeRegistry` pointer.
///   OWNER_ADDRESS  — Initial owner of the registry. Production uses the
///                    MultisigProxy address so route administration is
///                    federation-governed from t=0.
///
/// Usage:
///   forge script script/deploy/DeployRouteRegistry.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployRouteRegistry is Script {
    function run() external returns (RouteRegistry registry) {
        uint256 pk     = vm.envUint('PRIVATE_KEY');
        address bridge = vm.envAddress('BRIDGE_ADDRESS');
        address owner  = vm.envAddress('OWNER_ADDRESS');

        vm.startBroadcast(pk);
        registry = new RouteRegistry(bridge, owner);
        vm.stopBroadcast();

        console2.log('RouteRegistry deployed at:', address(registry));
        console2.log('Bridge (immutable):       ', registry.bridge());
        console2.log('Owner:                    ', registry.owner());
    }
}
