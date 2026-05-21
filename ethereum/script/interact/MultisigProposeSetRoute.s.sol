// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script, console2 } from 'forge-std/Script.sol';
import { MultisigProxy } from '../../src/MultisigProxy.sol';
import { MultisigHelper } from '../../test/mocks/MultisigHelper.sol';

/// @title MultisigProposeSetRoute
/// @notice Signs and submits a `proposeSetRoute(...)` federation proposal
///         against MultisigProxy. The first federation-side step after
///         DeployAll — registers or updates a route entry in the Bridge's
///         RouteRegistry once the timelock elapses.
///
/// @dev    The matching `executeProposal(...)` call (which is permissionless)
///         is intentionally NOT submitted by this script — operators run it
///         manually with `cast send` after the timelock window passes. The
///         `opData` payload required by `executeProposal` is printed below.
///
/// Env:
///   PRIVATE_KEY              — tx submitter (anyone)
///   PROXY_ADDRESS            — MultisigProxy address
///   SOURCE_CHAIN_ID (uint)   — source chain id of the route key
///   DEST_CHAIN_ID   (uint)   — destination chain id of the route key
///   ROUTE_ENABLED   (bool)   — `true` to (re)enable, `false` to pause-in-place
///   FINALITY_VERIFIER (addr) — verifier deployment (e.g. RGBVerifier)
///   SETTLEMENT_MODULE (addr) — settlement module deployment
///   FED_PKS                  — comma-separated federation private keys
///   FED_BITMAP               — participating signer bitmap
///   DEADLINE_OFFSET          — seconds from now (e.g. 7 days)
contract MultisigProposeSetRoute is Script {
    function run() external returns (bytes32 proposalId) {
        uint256 pk                  = vm.envUint('PRIVATE_KEY');
        address proxyAddr           = vm.envAddress('PROXY_ADDRESS');
        uint256 sourceChainId       = vm.envUint('SOURCE_CHAIN_ID');
        uint256 destChainId         = vm.envUint('DEST_CHAIN_ID');
        bool    enabled             = vm.envBool('ROUTE_ENABLED');
        address finalityVerifier    = vm.envAddress('FINALITY_VERIFIER');
        address settlementModule    = vm.envAddress('SETTLEMENT_MODULE');
        uint256[] memory ks         = vm.envUint('FED_PKS', ',');
        uint256 bitmap              = vm.envUint('FED_BITMAP');
        uint256 offset              = vm.envUint('DEADLINE_OFFSET');

        MultisigProxy proxy = MultisigProxy(proxyAddr);
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + offset;

        bytes32 digest = MultisigHelper.digestProposeSetRoute(
            proxy.DOMAIN_SEPARATOR(),
            sourceChainId, destChainId, enabled, finalityVerifier, settlementModule,
            nonce, deadline
        );
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, ks);

        vm.startBroadcast(pk);
        proposalId = proxy.proposeSetRoute(
            sourceChainId, destChainId, enabled, finalityVerifier, settlementModule,
            nonce, deadline, bitmap, sigs
        );
        vm.stopBroadcast();

        console2.log('proposeSetRoute submitted');
        console2.log('  proposalId:        ');
        console2.logBytes32(proposalId);
        console2.log('  nonce:             ', nonce);
        console2.log('  deadline (unix s): ', deadline);
        console2.log('');
        console2.log('After the timelock elapses, run:');
        console2.log('  cast send <PROXY_ADDRESS> "executeProposal(bytes32,bytes)" <proposalId> <opData>');
        console2.log('where opData =');
        console2.logBytes(abi.encode(
            sourceChainId, destChainId, enabled, finalityVerifier, settlementModule
        ));
    }
}
