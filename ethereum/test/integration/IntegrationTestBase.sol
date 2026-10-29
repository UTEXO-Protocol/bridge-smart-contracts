// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Bridge} from "../../src/Bridge.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {RouteRegistry} from "../../src/RouteRegistry.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {IArbSys} from "../../src/interfaces/IArbSys.sol";
import {
    CommissionConfig,
    CommissionCurrency,
    CommissionSide,
    ICommissionManager
} from "../../src/interfaces/ICommissionManager.sol";
import {OutflowRateLimiter} from "../../src/libraries/OutflowRateLimiter.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {RGBVerifier} from "../../src/verifiers/RGBVerifier.sol";
import {BridgeProxyTestUtils} from "../helpers/BridgeProxyTestUtils.sol";
import {BurnIdHelper} from "../helpers/BurnIdHelper.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MockBtcRelay} from "../mocks/MockBtcRelay.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared fixture and helpers for integration tests; contains no test cases.
/// @dev Exercises EVM contract interactions with mocked Bitcoin finality.
abstract contract IntegrationTestBase is Test, BridgeProxyTestUtils {
    struct FundsOutAuthorization {
        uint256 nonce;
        uint256 deadline;
        bytes[] signatures;
    }

    address internal deployer = makeAddr("deployer");

    address internal user = makeAddr("user");

    address internal recipient = makeAddr("recipient");

    address internal commissionReceiver = makeAddr("commissionReceiver");

    uint256 internal constant ENC_PK_1 = 0xE1;

    uint256 internal constant ENC_PK_2 = 0xE2;

    uint256 internal constant ENC_PK_3 = 0xE3;

    uint256 internal constant FED_PK_1 = 0xF1;

    uint256 internal constant FED_PK_2 = 0xF2;

    uint256 internal constant FED_PK_3 = 0xF3;

    address internal encA1;

    address internal encA2;

    address internal encA3;

    address internal fedA1;

    address internal fedA2;

    address internal fedA3;

    MockERC20 internal token;

    MockBtcRelay internal btcRelay;

    CommissionManager internal cm;

    RouteRegistry internal routeRegistry;

    RGBVerifier internal rgbVerifier;

    RgbSettlementModule internal rgbModule;

    Bridge internal bridge;

    MultisigProxy internal proxy;

    bytes32 internal domainSep;

    uint256 internal constant SOURCE_CHAIN_ID = 31337; // foundry default block.chainid

    uint256 internal constant RGB_CHAIN_ID = 827166; // protocol-assigned RGB network

    uint256 internal constant USER_DEPOSIT = 1 ether; // one 18-decimal mock token gross

    // FUNDS_IN route: 2% token commission (stablePercent = 200, multiplier = 100 → 200/100/100 =
    // 2%).
    uint256 internal constant FUNDS_IN_PERCENT = 200;

    uint8 internal constant FUNDS_IN_MULT = 100;

    // FUNDS_OUT route: 1% token commission (stablePercent = 100, multiplier = 100 → 1%).
    uint256 internal constant FUNDS_OUT_PERCENT = 100;

    uint8 internal constant FUNDS_OUT_MULT = 100;

    // Non-zero RGB OpId threaded through the RGB-route settlementData on fundsIn.
    uint256 internal constant RGB_OP_ID = 0xABCDEF;

    uint256 internal constant ARBITRUM_L2_BLOCK = 1_000_000;

    uint64 internal constant RGB_BEFORE_BLOCK = 1_100_000;

    bytes32 internal constant SRC_BURN_TX_ID = keccak256("integration-burn-tx-default");

    // RGB proof = two (height, commit) pairs: a deep source block (RGB
    // burn/lock) and a fresh latest block (relay head). gap = 6 - 1 = 5.
    uint256 internal constant BLOCK_HEIGHT = 850_000; // source block

    bytes32 internal constant COMMITMENT_HASH = keccak256("integration-btc-block");

    uint256 internal constant BTC_CONFIRMATIONS = 6; // source confirmations

    uint256 internal constant LATEST_HEIGHT = 850_005;

    bytes32 internal constant LATEST_COMMIT = keccak256("integration-btc-latest");

    uint256 internal constant LATEST_CONFIRMATIONS = 1;

    uint256 internal constant TIMELOCK = 1 hours;

    uint256 internal constant MIN_TIMELOCK = 1 hours; // floor passed to the proxy constructor in tests

    string internal constant RGB_INVOICE = "";

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

    function setUp() public {
        vm.mockCall(address(100), abi.encodeCall(IArbSys.arbBlockNumber, ()), abi.encode(ARBITRUM_L2_BLOCK));

        encA1 = vm.addr(ENC_PK_1);
        encA2 = vm.addr(ENC_PK_2);
        encA3 = vm.addr(ENC_PK_3);
        fedA1 = vm.addr(FED_PK_1);
        fedA2 = vm.addr(FED_PK_2);
        fedA3 = vm.addr(FED_PK_3);

        token = new MockERC20("Mock USDT0", "USDT0");
        btcRelay = new MockBtcRelay();
        // Reject queried heights below the configured checkpoint, as the
        // deployed relay does.
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

        rgbVerifier =
            new RGBVerifier(address(btcRelay), BTC_CONFIRMATIONS, LATEST_CONFIRMATIONS, LATEST_HEIGHT - BLOCK_HEIGHT);
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
        // governance-accept path is exercised in multisig/Governance.t.sol).
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

    /// @dev Proposes `callData` as an AdminExecuteCommissionManager op, waits
    ///      out the timelock, and executes. Used by tests to configure the CM.
    function _proposeAndExecuteCmAdminCall(bytes memory callData) internal {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 7 days;

        bytes4 selector = bytes4(callData);

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteCM(
            domainSep, proxy.commissionManager(), selector, callData, nonce, deadline
        );
        bytes[] memory sigs = _signFed2of3(digest);

        bytes32 proposalId = proxy.proposeAdminExecuteCommissionManager(callData, nonce, deadline, 3, sigs);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(proposalId, callData);
    }

    function _proposeBridgeAdminCall(bytes memory callData) internal returns (bytes32) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 7 days;
        bytes4 selector = bytes4(callData);
        bytes32 digest =
            MultisigHelper.digestProposeAdminExecute(domainSep, proxy.bridge(), selector, callData, nonce, deadline);
        return proxy.proposeAdminExecute(callData, nonce, deadline, 3, _signFed2of3(digest));
    }

    function _proposeAndExecuteBridgeAdminCall(bytes memory callData) internal {
        bytes32 proposalId = _proposeBridgeAdminCall(callData);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(proposalId, callData);
    }

    function _signEnclave2of3(bytes32 digest) internal pure returns (bytes[] memory sigs) {
        uint256[] memory pks = new uint256[](2);
        pks[0] = ENC_PK_1;
        pks[1] = ENC_PK_2;
        sigs = MultisigHelper.signAll(vm, digest, pks);
    }

    function _signFed2of3(bytes32 digest) internal pure returns (bytes[] memory sigs) {
        uint256[] memory pks = new uint256[](2);
        pks[0] = FED_PK_1;
        pks[1] = FED_PK_2;
        sigs = MultisigHelper.signAll(vm, digest, pks);
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
        firstOpId = bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(rgbOpBase, RGB_BEFORE_BLOCK));
        for (uint256 i = 1; i < n; i++) {
            vm.prank(user);
            bridge.fundsIn(USER_DEPOSIT, RGB_CHAIN_ID, RGB_INVOICE, abi.encode(rgbOpBase + i, RGB_BEFORE_BLOCK));
        }
    }

    function _validProof() internal pure returns (bytes memory) {
        return abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
    }

    function _buildFundsOut(bytes32 sdOpId, uint256 releaseAmount, string memory srcAddr, bytes memory proof)
        internal
        view
        returns (IBridge.FundsOutParams memory params, uint256 burnId)
    {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = sdOpId;
        bytes memory settlementData = abi.encode(ids);
        burnId = _deriveBurnId(releaseAmount, RGB_CHAIN_ID, srcAddr, SRC_BURN_TX_ID);
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

    /// @dev Resolve getters and signatures before installing call expectations.
    function _prepareFundsOut(IBridge.FundsOutParams memory params)
        internal
        view
        returns (FundsOutAuthorization memory authorization)
    {
        authorization.nonce = proxy.teeNonce(params.sourceChainId);
        authorization.deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest =
            MultisigHelper.digestTeeFundsOut(domainSep, params, authorization.nonce, authorization.deadline);
        authorization.signatures = _signEnclave2of3(digest);
    }

    /// @dev Common successful release path. For call expectations, prepare first
    ///      and invoke fundsOutCall directly because preparation reads the proxy.
    function _submitFundsOut(IBridge.FundsOutParams memory params) internal {
        FundsOutAuthorization memory authorization = _prepareFundsOut(params);
        proxy.fundsOutCall(params, authorization.nonce, authorization.deadline, 3, authorization.signatures);
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

    /// @dev Reads no contracts, so it does not consume a pending prank.
    function _deriveBurnId(uint256 amount, uint256 sourceChainId, string memory sourceAddress, bytes32 sourceBurnTxId)
        internal
        view
        returns (uint256)
    {
        return BurnIdHelper.derive(
            address(bridge), block.chainid, address(token), amount, sourceChainId, sourceAddress, sourceBurnTxId
        );
    }
}
