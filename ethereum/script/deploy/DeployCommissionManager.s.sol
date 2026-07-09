// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Script, console2 } from 'forge-std/Script.sol';
import { CommissionManager } from '../../src/CommissionManager.sol';

/// @title DeployCommissionManager
/// @notice Deploys CommissionManager for an already-known Bridge address.
///
/// Env:
///   PRIVATE_KEY       — deployer private key (becomes CM owner; transfer to multisig afterwards)
///   BRIDGE_ADDRESS    — Bridge contract that will send commissions (non-zero)
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
///   SEQUENCER_UPTIME_FEED — Optional (Arbitrum, R-I-14) Chainlink L2 Sequencer
///                       Uptime feed. When set, NATIVE quotes reject prices
///                       during sequencer downtime + the post-restart grace.
///   ETH_USD_MIN_PRICE / ETH_USD_MAX_PRICE — Optional (R-I-14) ETH/USD sanity
///                       band in feed decimals; set both or neither.
///   REQUIRE_CHAINLINK_HARDENING (false) — when true, revert unless ETH_USD_FEED,
///                       SEQUENCER_UPTIME_FEED, and the price band are all set
///                       (recommended for Arbitrum production).
///
/// Usage:
///   forge script script/deploy/DeployCommissionManager.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployCommissionManager is Script {
    function run() external returns (CommissionManager cm) {
        uint256 pk            = vm.envUint('PRIVATE_KEY');
        address bridgeAddress = vm.envAddress('BRIDGE_ADDRESS');
        address ethUsdFeed    = vm.envOr('ETH_USD_FEED', address(0));
        uint256 ethUsdHb      = vm.envOr('ETH_USD_HEARTBEAT', uint256(0));
        address seqFeed        = vm.envOr('SEQUENCER_UPTIME_FEED', address(0));
        uint256 ethUsdMinPrice = vm.envOr('ETH_USD_MIN_PRICE', uint256(0));
        uint256 ethUsdMaxPrice = vm.envOr('ETH_USD_MAX_PRICE', uint256(0));
        bool    reqHardening   = vm.envOr('REQUIRE_CHAINLINK_HARDENING', false);

        // Misconfiguration checks (fail-fast, before broadcast). Price band is
        // all-or-nothing (a half-set band would be silently ignored). The opt-in
        // prod guard enforces the full R-I-14 config when NATIVE is enabled.
        require((ethUsdMinPrice == 0) == (ethUsdMaxPrice == 0),
            'set both ETH_USD_MIN_PRICE and ETH_USD_MAX_PRICE, or neither');
        if (reqHardening) {
            require(ethUsdFeed != address(0), 'hardening: ETH_USD_FEED must be set');
            require(seqFeed != address(0),    'hardening: SEQUENCER_UPTIME_FEED must be set');
            require(ethUsdMaxPrice != 0,      'hardening: ETH_USD_MIN/MAX_PRICE must be set');
        }

        vm.startBroadcast(pk);
        cm = new CommissionManager(bridgeAddress);
        if (ethUsdFeed != address(0)) {
            require(ethUsdHb != 0, 'ETH_USD_HEARTBEAT must be set when ETH_USD_FEED is provided');
            cm.setEthUsdFeed(ethUsdFeed, ethUsdHb);
        }
        // R-I-14 Arbitrum hardening (owner-only; deployer is owner here).
        if (seqFeed != address(0)) {
            cm.setSequencerUptimeFeed(seqFeed);
        }
        if (ethUsdMaxPrice != 0) {
            cm.setEthUsdPriceBounds(ethUsdMinPrice, ethUsdMaxPrice);
        }
        vm.stopBroadcast();

        console2.log('CommissionManager deployed at:', address(cm));
        console2.log('Bridge address:               ', cm.bridgeAddress());
        console2.log('Owner (deployer):             ', cm.owner());
        if (ethUsdFeed != address(0)) {
            console2.log('ETH/USD feed wired:           ', ethUsdFeed);
            console2.log('ETH/USD heartbeat (s):        ', ethUsdHb);
        } else {
            console2.log('ETH/USD feed:                 ', 'UNSET (NATIVE quotes will revert until configured)');
        }
        if (seqFeed != address(0)) {
            console2.log('Sequencer uptime feed wired:  ', seqFeed);
        }
        if (ethUsdMaxPrice != 0) {
            console2.log('ETH/USD price band min:       ', ethUsdMinPrice);
            console2.log('ETH/USD price band max:       ', ethUsdMaxPrice);
        }
    }
}
