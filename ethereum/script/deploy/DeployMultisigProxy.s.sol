// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";

/// @title DeployMultisigProxy
/// @notice Deploys governance for an existing Bridge and CommissionManager.
/// @dev Does not transfer or accept ownership of the managed contracts.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `BRIDGE_ADDRESS`, `COMMISSION_MANAGER`, `EMERGENCY_GUARDIAN`,
///      `ENCLAVE_SIGNERS`, `ENCLAVE_THRESHOLD`, `INITIAL_ENCLAVE_SOURCE_CHAIN_ID`,
///      `FEDERATION_SIGNERS`, `FEDERATION_THRESHOLD`, `TIMELOCK_DURATION`, `MIN_TIMELOCK`.
contract DeployMultisigProxy is Script {
    function run() external returns (MultisigProxy proxy) {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address bridgeAddr = vm.envAddress("BRIDGE_ADDRESS");
        address commissionManager = vm.envAddress("COMMISSION_MANAGER");
        address emergencyGuardian = vm.envAddress("EMERGENCY_GUARDIAN");
        address[] memory enc = vm.envAddress("ENCLAVE_SIGNERS", ",");
        uint256 encThr = vm.envUint("ENCLAVE_THRESHOLD");
        uint256 initialSrcChain = vm.envUint("INITIAL_ENCLAVE_SOURCE_CHAIN_ID");
        address[] memory fed = vm.envAddress("FEDERATION_SIGNERS", ",");
        uint256 fedThr = vm.envUint("FEDERATION_THRESHOLD");
        uint256 timelock = vm.envUint("TIMELOCK_DURATION");
        uint256 minTimelock = vm.envUint("MIN_TIMELOCK");

        vm.startBroadcast(pk);
        proxy = new MultisigProxy(
            bridgeAddr,
            commissionManager,
            emergencyGuardian,
            enc,
            encThr,
            initialSrcChain,
            fed,
            fedThr,
            timelock,
            minTimelock
        );
        vm.stopBroadcast();

        console2.log("MultisigProxy deployed at:", address(proxy));
        console2.log("Bridge:                   ", proxy.bridge());
        console2.log("CommissionManager:        ", proxy.commissionManager());
        console2.log("Emergency guardian:       ", proxy.emergencyGuardian());
        console2.log("Initial enclave srcChain: ", initialSrcChain);
        console2.log("Enclave threshold:        ", proxy.enclaveThreshold(initialSrcChain));
        console2.log("Federation threshold:     ", proxy.federationThreshold());
        console2.log("Commission recipient:     ", proxy.commissionRecipient());
        console2.log("Timelock duration (sec):  ", proxy.timelockDuration());
        console2.log("");
        console2.log("lzAdapter (proxy):        ", proxy.lzAdapter());
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1) Transfer Bridge ownership to MultisigProxy.");
        console2.log("  2) Transfer CommissionManager ownership to MultisigProxy.");
        console2.log("  3) Once the LayerZero adapter is deployed:");
        console2.log("     a) propose Bridge.setLZAdapter(adapter) via proposeAdminExecute");
        console2.log("     b) propose MultisigProxy.lzAdapter via proposeUpdateLZAdapter");
    }
}
