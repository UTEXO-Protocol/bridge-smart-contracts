// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {MultisigHelper} from "../../test/mocks/MultisigHelper.sol";

/// @title MultisigProposeSetEmergencyGuardian
/// @notice Signs and submits a timelocked federation proposal to rotate or
///         disable the direct emergency guardian.
/// @dev NEW_EMERGENCY_GUARDIAN may be address(0) to disable guardian access.
///      Execution is intentionally left to operators after the timelock.
///
/// Env:
///   PRIVATE_KEY             — tx submitter
///   PROXY_ADDRESS           — MultisigProxy address
///   NEW_EMERGENCY_GUARDIAN  — replacement guardian or address(0) to disable
///   FED_PKS                 — comma-separated federation private keys
///   FED_BITMAP              — participating signer bitmap
///   DEADLINE_OFFSET         — seconds from now (e.g. 7 days)
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
