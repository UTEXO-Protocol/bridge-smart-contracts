// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script, console2 } from 'forge-std/Script.sol';
import { RGBVerifier } from '../../src/verifiers/RGBVerifier.sol';

/// @title DeployRGBVerifier
/// @notice Deploys the RGB-route finality verifier (thin wrapper around the
///         Atomiq `IBtcRelayView` SPV header relay). The verifier is
///         stateless apart from the immutable `btcRelay` reference; rotation
///         = redeploy + federation `proposeSetRoute` pointing the RGB route
///         at the new verifier.
///
/// Env:
///   PRIVATE_KEY        — deployer private key
///   BTC_RELAY_ADDRESS  — deployed `IBtcRelayView` instance
///
/// Usage:
///   forge script script/deploy/DeployRGBVerifier.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployRGBVerifier is Script {
    function run() external returns (RGBVerifier verifier) {
        uint256 pk       = vm.envUint('PRIVATE_KEY');
        address btcRelay = vm.envAddress('BTC_RELAY_ADDRESS');

        vm.startBroadcast(pk);
        verifier = new RGBVerifier(btcRelay);
        vm.stopBroadcast();

        console2.log('RGBVerifier deployed at:', address(verifier));
        console2.log('BtcRelay (immutable):   ', verifier.btcRelay());
    }
}
