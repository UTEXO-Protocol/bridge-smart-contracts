// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script, console2 } from 'forge-std/Script.sol';
import { Bridge } from '../../src/Bridge.sol';

/// @title DeployBridge
/// @notice Deploys the UTEXO Bridge. Deployer is the initial owner.
///         Transfer ownership to MultisigProxy after deployment (see DeployAll.s.sol
///         or call bridge.transferOwnership(proxy) from a follow-up script).
///
/// Env:
///   PRIVATE_KEY               — deployer private key
///   USDT0_ADDRESS             — accepted ERC-20 token
///   BTC_RELAY_ADDRESS         — BtcRelay contract for Bitcoin header verification
///   COMMISSION_MANAGER        — CommissionManager contract (must already be deployed)
///   LZ_ADAPTER                — Optional initial LayerZero adapter address;
///                               omit or pass `0x0` if the adapter has not been
///                               deployed yet. Once the adapter exists in
///                               `utexo-usdt0-contracts`, wire it in via
///                               federation governance: `proposeAdminExecute`
///                               on MultisigProxy with calldata
///                               `Bridge.setLZAdapter(adapter)`. The Bridge
///                               accepts adapter-only `fundsInFromAdapter`
///                               calls *only* from the configured adapter.
///
/// Usage:
///   forge script script/deploy/DeployBridge.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployBridge is Script {
    function run() external returns (Bridge bridge) {
        uint256 pk                = vm.envUint('PRIVATE_KEY');
        address usdt0             = vm.envAddress('USDT0_ADDRESS');
        address btcRelay          = vm.envAddress('BTC_RELAY_ADDRESS');
        address commissionManager = vm.envAddress('COMMISSION_MANAGER');
        address lzAdapter         = vm.envOr('LZ_ADAPTER', address(0));

        vm.startBroadcast(pk);
        bridge = new Bridge(usdt0, btcRelay, payable(commissionManager), lzAdapter);
        vm.stopBroadcast();

        console2.log('Bridge deployed at:  ', address(bridge));
        console2.log('Owner (deployer):    ', bridge.owner());
        console2.log('Token:               ', bridge.TOKEN());
        console2.log('BtcRelay:            ', bridge.btcRelay());
        console2.log('CommissionManager:   ', address(bridge.commissionManager()));
        console2.log('LZ adapter:          ', bridge.lzAdapter());
    }
}
