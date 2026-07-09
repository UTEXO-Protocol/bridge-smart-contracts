// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Script, console2 } from 'forge-std/Script.sol';
import { RGBVerifier } from '../../src/verifiers/RGBVerifier.sol';

/// @title DeployRGBVerifier
/// @notice Deploys the RGB-route finality verifier (thin wrapper around the
///         Atomiq `IBtcRelayView` SPV header relay). The verifier is
///         stateless apart from its immutable config (`btcRelay` plus the
///         confirmation-depth thresholds); retuning = redeploy + federation
///         `proposeSetRoute` pointing the RGB route at the new verifier.
///
/// Env (required):
///   PRIVATE_KEY        — deployer private key
///   BTC_RELAY_ADDRESS  — deployed `IBtcRelayView` instance
///
/// Env (optional, confirmation-depth thresholds; defaults in parens):
///   MIN_SOURCE_CONFIRMATIONS (6) — min depth of the source (RGB burn/lock) block
///   MAX_LATEST_CONFIRMATIONS (1) — max depth of the latest (freshness) block; must be >= 1
///   MIN_CONFIRMATION_GAP     (5) — min depth gap between source and latest
///
/// Usage:
///   forge script script/deploy/DeployRGBVerifier.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployRGBVerifier is Script {
    function run() external returns (RGBVerifier verifier) {
        uint256 pk        = vm.envUint('PRIVATE_KEY');
        address btcRelay  = vm.envAddress('BTC_RELAY_ADDRESS');
        uint256 minSource = vm.envOr('MIN_SOURCE_CONFIRMATIONS', uint256(6));
        uint256 maxLatest = vm.envOr('MAX_LATEST_CONFIRMATIONS', uint256(1));
        uint256 minGap    = vm.envOr('MIN_CONFIRMATION_GAP',     uint256(5));

        vm.startBroadcast(pk);
        verifier = new RGBVerifier(btcRelay, minSource, maxLatest, minGap);
        vm.stopBroadcast();

        console2.log('RGBVerifier deployed at:   ', address(verifier));
        console2.log('BtcRelay (immutable):      ', verifier.btcRelay());
        console2.log('minSourceConfirmations:    ', verifier.minSourceConfirmations());
        console2.log('maxLatestConfirmations:    ', verifier.maxLatestConfirmations());
        console2.log('minConfirmationGap:        ', verifier.minConfirmationGap());
    }
}
