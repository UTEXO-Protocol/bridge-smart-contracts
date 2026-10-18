// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";

/// @title DeployCommissionManager
/// @notice Deploys and optionally configures a CommissionManager owned by the deployer.
/// @dev A non-zero ETH_USD_FEED requires heartbeat, sequencer feed and price bounds.
///      Ownership handoff is separate; follow the CM migration order in docs/README.md.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `BRIDGE_ADDRESS`, `COMMISSION_RECIPIENT`, `ETH_USD_FEED`,
///      `ETH_USD_HEARTBEAT`, `SEQUENCER_UPTIME_FEED`, `ETH_USD_MIN_PRICE`, `ETH_USD_MAX_PRICE`.
contract DeployCommissionManager is Script {
    function run() external returns (CommissionManager cm) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address bridgeAddress = vm.envAddress("BRIDGE_ADDRESS");
        address commissionRecipient = vm.envAddress("COMMISSION_RECIPIENT");
        address ethUsdFeed = vm.envOr("ETH_USD_FEED", address(0));
        uint256 ethUsdHb = vm.envOr("ETH_USD_HEARTBEAT", uint256(0));
        address seqFeed = vm.envOr("SEQUENCER_UPTIME_FEED", address(0));
        uint256 ethUsdMinPrice = vm.envOr("ETH_USD_MIN_PRICE", uint256(0));
        uint256 ethUsdMaxPrice = vm.envOr("ETH_USD_MAX_PRICE", uint256(0));

        // Require complete oracle settings before broadcasting.
        require(
            (ethUsdMinPrice == 0) == (ethUsdMaxPrice == 0),
            "set both ETH_USD_MIN_PRICE and ETH_USD_MAX_PRICE, or neither"
        );
        require(ethUsdMaxPrice == 0 || ethUsdMinPrice < ethUsdMaxPrice, "ETH_USD_MIN_PRICE must be below MAX");
        if (ethUsdFeed != address(0)) {
            require(ethUsdHb != 0, "ETH_USD_HEARTBEAT must be set when ETH_USD_FEED is provided");
            require(seqFeed != address(0), "hardening: SEQUENCER_UPTIME_FEED must be set");
            require(ethUsdMaxPrice != 0, "hardening: ETH_USD_MIN/MAX_PRICE must be set");
        }

        vm.startBroadcast(pk);
        cm = new CommissionManager(bridgeAddress, commissionRecipient);
        // Install the safety dependencies before enabling ETH/USD quotes.
        if (seqFeed != address(0)) {
            cm.setSequencerUptimeFeed(seqFeed);
        }
        if (ethUsdMaxPrice != 0) {
            cm.setEthUsdPriceBounds(ethUsdMinPrice, ethUsdMaxPrice);
        }
        if (ethUsdFeed != address(0)) {
            cm.setEthUsdFeed(ethUsdFeed, ethUsdHb);
        }
        vm.stopBroadcast();

        console2.log("CommissionManager deployed at:", address(cm));
        console2.log("Bridge address:               ", cm.bridgeAddress());
        console2.log("Immutable commission recipient:", cm.commissionRecipient());
        console2.log("Owner (deployer):             ", cm.owner());
        if (ethUsdFeed != address(0)) {
            console2.log("ETH/USD feed wired:           ", ethUsdFeed);
            console2.log("ETH/USD heartbeat (s):        ", ethUsdHb);
        } else {
            console2.log("ETH/USD feed:                 ", "UNSET (NATIVE quotes will revert until configured)");
        }
        if (seqFeed != address(0)) {
            console2.log("Sequencer uptime feed wired:  ", seqFeed);
        }
        if (ethUsdMaxPrice != 0) {
            console2.log("ETH/USD price band min:       ", ethUsdMinPrice);
            console2.log("ETH/USD price band max:       ", ethUsdMaxPrice);
        }
    }
}
