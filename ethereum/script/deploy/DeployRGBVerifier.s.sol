// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {RGBVerifier} from "../../src/verifiers/RGBVerifier.sol";

/// @title DeployRGBVerifier
/// @notice Deploys an RGB verifier for BTC_RELAY_ADDRESS.
/// @dev Thresholds default to 3/2/2 and accept environment overrides;
///      route activation is a separate governance proposal.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `BTC_RELAY_ADDRESS`, `MIN_SOURCE_CONFIRMATIONS`,
///      `MAX_LATEST_CONFIRMATIONS`, `MIN_CONFIRMATION_GAP`.
contract DeployRGBVerifier is Script {
    function run() external returns (RGBVerifier verifier) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address btcRelay = vm.envAddress("BTC_RELAY_ADDRESS");
        uint256 minSource = vm.envOr("MIN_SOURCE_CONFIRMATIONS", uint256(3));
        uint256 maxLatest = vm.envOr("MAX_LATEST_CONFIRMATIONS", uint256(2));
        uint256 minGap = vm.envOr("MIN_CONFIRMATION_GAP", uint256(2));

        vm.startBroadcast(pk);
        verifier = new RGBVerifier(btcRelay, minSource, maxLatest, minGap);
        vm.stopBroadcast();

        console2.log("RGBVerifier deployed at:   ", address(verifier));
        console2.log("BtcRelay (immutable):      ", verifier.btcRelay());
        console2.log("minSourceConfirmations:    ", verifier.minSourceConfirmations());
        console2.log("maxLatestConfirmations:    ", verifier.maxLatestConfirmations());
        console2.log("minConfirmationGap:        ", verifier.minConfirmationGap());
    }
}
