// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {Bridge} from "../../src/Bridge.sol";

/// @title DeployBridgeImplementation
/// @notice Deploys a locked Bridge implementation for a later proxy upgrade.
/// @dev Does not deploy or modify the canonical Bridge proxy.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`.
contract DeployBridgeImplementation is Script {
    function run() external returns (Bridge implementation) {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        implementation = new Bridge();
        vm.stopBroadcast();

        console2.log("Bridge implementation deployed at:", address(implementation));
        console2.logBytes32(implementation.bridgeProxyCompatibilityUUID());
    }
}
