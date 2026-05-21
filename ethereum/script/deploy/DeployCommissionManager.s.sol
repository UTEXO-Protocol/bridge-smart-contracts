// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

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

        vm.startBroadcast(pk);
        cm = new CommissionManager(bridgeAddress);
        if (ethUsdFeed != address(0)) {
            require(ethUsdHb != 0, 'ETH_USD_HEARTBEAT must be set when ETH_USD_FEED is provided');
            cm.setEthUsdFeed(ethUsdFeed, ethUsdHb);
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
    }
}
