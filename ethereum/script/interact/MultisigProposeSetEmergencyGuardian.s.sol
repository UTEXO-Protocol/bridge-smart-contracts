// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {MultisigHelper} from "../../test/helpers/MultisigHelper.sol";

/// @title MultisigProposeSetEmergencyGuardian
/// @notice Locally signs and submits a guardian replacement or disabling proposal.
/// @dev A zero NEW_EMERGENCY_GUARDIAN disables direct guardian access. Execute separately
///      after the timelock. DEADLINE_OFFSET must cover the delay plus an execution window,
///      and must be at most 30 days.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `PROXY_ADDRESS`, `NEW_EMERGENCY_GUARDIAN`, `FED_PKS`, `FED_BITMAP`,
///      `DEADLINE_OFFSET`.
contract MultisigProposeSetEmergencyGuardian is Script {
    function run() external returns (bytes32 proposalId) {
        uint256 submitterPk = vm.envUint("PRIVATE_KEY");
        MultisigProxy proxy = MultisigProxy(vm.envAddress("PROXY_ADDRESS"));
        address newGuardian = vm.envAddress("NEW_EMERGENCY_GUARDIAN");
        uint256[] memory federationPks = vm.envUint("FED_PKS", ",");
        uint256 bitmap = vm.envUint("FED_BITMAP");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + vm.envUint("DEADLINE_OFFSET");

        bytes32 digest =
            MultisigHelper.digestProposeSetEmergencyGuardian(proxy.DOMAIN_SEPARATOR(), newGuardian, nonce, deadline);
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, federationPks);

        vm.startBroadcast(submitterPk);
        proposalId = proxy.proposeSetEmergencyGuardian(newGuardian, nonce, deadline, bitmap, sigs);
        vm.stopBroadcast();

        console2.log("proposeSetEmergencyGuardian submitted");
        console2.log("  new guardian:      ", newGuardian);
        console2.log("  proposalId:");
        console2.logBytes32(proposalId);
        console2.log("  nonce:             ", nonce);
        console2.log("  deadline (unix s): ", deadline);
        console2.log("After the timelock, execute with opData:");
        console2.logBytes(abi.encode(newGuardian));
    }
}
