// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {MinimalBridge} from "../../src/MinimalBridge.sol";

/// @title DeployMinimalBridge
/// @notice Deploys MinimalBridge with USDT0_ADDRESS as its accepted token.
/// @dev The deployer is initial owner. Start a two-step ownership transfer separately.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `USDT0_ADDRESS`.
contract DeployMinimalBridge is Script {
    function run() external returns (MinimalBridge bridge) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address token = vm.envAddress("USDT0_ADDRESS");

        vm.startBroadcast(pk);
        bridge = new MinimalBridge(token);
        vm.stopBroadcast();

        console2.log("MinimalBridge deployed at:", address(bridge));
        console2.log("Owner (deployer):      ", bridge.owner());
        console2.log("Token:                 ", bridge.TOKEN());
    }
}
