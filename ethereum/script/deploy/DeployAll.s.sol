// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {Bridge} from "../../src/Bridge.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {RouteRegistry} from "../../src/RouteRegistry.sol";
import {RGBVerifier} from "../../src/verifiers/RGBVerifier.sol";
import {NullVerifier} from "../../src/verifiers/NullVerifier.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {RgbOutboundSettlementModule} from "../../src/settlement/RgbOutboundSettlementModule.sol";

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
///   n + 5  → NullVerifier       (explicit no-proof verifier for operational /
///                                 non-RGB-source routes, e.g. Arch → RGB)
///   n + 6  → RgbOutboundSettlementModule (debit-RGB / non-RGB-credit routes,
///                                 e.g. RGB → Arch; wraps RgbSettlementModule)
///   n + 7  → MultisigProxy
///          → Bridge.setOutflowLimit for INITIAL_ENCLAVE_SOURCE_CHAIN_ID
///          → Bridge.setGlobalOutflowLimit
///          → (optional) CommissionManager config txs, each present only when
///            its env is set: setEthUsdFeed, setSequencerUptimeFeed,
///            setEthUsdPriceBounds. These shift the transferOwnership nonces
///            below by however many are emitted (0–3).
///          → CommissionManager.transferOwnership (starts two-step handoff)
///          → Bridge.transferOwnership (starts two-step handoff)
///          → RouteRegistry.transferOwnership (starts two-step handoff)
///
/// Ownership is Ownable2Step: the transferOwnership calls only set
/// pendingOwner = MultisigProxy. The federation MUST accept post-deploy via
/// governance (acceptOwnership) — see the post-deploy reminder. Until then,
/// `deployer` remains the owner.
///
/// Routes are NOT registered here. Federation configures them through
/// `MultisigProxy.proposeSetRoute(...)` after deploy — this mirrors the
/// permanent governance path and keeps the deploy script audit-clean.
///
/// Env (required):
///   PRIVATE_KEY, USDT0_ADDRESS, BTC_RELAY_ADDRESS,
///   ENCLAVE_SIGNERS, ENCLAVE_THRESHOLD, INITIAL_ENCLAVE_SOURCE_CHAIN_ID,
///   FEDERATION_SIGNERS, FEDERATION_THRESHOLD,
///   COMMISSION_RECIPIENT, TIMELOCK_DURATION, MIN_TIMELOCK,
///   MIN_FUNDS_IN_AMOUNT,
///   INITIAL_CHAIN_BURST_BPS, INITIAL_CHAIN_REFILL_BPS_PER_WINDOW,
///   GLOBAL_BURST_BPS, GLOBAL_REFILL_BPS_PER_WINDOW
///
/// Env (optional):
///   ETH_USD_FEED      — Chainlink ETH/USD aggregator (wired in before CM
///                       ownership transfer, so NATIVE commission quotes
///                       are live the moment the proxy takes over).
///   ETH_USD_HEARTBEAT — Seconds before the feed answer is considered stale.
///                       Required when ETH_USD_FEED is provided.
///   MIN_SOURCE_CONFIRMATIONS (6) — RGBVerifier: min depth of the source
///                       (RGB burn/lock) block.
///   MAX_LATEST_CONFIRMATIONS (1) — RGBVerifier: max depth of the latest
///                       (freshness) block; must be >= 1.
///   MIN_CONFIRMATION_GAP     (5) — RGBVerifier: min depth gap between the
///                       source and latest blocks.
///   SEQUENCER_UPTIME_FEED — (Arbitrum, R-I-14) Chainlink L2 Sequencer Uptime
///                       feed. When set, NATIVE quotes reject prices during
///                       sequencer downtime and the post-restart grace period.
///                       SHOULD be set on Arbitrum when NATIVE commission is used.
///   ETH_USD_MIN_PRICE / ETH_USD_MAX_PRICE — (R-I-14) optional ETH/USD sanity
///                       band in feed decimals (e.g. 100e8 / 100000e8). Set both
///                       or neither; else 0 < min < max.
///   REQUIRE_CHAINLINK_HARDENING (false) — when true, the deploy reverts unless
///                       ETH_USD_FEED, SEQUENCER_UPTIME_FEED, and the price band
///                       are all set. Recommended for Arbitrum production so the
///                       R-I-14 guards can never be silently absent.
///
/// Usage:
///   forge script script/deploy/DeployAll.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeployAll is Script {
    uint256 private constant MAX_OUTFLOW_POLICY_BPS = 2_000;

    function run()
        external
        returns (
            Bridge bridge,
            CommissionManager cm,
            RouteRegistry routeRegistry,
            RGBVerifier rgbVerifier,
            RgbSettlementModule rgbModule,
            NullVerifier nullVerifier,
            RgbOutboundSettlementModule outboundModule,
            MultisigProxy proxy
        )
    {
        // ---- 1. Load env --------------------------------------------------
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address usdt0 = vm.envAddress("USDT0_ADDRESS");
        address btcRelay = vm.envAddress("BTC_RELAY_ADDRESS");
        address[] memory enc = vm.envAddress("ENCLAVE_SIGNERS", ",");
        uint256 encThr = vm.envUint("ENCLAVE_THRESHOLD");
        uint256 initialSrcChain = vm.envUint("INITIAL_ENCLAVE_SOURCE_CHAIN_ID");
        address[] memory fed = vm.envAddress("FEDERATION_SIGNERS", ",");
        uint256 fedThr = vm.envUint("FEDERATION_THRESHOLD");
        address commission = vm.envAddress("COMMISSION_RECIPIENT");
        uint256 timelock = vm.envUint("TIMELOCK_DURATION");
        uint256 minTimelock = vm.envUint("MIN_TIMELOCK");
        address ethUsdFeed = vm.envOr("ETH_USD_FEED", address(0));
        uint256 ethUsdHb = vm.envOr("ETH_USD_HEARTBEAT", uint256(0));
        uint256 minFundsIn = vm.envUint("MIN_FUNDS_IN_AMOUNT");
        uint256 minSourceConf = vm.envOr("MIN_SOURCE_CONFIRMATIONS", uint256(6));
        uint256 maxLatestConf = vm.envOr("MAX_LATEST_CONFIRMATIONS", uint256(1));
        uint256 minConfGap = vm.envOr("MIN_CONFIRMATION_GAP", uint256(5));
        address seqFeed = vm.envOr("SEQUENCER_UPTIME_FEED", address(0));
        uint256 ethUsdMinPrice = vm.envOr("ETH_USD_MIN_PRICE", uint256(0));
        uint256 ethUsdMaxPrice = vm.envOr("ETH_USD_MAX_PRICE", uint256(0));
        bool reqHardening = vm.envOr("REQUIRE_CHAINLINK_HARDENING", false);
        uint256 initialChainBurstBps = vm.envUint("INITIAL_CHAIN_BURST_BPS");
        uint256 initialChainRefillBps = vm.envUint("INITIAL_CHAIN_REFILL_BPS_PER_WINDOW");
        uint256 globalBurstBps = vm.envUint("GLOBAL_BURST_BPS");
        uint256 globalRefillBps = vm.envUint("GLOBAL_REFILL_BPS_PER_WINDOW");

        // ---- 1a. Misconfiguration checks (fail-fast, before any broadcast) ---
        // Price band is all-or-nothing: a half-set band would otherwise be
        // silently ignored (setter only runs when max != 0).
        require(
            (ethUsdMinPrice == 0) == (ethUsdMaxPrice == 0),
            "set both ETH_USD_MIN_PRICE and ETH_USD_MAX_PRICE, or neither"
        );
        // Opt-in prod guard (set REQUIRE_CHAINLINK_HARDENING=true for Arbitrum):
        // when NATIVE commission is enabled, the sequencer feed and price band
        // must be wired too, so the R-I-14 protections are not silently absent.
        if (reqHardening) {
            require(ethUsdFeed != address(0), "hardening: ETH_USD_FEED must be set");
            require(seqFeed != address(0), "hardening: SEQUENCER_UPTIME_FEED must be set");
            require(ethUsdMaxPrice != 0, "hardening: ETH_USD_MIN/MAX_PRICE must be set");
        }
        require(
            _validOutflowPolicy(initialChainBurstBps, initialChainRefillBps), "invalid initial chain outflow policy"
        );
        require(_validOutflowPolicy(globalBurstBps, globalRefillBps), "invalid global outflow policy");

        address deployer = vm.addr(pk);
        uint64 startNonce = vm.getNonce(deployer);

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
        bridge = new Bridge(usdt0, address(routeRegistry), payable(address(cm)), address(0), minFundsIn);

        // ---- 5. Route plugins (nonce n+3 .. n+6) -------------------------
        rgbVerifier = new RGBVerifier(btcRelay, minSourceConf, maxLatestConf, minConfGap);
        rgbModule = new RgbSettlementModule(address(routeRegistry));
        // NullVerifier: explicit no-proof verifier for operational / non-RGB-
        // source routes (e.g. Arch → RGB, Pool → MintBurn). One instance serves
        // every such route. Federation wires it per route via `proposeSetRoute`.
        nullVerifier = new NullVerifier();
        // RgbOutboundSettlementModule: for debit-RGB / non-RGB-credit routes
        // (e.g. RGB → Arch) — reads the canonical RGB ledger (amount + network
        // tag), writes nothing on credit. Routes with an RGB credit side use the
        // canonical `rgbModule` instead.
        outboundModule = new RgbOutboundSettlementModule(address(routeRegistry), address(rgbModule));

        // ---- 6. MultisigProxy (nonce n+7) --------------------------------
        proxy = new MultisigProxy(
            address(bridge), address(cm), enc, encThr, initialSrcChain, fed, fedThr, commission, timelock, minTimelock
        );

        // ---- 7. Install initial outflow policies before ownership transfer -
        // Percentage policies are valid at zero liquidity. Installing both
        // buckets while the deployer still owns Bridge means the initial route
        // is ready for fundsOut as soon as routes and ownership are activated;
        // it cannot be stranded behind a fresh timelocked admin proposal.
        bridge.setOutflowLimit(initialSrcChain, initialChainBurstBps, initialChainRefillBps);
        bridge.setGlobalOutflowLimit(globalBurstBps, globalRefillBps);

        // ---- 8. Wire optional ETH/USD feed before CM ownership transfer --
        if (ethUsdFeed != address(0)) {
            require(ethUsdHb != 0, "ETH_USD_HEARTBEAT must be set when ETH_USD_FEED is provided");
            cm.setEthUsdFeed(ethUsdFeed, ethUsdHb);
        }

        // ---- 8b. Wire optional R-I-14 Arbitrum hardening (owner-only, before
        //          the ownership transfer): the L2 sequencer-uptime feed and the
        //          ETH/USD sanity band. On Arbitrum these SHOULD be set whenever
        //          the NATIVE commission path (ETH_USD_FEED) is used.
        if (seqFeed != address(0)) {
            cm.setSequencerUptimeFeed(seqFeed);
        }
        if (ethUsdMaxPrice != 0) {
            cm.setEthUsdPriceBounds(ethUsdMinPrice, ethUsdMaxPrice);
        }

        // ---- 9. Start two-step ownership handover to federation ----------
        // Ownable2Step: these only set pendingOwner = proxy. The federation
        // completes the handoff post-deploy by accepting via governance
        // (AdminExecute / AdminExecuteCommissionManager / AdminExecuteRouteRegistry
        // -> acceptOwnership). Until then, `deployer` stays the owner.
        cm.transferOwnership(address(proxy));
        bridge.transferOwnership(address(proxy));
        routeRegistry.transferOwnership(address(proxy));

        vm.stopBroadcast();

        // ---- 10. Summary -------------------------------------------------
        console2.log("CommissionManager deployed at:  ", address(cm));
        console2.log("RouteRegistry deployed at:      ", address(routeRegistry));
        console2.log("Bridge deployed at:             ", address(bridge));
        console2.log("RGBVerifier deployed at:        ", address(rgbVerifier));
        console2.log("  minSourceConfirmations:       ", rgbVerifier.minSourceConfirmations());
        console2.log("  maxLatestConfirmations:       ", rgbVerifier.maxLatestConfirmations());
        console2.log("  minConfirmationGap:           ", rgbVerifier.minConfirmationGap());
        console2.log("RgbSettlementModule deployed at:", address(rgbModule));
        console2.log("NullVerifier deployed at:       ", address(nullVerifier));
        console2.log("RgbOutboundSettlementModule at: ", address(outboundModule));
        console2.log("MultisigProxy deployed at:      ", address(proxy));
        console2.log("Initial chain bucket burst bps: ", initialChainBurstBps);
        console2.log("Initial chain bucket refill bps:", initialChainRefillBps);
        console2.log("Global bucket burst bps:        ", globalBurstBps);
        console2.log("Global bucket refill bps:       ", globalRefillBps);
        if (ethUsdFeed != address(0)) {
            console2.log("ETH/USD feed wired:             ", ethUsdFeed);
            console2.log("ETH/USD heartbeat (s):          ", ethUsdHb);
        } else {
            console2.log(
                "ETH/USD feed:                   ", "UNSET (NATIVE quotes will revert until governance wires one)"
            );
        }
        if (seqFeed != address(0)) {
            console2.log("Sequencer uptime feed wired:    ", seqFeed);
        } else {
            console2.log("Sequencer uptime feed:          ", "UNSET (set on Arbitrum when NATIVE commission is used)");
        }
        if (ethUsdMaxPrice != 0) {
            console2.log("ETH/USD price band min:         ", ethUsdMinPrice);
            console2.log("ETH/USD price band max:         ", ethUsdMaxPrice);
        }

        // ---- 11. Invariant checks ---------------------------------------
        require(address(bridge) == predictedBridge, "Bridge address prediction mismatch");
        require(routeRegistry.bridge() == address(bridge), "RouteRegistry.bridge mismatch");
        require(rgbModule.routeRegistry() == address(routeRegistry), "RgbSettlementModule.routeRegistry mismatch");
        require(
            outboundModule.routeRegistry() == address(routeRegistry),
            "RgbOutboundSettlementModule.routeRegistry mismatch"
        );
        require(
            address(outboundModule.rgbModule()) == address(rgbModule), "RgbOutboundSettlementModule.rgbModule mismatch"
        );
        require(bridge.routeRegistry() == address(routeRegistry), "Bridge.routeRegistry mismatch");
        require(cm.bridgeAddress() == address(bridge), "CM.bridgeAddress mismatch");
        (uint128 chainTokens,, bool chainEnabled, uint128 chainCapacity, uint128 chainRate) =
            bridge.chainBuckets(initialSrcChain);
        require(chainEnabled && chainTokens == chainCapacity && chainRate != 0, "initial chain bucket not configured");
        (uint128 globalTokens,, bool globalEnabled, uint128 globalCapacity, uint128 globalRate) = bridge.globalBucket();
        require(globalEnabled && globalTokens == globalCapacity && globalRate != 0, "global bucket not configured");
        // Two-step: ownership stays with `deployer` until the federation
        // accepts; assert the pending transfer to the proxy was initiated.
        require(
            bridge.owner() == deployer && bridge.pendingOwner() == address(proxy),
            "Bridge ownership handoff not initiated"
        );
        require(cm.owner() == deployer && cm.pendingOwner() == address(proxy), "CM ownership handoff not initiated");
        require(
            routeRegistry.owner() == deployer && routeRegistry.pendingOwner() == address(proxy),
            "RouteRegistry ownership handoff not initiated"
        );
        if (ethUsdFeed != address(0)) {
            require(cm.ethUsdFeed() == ethUsdFeed, "CM.ethUsdFeed mismatch");
            require(cm.ethUsdHeartbeat() == ethUsdHb, "CM.ethUsdHeartbeat mismatch");
        }
        if (seqFeed != address(0)) {
            require(cm.sequencerUptimeFeed() == seqFeed, "CM.sequencerUptimeFeed mismatch");
        }
        if (ethUsdMaxPrice != 0) {
            require(
                cm.ethUsdMinPrice() == ethUsdMinPrice && cm.ethUsdMaxPrice() == ethUsdMaxPrice,
                "CM.ethUsdPriceBounds mismatch"
            );
        }

        // ---- 12. Post-deploy reminder -----------------------------------
        console2.log("");
        console2.log("Ownership handoff is two-step: deployer still owns Bridge/CM/");
        console2.log("RouteRegistry until the federation accepts via governance:");
        console2.log("  AdminExecute                  -> Bridge.acceptOwnership()");
        console2.log("  AdminExecuteCommissionManager -> CommissionManager.acceptOwnership()");
        console2.log("  AdminExecuteRouteRegistry     -> RouteRegistry.acceptOwnership()");
        console2.log("");
        console2.log("Next step: federation must register routes via");
        console2.log("  MultisigProxy.proposeSetRoute(src, dst, true, verifier, module)");
        console2.log("for each supported (sourceChainId, destChainId) pair");
        console2.log("before any fundsIn / fundsOut traffic is accepted.");
        console2.log("For every additional fundsOut source chain, federation must also");
        console2.log("install setOutflowLimit(chainId, burstBps, refillBpsPerWindow)");
        console2.log("before enabling traffic for that chain.");
    }

    function _validOutflowPolicy(uint256 burstBps, uint256 refillBpsPerWindow) private pure returns (bool) {
        return burstBps != 0 && refillBpsPerWindow != 0 && burstBps <= MAX_OUTFLOW_POLICY_BPS
            && refillBpsPerWindow <= MAX_OUTFLOW_POLICY_BPS && burstBps + refillBpsPerWindow <= MAX_OUTFLOW_POLICY_BPS;
    }
}
