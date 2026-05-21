// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script, console2 } from 'forge-std/Script.sol';

import { Bridge }              from '../../src/Bridge.sol';
import { CommissionManager }   from '../../src/CommissionManager.sol';
import { MultisigProxy }       from '../../src/MultisigProxy.sol';
import { RouteRegistry }       from '../../src/RouteRegistry.sol';
import { RGBVerifier }         from '../../src/verifiers/RGBVerifier.sol';
import { RgbSettlementModule } from '../../src/settlement/RgbSettlementModule.sol';

/// @title DeployAll
/// @notice Full production deploy flow.
///
/// Deployer tx order (nonce n):
///   n      → CommissionManager  (uses predicted Bridge for its
///                                 `bridgeAddress`)
///   n + 1  → RouteRegistry      (uses predicted Bridge for its `bridge_`
///                                 immutable; deployer keeps ownership for
///                                 this transaction batch — ownership is
///                                 transferred to MultisigProxy at the end)
///   n + 2  → Bridge             (uses the live RouteRegistry + CM)
///   n + 3  → RGBVerifier        (wraps the BtcRelay)
///   n + 4  → RgbSettlementModule (paired with RouteRegistry)
///   n + 5  → MultisigProxy
///   n + 6  → (optional) CommissionManager.setEthUsdFeed
///   n + 7  → CommissionManager.transferOwnership → MultisigProxy
///   n + 8  → Bridge.transferOwnership → MultisigProxy
///   n + 9  → RouteRegistry.transferOwnership → MultisigProxy
///
/// Routes are NOT registered here. Federation configures them through
/// `MultisigProxy.proposeSetRoute(...)` after deploy — this mirrors the
/// permanent governance path and keeps the deploy script audit-clean.
///
/// Env (required):
///   PRIVATE_KEY, USDT0_ADDRESS, BTC_RELAY_ADDRESS,
///   ENCLAVE_SIGNERS, ENCLAVE_THRESHOLD,
///   FEDERATION_SIGNERS, FEDERATION_THRESHOLD,
///   COMMISSION_RECIPIENT, TIMELOCK_DURATION
///
/// Env (optional):
///   ETH_USD_FEED      — Chainlink ETH/USD aggregator (wired in before CM
///                       ownership transfer, so NATIVE commission quotes
///                       are live the moment the proxy takes over).
///   ETH_USD_HEARTBEAT — Seconds before the feed answer is considered stale.
///                       Required when ETH_USD_FEED is provided.
///
/// Usage:
///   forge script script/deploy/DeployAll.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployAll is Script {
    function run()
        external
        returns (
            Bridge              bridge,
            CommissionManager   cm,
            RouteRegistry       routeRegistry,
            RGBVerifier         rgbVerifier,
            RgbSettlementModule rgbModule,
            MultisigProxy       proxy
        )
    {
        // ---- 1. Load env --------------------------------------------------
        uint256 pk             = vm.envUint('PRIVATE_KEY');
        address usdt0          = vm.envAddress('USDT0_ADDRESS');
        address btcRelay       = vm.envAddress('BTC_RELAY_ADDRESS');
        address[] memory enc   = vm.envAddress('ENCLAVE_SIGNERS', ',');
        uint256 encThr         = vm.envUint('ENCLAVE_THRESHOLD');
        address[] memory fed   = vm.envAddress('FEDERATION_SIGNERS', ',');
        uint256 fedThr         = vm.envUint('FEDERATION_THRESHOLD');
        address commission     = vm.envAddress('COMMISSION_RECIPIENT');
        uint256 timelock       = vm.envUint('TIMELOCK_DURATION');
        address ethUsdFeed     = vm.envOr('ETH_USD_FEED', address(0));
        uint256 ethUsdHb       = vm.envOr('ETH_USD_HEARTBEAT', uint256(0));

        address deployer    = vm.addr(pk);
        uint64  startNonce  = vm.getNonce(deployer);

        // Bridge sits at nonce + 2 (CM, RouteRegistry, then Bridge).
        address predictedBridge = vm.computeCreateAddress(deployer, startNonce + 2);

        vm.startBroadcast(pk);

        // ---- 2. CommissionManager (nonce n) ------------------------------
        cm = new CommissionManager(predictedBridge);

        // ---- 3. RouteRegistry (nonce n+1) --------------------------------
        // Owned by `deployer` for this batch; transferred to the proxy below
        // after the proxy has been deployed.
        routeRegistry = new RouteRegistry(predictedBridge, deployer);

        // ---- 4. Bridge (nonce n+2) ---------------------------------------
        bridge = new Bridge(
            usdt0,
            address(routeRegistry),
            payable(address(cm)),
            address(0)
        );

        // ---- 5. Route plugins (nonce n+3, n+4) ---------------------------
        rgbVerifier = new RGBVerifier(btcRelay);
        rgbModule   = new RgbSettlementModule(address(routeRegistry));

        // ---- 6. MultisigProxy (nonce n+5) --------------------------------
        proxy = new MultisigProxy(
            address(bridge),
            address(cm),
            enc, encThr,
            fed, fedThr,
            commission,
            timelock
        );

        // ---- 7. Wire optional ETH/USD feed before CM ownership transfer --
        if (ethUsdFeed != address(0)) {
            require(ethUsdHb != 0, 'ETH_USD_HEARTBEAT must be set when ETH_USD_FEED is provided');
            cm.setEthUsdFeed(ethUsdFeed, ethUsdHb);
        }

        // ---- 8. Hand over to federation ----------------------------------
        cm.transferOwnership(address(proxy));
        bridge.transferOwnership(address(proxy));
        routeRegistry.transferOwnership(address(proxy));

        vm.stopBroadcast();

        // ---- 9. Summary --------------------------------------------------
        console2.log('CommissionManager deployed at:  ', address(cm));
        console2.log('RouteRegistry deployed at:      ', address(routeRegistry));
        console2.log('Bridge deployed at:             ', address(bridge));
        console2.log('RGBVerifier deployed at:        ', address(rgbVerifier));
        console2.log('RgbSettlementModule deployed at:', address(rgbModule));
        console2.log('MultisigProxy deployed at:      ', address(proxy));
        if (ethUsdFeed != address(0)) {
            console2.log('ETH/USD feed wired:             ', ethUsdFeed);
            console2.log('ETH/USD heartbeat (s):          ', ethUsdHb);
        } else {
            console2.log('ETH/USD feed:                   ', 'UNSET (NATIVE quotes will revert until governance wires one)');
        }

        // ---- 10. Invariant checks ---------------------------------------
        require(address(bridge) == predictedBridge,         'Bridge address prediction mismatch');
        require(routeRegistry.bridge() == address(bridge),  'RouteRegistry.bridge mismatch');
        require(rgbModule.routeRegistry() == address(routeRegistry), 'RgbSettlementModule.routeRegistry mismatch');
        require(bridge.routeRegistry() == address(routeRegistry),    'Bridge.routeRegistry mismatch');
        require(cm.bridgeAddress() == address(bridge),      'CM.bridgeAddress mismatch');
        require(bridge.owner() == address(proxy),           'Bridge ownership transfer failed');
        require(cm.owner()     == address(proxy),           'CM ownership transfer failed');
        require(routeRegistry.owner() == address(proxy),    'RouteRegistry ownership transfer failed');
        if (ethUsdFeed != address(0)) {
            require(cm.ethUsdFeed() == ethUsdFeed,          'CM.ethUsdFeed mismatch');
            require(cm.ethUsdHeartbeat() == ethUsdHb,       'CM.ethUsdHeartbeat mismatch');
        }

        // ---- 11. Post-deploy reminder -----------------------------------
        console2.log('');
        console2.log('Next step: federation must register routes via');
        console2.log('  MultisigProxy.proposeSetRoute(src, dst, true, verifier, module)');
        console2.log('for each supported (sourceChainId, destChainId) pair');
        console2.log('before any fundsIn / fundsOut traffic is accepted.');
    }
}
