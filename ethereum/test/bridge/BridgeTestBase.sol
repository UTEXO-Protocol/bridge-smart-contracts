// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Bridge} from "../../src/Bridge.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {RouteRegistry} from "../../src/RouteRegistry.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {CommissionConfig, CommissionCurrency, CommissionSide} from "../../src/interfaces/ICommissionManager.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {RGBVerifier} from "../../src/verifiers/RGBVerifier.sol";
import {BridgeProxyTestUtils} from "../helpers/BridgeProxyTestUtils.sol";
import {BurnIdHelper} from "../helpers/BurnIdHelper.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockBtcRelay} from "../mocks/MockBtcRelay.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared Bridge deployment and accounting fixtures.
abstract contract BridgeTestBase is Test, BridgeProxyTestUtils {
    Bridge internal bridge;

    MockERC20 internal usdt0;

    MockBtcRelay internal btcRelay;

    CommissionManager internal cm;

    RouteRegistry internal routeRegistry;

    RGBVerifier internal rgbVerifier;

    RgbSettlementModule internal rgbModule;

    MockAggregatorV3 internal ethUsdFeed;

    MockAggregatorV3 internal sequencerUptimeFeed;

    address internal deployer = makeAddr("deployer");

    address internal user = makeAddr("user");

    address internal recipient = makeAddr("recipient");

    address internal multisig = makeAddr("multisig");

    uint256 internal constant SOURCE_CHAIN_ID = 31337; // foundry block.chainid

    uint256 internal constant RGB_CHAIN_ID = 1_000_001; // backend-assigned for RGB

    string internal constant DST_ADDR = "";

    string internal constant SRC_ADDR = ""; // RGB has no source-address concept

    uint256 internal constant AMOUNT = 1e18;

    /// @notice Non-zero RGB OpId threaded through the RGB-route settlementData.
    uint256 internal constant RGB_OP_ID = 0xABCDEF;

    /// @notice Default source-chain burn identifier used by the helpers. Tests
    ///         that need two distinct burns pass an explicit id instead.
    bytes32 internal constant SRC_BURN_TX_ID = keccak256("rgb-burn-tx-default");

    // BtcRelay test data
    // RGB proof = two (height, commit) pairs. The source block (RGB burn/lock)
    // is deep; the latest block is fresh (relay head). gap = 6 - 1 = 5.
    uint256 internal constant BLOCK_HEIGHT = 850_000; // source block

    bytes32 internal constant COMMITMENT_HASH = keccak256("test-btc-block-commitment");

    uint256 internal constant CONFIRMATIONS = 6; // source confirmations

    uint256 internal constant LATEST_HEIGHT = 850_005;

    bytes32 internal constant LATEST_COMMIT = keccak256("test-btc-latest-commitment");

    uint256 internal constant LATEST_CONFIRMATIONS = 1;

    /// @dev Balanced policy that consumes the full 20% configurable budget:
    ///      10% instant burst plus 10% refill per window. Test liquidity is
    ///      sized so this bucket stays out of the way unless it is the subject.
    uint256 internal constant MAX_BURST_BPS = 1_000;

    uint256 internal constant MAX_REFILL_BPS = 1_000;

    /// @dev Net amount recorded under `_seedOpId` by the last `_seedRGB`
    ///      deposit; used for exact-match payloads without external reads.
    uint256 internal _seedAmt;

    /// @dev Bridge-derived operationId of the last `_seedRGB` deposit; used as
    ///      the record key in `_releaseRGB` settlement data.
    bytes32 internal _seedOpId;

    /// @dev Token / native / pool balances plus one RGB record, bundled so the
    ///      revert-path assertions do not keep a dozen locals live at once
    ///      (which pushes the enclosing frame past the via-ir stack limit).
    struct LedgerSnapshot {
        uint256 userToken;
        uint256 bridgeToken;
        uint256 cmToken;
        uint256 userNative;
        uint256 bridgeNative;
        uint256 cmNative;
        uint256 cmPool;
        uint256 nativePool;
        uint256 record;
    }

    function setUp() public virtual {
        // Leave enough history for the healthy sequencer round to be past the
        // mandatory one-hour post-restart grace period.
        vm.warp(2 hours);

        usdt0 = new MockERC20("Mock USDT0", "USDT0");
        btcRelay = new MockBtcRelay();
        // Reject queried heights below the configured checkpoint, as the
        // deployed relay does.
        btcRelay.setCheckpointHeight(BLOCK_HEIGHT);
        btcRelay.setBlock(BLOCK_HEIGHT, COMMITMENT_HASH, CONFIRMATIONS);
        btcRelay.setBlock(LATEST_HEIGHT, LATEST_COMMIT, LATEST_CONFIRMATIONS);

        // DeployAll-style deploy with predicted Bridge address:
        //   nonce n      → CommissionManager (uses predicted Bridge)
        //   nonce n+1    → RouteRegistry     (uses predicted Bridge,
        //                                     deployer = owner)
        //   nonce n+2    → Bridge implementation
        //   nonce n+3    → BridgeProxy (initialized with RouteRegistry and CM)
        //   nonce n+4    → RGBVerifier
        //   nonce n+5    → RgbSettlementModule
        // Routes are then registered by deployer before ownership transfer.
        vm.startPrank(deployer);
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 3);

        cm = new CommissionManager(predictedBridge, recipient);
        routeRegistry = new RouteRegistry(predictedBridge, deployer);
        bridge = _deployBridge(
            address(usdt0),
            address(routeRegistry),
            payable(address(cm)),
            address(0),
            1, // minFundsInAmount: smallest non-zero floor; cases that need a higher floor deploy their own Bridge
            1, // minFundsOutAmount: smallest non-zero floor for tests
            deployer
        );

        rgbVerifier =
            new RGBVerifier(address(btcRelay), CONFIRMATIONS, LATEST_CONFIRMATIONS, LATEST_HEIGHT - BLOCK_HEIGHT);
        rgbModule = new RgbSettlementModule(address(routeRegistry));

        // Both directions of the RGB route share the same verifier + module.
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // Wire the complete mandatory oracle config: healthy sequencer, ETH/USD
        // circuit-breaker bounds, then the fresh ETH/USD price feed.
        ethUsdFeed = new MockAggregatorV3(8, 2_000e8, vm.getBlockTimestamp());
        sequencerUptimeFeed = new MockAggregatorV3(0, 0, vm.getBlockTimestamp() - 1 hours - 1);
        cm.setSequencerUptimeFeed(address(sequencerUptimeFeed));
        cm.setEthUsdPriceBounds(100e8, 100_000e8);
        cm.setEthUsdFeed(address(ethUsdFeed), 1 hours);

        // Production-flow ownership transfer of Bridge → multisig. CM and
        // RouteRegistry stay owned by deployer for this suite so individual
        // tests can configure commission rules and routes inline. The
        // governance-driven paths live in multisig/Governance.t.sol and integration/.
        bridge.transferOwnership(multisig);
        vm.stopPrank();

        // Ownable2Step: the new owner must accept before it takes effect.
        vm.prank(multisig);
        bridge.acceptOwnership();

        // fund user and approve bridge
        usdt0.mint(user, AMOUNT * 10);
        vm.prank(user);
        usdt0.approve(address(bridge), type(uint256).max);
    }

    /// @dev RGB-route `settlementData` for `fundsIn`: the module decodes a
    ///      non-zero `uint256 rgbOpId`.
    function _rgbData() internal pure returns (bytes memory) {
        return abi.encode(RGB_OP_ID);
    }

    /// @dev RGB-route `settlementData` with an explicit rgbOpId (for tests that
    ///      need distinct ids or the zero-id revert path).
    function _rgbData(uint256 rgbOpId) internal pure returns (bytes memory) {
        return abi.encode(rgbOpId);
    }

    /// @dev Single-element `bytes32[]` for fundsOut settlement operationIds.
    function _ids(bytes32 id) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = id;
    }

    /// @dev Independent legacy deposit formula for non-RGB route assertions.
    ///      Prefer capturing the return value of `fundsIn`; this exists for the
    ///      cases where the id is needed BEFORE the call (event assertions).
    function _deriveOpId(
        uint256 sourceChainId,
        bytes32 sourceSender,
        uint256 senderNonce,
        uint256 grossAmount,
        uint256 destinationChainId,
        string memory destinationAddress,
        bytes memory settlementData
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                bridge.FUNDS_IN_OPERATION_TYPEHASH(),
                address(bridge),
                sourceChainId,
                sourceSender,
                senderNonce,
                bridge.TOKEN(),
                grossAmount,
                destinationChainId,
                keccak256(bytes(destinationAddress)),
                keccak256(settlementData),
                block.chainid
            )
        );
    }

    /// @dev The published RGB formula, independent of Bridge's helper.
    function _deriveRgbOpId(uint256 rgbNetwork, uint256 rgbOpId, uint256 netAmount) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "UtexoRgbMintDeposit(address bridge,uint256 chainId,address token,uint256 rgbNetwork,uint256 rgbOpId,uint256 netAmount)"
                ),
                address(bridge),
                block.chainid,
                address(usdt0),
                rgbNetwork,
                rgbOpId,
                netAmount
            )
        );
    }

    function _proof() internal pure returns (bytes memory) {
        return abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
    }

    /// @dev Build `settlementData` for RgbSettlementModule, which
    ///      expects `(bytes32[] operationIds, uint256[] amounts)` and checks
    ///      each id exists with an EXACTLY matching amount (no consumption).
    ///
    ///      This convenience encodes `AMOUNT` for every id — the standard
    ///      deposit size used across these tests. It is intentionally `pure`: it must NOT make an external
    ///      call, because it is frequently passed inline as a `fundsOut`
    ///      argument right after `vm.prank`/`vm.expectRevert`, and a staticcall
    ///      there would consume the cheatcode. Tests whose records differ from
    ///      `AMOUNT` (seeded liquidity, multi-amount, fuzz, deliberate
    ///      mismatch) use `_settlementWithAmounts` with explicit values.
    function _settlement(bytes32[] memory ids) internal pure returns (bytes memory) {
        uint256[] memory amounts = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            amounts[i] = AMOUNT;
        }
        return abi.encode(ids, amounts);
    }

    /// @dev Explicit `(ids, amounts)` encoding for records that are not `AMOUNT`
    ///      (seeded liquidity, multi-amount, fuzz) and for mismatch/length tests.
    function _settlementWithAmounts(bytes32[] memory ids, uint256[] memory amounts)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(ids, amounts);
    }

    /// @dev Single-element `uint256[]` (used for explicit amount arrays).
    function _one(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    /// @dev Builds and submits a release with an explicit source burn transaction.
    ///      Pure preparation keeps Bridge.fundsOut as the next external call.
    function _fundsOut(
        address payoutRecipient,
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory sourceAddress,
        bytes memory proof,
        bytes memory settlementData,
        bytes32 sourceBurnTxId
    ) internal returns (uint256 burnId) {
        burnId = _deriveBurnId(amount, sourceChainId, sourceAddress, sourceBurnTxId);
        bridge.fundsOut(
            IBridge.FundsOutParams({
                recipient: payoutRecipient,
                amount: amount,
                burnId: burnId,
                sourceChainId: sourceChainId,
                destinationChainId: destinationChainId,
                sourceAddress: sourceAddress,
                proof: proof,
                settlementData: settlementData,
                sourceBurnTxId: sourceBurnTxId
            })
        );
    }

    function _fundsOutWithBurnId(
        address recipient_,
        uint256 amount,
        uint256 burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory sourceAddress,
        bytes memory proof,
        bytes memory settlementData
    ) internal {
        bridge.fundsOut(
            IBridge.FundsOutParams(
                recipient_,
                amount,
                burnId,
                sourceChainId,
                destinationChainId,
                sourceAddress,
                proof,
                settlementData,
                SRC_BURN_TX_ID
            )
        );
    }

    function _setFundsInTokenRule(uint256 percent) internal {
        vm.prank(deployer);
        cm.setCommissionRule(
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );
    }

    function _setFundsInNativeRule(uint256 percent) internal {
        vm.prank(deployer);
        cm.setCommissionRule(
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.NATIVE,
                isSet: true
            })
        );
    }

    function _setFundsOutTokenRule(uint256 percent) internal {
        vm.prank(deployer);
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );
    }

    /// @dev Ensure `requested` fits under the configured bucket burst (and
    ///      therefore also under the immutable 20% safety ceiling). Used by
    ///      success-path tests whose subject is not the rolling limiter.
    function _ensureRgbSafetyCapacity(uint256 requested) internal {
        uint256 requiredLiquidity = requested * bridge.BPS_DENOMINATOR() / MAX_BURST_BPS;
        uint256 currentLiquidity = bridge.lockedLiquidity(RGB_CHAIN_ID);
        if (currentLiquidity < requiredLiquidity) {
            uint256 topUp = requiredLiquidity - currentLiquidity;
            usdt0.mint(user, topUp);
            vm.prank(user);
            bridge.fundsIn(topUp, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 1_000_000));
        }

        _configureMaxSafeBuckets();
    }

    function _configureMaxSafeBuckets() internal {
        vm.startPrank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setGlobalOutflowLimit(MAX_BURST_BPS, MAX_REFILL_BPS);
        vm.stopPrank();
    }

    /// @dev Deposit enough liquidity for `amount` to fit the 10% burst, then
    ///      configure chain and global buckets with a 10% burst and 10% refill.
    function _seedRGB(uint256 amount) internal {
        uint256 seededLiquidity = amount * bridge.BPS_DENOMINATOR() / MAX_BURST_BPS;
        _seedAmt = seededLiquidity; // no fundsIn commission in this suite → net == gross
        usdt0.mint(user, seededLiquidity);
        vm.prank(user);
        _seedOpId = bridge.fundsIn(seededLiquidity, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _configureMaxSafeBuckets();
    }

    function _releaseRGB(uint256 amount, bytes32 sourceBurnTxId) internal {
        _releaseRGBTo(recipient, amount, sourceBurnTxId);
    }

    function _releaseRGBTo(address payoutRecipient, uint256 amount, bytes32 sourceBurnTxId) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = _seedOpId;
        vm.prank(multisig);
        _fundsOut(
            payoutRecipient,
            amount,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(ids, _one(_seedAmt)),
            sourceBurnTxId
        );
    }

    function _snapshotLedger(bytes32 opId) internal view returns (LedgerSnapshot memory s) {
        s.userToken = usdt0.balanceOf(user);
        s.bridgeToken = usdt0.balanceOf(address(bridge));
        s.cmToken = usdt0.balanceOf(address(cm));
        s.userNative = user.balance;
        s.bridgeNative = address(bridge).balance;
        s.cmNative = address(cm).balance;
        s.cmPool = cm.tokenCommissionPool(address(usdt0));
        s.nativePool = cm.nativeCommissionPool();
        s.record = rgbModule.fundsInRecords(opId);
    }

    function _assertLedgerUnchanged(LedgerSnapshot memory before, bytes32 opId) internal view {
        assertEq(usdt0.balanceOf(user), before.userToken, "user token unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), before.bridgeToken, "bridge token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), before.cmToken, "cm token unchanged");
        assertEq(user.balance, before.userNative, "user native unchanged");
        assertEq(address(bridge).balance, before.bridgeNative, "bridge native unchanged");
        assertEq(address(cm).balance, before.cmNative, "cm native unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), before.cmPool, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), before.nativePool, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId), before.record, "rgb record unchanged");
    }

    /// @dev Reads no contracts, so it does not consume a pending prank.
    function _deriveBurnId(uint256 amount, uint256 sourceChainId, string memory sourceAddress, bytes32 sourceBurnTxId)
        internal
        view
        returns (uint256)
    {
        return BurnIdHelper.derive(
            address(bridge), block.chainid, address(usdt0), amount, sourceChainId, sourceAddress, sourceBurnTxId
        );
    }
}
