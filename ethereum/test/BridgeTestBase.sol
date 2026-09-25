// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, Vm} from "forge-std/Test.sol";

import {Bridge} from "../src/Bridge.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {BridgeBaseUpgradeable} from "../src/BridgeBaseUpgradeable.sol";
import {CommissionManager} from "../src/CommissionManager.sol";
import {RouteRegistry} from "../src/RouteRegistry.sol";
import {IRouteRegistry} from "../src/interfaces/IRouteRegistry.sol";
import {RGBVerifier} from "../src/verifiers/RGBVerifier.sol";
import {RgbSettlementModule} from "../src/settlement/RgbSettlementModule.sol";
import {OutflowRateLimiter} from "../src/libraries/OutflowRateLimiter.sol";
import {
    CommissionConfig,
    CommissionSide,
    CommissionCurrency,
    ICommissionManager
} from "../src/interfaces/ICommissionManager.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {MockBtcRelay} from "./mocks/MockBtcRelay.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockSettlementModule} from "./mocks/MockSettlementModule.sol";
import {MockDepositFloor} from "./mocks/MockDepositFloor.sol";
import {BridgeProxyTestUtils} from "./mocks/BridgeProxyTestUtils.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ZeroNetCommissionManager {
    function calculateFundsOutCommission(uint256, uint256, address, uint256 amount)
        external
        pure
        returns (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount)
    {
        return (amount, 0, 0);
    }
}

