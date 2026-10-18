// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {MultisigHelper} from "../../test/helpers/MultisigHelper.sol";

/// @title MultisigProposeSetRoute
/// @notice Locally signs and submits a route proposal, then prints execution data.
/// @dev Reads DEST_CHAIN_ID, not DESTINATION_CHAIN_ID. Execute the printed opData after
///      the timelock. DEADLINE_OFFSET must cover the delay plus an execution window,
///      and must be at most 30 days.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `PROXY_ADDRESS`, `SOURCE_CHAIN_ID`, `DEST_CHAIN_ID`, `ROUTE_ENABLED`,
///      `FINALITY_VERIFIER`, `SETTLEMENT_MODULE`, `FED_PKS`, `FED_BITMAP`, `DEADLINE_OFFSET`.
contract MultisigProposeSetRoute is Script {
    function run() external returns (bytes32 proposalId) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address proxyAddr = vm.envAddress("PROXY_ADDRESS");
        uint256 sourceChainId = vm.envUint("SOURCE_CHAIN_ID");
        uint256 destChainId = vm.envUint("DEST_CHAIN_ID");
        bool enabled = vm.envBool("ROUTE_ENABLED");
        address finalityVerifier = vm.envAddress("FINALITY_VERIFIER");
        address settlementModule = vm.envAddress("SETTLEMENT_MODULE");
        uint256[] memory ks = vm.envUint("FED_PKS", ",");
        uint256 bitmap = vm.envUint("FED_BITMAP");
        uint256 offset = vm.envUint("DEADLINE_OFFSET");

        MultisigProxy proxy = MultisigProxy(proxyAddr);
        address target = IBridge(proxy.bridge()).routeRegistry();
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + offset;

        bytes32 digest = MultisigHelper.digestProposeSetRoute(
            proxy.DOMAIN_SEPARATOR(),
            target,
            sourceChainId,
            destChainId,
            enabled,
            finalityVerifier,
            settlementModule,
            nonce,
            deadline
        );
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, ks);

        vm.startBroadcast(pk);
        proposalId = proxy.proposeSetRoute(
            sourceChainId, destChainId, enabled, finalityVerifier, settlementModule, nonce, deadline, bitmap, sigs
        );
        vm.stopBroadcast();

        console2.log("proposeSetRoute submitted");
        console2.log("  proposalId:        ");
        console2.logBytes32(proposalId);
        console2.log("  signed registry:   ", target);
        console2.log("  nonce:             ", nonce);
        console2.log("  deadline (unix s): ", deadline);
        console2.log("");
        console2.log("After the timelock elapses, run:");
        console2.log('  cast send <PROXY_ADDRESS> "executeProposal(bytes32,bytes)" <proposalId> <opData>');
        console2.log("where opData =");
        console2.logBytes(abi.encode(sourceChainId, destChainId, enabled, finalityVerifier, settlementModule));
    }
}
