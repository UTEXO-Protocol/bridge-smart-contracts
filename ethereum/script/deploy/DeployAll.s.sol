// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {Bridge} from "../../src/Bridge.sol";
import {BridgeProxy} from "../../src/BridgeProxy.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {RouteRegistry} from "../../src/RouteRegistry.sol";
import {RGBVerifier} from "../../src/verifiers/RGBVerifier.sol";
import {NullVerifier} from "../../src/verifiers/NullVerifier.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {RgbOutboundSettlementModule} from "../../src/settlement/RgbOutboundSettlementModule.sol";
import {NullSettlementModule} from "../../src/settlement/NullSettlementModule.sol";

/// @title DeployAll
/// @notice Deploys the bridge stack and starts ownership handoffs to MultisigProxy.
/// @dev Predicts BridgeProxy at deployer nonce + 3. Configures outflow policies and optional
///      oracle settings before handoff. Federation accepts ownership and registers routes
///      separately. Verifier thresholds default to 3/2/2 and accept environment overrides.
///      Inputs (see the matching .env example for values):
///      `PRIVATE_KEY`, `USDT0_ADDRESS`, `BTC_RELAY_ADDRESS`, `ENCLAVE_SIGNERS`,
///      `ENCLAVE_THRESHOLD`, `INITIAL_ENCLAVE_SOURCE_CHAIN_ID`, `FEDERATION_SIGNERS`,
///      `FEDERATION_THRESHOLD`, `EMERGENCY_GUARDIAN`, `COMMISSION_RECIPIENT`, `TIMELOCK_DURATION`,
///      `MIN_TIMELOCK`, `ETH_USD_FEED`, `ETH_USD_HEARTBEAT`, `MIN_FUNDS_IN_AMOUNT`,
///      `MIN_FUNDS_OUT_AMOUNT`, `MIN_SOURCE_CONFIRMATIONS`, `MAX_LATEST_CONFIRMATIONS`,
///      `MIN_CONFIRMATION_GAP`, `SEQUENCER_UPTIME_FEED`, `ETH_USD_MIN_PRICE`, `ETH_USD_MAX_PRICE`,
///      `INITIAL_CHAIN_BURST_BPS`, `INITIAL_CHAIN_REFILL_BPS_PER_WINDOW`, `GLOBAL_BURST_BPS`,
///      `GLOBAL_REFILL_BPS_PER_WINDOW`.
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
            NullSettlementModule nullModule,
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
        address emergencyGuardian = vm.envAddress("EMERGENCY_GUARDIAN");
        address commission = vm.envAddress("COMMISSION_RECIPIENT");
        uint256 timelock = vm.envUint("TIMELOCK_DURATION");
        uint256 minTimelock = vm.envUint("MIN_TIMELOCK");
        address ethUsdFeed = vm.envOr("ETH_USD_FEED", address(0));
        uint256 ethUsdHb = vm.envOr("ETH_USD_HEARTBEAT", uint256(0));
        uint256 minFundsIn = vm.envUint("MIN_FUNDS_IN_AMOUNT");
        uint256 minFundsOut = vm.envUint("MIN_FUNDS_OUT_AMOUNT");
        uint256 minSourceConf = vm.envOr("MIN_SOURCE_CONFIRMATIONS", uint256(3));
        uint256 maxLatestConf = vm.envOr("MAX_LATEST_CONFIRMATIONS", uint256(2));
        uint256 minConfGap = vm.envOr("MIN_CONFIRMATION_GAP", uint256(2));
        address seqFeed = vm.envOr("SEQUENCER_UPTIME_FEED", address(0));
        uint256 ethUsdMinPrice = vm.envOr("ETH_USD_MIN_PRICE", uint256(0));
        uint256 ethUsdMaxPrice = vm.envOr("ETH_USD_MAX_PRICE", uint256(0));
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
        require(ethUsdMaxPrice == 0 || ethUsdMinPrice < ethUsdMaxPrice, "ETH_USD_MIN_PRICE must be below MAX");
        // Native quotes require heartbeat, sequencer and price-bound configuration.
        if (ethUsdFeed != address(0)) {
            require(ethUsdHb != 0, "ETH_USD_HEARTBEAT must be set when ETH_USD_FEED is provided");
            require(seqFeed != address(0), "hardening: SEQUENCER_UPTIME_FEED must be set");
            require(ethUsdMaxPrice != 0, "hardening: ETH_USD_MIN/MAX_PRICE must be set");
        }
        require(
            _validOutflowPolicy(initialChainBurstBps, initialChainRefillBps), "invalid initial chain outflow policy"
        );
        require(_validOutflowPolicy(globalBurstBps, globalRefillBps), "invalid global outflow policy");

        address deployer = vm.addr(pk);
        uint64 startNonce = vm.getNonce(deployer);

        // The canonical Bridge proxy sits at nonce + 3 (CM, RouteRegistry,
        // implementation, then proxy).
        address predictedBridge = vm.computeCreateAddress(deployer, startNonce + 3);

        vm.startBroadcast(pk);

        // ---- 2. CommissionManager (nonce n) ------------------------------
        cm = new CommissionManager(predictedBridge, commission);

        // ---- 3. RouteRegistry (nonce n+1) --------------------------------
        // Owned by `deployer` for this batch; transferred to the proxy below
        // after the proxy has been deployed.
        routeRegistry = new RouteRegistry(predictedBridge, deployer);

        // ---- 4. Bridge implementation + proxy (nonce n+2, n+3) -----------
        Bridge bridgeImplementation = new Bridge();
        bytes memory bridgeInitializationData = abi.encodeCall(
            Bridge.initialize,
            (usdt0, address(routeRegistry), payable(address(cm)), address(0), minFundsIn, minFundsOut, deployer)
        );
        BridgeProxy bridgeProxy = new BridgeProxy(address(bridgeImplementation), bridgeInitializationData);
        bridge = Bridge(address(bridgeProxy));

        // ---- 5. Route plugins (nonce n+4 .. n+8) -------------------------
        rgbVerifier = new RGBVerifier(btcRelay, minSourceConf, maxLatestConf, minConfGap);
        rgbModule = new RgbSettlementModule(address(routeRegistry));
        // Optional verifier for routes whose finality is checked upstream.
        nullVerifier = new NullVerifier();
        // Reads the RGB ledger for debits without creating records on non-RGB credits.
        outboundModule = new RgbOutboundSettlementModule(address(routeRegistry), address(rgbModule));
        // Stateless routes whose settlement/finality is handled by the TEE or
        // an external delivery layer still use an explicit non-zero module.
        nullModule = new NullSettlementModule();

        // ---- 6. MultisigProxy (nonce n+9) -------------------------------
        proxy = new MultisigProxy(
            address(bridge),
            address(cm),
            emergencyGuardian,
            enc,
            encThr,
            initialSrcChain,
            fed,
            fedThr,
            timelock,
            minTimelock
        );

        // ---- 7. Configure outflow policies before ownership handoff --------
        bridge.setOutflowLimit(initialSrcChain, initialChainBurstBps, initialChainRefillBps);
        bridge.setGlobalOutflowLimit(globalBurstBps, globalRefillBps);

        // ---- 8. Wire oracle dependencies before enabling ETH/USD quotes ----
        if (seqFeed != address(0)) {
            cm.setSequencerUptimeFeed(seqFeed);
        }
        if (ethUsdMaxPrice != 0) {
            cm.setEthUsdPriceBounds(ethUsdMinPrice, ethUsdMaxPrice);
        }
        if (ethUsdFeed != address(0)) {
            cm.setEthUsdFeed(ethUsdFeed, ethUsdHb);
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
        console2.log("Immutable commission recipient:", cm.commissionRecipient());
        console2.log("RouteRegistry deployed at:      ", address(routeRegistry));
        console2.log("Bridge deployed at:             ", address(bridge));
        console2.log("Bridge implementation at:      ", address(bridgeImplementation));
        console2.log("RGBVerifier deployed at:        ", address(rgbVerifier));
        console2.log("  minSourceConfirmations:       ", rgbVerifier.minSourceConfirmations());
        console2.log("  maxLatestConfirmations:       ", rgbVerifier.maxLatestConfirmations());
        console2.log("  minConfirmationGap:           ", rgbVerifier.minConfirmationGap());
        console2.log("RgbSettlementModule deployed at:", address(rgbModule));
        console2.log("NullVerifier deployed at:       ", address(nullVerifier));
        console2.log("RgbOutboundSettlementModule at: ", address(outboundModule));
        console2.log("NullSettlementModule at:        ", address(nullModule));
        console2.log("MultisigProxy deployed at:      ", address(proxy));
        console2.log("Emergency guardian:             ", proxy.emergencyGuardian());
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
        require(bridgeProxy.implementation() == address(bridgeImplementation), "Bridge implementation mismatch");
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
        require(proxy.emergencyGuardian() == emergencyGuardian, "MultisigProxy guardian mismatch");
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
        console2.log("Production RGB settlement modules:");
        console2.log("  42161 -> 827166: RgbSettlementModule");
        console2.log("  827166 -> 42161: RgbSettlementModule");
        console2.log("For every additional fundsOut source chain, federation must also");
        console2.log("install setOutflowLimit(chainId, burstBps, refillBpsPerWindow)");
        console2.log("before enabling traffic for that chain.");
    }

    function _validOutflowPolicy(uint256 burstBps, uint256 refillBpsPerWindow) private pure returns (bool) {
        return burstBps != 0 && refillBpsPerWindow != 0 && burstBps <= MAX_OUTFLOW_POLICY_BPS
            && refillBpsPerWindow <= MAX_OUTFLOW_POLICY_BPS && burstBps + refillBpsPerWindow <= MAX_OUTFLOW_POLICY_BPS;
    }
}
