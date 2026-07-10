// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {BaseBridge} from "../../src/BaseBridge.sol";

/// @title DeployBaseBridge
/// @notice Deploys the minimal BaseBridge.
///         Deployer becomes the initial owner. Transfer ownership to the integrator's
///         multisig/EOA after deployment.
///
/// Env:
///   PRIVATE_KEY   — deployer private key
///   TOKEN_ADDRESS — accepted ERC-20 token
///
/// Usage:
///   forge script script/deploy/DeployBaseBridge.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployBaseBridge is Script {
    function run() external returns (BaseBridge bridge) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address token = vm.envAddress("USDT0_ADDRESS");

        vm.startBroadcast(pk);
        bridge = new BaseBridge(token);
        vm.stopBroadcast();

        console2.log("BaseBridge deployed at:", address(bridge));
        console2.log("Owner (deployer):      ", bridge.owner());
        console2.log("Token:                 ", bridge.TOKEN());
    }
}
