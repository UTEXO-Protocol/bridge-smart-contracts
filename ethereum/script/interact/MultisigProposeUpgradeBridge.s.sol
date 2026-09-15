// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {MultisigHelper} from "../../test/mocks/MultisigHelper.sol";

/// @title MultisigProposeUpgradeBridge
/// @notice Signs and submits a timelocked Bridge implementation upgrade.
/// @dev UPGRADE_CALLDATA is delegatecalled on the new implementation in the
///      same transaction as the upgrade. Use `0x` when no reinitializer is needed.
contract MultisigProposeUpgradeBridge is Script {
    function run() external returns (bytes32 proposalId) {
        uint256 submitterPk = vm.envUint("PRIVATE_KEY");
        MultisigProxy proxy = MultisigProxy(vm.envAddress("PROXY_ADDRESS"));
        address bridgeProxy = proxy.bridge();
        address newImplementation = vm.envAddress("NEW_BRIDGE_IMPLEMENTATION");
        bytes memory initializationData = vm.envBytes("UPGRADE_CALLDATA");
        uint256[] memory federationPks = vm.envUint("FED_PKS", ",");
        uint256 bitmap = vm.envUint("FED_BITMAP");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + vm.envUint("DEADLINE_OFFSET");

        bytes32 digest = MultisigHelper.digestProposeUpgradeBridgeImplementation(
            proxy.DOMAIN_SEPARATOR(), bridgeProxy, newImplementation, initializationData, nonce, deadline
        );
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, federationPks);

        vm.startBroadcast(submitterPk);
        proposalId = proxy.proposeUpgradeBridgeImplementation(
            bridgeProxy, newImplementation, initializationData, nonce, deadline, bitmap, sigs
        );
        vm.stopBroadcast();

        console2.log("proposeUpgradeBridgeImplementation submitted");
        console2.log("  bridge proxy:      ", bridgeProxy);
        console2.log("  implementation:    ", newImplementation);
        console2.log("  proposalId:");
        console2.logBytes32(proposalId);
        console2.log("  nonce:             ", nonce);
        console2.log("  deadline (unix s): ", deadline);
        console2.log("After the timelock, execute with opData:");
        console2.logBytes(abi.encode(bridgeProxy, newImplementation, initializationData));
    }
}
