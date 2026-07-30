// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";

/// @title DeployCommissionManager
/// @notice Deploys CommissionManager for an already-known Bridge address.
///
/// Env:
///   PRIVATE_KEY       — deployer private key (becomes CM owner; transfer to multisig afterwards)
///   BRIDGE_ADDRESS    — Bridge contract that will send commissions (non-zero)
///   COMMISSION_RECIPIENT — immutable destination for every commission withdrawal
///
///   ETH_USD_FEED      — Optional Chainlink ETH/USD aggregator address. When
///                       supplied (non-zero) the script also calls
///                       `setEthUsdFeed(feed, ETH_USD_HEARTBEAT)` so the
///                       NATIVE-currency commission path is live immediately.
///                       Omit (or leave zero) to wire the feed later via
///                       federation governance once ownership is transferred.
///   ETH_USD_HEARTBEAT — Required when `ETH_USD_FEED` is set; seconds before
///                       the feed answer is considered stale. Arbitrum One
///                       ETH/USD heartbeats at 86400 s — use ~87000 with a
///                       small buffer.
///   SEQUENCER_UPTIME_FEED — Required whenever ETH_USD_FEED is set. Chainlink
///                       Arbitrum L2 Sequencer Uptime feed used to reject NATIVE
///                       quotes during downtime + the post-restart grace period.
///   ETH_USD_MIN_PRICE / ETH_USD_MAX_PRICE — Required whenever ETH_USD_FEED is
///                       set. ETH/USD sanity band in the price feed's decimals.
///
/// Usage:
///   forge script script/deploy/DeployCommissionManager.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
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

        // Misconfiguration checks (fail-fast, before broadcast). Price band is
        // all-or-nothing. Hardening is mandatory whenever the NATIVE
        // oracle path is enabled; there is no production opt-out.
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
