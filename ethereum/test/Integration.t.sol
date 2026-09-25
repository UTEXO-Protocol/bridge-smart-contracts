// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {Bridge} from "../src/Bridge.sol";
import {BridgeProxy} from "../src/BridgeProxy.sol";
import {CommissionManager} from "../src/CommissionManager.sol";
import {MultisigProxy} from "../src/MultisigProxy.sol";
import {IMultisigProxy} from "../src/interfaces/IMultisigProxy.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {RouteRegistry} from "../src/RouteRegistry.sol";
import {RGBVerifier} from "../src/verifiers/RGBVerifier.sol";
import {RgbSettlementModule} from "../src/settlement/RgbSettlementModule.sol";
import {
    CommissionConfig,
    CommissionSide,
    CommissionCurrency,
    ICommissionManager
} from "../src/interfaces/ICommissionManager.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBtcRelay} from "./mocks/MockBtcRelay.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {BridgeProxyTestUtils} from "./mocks/BridgeProxyTestUtils.sol";
import {BridgeBaseUpgradeable} from "../src/BridgeBaseUpgradeable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MultisigHelper} from "./mocks/MultisigHelper.sol";
import {OutflowRateLimiter} from "../src/libraries/OutflowRateLimiter.sol";

/// @title IntegrationTest
/// @notice End-to-end lifecycle:
///           deploy (DeployAll-style via predicted Bridge address) +
///             RouteRegistry + RGBVerifier + RgbSettlementModule wired in
///           → federation configures commission routes on CM
///           → user fundsIn (TOKEN commission on the source side; the RGB
///             settlement module records `operationId → netAmount`)
///           → TEE signs + multisig executes fundsOut (TOKEN commission on
///             the outbound side; the verifier checks the BtcRelay header,
///             the settlement module validates permanent fundsIn records)
///           → federation withdraws accumulated commissions from CM
///         Verifies token accounting across every step and event emission for
///         the fundsOut → commission → withdrawal trail.
/// @dev EVM integration only: Bitcoin blocks are provided by MockBtcRelay;
///      real source-side RGB mint/burn and transaction inclusion are not tested.
contract IntegrationTest is Test, BridgeProxyTestUtils {
    // =========================================================================
    // Actors
    // =========================================================================

    address deployer = makeAddr("deployer");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address commissionReceiver = makeAddr("commissionReceiver");

    uint256 encPk1 = 0xE1;
    uint256 encPk2 = 0xE2;
    uint256 encPk3 = 0xE3;
    uint256 fedPk1 = 0xF1;
    uint256 fedPk2 = 0xF2;
    uint256 fedPk3 = 0xF3;
    address encA1;
    address encA2;
    address encA3;
    address fedA1;
    address fedA2;
    address fedA3;

    // =========================================================================
    // System
    // =========================================================================

    MockERC20 token;
    MockBtcRelay btcRelay;
    MockAggregatorV3 ethUsdFeed;
    CommissionManager cm;
    RouteRegistry routeRegistry;
    RGBVerifier rgbVerifier;
    RgbSettlementModule rgbModule;
    Bridge bridge;
    MultisigProxy proxy;
    bytes32 domainSep;

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 constant SOURCE_CHAIN_ID = 31337; // foundry default block.chainid
    uint256 constant RGB_CHAIN_ID = 1_000_001; // backend-assigned for RGB

    uint256 constant USER_DEPOSIT = 1 ether; // one 18-decimal mock token gross
    // FUNDS_IN route: 2% token commission (stablePercent = 200, multiplier = 100 → 200/100/100 = 2%).
    uint256 constant FUNDS_IN_PERCENT = 200;
    uint8 constant FUNDS_IN_MULT = 100;
    // FUNDS_OUT route: 1% token commission (stablePercent = 100, multiplier = 100 → 1%).
    uint256 constant FUNDS_OUT_PERCENT = 100;
    uint8 constant FUNDS_OUT_MULT = 100;

    // Non-zero RGB OpId threaded through the RGB-route settlementData on fundsIn.
    uint256 constant RGB_OP_ID = 0xABCDEF;
    bytes32 constant BURN_TYPEHASH = keccak256(
        "UtexoBurnId(address bridge,uint256 chainId,address token,uint256 amount,uint256 sourceChainId,uint256 destinationChainId,bytes32 sourceAddressHash,bytes32 settlementDataHash,bytes32 sourceBurnTxId)"
    );
    bytes32 constant SRC_BURN_TX_ID = keccak256("integration-burn-tx-default");

    // RGB proof = two (height, commit) pairs: a deep source block (RGB
    // burn/lock) and a fresh latest block (relay head). gap = 6 - 1 = 5.
    uint256 constant BLOCK_HEIGHT = 850_000; // source block
    bytes32 constant COMMITMENT_HASH = keccak256("integration-btc-block");
    uint256 constant BTC_CONFIRMATIONS = 6; // source confirmations
    uint256 constant LATEST_HEIGHT = 850_005;
    bytes32 constant LATEST_COMMIT = keccak256("integration-btc-latest");
    uint256 constant LATEST_CONFIRMATIONS = 1;

    uint256 constant TIMELOCK = 1 hours;
    uint256 constant MIN_TIMELOCK = 1 hours; // floor passed to the proxy constructor in tests

    // =========================================================================
    // Re-declared events for vm.expectEmit
    // =========================================================================

    event BridgeFundsOut(
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 indexed burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string sourceAddress,
        bytes settlementData
    );

    event CommissionWithdrawn(address indexed token, uint256 amount, address indexed recipient);

    // =========================================================================
    // Setup
    // =========================================================================

    function _deriveBurnId(
        address recipient_,
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory sourceAddress,
        bytes memory proof,
        bytes memory settlementData
    ) internal view returns (uint256) {
        recipient_; // no longer part of the key
        proof; // no longer part of the key
        return uint256(
            keccak256(
                abi.encode(
                    BURN_TYPEHASH,
                    address(bridge),
                    block.chainid,
                    address(token),
                    amount,
                    sourceChainId,
                    destinationChainId,
                    keccak256(bytes(sourceAddress)),
                    keccak256(settlementData),
                    SRC_BURN_TX_ID
                )
            )
        );
    }

    function setUp() public {
        encA1 = vm.addr(encPk1);
        encA2 = vm.addr(encPk2);
        encA3 = vm.addr(encPk3);
        fedA1 = vm.addr(fedPk1);
        fedA2 = vm.addr(fedPk2);
        fedA3 = vm.addr(fedPk3);

        token = new MockERC20("Mock USDT0", "USDT0");
        btcRelay = new MockBtcRelay();
        // The real relay never stores a header below its initialisation
        // checkpoint; mirror that here so a proof this suite accepts is one
        // the deployed relay would also accept.
        btcRelay.setCheckpointHeight(BLOCK_HEIGHT);
        btcRelay.setBlock(BLOCK_HEIGHT, COMMITMENT_HASH, BTC_CONFIRMATIONS);
        btcRelay.setBlock(LATEST_HEIGHT, LATEST_COMMIT, LATEST_CONFIRMATIONS);

        // DeployAll-style deployment. Deployer tx order:
        //   nonce n      → CommissionManager (uses predicted Bridge)
        //   nonce n+1    → RouteRegistry     (uses predicted Bridge;
        //                                     deployer stays owner so the
        //                                     test can register routes
        //                                     before MultisigProxy exists)
        //   nonce n+2    → Bridge implementation
        //   nonce n+3    → BridgeProxy       (initialized with RouteRegistry, CM)
        //   nonce n+4    → RGBVerifier       (wraps BtcRelay)
        //   nonce n+5    → RgbSettlementModule (paired with RouteRegistry)
        //   nonce n+6    → MultisigProxy
        // Both CM and RouteRegistry need to know Bridge's address up front;
        // they share the same `currentNonce + 3` prediction (the proxy address).
        vm.startPrank(deployer);

        uint64 currentNonce = vm.getNonce(deployer);
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 3);

        cm = new CommissionManager(predictedBridge, commissionReceiver);
        routeRegistry = new RouteRegistry(predictedBridge, deployer);
        bridge = _deployBridge(
            address(token),
            address(routeRegistry),
            payable(address(cm)),
            address(0),
            1, // minFundsInAmount: smallest non-zero floor for tests
            1, // minFundsOutAmount: smallest non-zero floor for tests
            deployer
        );

        rgbVerifier = new RGBVerifier(address(btcRelay), 6, 1, 5);
        rgbModule = new RgbSettlementModule(address(routeRegistry));

        // Register both directions of the RGB route, using the same verifier
        // and settlement module. Inbound (SOURCE → RGB) never calls verify;
        // outbound (RGB → SOURCE) runs the BtcRelay check.
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        address[] memory enc = new address[](3);
        enc[0] = encA1;
        enc[1] = encA2;
        enc[2] = encA3;
        address[] memory fed = new address[](3);
        fed[0] = fedA1;
        fed[1] = fedA2;
        fed[2] = fedA3;

        proxy = new MultisigProxy(
            address(bridge),
            address(cm),
            makeAddr("emergencyGuardian"),
            enc,
            2,
            RGB_CHAIN_ID,
            fed,
            2,
            TIMELOCK,
            MIN_TIMELOCK
        );

        cm.transferOwnership(address(proxy));
        bridge.transferOwnership(address(proxy));
        vm.stopPrank();

        // Ownable2Step: the proxy accepts ownership (prank shortcut; the real
        // governance-accept path is exercised in MultisigProxy.t.sol).
        vm.prank(address(proxy));
        cm.acceptOwnership();
        vm.prank(address(proxy));
        bridge.acceptOwnership();

        // Invariants from deployment.
        assertEq(address(bridge), predictedBridge, "bridge prediction");
        assertEq(cm.bridgeAddress(), address(bridge), "CM.bridgeAddress");
        assertEq(address(bridge.commissionManager()), address(cm), "bridge.commissionManager");
        assertEq(address(bridge.routeRegistry()), address(routeRegistry), "bridge.routeRegistry");
        assertEq(routeRegistry.bridge(), address(bridge), "routeRegistry.bridge");
        assertEq(rgbModule.routeRegistry(), address(routeRegistry), "rgbModule.routeRegistry");
        assertEq(rgbVerifier.btcRelay(), address(btcRelay), "rgbVerifier.btcRelay");
        assertEq(bridge.owner(), address(proxy), "bridge owner");
        assertEq(cm.owner(), address(proxy), "cm owner");
        assertEq(routeRegistry.owner(), deployer, "registry owner (deployer)");
        assertEq(proxy.bridge(), address(bridge), "proxy.bridge");
        assertEq(proxy.commissionManager(), address(cm), "proxy.commissionManager");

        domainSep = proxy.DOMAIN_SEPARATOR();

        // Fund the user
        token.mint(user, USER_DEPOSIT * 10);
        vm.prank(user);
        token.approve(address(bridge), type(uint256).max);
    }

    // =========================================================================
    // Main e2e test — TOKEN commission on both sides
    // =========================================================================

    function test_endToEnd_tokenCommission_inboundAndOutbound() public {
        // -------------------------------------------------------------------------
        // 1. Federation configures commission routes on CommissionManager via two
        //    AdminExecuteCommissionManager proposals.
        // -------------------------------------------------------------------------
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(
                ICommissionManager.setCommissionRule.selector,
                SOURCE_CHAIN_ID,
                RGB_CHAIN_ID,
                address(token),
                CommissionConfig({
                    stablePercent: FUNDS_IN_PERCENT,
                    baseFee: 0,
                    multiplier: FUNDS_IN_MULT,
                    side: CommissionSide.FUNDS_IN,
                    currency: CommissionCurrency.TOKEN,
                    isSet: true
                })
            )
        );

        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(
                ICommissionManager.setCommissionRule.selector,
                RGB_CHAIN_ID,
                SOURCE_CHAIN_ID,
                address(token),
                CommissionConfig({
                    stablePercent: FUNDS_OUT_PERCENT,
                    baseFee: 0,
                    multiplier: FUNDS_OUT_MULT,
                    side: CommissionSide.FUNDS_OUT,
                    currency: CommissionCurrency.TOKEN,
                    isSet: true
                })
            )
        );

        // Sanity: CM now quotes commission for both routes.
        (uint256 tInQuote,, uint256 netIn) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(token), USER_DEPOSIT);
        assertEq(tInQuote, USER_DEPOSIT * FUNDS_IN_PERCENT / FUNDS_IN_MULT / FUNDS_IN_MULT, "quote in");
        assertEq(netIn, USER_DEPOSIT - tInQuote, "net in");

        // -------------------------------------------------------------------------
        // 2. User fundsIn — TOKEN commission routed to CM; the RGB settlement
        //    module records the inbound deposit.
        // -------------------------------------------------------------------------
        uint256 userBefore = token.balanceOf(user);

        // Ten equal deposits make the release below exactly 10% of isolated
        // and global TVL — the configured bucket burst.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, "", abi.encode(RGB_OP_ID));
        for (uint256 i = 1; i < 10; i++) {
            vm.prank(user);
            bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, "", abi.encode(RGB_OP_ID + i));
        }

        uint256 tokenCommissionIn = tInQuote * 10;
        uint256 netBridgedIn = netIn;

        // Balanced maximum-total policy: 10% burst plus 10% refill per window.
        // Ten deposits back a release of one, so the full burst is spendable.
        vm.startPrank(address(proxy));
        bridge.setOutflowLimit(RGB_CHAIN_ID, 1_000, 1_000);
        bridge.setGlobalOutflowLimit(1_000, 1_000);
        vm.stopPrank();

        assertEq(token.balanceOf(user), userBefore - USER_DEPOSIT * 10, "user debited ten gross deposits");
        assertEq(token.balanceOf(address(bridge)), netBridgedIn * 10, "bridge keeps ten net deposits");
        assertEq(token.balanceOf(address(cm)), tokenCommissionIn, "cm got commission");
        assertEq(cm.tokenCommissionPool(address(token)), tokenCommissionIn, "cm pool mirrors balance");
        assertEq(rgbModule.fundsInRecords(opId), netBridgedIn, "record stores net");

        // -------------------------------------------------------------------------
        // 3. TEE-signed fundsOut — RGBVerifier checks the BtcRelay header, the
        //    settlement module verifies the referenced mint exists for the exact
        //    amount (no consumption), Bridge releases `netBridgedIn` from the
        //    pool. 1% outbound commission to CM, the rest to recipient.
        // -------------------------------------------------------------------------
        bytes32[] memory fundsInIds = new bytes32[](1);
        fundsInIds[0] = opId;
        uint256[] memory fundsInAmounts = new uint256[](1);
        fundsInAmounts[0] = netBridgedIn; // must equal the recorded mint amount

        bytes memory proof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
        bytes memory settlementData = abi.encode(fundsInIds, fundsInAmounts);
        string memory sourceAddress = ""; // RGB has no source-address concept
        uint256 burnId =
            _deriveBurnId(recipient, netBridgedIn, RGB_CHAIN_ID, SOURCE_CHAIN_ID, sourceAddress, proof, settlementData);

        IBridge.FundsOutParams memory params = IBridge.FundsOutParams(
            recipient,
            netBridgedIn, // amount = full bridged pool from this deposit
            burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            sourceAddress,
            proof,
            settlementData,
            SRC_BURN_TX_ID
        );

        uint256 outNonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 outDeadline = block.timestamp + 1 hours;
        bytes32 outDigest = MultisigHelper.digestTeeFundsOut(domainSep, params, outNonce, outDeadline);
        bytes[] memory teeSigs = _signEnclave2of3(outDigest); // signers 0 and 1

        uint256 tokenCommissionOut = netBridgedIn * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT;
        uint256 netOut = netBridgedIn - tokenCommissionOut;

        vm.expectEmit(true, true, false, true, address(bridge));
        emit BridgeFundsOut(
            recipient,
            netBridgedIn,
            netOut,
            tokenCommissionOut,
            burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            sourceAddress,
            settlementData
        );

        proxy.fundsOutCall(params, outNonce, outDeadline, 3, teeSigs);

        assertEq(token.balanceOf(address(bridge)), netBridgedIn * 9, "one tenth released; safety reserve remains");
        assertEq(token.balanceOf(recipient), netOut, "recipient got net");
        assertEq(token.balanceOf(address(cm)), tokenCommissionIn + tokenCommissionOut, "cm accrued both fees");
        assertEq(cm.tokenCommissionPool(address(token)), tokenCommissionIn + tokenCommissionOut, "cm pool mirrors");
        assertEq(rgbModule.fundsInRecords(opId), netBridgedIn, "fundsIn record unchanged (permanent)");
        assertTrue(bridge.consumedBurnIds(burnId), "burnId recorded");

        // -------------------------------------------------------------------------
        // 4. Federation withdraws ERC-20 commission from CM to commissionReceiver.
        // -------------------------------------------------------------------------
        uint256 totalCommission = tokenCommissionIn + tokenCommissionOut;

        uint256 wdNonce = proxy.proposalNonce();
        uint256 wdDeadline = block.timestamp + 7 days;
        bytes32 wdDigest = MultisigHelper.digestProposeWithdrawTokenCommissionCM(
            domainSep, address(token), totalCommission, wdNonce, wdDeadline
        );
        bytes[] memory fedSigs = _signFed2of3(wdDigest);

        bytes32 proposalId =
            proxy.proposeWithdrawTokenCommissionCM(address(token), totalCommission, wdNonce, wdDeadline, 3, fedSigs);

        // Move past the timelock.
        vm.warp(block.timestamp + TIMELOCK + 1);

        bytes memory opData = abi.encode(address(token), totalCommission);

        vm.expectEmit(true, false, true, true, address(proxy));
        emit CommissionWithdrawn(address(token), totalCommission, commissionReceiver);

        proxy.executeProposal(proposalId, opData);

        // -------------------------------------------------------------------------
        // 5. Final invariants: the nine-deposit safety reserve remains in the
        //    bridge, CM is empty, and all commissions reached their receiver.
        // -------------------------------------------------------------------------
        assertEq(token.balanceOf(address(bridge)), netBridgedIn * 9, "nine-deposit safety reserve remains");
        assertEq(token.balanceOf(address(cm)), 0, "cm drained");
        assertEq(cm.tokenCommissionPool(address(token)), 0, "cm pool drained");
        assertEq(token.balanceOf(recipient), netOut, "recipient unchanged");
        assertEq(token.balanceOf(commissionReceiver), totalCommission, "commissionReceiver paid");
        // Token conservation: ten gross deposits remain fully accounted for.
        assertEq(
            token.balanceOf(address(bridge)) + token.balanceOf(recipient) + token.balanceOf(commissionReceiver),
            USER_DEPOSIT * 10,
            "token conservation"
        );
    }

    // =========================================================================
    // Secondary e2e — NATIVE commission on fundsIn, native withdrawal via proxy
    // =========================================================================

    function test_endToEnd_nativeCommission_inboundAndWithdraw() public {
        // Configure a NATIVE FUNDS_IN route (2% on token amount, paid in wei).
        // Wire the complete mandatory oracle config through federation
        // governance — dependencies first, ETH/USD feed last.
        MockAggregatorV3 sequencerFeed = new MockAggregatorV3(0, 0, block.timestamp);
        ethUsdFeed = new MockAggregatorV3(8, 2_000e8, block.timestamp);
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(ICommissionManager.setSequencerUptimeFeed.selector, address(sequencerFeed))
        );
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(ICommissionManager.setEthUsdPriceBounds.selector, uint256(100e8), uint256(100_000e8))
        );
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(ICommissionManager.setEthUsdFeed.selector, address(ethUsdFeed), uint256(1 days))
        );
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(
                ICommissionManager.setCommissionRule.selector,
                SOURCE_CHAIN_ID,
                RGB_CHAIN_ID,
                address(token),
                CommissionConfig({
                    stablePercent: FUNDS_IN_PERCENT,
                    baseFee: 0,
                    multiplier: FUNDS_IN_MULT,
                    side: CommissionSide.FUNDS_IN,
                    currency: CommissionCurrency.NATIVE,
                    isSet: true
                })
            )
        );

        (, uint256 nativeQuote, uint256 netQuote) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(token), USER_DEPOSIT);
        assertEq(netQuote, USER_DEPOSIT, "NATIVE: full amount bridges");
        // 2% of USER_DEPOSIT in token units, converted to wei via the feed.
        uint256 stableFee = USER_DEPOSIT * FUNDS_IN_PERCENT / FUNDS_IN_MULT / FUNDS_IN_MULT;
        assertEq(nativeQuote, cm.convertTokenFeeToNative(stableFee, 18), "native quote matches feed");

        vm.deal(user, nativeQuote);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn{value: nativeQuote}(USER_DEPOSIT, RGB_CHAIN_ID, "", abi.encode(RGB_OP_ID));

        assertEq(token.balanceOf(address(bridge)), USER_DEPOSIT, "bridge got full token amount");
        assertEq(token.balanceOf(address(cm)), 0, "cm no token commission");
        assertEq(address(cm).balance, nativeQuote, "cm got native commission");
        assertEq(cm.nativeCommissionPool(), nativeQuote, "cm native pool");
        assertEq(rgbModule.fundsInRecords(opId), USER_DEPOSIT, "record stores full amount");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), USER_DEPOSIT, "native deposit credits full chain liquidity");
        assertEq(bridge.totalLockedLiquidity(), USER_DEPOSIT, "native deposit credits full total liquidity");
        assertEq(address(bridge).balance, 0, "bridge retains no native commission");

        // Federation withdraws native commission.
        uint256 wdNonce = proxy.proposalNonce();
        uint256 wdDeadline = block.timestamp + 7 days;
        bytes32 wdDigest =
            MultisigHelper.digestProposeWithdrawNativeCommissionCM(domainSep, nativeQuote, wdNonce, wdDeadline);
        bytes[] memory fedSigs = _signFed2of3(wdDigest);

        bytes32 proposalId = proxy.proposeWithdrawNativeCommissionCM(nativeQuote, wdNonce, wdDeadline, 3, fedSigs);

        vm.warp(block.timestamp + TIMELOCK + 1);

        uint256 receiverBefore = commissionReceiver.balance;
        proxy.executeProposal(proposalId, abi.encode(nativeQuote));

        assertEq(address(cm).balance, 0, "cm native drained");
        assertEq(cm.nativeCommissionPool(), 0, "cm pool drained");
        assertEq(commissionReceiver.balance - receiverBefore, nativeQuote, "receiver paid in native");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Proposes `callData` as an AdminExecuteCommissionManager op, waits
    ///      out the timelock, and executes. Used by tests to configure the CM.
    function _proposeAndExecuteCmAdminCall(bytes memory callData) internal {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 7 days;

        bytes4 selector;
        assembly { selector := mload(add(callData, 32)) }

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteCM(domainSep, selector, callData, nonce, deadline);
        bytes[] memory sigs = _signFed2of3(digest);

        bytes32 proposalId = proxy.proposeAdminExecuteCommissionManager(callData, nonce, deadline, 3, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(proposalId, callData);
    }

    function _proposeAndExecuteBridgeAdminCall(bytes memory callData) internal {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 7 days;
        bytes4 selector;
        assembly { selector := mload(add(callData, 32)) }
        bytes32 digest = MultisigHelper.digestProposeAdminExecute(domainSep, selector, callData, nonce, deadline);
        bytes32 proposalId = proxy.proposeAdminExecute(callData, nonce, deadline, 3, _signFed2of3(digest));
        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(proposalId, callData);
    }

    function _signEnclave2of3(bytes32 digest) internal view returns (bytes[] memory sigs) {
        uint256[] memory pks = new uint256[](2);
        pks[0] = encPk1;
        pks[1] = encPk2;
        sigs = MultisigHelper.signAll(vm, digest, pks);
    }

    function _signFed2of3(bytes32 digest) internal view returns (bytes[] memory sigs) {
        uint256[] memory pks = new uint256[](2);
        pks[0] = fedPk1;
        pks[1] = fedPk2;
        sigs = MultisigHelper.signAll(vm, digest, pks);
    }

    // =========================================================================
    // Shared helpers for the FundsIn (mint) / FundsOut (burn) e2e groups
    // =========================================================================

    string constant RGB_INVOICE = "";

    struct ReleaseState {
        uint256 teeNonce;
        uint256 recipientBalance;
        uint256 bridgeBalance;
        uint256 cmBalance;
        uint256 tokenPool;
        uint256 nativePool;
        uint256 bridgeNativeBalance;
        uint256 cmNativeBalance;
        uint256 chainLiquidity;
        uint256 totalLiquidity;
        uint256 chainSafetyAllowance;
        uint256 globalSafetyAllowance;
        bytes32 chainBucketState;
        bytes32 globalBucketState;
        bool burnConsumed;
    }

    function _configTokenCommissionRoutes() internal {
        _configTokenCommissionRoutes(0, 0);
    }

    function _configTokenCommissionRoutes(uint256 inBaseFee, uint256 outBaseFee) internal {
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(
                ICommissionManager.setCommissionRule.selector,
                SOURCE_CHAIN_ID,
                RGB_CHAIN_ID,
                address(token),
                CommissionConfig({
                    stablePercent: FUNDS_IN_PERCENT,
                    baseFee: inBaseFee,
                    multiplier: FUNDS_IN_MULT,
                    side: CommissionSide.FUNDS_IN,
                    currency: CommissionCurrency.TOKEN,
                    isSet: true
                })
            )
        );
        _proposeAndExecuteCmAdminCall(
            abi.encodeWithSelector(
                ICommissionManager.setCommissionRule.selector,
                RGB_CHAIN_ID,
                SOURCE_CHAIN_ID,
                address(token),
                CommissionConfig({
                    stablePercent: FUNDS_OUT_PERCENT,
                    baseFee: outBaseFee,
                    multiplier: FUNDS_OUT_MULT,
                    side: CommissionSide.FUNDS_OUT,
                    currency: CommissionCurrency.TOKEN,
                    isSet: true
                })
            )
        );
    }

    function _openOutflowLimits() internal {
        vm.startPrank(address(proxy));
        bridge.setOutflowLimit(RGB_CHAIN_ID, 1_000, 1_000);
        bridge.setGlobalOutflowLimit(1_000, 1_000);
        vm.stopPrank();
    }

    function _netIn() internal pure returns (uint256) {
        uint256 fee = USER_DEPOSIT * FUNDS_IN_PERCENT / FUNDS_IN_MULT / FUNDS_IN_MULT;
        return USER_DEPOSIT - fee;
    }

    function _depositN(uint256 n, uint256 rgbOpBase) internal returns (bytes32 firstOpId) {
        vm.prank(user);
        firstOpId = bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(rgbOpBase));
        for (uint256 i = 1; i < n; i++) {
            vm.prank(user);
            bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(rgbOpBase + i));
        }
    }

    function _validProof() internal pure returns (bytes memory) {
        return abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
    }

    function _buildFundsOut(
        bytes32 sdOpId,
        uint256 sdAmount,
        uint256 releaseAmount,
        string memory srcAddr,
        bytes memory proof
    ) internal view returns (IBridge.FundsOutParams memory params, uint256 burnId) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = sdOpId;
        uint256[] memory amts = new uint256[](1);
        amts[0] = sdAmount;
        bytes memory settlementData = abi.encode(ids, amts);
        burnId = _deriveBurnId(recipient, releaseAmount, RGB_CHAIN_ID, SOURCE_CHAIN_ID, srcAddr, proof, settlementData);
        params = IBridge.FundsOutParams(
            recipient,
            releaseAmount,
            burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            srcAddr,
            proof,
            settlementData,
            SRC_BURN_TX_ID
        );
    }

    function _signEnclave1(bytes32 digest) internal view returns (bytes[] memory sigs) {
        uint256[] memory pks = new uint256[](1);
        pks[0] = encPk1;
        sigs = MultisigHelper.signAll(vm, digest, pks);
    }

    /// @dev Signs and submits a fundsOut; reverts bubble up to the caller's expectRevert.
    function _submitFundsOut(IBridge.FundsOutParams memory params, uint256 bitmap, bytes[] memory sigs) internal {
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        // `sigs`/`bitmap` are recomputed here from `digest` unless caller passed a custom set.
        if (sigs.length == 0) {
            sigs = _signEnclave2of3(digest);
            bitmap = 3;
        }
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    function _bucketStateHash(bool global) internal view returns (bytes32) {
        OutflowRateLimiter.Bucket memory bucket;
        if (global) {
            (bucket.tokens, bucket.lastUpdated, bucket.isEnabled, bucket.capacity, bucket.rate) = bridge.globalBucket();
        } else {
            (bucket.tokens, bucket.lastUpdated, bucket.isEnabled, bucket.capacity, bucket.rate) =
                bridge.chainBuckets(RGB_CHAIN_ID);
        }
        return keccak256(abi.encode(bucket));
    }

    function _releaseState(uint256 burnId) internal view returns (ReleaseState memory state) {
        state.teeNonce = proxy.teeNonce(RGB_CHAIN_ID);
        state.recipientBalance = token.balanceOf(recipient);
        state.bridgeBalance = token.balanceOf(address(bridge));
        state.cmBalance = token.balanceOf(address(cm));
        state.tokenPool = cm.tokenCommissionPool(address(token));
        state.nativePool = cm.nativeCommissionPool();
        state.bridgeNativeBalance = address(bridge).balance;
        state.cmNativeBalance = address(cm).balance;
        state.chainLiquidity = bridge.lockedLiquidity(RGB_CHAIN_ID);
        state.totalLiquidity = bridge.totalLockedLiquidity();
        state.chainSafetyAllowance = bridge.availableChainSafetyOutflow(RGB_CHAIN_ID);
        state.globalSafetyAllowance = bridge.availableGlobalSafetyOutflow();
        state.chainBucketState = _bucketStateHash(false);
        state.globalBucketState = _bucketStateHash(true);
        state.burnConsumed = bridge.consumedBurnIds(burnId);
    }

    /// @dev Compare at the same timestamp: rejected releases must restore both
    ///      nonce/replay state and every observed custody, fee and limiter value.
    function _assertReleaseUnchanged(uint256 burnId, ReleaseState memory beforeState) internal view {
        ReleaseState memory afterState = _releaseState(burnId);
        assertEq(afterState.teeNonce, beforeState.teeNonce, "TEE nonce unchanged");
        assertEq(afterState.recipientBalance, beforeState.recipientBalance, "recipient balance unchanged");
        assertEq(afterState.bridgeBalance, beforeState.bridgeBalance, "bridge balance unchanged");
        assertEq(afterState.cmBalance, beforeState.cmBalance, "CM balance unchanged");
        assertEq(afterState.tokenPool, beforeState.tokenPool, "token commission pool unchanged");
        assertEq(afterState.nativePool, beforeState.nativePool, "native commission pool unchanged");
        assertEq(afterState.bridgeNativeBalance, beforeState.bridgeNativeBalance, "bridge native balance unchanged");
        assertEq(afterState.cmNativeBalance, beforeState.cmNativeBalance, "CM native balance unchanged");
        assertEq(afterState.chainLiquidity, beforeState.chainLiquidity, "source liquidity unchanged");
        assertEq(afterState.totalLiquidity, beforeState.totalLiquidity, "total liquidity unchanged");
        assertEq(afterState.chainSafetyAllowance, beforeState.chainSafetyAllowance, "chain safety allowance unchanged");
        assertEq(
            afterState.globalSafetyAllowance, beforeState.globalSafetyAllowance, "global safety allowance unchanged"
        );
        assertEq(afterState.chainBucketState, beforeState.chainBucketState, "chain bucket unchanged");
        assertEq(afterState.globalBucketState, beforeState.globalBucketState, "global bucket unchanged");
        assertEq(afterState.burnConsumed, beforeState.burnConsumed, "burn consumption unchanged");
    }

    function _assertSuccessfulRelease(
        IBridge.FundsOutParams memory params,
        ReleaseState memory beforeState,
        uint256 outFee
    ) internal view {
        assertFalse(beforeState.burnConsumed, "release starts unconsumed");
        assertTrue(bridge.consumedBurnIds(params.burnId), "release consumed");
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), beforeState.teeNonce + 1, "one TEE nonce consumed");
        assertEq(
            token.balanceOf(recipient), beforeState.recipientBalance + params.amount - outFee, "recipient paid net"
        );
        assertEq(token.balanceOf(address(bridge)), beforeState.bridgeBalance - params.amount, "bridge debited gross");
        assertEq(
            bridge.lockedLiquidity(RGB_CHAIN_ID), beforeState.chainLiquidity - params.amount, "chain debited gross"
        );
        assertEq(bridge.totalLockedLiquidity(), beforeState.totalLiquidity - params.amount, "total debited gross");
        assertEq(token.balanceOf(address(cm)), beforeState.cmBalance + outFee, "CM received outbound fee");
        assertEq(cm.tokenCommissionPool(address(token)), beforeState.tokenPool + outFee, "CM recorded outbound fee");
        assertEq(cm.tokenCommissionPool(address(token)), token.balanceOf(address(cm)), "CM pool mirrors custody");
        assertEq(cm.nativeCommissionPool(), beforeState.nativePool, "no native fee on release");
        assertEq(address(cm).balance, beforeState.cmNativeBalance, "CM native custody unchanged");
        assertEq(address(bridge).balance, beforeState.bridgeNativeBalance, "bridge native custody unchanged");
        assertEq(
            bridge.availableChainSafetyOutflow(RGB_CHAIN_ID),
            beforeState.chainSafetyAllowance - params.amount,
            "chain safety charged gross"
        );
        assertEq(
            bridge.availableGlobalSafetyOutflow(),
            beforeState.globalSafetyAllowance - params.amount,
            "global safety charged gross"
        );
    }

    // =========================================================================
    // FundsIn (mint) - deposit leg: source-chain lock -> RGB mint
    // =========================================================================

    /// @notice A deposit records its mint (operationId -> net) and credits the
    ///         destination chain's bridged liquidity; commission routed to CM.
    function test_fundsIn_mint_recordsDepositAndCreditsLiquidity() public {
        _configTokenCommissionRoutes();
        uint256 netIn = _netIn();
        uint256 fee = USER_DEPOSIT - netIn;

        uint256 userBefore = token.balanceOf(user);
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(RGB_OP_ID));

        assertEq(token.balanceOf(user), userBefore - USER_DEPOSIT, "user debited gross");
        assertEq(token.balanceOf(address(bridge)), netIn, "bridge keeps net");
        assertEq(token.balanceOf(address(cm)), fee, "commission to CM");
        assertEq(cm.tokenCommissionPool(address(token)), fee, "CM recorded inbound fee");
        assertEq(rgbModule.fundsInRecords(opId), netIn, "mint record stores net");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), netIn, "destination liquidity credited");
        assertEq(bridge.totalLockedLiquidity(), netIn, "total liquidity credited");
        assertEq(
            bridge.sourceSenderNonces(SOURCE_CHAIN_ID, bytes32(uint256(uint160(user)))), 1, "deposit nonce consumed"
        );
        // Conservation: gross deposit is split between bridge pool and CM, nothing lost.
        assertEq(token.balanceOf(address(bridge)) + token.balanceOf(address(cm)), USER_DEPOSIT, "deposit conserved");
    }

    /// @notice Two identical deposits produce distinct operationIds (per-sender
    ///         nonce), so neither collides in the mint ledger.
    function test_fundsIn_mint_distinctDepositsGetDistinctOperationIds() public {
        _configTokenCommissionRoutes();
        vm.prank(user);
        bytes32 op1 = bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(RGB_OP_ID));
        vm.prank(user);
        bytes32 op2 = bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(RGB_OP_ID));

        assertTrue(op1 != op2, "operationIds distinct");
        assertEq(rgbModule.fundsInRecords(op1), _netIn(), "first recorded");
        assertEq(rgbModule.fundsInRecords(op2), _netIn(), "second recorded");
        assertEq(bridge.totalLockedLiquidity(), _netIn() * 2, "both deposits accounted");
        assertEq(cm.tokenCommissionPool(address(token)), (USER_DEPOSIT - _netIn()) * 2, "both inbound fees recorded");
        assertEq(
            bridge.sourceSenderNonces(SOURCE_CHAIN_ID, bytes32(uint256(uint160(user)))),
            2,
            "two deposit nonces consumed"
        );
    }

    /// @notice A mint route must carry a non-zero RGB OpId in settlementData.
    function test_fundsIn_mint_zeroRgbOpIdReverts() public {
        _configTokenCommissionRoutes();
        ReleaseState memory beforeState = _releaseState(0);
        uint256 userBefore = token.balanceOf(user);
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        uint256 nonceBefore = bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender);
        vm.prank(user);
        vm.expectRevert(RgbSettlementModule.InvalidRgbOpId.selector);
        bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(uint256(0)));
        _assertReleaseUnchanged(0, beforeState);
        assertEq(token.balanceOf(user), userBefore, "failed deposit does not debit user");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), nonceBefore, "failed deposit restores nonce");
    }

    /// @notice Pausing inflow stops deposits while withdrawals still flow
    ///         (independent pause flags).
    function test_fundsIn_mint_inflowPauseStopsDepositsReleasesStillFlow() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        vm.prank(address(proxy));
        bridge.pauseInflow();

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(RGB_OP_ID + 100));

        // Outflow is a separate flag - a withdraw still succeeds.
        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());
        ReleaseState memory beforeState = _releaseState(burnId);
        _submitFundsOut(params, 0, new bytes[](0));
        uint256 outFee = netIn * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT;
        _assertSuccessfulRelease(params, beforeState, outFee);
        assertTrue(bridge.paused(), "release leaves inflow paused");
    }

    // =========================================================================
    // FundsOut (burn) - release leg: RGB burn -> destination-chain unlock
    // =========================================================================

    /// @notice A withdraw releases against a recorded deposit: event emitted,
    ///         recipient paid, source liquidity debited, burnId consumed, record
    ///         permanent, and total tokens are conserved across all holders.
    function test_fundsOut_burn_releasesAgainstRecordedDeposit() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();
        uint256 inFee = USER_DEPOSIT - netIn;
        uint256 outFee = netIn * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT;
        uint256 netOut = netIn - outFee;

        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());

        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BridgeFundsOut(
            recipient, netIn, netOut, outFee, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, "", params.settlementData
        );
        _submitFundsOut(params, 0, new bytes[](0));

        _assertSuccessfulRelease(params, beforeState, outFee);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "full chain burst consumed");
        assertEq(bridge.availableGlobalOutflow(), 0, "full global burst consumed");
        assertEq(token.balanceOf(recipient), netOut, "recipient got net");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), netIn * 9, "source liquidity debited by one");
        assertTrue(bridge.consumedBurnIds(burnId), "burnId consumed");
        assertEq(rgbModule.fundsInRecords(opId), netIn, "mint record permanent");
        // Conservation: ten gross deposits are fully accounted for.
        assertEq(
            token.balanceOf(address(bridge)) + token.balanceOf(recipient) + token.balanceOf(address(cm)),
            USER_DEPOSIT * 10,
            "tokens conserved"
        );
        assertEq(token.balanceOf(address(cm)), inFee * 10 + outFee, "cm accrued both legs");
    }

    /// @notice The identical release intent cannot pay out twice: re-authorizing an already
    ///         consumed burnId reverts and leaves no additional trace.
    function test_fundsOut_burn_sameBurnCannotReplay() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());
        _submitFundsOut(params, 0, new bytes[](0));

        ReleaseState memory afterFirst = _releaseState(burnId);
        assertTrue(afterFirst.burnConsumed, "first release consumed intent");

        // Re-sign identical params with the advanced teeNonce; Bridge derives the
        // same burnId and rejects it as already consumed.
        uint256 nonce2 = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline2 = block.timestamp + 1 hours;
        bytes32 digest2 = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce2, deadline2);
        bytes[] memory sigs2 = _signEnclave2of3(digest2);
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, burnId));
        proxy.fundsOutCall(params, nonce2, deadline2, 3, sigs2);

        _assertReleaseUnchanged(burnId, afterFirst);
    }

    /// @notice A withdraw below the enclave signature threshold is rejected with no trace.
    function test_fundsOut_burn_belowQuorumRejected() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        ReleaseState memory beforeState = _releaseState(burnId);

        vm.expectRevert(IMultisigProxy.BelowThreshold.selector);
        proxy.fundsOutCall(params, nonce, deadline, 1, _signEnclave1(digest)); // 1-of-3 < threshold 2

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice A withdraw larger than the bridge's token pool is rejected with no trace.
    function test_fundsOut_burn_exceedsBridgePoolRejected() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();
        uint256 poolPlusOne = token.balanceOf(address(bridge)) + 1;

        (IBridge.FundsOutParams memory params, uint256 burnId) =
            _buildFundsOut(opId, netIn, poolPlusOne, "", _validProof());

        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        bytes[] memory sigs = _signEnclave2of3(digest);
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectRevert(BridgeBaseUpgradeable.AmountExceedBridgePool.selector);
        proxy.fundsOutCall(params, nonce, deadline, 3, sigs);

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice A withdraw without a valid BtcRelay proof (source block too shallow)
    ///         is rejected with no trace.
    function test_fundsOut_burn_invalidBtcProofRejected() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        // Use the fresh (1-confirmation) block as the source: below the 6 required.
        bytes memory shallowProof = abi.encode(LATEST_HEIGHT, LATEST_COMMIT, LATEST_HEIGHT, LATEST_COMMIT);
        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", shallowProof);

        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        bytes[] memory sigs = _signEnclave2of3(digest);
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectRevert(
            abi.encodeWithSelector(RGBVerifier.InsufficientSourceConfirmations.selector, uint256(1), uint256(6))
        );
        proxy.fundsOutCall(params, nonce, deadline, 3, sigs);

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice A withdraw referencing a deposit that never happened is rejected with no trace.
    function test_fundsOut_burn_unknownDepositRejected() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        bytes32 fakeOpId = keccak256("nonexistent-deposit");
        (IBridge.FundsOutParams memory params, uint256 burnId) =
            _buildFundsOut(fakeOpId, netIn, netIn, "", _validProof());

        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        bytes[] memory sigs = _signEnclave2of3(digest);
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectRevert(abi.encodeWithSelector(RgbSettlementModule.FundsInNotFound.selector, fakeOpId));
        proxy.fundsOutCall(params, nonce, deadline, 3, sigs);

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice A withdraw whose proof-of-mint amount differs from the recorded
    ///         deposit is rejected with no trace.
    function test_fundsOut_burn_amountMismatchRejected() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        (IBridge.FundsOutParams memory params, uint256 burnId) =
            _buildFundsOut(opId, netIn + 1, netIn, "", _validProof());

        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        bytes[] memory sigs = _signEnclave2of3(digest);
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectRevert(abi.encodeWithSelector(RgbSettlementModule.AmountMismatch.selector, opId, netIn + 1, netIn));
        proxy.fundsOutCall(params, nonce, deadline, 3, sigs);

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice Emergency pause freezes withdrawals; no trace on the rejected release.
    function test_fundsOut_burn_emergencyPauseStopsWithdrawals() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();

        vm.prank(address(proxy));
        bridge.emergencyPauseAll();

        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());

        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        bytes[] memory sigs = _signEnclave2of3(digest);
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectRevert(BridgeBaseUpgradeable.OutflowEnforcedPause.selector);
        proxy.fundsOutCall(params, nonce, deadline, 3, sigs);

        _assertReleaseUnchanged(burnId, beforeState);
    }

    /// @notice The real guardian lane pauses both paths and allows the exact
    ///         same signed release to succeed after unpause, without re-signing.
    function test_guardian_pauseUnpauseRetriesSameSignedRelease() public {
        _configTokenCommissionRoutes();
        _openOutflowLimits();
        bytes32 opId = _depositN(10, RGB_OP_ID);
        uint256 netIn = _netIn();
        uint256 outFee = netIn * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT;
        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _signEnclave2of3(MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline));
        ReleaseState memory beforeState = _releaseState(burnId);
        uint256 emergencyNonceBefore = proxy.emergencyNonce();
        uint256 proposalNonceBefore = proxy.proposalNonce();

        vm.prank(proxy.emergencyGuardian());
        proxy.guardianEmergencyPause();
        assertTrue(bridge.paused(), "guardian paused inflow");
        assertTrue(bridge.outflowPaused(), "guardian paused outflow");
        _assertReleaseUnchanged(burnId, beforeState);

        vm.expectRevert(BridgeBaseUpgradeable.OutflowEnforcedPause.selector);
        proxy.fundsOutCall(params, nonce, deadline, 3, sigs);
        _assertReleaseUnchanged(burnId, beforeState);

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(RGB_OP_ID + 100));
        _assertReleaseUnchanged(burnId, beforeState);

        vm.prank(proxy.emergencyGuardian());
        proxy.guardianEmergencyUnpause();
        assertFalse(bridge.paused(), "guardian resumed inflow");
        assertFalse(bridge.outflowPaused(), "guardian resumed outflow");
        assertEq(proxy.emergencyNonce(), emergencyNonceBefore, "guardian does not consume federation emergency nonce");
        assertEq(proxy.proposalNonce(), proposalNonceBefore, "guardian does not consume proposal nonce");

        proxy.fundsOutCall(params, nonce, deadline, 3, sigs);
        _assertSuccessfulRelease(params, beforeState, outFee);
        assertEq(rgbModule.fundsInRecords(opId), netIn, "mint record remains permanent");
    }

    function test_guardian_unauthorizedCallsCannotChangePauseState() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnauthorizedEmergencyGuardian.selector, user));
        proxy.guardianEmergencyPause();
        assertFalse(bridge.paused(), "unauthorized caller cannot pause inflow");
        assertFalse(bridge.outflowPaused(), "unauthorized caller cannot pause outflow");

        vm.prank(proxy.emergencyGuardian());
        proxy.guardianEmergencyPause();
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnauthorizedEmergencyGuardian.selector, user));
        proxy.guardianEmergencyUnpause();
        assertTrue(bridge.paused(), "unauthorized caller cannot resume inflow");
        assertTrue(bridge.outflowPaused(), "unauthorized caller cannot resume outflow");
    }

    /// @notice Percentage plus flat fees are accounted on both legs and paid
    ///         to the pinned recipient through a real timelocked withdrawal.
    function test_endToEnd_tokenCommissionWithBaseFees() public {
        uint256 inBaseFee = 0.01 ether;
        uint256 outBaseFee = 0.005 ether;
        // The flat fee must leave positive net at each side's amount floor.
        _proposeAndExecuteBridgeAdminCall(abi.encodeCall(IBridge.setMinFundsInAmount, (0.1 ether)));
        _proposeAndExecuteBridgeAdminCall(abi.encodeCall(IBridge.setMinFundsOutAmount, (0.1 ether)));
        _configTokenCommissionRoutes(inBaseFee, outBaseFee);
        _openOutflowLimits();

        uint256 inFee = USER_DEPOSIT * FUNDS_IN_PERCENT / FUNDS_IN_MULT / FUNDS_IN_MULT + inBaseFee;
        uint256 netIn = USER_DEPOSIT - inFee;
        bytes32 opId = _depositN(10, RGB_OP_ID);
        assertEq(token.balanceOf(user), 0, "user paid ten gross deposits");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), netIn * 10, "chain credited net after both fee components");
        assertEq(bridge.totalLockedLiquidity(), netIn * 10, "total credited net after both fee components");
        assertEq(token.balanceOf(address(bridge)), netIn * 10, "bridge custody equals net deposits");
        assertEq(cm.tokenCommissionPool(address(token)), inFee * 10, "CM recorded percentage plus inbound base fee");
        assertEq(token.balanceOf(address(cm)), inFee * 10, "CM received percentage plus inbound base fee");
        assertEq(rgbModule.fundsInRecords(opId), netIn, "mint record excludes full inbound fee");

        uint256 outFee = netIn * FUNDS_OUT_PERCENT / FUNDS_OUT_MULT / FUNDS_OUT_MULT + outBaseFee;
        (IBridge.FundsOutParams memory params, uint256 burnId) = _buildFundsOut(opId, netIn, netIn, "", _validProof());
        ReleaseState memory beforeState = _releaseState(burnId);
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BridgeFundsOut(
            recipient, netIn, netIn - outFee, outFee, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, "", params.settlementData
        );
        _submitFundsOut(params, 0, new bytes[](0));
        _assertSuccessfulRelease(params, beforeState, outFee);
        assertEq(rgbModule.fundsInRecords(opId), netIn, "release preserves mint record");

        uint256 totalCommission = inFee * 10 + outFee;
        uint256 wdNonce = proxy.proposalNonce();
        uint256 wdDeadline = block.timestamp + 7 days;
        bytes32 wdDigest = MultisigHelper.digestProposeWithdrawTokenCommissionCM(
            domainSep, address(token), totalCommission, wdNonce, wdDeadline
        );
        bytes32 proposalId = proxy.proposeWithdrawTokenCommissionCM(
            address(token), totalCommission, wdNonce, wdDeadline, 3, _signFed2of3(wdDigest)
        );
        uint256 receiverBefore = token.balanceOf(commissionReceiver);
        vm.expectRevert(IMultisigProxy.TimelockActive.selector);
        proxy.executeProposal(proposalId, abi.encode(address(token), totalCommission));
        assertEq(cm.tokenCommissionPool(address(token)), totalCommission, "timelock rejection preserves pool");
        assertEq(token.balanceOf(address(cm)), totalCommission, "timelock rejection preserves custody");
        assertEq(token.balanceOf(commissionReceiver), receiverBefore, "timelock rejection pays nothing");
        assertEq(uint256(proxy.getProposal(proposalId).status), uint256(IMultisigProxy.ProposalStatus.Pending));

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(proposalId, abi.encode(address(token), totalCommission));
        assertEq(cm.tokenCommissionPool(address(token)), 0, "commission pool emptied");
        assertEq(token.balanceOf(address(cm)), 0, "CM custody emptied");
        assertEq(
            token.balanceOf(commissionReceiver), receiverBefore + totalCommission, "pinned recipient received fees"
        );
        assertEq(bridge.totalLockedLiquidity(), netIn * 9, "commission withdrawal preserves remaining liquidity");
        assertEq(
            token.balanceOf(address(bridge)) + token.balanceOf(recipient) + token.balanceOf(commissionReceiver),
            USER_DEPOSIT * 10,
            "percentage and flat fee lifecycle conserves tokens"
        );
    }
}
