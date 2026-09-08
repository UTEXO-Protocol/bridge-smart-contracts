// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";

/// @title GuardianEmergencyUnpause
/// @notice Submits a direct guardian-authorized emergency unpause without signatures.
///
/// Env:
///   PRIVATE_KEY    — configured emergency guardian private key
///   PROXY_ADDRESS  — MultisigProxy address
contract GuardianEmergencyUnpause is Script {
    function run() external {
        uint256 guardianPk = vm.envUint("PRIVATE_KEY");
        MultisigProxy proxy = MultisigProxy(vm.envAddress("PROXY_ADDRESS"));

        vm.startBroadcast(guardianPk);
        proxy.guardianEmergencyUnpause();
        vm.stopBroadcast();

        console2.log("guardianEmergencyUnpause submitted by:", vm.addr(guardianPk));
    }
}