/// @title BridgeTestBase
/// @notice Shared fixture for the Bridge suites: deployment, actors, route
///         wiring, and the calldata / burnId helpers every case builds on.
/// @dev    Cases live in `Bridge.t.sol` and `BridgeOutflow.t.sol`. They are
///         split across two contracts
///         because one contract holding all of them exceeds what the via-ir
///         pipeline can allocate stack slots for.
abstract contract BridgeTestBase is Test, BridgeProxyTestUtils {
    // Events re-declared locally for vm.expectEmit
    event FundsIn(address indexed sender, uint256 rgbOpId, uint64 amount);
    event BridgeFundsIn(
        bytes32 indexed operationId,
        bytes32 indexed sourceSender,
        address indexed sender,
        uint256 senderNonce,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 nativeCommission,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string destinationAddress,
        bytes settlementData
    );
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
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event LZAdapterDisabled(address indexed oldAdapter);
    event RouteRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event CommissionManagerUpdated(address indexed oldCommissionManager, address indexed newCommissionManager);
    event MinFundsInAmountUpdated(uint256 oldMinimum, uint256 newMinimum);
    event MinFundsOutAmountUpdated(uint256 oldMinimum, uint256 newMinimum);
    event OutflowLimitUpdated(uint256 indexed chainId, uint256 capacity, uint256 refillRate, uint256 available);
    event GlobalOutflowLimitUpdated(uint256 capacity, uint256 refillRate, uint256 available);

    Bridge bridge;
    MockERC20 usdt0;
    MockBtcRelay btcRelay;
    CommissionManager cm;
    RouteRegistry routeRegistry;
    RGBVerifier rgbVerifier;
    RgbSettlementModule rgbModule;
    MockAggregatorV3 ethUsdFeed;
    MockAggregatorV3 sequencerUptimeFeed;

    address deployer = makeAddr("deployer");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address multisig = makeAddr("multisig");

    uint256 constant SOURCE_CHAIN_ID = 31337; // foundry block.chainid
    uint256 constant RGB_CHAIN_ID = 1_000_001; // backend-assigned for RGB
    string constant DST_ADDR = "";
    string constant SRC_ADDR = ""; // RGB has no source-address concept
    uint256 constant AMOUNT = 1e18;
    uint256 constant TX_ID = 42;
    uint256 constant BURN_ID = 9_001;
    /// @notice Non-zero RGB OpId threaded through the RGB-route settlementData.
    uint256 constant RGB_OP_ID = 0xABCDEF;
    bytes32 constant BURN_TYPEHASH = keccak256(
        "UtexoBurnId(address bridge,uint256 chainId,address token,uint256 amount,uint256 sourceChainId,uint256 destinationChainId,bytes32 sourceAddressHash,bytes32 settlementDataHash,bytes32 sourceBurnTxId)"
    );
    /// @notice Default source-chain burn identifier used by the helpers. Tests
    ///         that need two distinct burns pass an explicit id instead.
    bytes32 constant SRC_BURN_TX_ID = keccak256("rgb-burn-tx-default");

    // BtcRelay test data
    // RGB proof = two (height, commit) pairs. The source block (RGB burn/lock)
    // is deep; the latest block is fresh (relay head). gap = 6 - 1 = 5.
    uint256 constant BLOCK_HEIGHT = 850_000; // source block
    bytes32 constant COMMITMENT_HASH = keccak256("test-btc-block-commitment");
    uint256 constant CONFIRMATIONS = 6; // source confirmations
    uint256 constant LATEST_HEIGHT = 850_005;
    bytes32 constant LATEST_COMMIT = keccak256("test-btc-latest-commitment");
    uint256 constant LATEST_CONFIRMATIONS = 1;

    function setUp() public {
        // Leave enough history for the healthy sequencer round to be past the
        // mandatory one-hour post-restart grace period.
        vm.warp(2 hours);

        usdt0 = new MockERC20("Mock USDT0", "USDT0");
        btcRelay = new MockBtcRelay();
        // The real relay never stores a header below its initialisation
        // checkpoint; mirror that here so a proof this suite accepts is one
        // the deployed relay would also accept.
        btcRelay.setCheckpointHeight(BLOCK_HEIGHT);
        btcRelay.setBlock(BLOCK_HEIGHT, COMMITMENT_HASH, CONFIRMATIONS);
        btcRelay.setBlock(LATEST_HEIGHT, LATEST_COMMIT, LATEST_CONFIRMATIONS);

        // DeployAll-style deploy with predicted Bridge address:
        //   nonce n      → CommissionManager (uses predicted Bridge)
        //   nonce n+1    → RouteRegistry     (uses predicted Bridge,
        //                                     deployer = owner)
        //   nonce n+2    → Bridge            (uses RouteRegistry, CM)
        //   nonce n+3    → RGBVerifier
        //   nonce n+4    → RgbSettlementModule
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

        rgbVerifier = new RGBVerifier(address(btcRelay), 6, 1, 5);
        rgbModule = new RgbSettlementModule(address(routeRegistry));

        // Both directions of the RGB route share the same verifier + module.
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // Wire the complete mandatory oracle config: healthy sequencer, ETH/USD
        // circuit-breaker bounds, then the fresh ETH/USD price feed.
        ethUsdFeed = new MockAggregatorV3(8, 2_000e8, block.timestamp);
        sequencerUptimeFeed = new MockAggregatorV3(0, 0, block.timestamp - 1 hours - 1);
        cm.setSequencerUptimeFeed(address(sequencerUptimeFeed));
        cm.setEthUsdPriceBounds(100e8, 100_000e8);
        cm.setEthUsdFeed(address(ethUsdFeed), 1 hours);

        // Production-flow ownership transfer of Bridge → multisig. CM and
        // RouteRegistry stay owned by deployer for this suite so individual
        // tests can configure commission rules and routes inline. The
        // governance-driven paths live in MultisigProxy.t.sol / Integration.t.sol.
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

    // ========================================================================
    // helpers
    // ========================================================================

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

    /// @dev Mirror of `Bridge._deriveOperationId` so tests can precompute the
    ///      expected canonical id when they need it for an `expectEmit` topic.
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

    function _proof() internal pure returns (bytes memory) {
        return abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
    }

    /// @dev Mirror of `Bridge._deriveBurnId` so tests can build canonical
    ///      `fundsOut` payloads after.
    ///      The typehash is an internal formula/domain separator.
    function _deriveBurnId(
        address recipient_,
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory sourceAddress,
        bytes memory proof,
        bytes memory settlementData
    ) internal view returns (uint256) {
        return _deriveBurnIdWithTx(
            amount, sourceChainId, destinationChainId, sourceAddress, settlementData, SRC_BURN_TX_ID
        );
    }

    /// @dev Mirror of `Bridge._deriveBurnIdFromFields`. `recipient` and `proof`
    ///      are deliberately absent: the key is shared with `rebalanceLiquidity`,
    ///      which has no recipient, and `proof` carries the moving relay head.
    function _deriveBurnIdWithTx(
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory sourceAddress,
        bytes memory settlementData,
        bytes32 sourceBurnTxId
    ) internal view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    BURN_TYPEHASH,
                    address(bridge),
                    block.chainid,
                    address(usdt0),
                    amount,
                    sourceChainId,
                    destinationChainId,
                    keccak256(bytes(sourceAddress)),
                    keccak256(settlementData),
                    sourceBurnTxId
                )
            )
        );
    }

    /// @dev Build `settlementData` for the reworked RgbSettlementModule, which
    ///      expects `(uint256[] operationIds, uint256[] amounts)` and checks
    ///      each id exists with an EXACTLY matching amount (no consumption).
    ///
    ///      This convenience encodes `AMOUNT` for every id — the standard
    ///      deposit size used across these tests (`TX_ID` is funded with
    ///      `AMOUNT`). It is intentionally `pure`: it must NOT make an external
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

    /// @dev Wrap the former 8 positional `fundsOut` args into the typed struct
    ///      and make the external Bridge call. Keeps `vm.prank` / `vm.expectRevert`
    ///      working: the inner `bridge.fundsOut` is the next external call.
    function _fundsOut(
        address recipient_,
        uint256 amount,
        uint256,
        /* burnId */
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory sourceAddress,
        bytes memory proof,
        bytes memory settlementData
    ) internal returns (uint256 burnId) {
        burnId = _deriveBurnId(
            recipient_, amount, sourceChainId, destinationChainId, sourceAddress, proof, settlementData
        );
        _fundsOutWithBurnId(
            recipient_, amount, burnId, sourceChainId, destinationChainId, sourceAddress, proof, settlementData
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

    /// @dev Build an ASCII string of exactly `len` bytes (for address-length caps).
    function _str(uint256 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = "a";
        }
        return string(b);
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

    function _setFundsOutNativeRule(uint256 percent) internal {
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
                currency: CommissionCurrency.NATIVE,
                isSet: true
            })
        );
    }

    /// @dev Accepted `msg.value` band on the DIRECT overload: the floor is the
    ///      fresh quote itself, because the headroom above it is a refundable
    ///      drift buffer rather than extra commission.
    function _directNativeBounds(uint256 nativeCommission) internal view returns (uint256 minimum, uint256 maximum) {
        uint256 denominator = bridge.BPS_DENOMINATOR();
        uint256 tolerance = bridge.NATIVE_COMMISSION_TOLERANCE_BPS();
        minimum = nativeCommission;
        maximum = Math.mulDiv(nativeCommission, denominator + tolerance, denominator);
    }

    /// @dev Accepted `msg.value` band on the ADAPTER overload: symmetric, since
    ///      the source-chain payer is unreachable and nothing can be refunded.
    function _adapterNativeBounds(uint256 nativeCommission) internal view returns (uint256 minimum, uint256 maximum) {
        uint256 denominator = bridge.BPS_DENOMINATOR();
        uint256 tolerance = bridge.NATIVE_COMMISSION_TOLERANCE_BPS();
        minimum = Math.mulDiv(nativeCommission, denominator - tolerance, denominator, Math.Rounding.Ceil);
        maximum = Math.mulDiv(nativeCommission, denominator + tolerance, denominator);
    }

    function _nativeQuote(uint256 amount) internal view returns (uint256 quote) {
        (, quote,) = cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), amount);
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

    /// @dev Balanced policy that consumes the full 20% configurable budget:
    ///      10% instant burst plus 10% refill per window. Test liquidity is
    ///      sized so this bucket stays out of the way unless it is the subject.
    uint256 constant MAX_BURST_BPS = 1_000;
    uint256 constant MAX_REFILL_BPS = 1_000;

    function _configureMaxSafeBuckets() internal {
        vm.startPrank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setGlobalOutflowLimit(MAX_BURST_BPS, MAX_REFILL_BPS);
        vm.stopPrank();
    }

    /// @dev Convert an absolute token amount into bps of a chain's reference
    ///      liquidity, so bucket tests can keep expressing intent in amounts.
    function _bpsOfChain(uint256 chainId, uint256 amount) internal view returns (uint256) {
        return amount * bridge.BPS_DENOMINATOR() / bridge.lockedLiquidity(chainId);
    }

    /// @dev Same conversion against aggregate liquidity, for the global bucket.
    function _bpsOfGlobal(uint256 amount) internal view returns (uint256) {
        return amount * bridge.BPS_DENOMINATOR() / bridge.totalLockedLiquidity();
    }

    // ========================================================================
    // Proof length cap
    //
    // fundsOut forwards `proof` to the route verifier, so it is capped at
    // MAX_PROOF_LENGTH to bound calldata + verifier gas. The exact cap is
    // accepted; one byte over reverts ProofTooLong. The real RGB proof
    // (abi.encode(uint256, bytes32) = 64 bytes) is far under the cap.
    // ========================================================================

    /// @dev Build a `bytes` blob of exactly `len` bytes.
    function _bytesOfLength(uint256 len) internal pure returns (bytes memory b) {
        b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = 0x61;
        }
    }

    // ========================================================================
    // Outflow rate limit — OutflowRateLimiter token bucket
    //
    // fundsOut consumes the per-chain bucket (token-scoped errors) then the
    // global bucket (aggregate-scoped errors). `_seedRGB` configures both with a
    // balanced policy whose burst + refill equals the maximum 20% configurable
    // budget; tests can then reconfigure RGB down to exercise tighter limits.
    // SEED_TX seeds ample isolated liquidity + a settlement
    // record (proof-of-mint). Rate-limit reverts are matched by selector (the
    // library's minWait is an implementation detail).
    // ========================================================================

    uint256 constant SEED_TX = 5_000;

    /// @dev The net amount recorded under `SEED_TX` by the last `_seedRGB`, so
    ///      `_releaseRGB` can build a settlement whose amount matches the record
    ///      (the reworked module requires an exact match). Read internally only
    ///      — no external call — so inline use after a cheatcode is safe.
    uint256 _seedAmt;

    /// @dev Bridge-derived operationId of the last `_seedRGB` deposit; used as
    ///      the record key in `_releaseRGB` settlement data.
    bytes32 _seedOpId;

    function _seedRGB(uint256 amount) internal {
        uint256 seededLiquidity = amount * bridge.BPS_DENOMINATOR() / MAX_BURST_BPS;
        _seedAmt = seededLiquidity; // no fundsIn commission in this suite → net == gross
        usdt0.mint(user, seededLiquidity);
        vm.prank(user);
        _seedOpId = bridge.fundsIn(seededLiquidity, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _configureMaxSafeBuckets();
    }

    function _releaseRGB(uint256 amount, uint256 burnId) internal {
        _releaseRGBTo(recipient, amount, burnId);
    }

    function _releaseRGBTo(address payoutRecipient, uint256 amount, uint256 burnId) internal {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = _seedOpId;
        vm.prank(multisig);
        _fundsOut(
            payoutRecipient,
            amount,
            burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(ids, _one(_seedAmt))
        );
    }

    /// @dev Configure the RGB bucket from absolute token amounts, converted to
    ///      bps of the chain's current reference liquidity: `burstAmount` is the
    ///      instant allowance, `refillAmountPerWindow` the amount restored over
    ///      one `BUCKET_REFILL_WINDOW`.
    function _setRGBBucket(uint256 burstAmount, uint256 refillAmountPerWindow) internal {
        // Resolve the bps values first: each `_bpsOfChain` makes an external view
        // call, which would consume a pending `vm.prank`.
        uint256 burstBps = _bpsOfChain(RGB_CHAIN_ID, burstAmount);
        uint256 refillBps = _bpsOfChain(RGB_CHAIN_ID, refillAmountPerWindow);
        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, refillBps);
    }

    /// @dev A contract that is NOT the Bridge but still answers the deposit-floor
    ///      query the CommissionManager makes while quoting. Pointing CM's
    ///      `bridgeAddress` here isolates the failure to `receiveTokenCommission`
    ///      (`OnlyBridge`) — a codeless address would instead fail earlier, at the
    ///      quote, with `AmountFloorUnavailable`.
    function _wrongBridgeWithFloor() internal returns (address) {
        MockDepositFloor stub = new MockDepositFloor();
        stub.setMinFundsInAmount(bridge.minFundsInAmount());
        return address(stub);
    }

    function _assertFundsInRevertPathLeavesStateUnchanged(uint256 amount, uint8 failureMode) internal {
        bytes memory expectedRevert;
        MockSettlementModule revertingModule;

        if (failureMode == 0) {
            vm.prank(deployer);
            routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, false, address(rgbVerifier), address(rgbModule));
            expectedRevert =
                abi.encodeWithSelector(IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, RGB_CHAIN_ID);
        } else if (failureMode == 1) {
            revertingModule = new MockSettlementModule();
            revertingModule.setShouldRevertOnFundsIn(true);

            vm.prank(deployer);
            routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(revertingModule));
            expectedRevert = abi.encodeWithSelector(MockSettlementModule.MockModuleForcedRevert.selector);
        } else if (failureMode == 2) {
            _setFundsInTokenRule(400); // 4%, positive for the fuzzed amount range.
            // Deploy the stub BEFORE the prank — as a call argument it would consume it.
            address wrongBridge = _wrongBridgeWithFloor();
            vm.prank(deployer);
            cm.setBridgeAddress(wrongBridge);
            expectedRevert = abi.encodeWithSelector(ICommissionManager.OnlyBridge.selector);
        } else if (failureMode == 3) {
            _setFundsInNativeRule(100); // Positive native quote for the fuzzed amount range.
            vm.warp(block.timestamp + 2 hours);
            ethUsdFeed.setUpdatedAt(block.timestamp - 2 hours);
            expectedRevert = abi.encodeWithSelector(ICommissionManager.StalePrice.selector);
        } else {
            _setFundsInNativeRule(100); // Positive native quote for the fuzzed amount range.
            ethUsdFeed.setUpdatedAt(block.timestamp);
            ethUsdFeed.setAnswer(0);
            expectedRevert = abi.encodeWithSelector(ICommissionManager.InvalidPrice.selector);
        }

        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, amount, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        LedgerSnapshot memory before = _snapshotLedger(expectedOpId);

        vm.expectRevert(expectedRevert);
        vm.prank(user);
        bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        _assertLedgerUnchanged(before, expectedOpId);

        if (failureMode == 1) {
            assertEq(revertingModule.onFundsInCount(), 0, "module state unchanged");
        }
    }

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

    // ========================================================================
    // fee-on-transfer safe ingress accounting
    //
    // `_fundsIn` credits the ledger from the ACTUAL amount received
    // (balanceAfter - balanceBefore), not the nominal `amount`. For a
    // fee-on-transfer token the bridge receives less than `amount`, so the
    // record / lockedLiquidity / events must reflect `received - tokenCommission`
    // and never the nominal figure (which would overstate the ledger and later
    // brick the release with AmountExceedBridgePool).
    //
    // These tests build a full parallel stack whose Bridge TOKEN is a
    // FeeOnTransferERC20, mirroring setUp() exactly (same predicted-bridge nonce
    // math, CM, RouteRegistry, verifier reuse of `btcRelay`, module, both routes,
    // feed, outflow limits, ownership transfer+accept, user funding).
    // ========================================================================

    struct FeeStack {
        Bridge bridge;
        FeeOnTransferERC20 token;
        RgbSettlementModule module;
        CommissionManager cm;
    }

    /// @dev Deploy a full parallel bridge stack backed by a fee-on-transfer
    ///      token. Mirrors setUp() one-for-one. The RGB verifier / `btcRelay` /
    ///      `_proof()` are shared (the source-block relay data is identical).
    function _deployFeeStack(uint256 feeBps) internal returns (FeeStack memory s) {
        s.token = new FeeOnTransferERC20("Fee USDT0", "fUSDT0", feeBps);

        vm.startPrank(deployer);
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 3);

        s.cm = new CommissionManager(predictedBridge, recipient);
        RouteRegistry feeRouteRegistry = new RouteRegistry(predictedBridge, deployer);
        s.bridge = _deployBridge(
            address(s.token), address(feeRouteRegistry), payable(address(s.cm)), address(0), 1, 1, deployer
        );

        // Reuse the suite's RGB verifier (shares `btcRelay` + `_proof()`); a
        // fresh module is bound to this stack's route registry.
        s.module = new RgbSettlementModule(address(feeRouteRegistry));

        feeRouteRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(s.module));
        feeRouteRegistry.setRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(s.module));

        _configureFeeStack(s);
    }

    /// @dev Oracle wiring, ownership handoff and user funding for a `FeeStack`.
    ///      Split out of `_deployFeeStack` so neither frame trips the via-ir
    ///      stack limit once the caller is inlined.
    function _configureFeeStack(FeeStack memory s) private {
        s.cm.setSequencerUptimeFeed(address(sequencerUptimeFeed));
        s.cm.setEthUsdPriceBounds(100e8, 100_000e8);
        s.cm.setEthUsdFeed(address(ethUsdFeed), 1 hours);

        s.bridge.transferOwnership(multisig);
        vm.stopPrank();

        vm.prank(multisig);
        s.bridge.acceptOwnership();

        // Fund `user` generously and approve the fee bridge. `mint` is untaxed,
        // so `user` holds exactly the minted amount.
        s.token.mint(user, AMOUNT * 10);
        vm.prank(user);
        s.token.approve(address(s.bridge), type(uint256).max);
    }

    /// @dev Release through a `FeeStack`, isolated in its own frame so the
    ///      fee-token tests stay within via-ir stack limits.
    function _releaseFor(
        FeeStack memory s,
        uint256 amount,
        uint256 burnId,
        bytes memory proof,
        bytes memory settlementData
    ) internal {
        vm.prank(multisig);
        s.bridge
            .fundsOut(
                IBridge.FundsOutParams(
                    recipient,
                    amount,
                    burnId,
                    RGB_CHAIN_ID,
                    SOURCE_CHAIN_ID,
                    SRC_ADDR,
                    proof,
                    settlementData,
                    SRC_BURN_TX_ID
                )
            );
    }

    /// @dev Set a FUNDS_IN TOKEN commission rule on a fee stack's CM for the
    ///      (SOURCE_CHAIN_ID → RGB_CHAIN_ID) route.
    function _setFeeStackFundsInTokenRule(FeeStack memory s, uint256 stablePercent, uint8 multiplier) internal {
        vm.prank(deployer);
        s.cm
            .setCommissionRule(
                SOURCE_CHAIN_ID,
                RGB_CHAIN_ID,
                address(s.token),
                CommissionConfig({
                    stablePercent: stablePercent,
                    baseFee: 0,
                    multiplier: multiplier,
                    side: CommissionSide.FUNDS_IN,
                    currency: CommissionCurrency.TOKEN,
                    isSet: true
                })
            );
    }

    /// @dev Burn-id derivation bound to a fee stack's Bridge + token (the shared
    ///      `_deriveBurnId` binds the setUp `bridge`/`usdt0`).
    function _deriveBurnIdFor(
        FeeStack memory s,
        address recipient_,
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory sourceAddress,
        bytes memory,
        bytes memory settlementData
    ) internal view returns (uint256) {
        recipient_; // no longer part of the key
        return uint256(
            keccak256(
                abi.encode(
                    BURN_TYPEHASH,
                    address(s.bridge),
                    block.chainid,
                    address(s.token),
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
}

/// @dev Caller that deliberately cannot receive native value, used to cover the
///      `NativeRefundFailed` path on the direct `fundsIn` overload.
contract NonPayableDepositor {
    Bridge private immutable _bridge;
    MockERC20 private immutable _token;

    constructor(Bridge bridge_, MockERC20 token_) {
        _bridge = bridge_;
        _token = token_;
    }

    function approveBridge(uint256 amount) external {
        _token.approve(address(_bridge), amount);
    }

    function deposit(
        uint256 amount,
        uint256 destinationChainId,
        string calldata destinationAddress,
        bytes calldata settlementData,
        uint256 nativeValue
    ) external returns (bytes32) {
        return _bridge.fundsIn{value: nativeValue}(amount, destinationChainId, destinationAddress, settlementData);
    }

    // no receive / fallback: any refund attempt fails
}
