// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {Bridge} from "../src/Bridge.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {BridgeBase} from "../src/BridgeBase.sol";
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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract BridgeTest is Test {
    // Events re-declared locally for vm.expectEmit
    event FundsIn(address indexed sender, uint256 indexed rgbOpId, uint256 amount);
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
        string destinationAddress
    );
    event BridgeFundsOut(
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 indexed burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string sourceAddress
    );
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event LZAdapterDisabled(address indexed oldAdapter);
    event RouteRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
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
    string constant DST_ADDR = "rgb:asset1qp0y3mq6h5k8d9f2e4j7n6c3w/utxo1abc123";
    string constant SRC_ADDR = "rgb:sender/utxo1src";
    uint256 constant AMOUNT = 100e18;
    uint256 constant TX_ID = 42;
    uint256 constant BURN_ID = 9_001;
    /// @notice Non-zero RGB OpId threaded through the RGB-route settlementData.
    uint256 constant RGB_OP_ID = 0xABCDEF;
    bytes32 constant FUNDS_OUT_BURN_ID_TYPEHASH = keccak256(
        "UtexoFundsOutBurnId(address bridge,uint256 chainId,address token,address recipient,uint256 amount,uint256 sourceChainId,uint256 destinationChainId,bytes32 sourceAddressHash,bytes32 proofHash,bytes32 settlementDataHash)"
    );

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
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 2);

        cm = new CommissionManager(predictedBridge, recipient);
        routeRegistry = new RouteRegistry(predictedBridge, deployer);
        bridge = new Bridge(
            address(usdt0),
            address(routeRegistry),
            payable(address(cm)),
            address(0),
            1, // minFundsInAmount: smallest non-zero floor; cases that need a higher floor deploy their own Bridge
            1 // minFundsOutAmount: smallest non-zero floor for tests
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
        return uint256(
            keccak256(
                abi.encode(
                    FUNDS_OUT_BURN_ID_TYPEHASH,
                    address(bridge),
                    block.chainid,
                    address(usdt0),
                    recipient_,
                    amount,
                    sourceChainId,
                    destinationChainId,
                    keccak256(bytes(sourceAddress)),
                    keccak256(proof),
                    keccak256(settlementData)
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
                recipient_, amount, burnId, sourceChainId, destinationChainId, sourceAddress, proof, settlementData
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
    // Constructor
    // ========================================================================

    function test_constructor_setsTokenOwnerAndRouteRegistry() public view {
        assertEq(bridge.TOKEN(), address(usdt0));
        assertEq(bridge.owner(), multisig);
        assertEq(bridge.routeRegistry(), address(routeRegistry));
        assertEq(address(bridge.commissionManager()), address(cm));
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(BridgeBase.InvalidTokenAddress.selector);
        new Bridge(address(0), address(routeRegistry), payable(address(cm)), address(0), 1, 1);
    }

    function test_constructor_revertsOnZeroRouteRegistry() public {
        vm.expectRevert(IBridge.InvalidRouteRegistryAddress.selector);
        new Bridge(address(usdt0), address(0), payable(address(cm)), address(0), 1, 1);
    }

    function test_constructor_revertsOnZeroCommissionManager() public {
        vm.expectRevert(IBridge.InvalidCommissionManagerAddress.selector);
        new Bridge(address(usdt0), address(routeRegistry), payable(address(0)), address(0), 1, 1);
    }

    function test_constructor_storesInitialLZAdapter() public {
        address initialAdapter = makeAddr("initial-adapter");
        vm.prank(deployer);
        Bridge b = new Bridge(address(usdt0), address(routeRegistry), payable(address(cm)), initialAdapter, 1, 1);
        assertEq(b.lzAdapter(), initialAdapter, "lzAdapter set in constructor");
    }

    // ========================================================================
    // setLZAdapter
    // ========================================================================

    function test_setLZAdapter_rotatesToNonZero() public {
        address adapter = makeAddr("adapter");

        vm.expectEmit(true, true, false, true, address(bridge));
        emit LZAdapterUpdated(address(0), adapter);

        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        assertEq(bridge.lzAdapter(), adapter, "rotated");
    }

    function test_setLZAdapter_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidLZAdapter.selector);
        bridge.setLZAdapter(address(0));
    }

    function test_disableLZAdapter_clearsAndEmits() public {
        address adapter = makeAddr("adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);

        vm.expectEmit(true, false, false, false, address(bridge));
        emit LZAdapterDisabled(adapter);

        vm.prank(multisig);
        bridge.disableLZAdapter();
        assertEq(bridge.lzAdapter(), address(0), "disabled");
    }

    function test_disableLZAdapter_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.disableLZAdapter();
    }

    function test_setLZAdapter_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setLZAdapter(makeAddr("adapter"));
    }

    // ========================================================================
    // setRouteRegistry (new in PR6)
    // ========================================================================

    function test_setRouteRegistry_ownerCanRotate() public {
        // Deploy a NEW registry paired with the same Bridge (the documented
        // invariant). In production the new registry must already be wired
        // with this Bridge as its `bridge_` immutable.
        RouteRegistry newReg = new RouteRegistry(address(bridge), multisig);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit RouteRegistryUpdated(address(routeRegistry), address(newReg));

        vm.prank(multisig);
        bridge.setRouteRegistry(address(newReg));
        assertEq(bridge.routeRegistry(), address(newReg));
    }

    function test_setRouteRegistry_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidRouteRegistryAddress.selector);
        bridge.setRouteRegistry(address(0));
    }

    function test_setRouteRegistry_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setRouteRegistry(makeAddr("newReg"));
    }

    // ========================================================================
    // Minimum fundsIn amount + zero-amount guards
    //
    // `minFundsInAmount` is a non-zero floor enforced on the inbound path: it
    // rejects zero-amount deposits and dust whose commission would round to
    // zero. `fundsOut` is an authorized release and only rejects amount == 0.
    // The harness deploys with the smallest floor (1), so
    // tests that need a higher floor raise it via `setMinFundsInAmount`.
    // ========================================================================

    function test_constructor_storesMinFundsInAmount() public {
        vm.prank(deployer);
        Bridge b = new Bridge(address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1234, 1);
        assertEq(b.minFundsInAmount(), 1234, "minFundsInAmount stored from constructor");
    }

    function test_constructor_revertsOnZeroMinFundsInAmount() public {
        vm.expectRevert(IBridge.InvalidMinFundsInAmount.selector);
        new Bridge(address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 0, 1);
    }

    function test_setMinFundsInAmount_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(bridge));
        emit MinFundsInAmountUpdated(1, 1000);

        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);
        assertEq(bridge.minFundsInAmount(), 1000);
    }

    function test_setMinFundsInAmount_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidMinFundsInAmount.selector);
        bridge.setMinFundsInAmount(0);
    }

    function test_setMinFundsInAmount_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setMinFundsInAmount(1000);
    }

    // --- Minimum fundsOut amount (outbound mirror) ---

    function test_constructor_storesMinFundsOutAmount() public {
        vm.prank(deployer);
        Bridge b = new Bridge(address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1, 4321);
        assertEq(b.minFundsOutAmount(), 4321, "minFundsOutAmount stored from constructor");
    }

    function test_constructor_revertsOnZeroMinFundsOutAmount() public {
        vm.expectRevert(IBridge.InvalidMinFundsOutAmount.selector);
        new Bridge(address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1, 0);
    }

    function test_setMinFundsOutAmount_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(bridge));
        emit MinFundsOutAmountUpdated(1, 2000);

        vm.prank(multisig);
        bridge.setMinFundsOutAmount(2000);
        assertEq(bridge.minFundsOutAmount(), 2000);
    }

    function test_setMinFundsOutAmount_revertsOnZero() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidMinFundsOutAmount.selector);
        bridge.setMinFundsOutAmount(0);
    }

    function test_setMinFundsOutAmount_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setMinFundsOutAmount(2000);
    }

    /// @dev The floor is an on-chain backstop for a limit the TEE is not known
    ///      to enforce: a dust release costs the bridge more to settle than it
    ///      moves.
    function test_fundsOut_revertsBelowMinFundsOutAmount() public {
        _seedRGB(1000 ether);

        vm.prank(multisig);
        bridge.setMinFundsOutAmount(1 ether);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, 1 ether - 1, 1 ether));
        _releaseRGB(1 ether - 1, BURN_ID);
    }

    function test_fundsOut_acceptsExactlyMinFundsOutAmount() public {
        _seedRGB(1000 ether);

        vm.prank(multisig);
        bridge.setMinFundsOutAmount(1 ether);

        uint256 before = usdt0.balanceOf(recipient);
        _releaseRGB(1 ether, BURN_ID);
        assertEq(usdt0.balanceOf(recipient) - before, 1 ether, "release at the floor goes through");
    }

    /// @dev End-to-end mirror of the inbound flat-fee case: a `FUNDS_OUT` rule
    ///      with a `baseFee` deducts percentage + flat from the release and
    ///      forwards both to the CommissionManager pool.
    function test_fundsOut_baseFeeRoutesToCMOnTopOfPercentage() public {
        _seedRGB(1000 ether);

        uint256 percent = 400; // 4%
        uint256 baseFee = 1 ether;

        // The flat fee must fit under the release floor.
        vm.prank(multisig);
        bridge.setMinFundsOutAmount(10 ether);

        vm.prank(deployer);
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                baseFee: baseFee,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        uint256 release = 100 ether;
        uint256 expectedCommission = (release * percent) / 100 / 100 + baseFee;

        uint256 recipientBefore = usdt0.balanceOf(recipient);
        uint256 poolBefore = cm.tokenCommissionPool(address(usdt0));

        _releaseRGB(release, BURN_ID);

        assertEq(usdt0.balanceOf(recipient) - recipientBefore, release - expectedCommission, "recipient gets net");
        assertEq(
            cm.tokenCommissionPool(address(usdt0)) - poolBefore, expectedCommission, "pool holds percentage + flat"
        );
    }

    // --- Zero amount ---

    function test_fundsIn_revertsOnZeroAmount() public {
        // Floor is 1 (setUp), so a zero deposit is below the minimum.
        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(0), uint256(1)));
        vm.prank(user);
        bridge.fundsIn(0, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsOut_revertsOnZeroAmount() public {
        // fundsOut has no minimum — only the zero-amount no-op guard, which
        // fires before the burn-id and balance checks.
        vm.expectRevert(IBridge.ZeroAmount.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient, 0, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(new bytes32[](0))
        );
    }

    // --- Dust / below-minimum on the inbound path ---

    function test_fundsIn_revertsBelowMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(999), uint256(1000)));
        vm.prank(user);
        bridge.fundsIn(999, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_acceptsExactlyAtMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(1000, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), 1000, "deposit at the floor is accepted");
    }

    function test_fundsIn_acceptsAboveMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(1001, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), 1001, "deposit above the floor is accepted");
    }

    function test_fundsIn_dustThatRoundsCommissionToZeroIsRejected() public {
        // 4% token commission. Below 25 units the fee floors to zero
        // (24 * 400 / 100 / 100 == 0). The effective fee policy itself rejects
        // that dust, independently
        // of the separately configurable global minimum.
        _setFundsInTokenRule(400);

        assertEq(cm.calculateStableFee(24, 400, 100), 0, "sanity: 24 pays zero commission");

        vm.expectRevert(
            abi.encodeWithSelector(
                ICommissionManager.CommissionRoundsToZero.selector, uint256(24), uint256(400), uint8(100)
            )
        );
        vm.prank(user);
        bridge.fundsIn(24, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // The smallest amount that produces one fee unit is accepted.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(25, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), 24, "net = 25 - 1 commission");
    }

    function test_fundsOutDustThatRoundsCommissionToZeroIsRejected() public {
        uint256 dustAmount = 24;
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(dustAmount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(dustAmount);
        _setFundsOutTokenRule(400);

        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(_ids(opId), _one(dustAmount));
        uint256 burnId =
            _deriveBurnId(recipient, dustAmount, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICommissionManager.CommissionRoundsToZero.selector, dustAmount, uint256(400), uint8(100)
            )
        );
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, dustAmount, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData
        );

        assertFalse(bridge.consumedBurnIds(burnId), "reverted release does not consume burn id");
    }

    function test_fundsInFromAdapter_revertsBelowMinimum() public {
        // The adapter overload shares `_fundsIn`, so the floor applies there too.
        address mockAdapter = makeAddr("mock-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(mockAdapter);
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        usdt0.mint(mockAdapter, 999);
        vm.prank(mockAdapter);
        usdt0.approve(address(bridge), 999);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(999), uint256(1000)));
        vm.prank(mockAdapter);
        bridge.fundsIn(999, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_revertsOnDestinationAddressTooLong() public {
        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        string memory tooLong = _str(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AddressTooLong.selector, max + 1, max));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, tooLong, _rgbData());
    }

    function test_fundsIn_acceptsDestinationAddressAtMaxLength() public {
        uint256 max = bridge.MAX_ADDRESS_LENGTH();

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, _str(max), _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "deposit at the address-length cap is accepted");
    }

    function test_fundsIn_revertsOnSettlementDataTooLong() public {
        uint256 max = bridge.MAX_SETTLEMENT_DATA_LENGTH();
        bytes memory tooLong = _bytesOfLength(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.SettlementDataTooLong.selector, max + 1, max));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, tooLong);
    }

    function test_fundsIn_acceptsSettlementDataAtMaxLength() public {
        // The length guard lives in Bridge, ahead of the route module. A
        // maximal-length blob still decodes as a non-zero RGB OpId (the first
        // 32 bytes read as uint256), so the deposit clears the guard and
        // records normally under the bridge-derived operationId.
        uint256 max = bridge.MAX_SETTLEMENT_DATA_LENGTH();
        bytes memory atMax = _bytesOfLength(max);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, atMax);
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "deposit at the settlement-data cap is accepted");
    }

    function test_fundsOut_revertsOnSettlementDataTooLong() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 max = bridge.MAX_SETTLEMENT_DATA_LENGTH();
        bytes memory tooLong = _bytesOfLength(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.SettlementDataTooLong.selector, max + 1, max));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), tooLong);
    }

    function test_fundsOut_acceptsSettlementDataAtMaxLength() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // settlementData at the exact cap clears the length guard. The arbitrary
        // blob does not decode as a valid (bytes32[], uint256[]) settlement
        // encoding, so it reverts later (or on the unrelated burnId check) — the
        // guard is isolated by asserting the revert is NOT SettlementDataTooLong.
        uint256 max = bridge.MAX_SETTLEMENT_DATA_LENGTH();
        bytes memory atMax = _bytesOfLength(max);

        vm.prank(multisig);
        try bridge.fundsOut(
            IBridge.FundsOutParams(recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), atMax)
        ) {
        // a valid settlement blob would succeed; this one won't, but if it
        // did the length guard still passed — which is what we assert.
        }
        catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel != IBridge.SettlementDataTooLong.selector, "max-length settlementData must clear the length guard"
            );
        }
    }

    function test_fundsOut_revertsOnSourceAddressTooLong() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        string memory tooLong = _str(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AddressTooLong.selector, max + 1, max));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, tooLong, _proof(), _settlement(_ids(opId)));
    }

    function test_fundsOut_acceptsSourceAddressAtMaxLength() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        uint256 max = bridge.MAX_ADDRESS_LENGTH();

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, _str(max), _proof(), _settlement(_ids(opId))
        );
        assertEq(usdt0.balanceOf(recipient), AMOUNT, "release with sourceAddress at the cap succeeds");
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

    function test_fundsOut_revertsOnProofTooLong() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 max = bridge.MAX_PROOF_LENGTH();
        bytes memory tooLong = _bytesOfLength(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.ProofTooLong.selector, max + 1, max));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, tooLong, _settlement(_ids(opId)));
    }

    function test_fundsOut_acceptsProofAtMaxLength() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // A proof at the exact cap passes the length guard. It then reverts in
        // the verifier (the blob is not a valid (height, commitment) pair), so
        // the cap check is isolated by asserting it is NOT ProofTooLong: the
        // call reaches the verifier instead.
        uint256 max = bridge.MAX_PROOF_LENGTH();
        bytes memory atMax = _bytesOfLength(max);
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, atMax, settlementData);

        vm.prank(multisig);
        try bridge.fundsOut(
            IBridge.FundsOutParams(
                recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, atMax, settlementData
            )
        ) {
        // a decodable proof would succeed; this blob won't, so we don't
        // expect to land here — but if a future verifier accepts it, the
        // length guard still passed, which is what this test asserts.
        }
        catch (bytes memory reason) {
            // Must NOT be the length guard — proving max-length passes it.
            bytes4 sel = bytes4(reason);
            assertTrue(sel != IBridge.ProofTooLong.selector, "max-length proof must clear the length guard");
        }
    }

    function test_fundsOut_acceptsRealProofUnderCap() public {
        // The production-shaped 64-byte RGB proof is well under the cap and the
        // happy path still succeeds.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        assertLt(_proof().length, bridge.MAX_PROOF_LENGTH(), "sanity: real proof under cap");

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );
        assertEq(usdt0.balanceOf(recipient), AMOUNT, "release with a normal proof succeeds");
    }

    // ========================================================================
    // fundsIn — adapter overload (`onlyLZAdapter`)
    // ========================================================================

    function test_fundsInFromAdapter_revertsIfCallerIsNotLZAdapter() public {
        // No adapter set in setUp — caller is `user`.
        vm.prank(user);
        vm.expectRevert(IBridge.NotLZAdapter.selector);
        bridge.fundsIn(AMOUNT, 1, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsInFromAdapter_acceptsCustomSourceChainId() public {
        address mockAdapter = makeAddr("mock-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(mockAdapter);

        usdt0.mint(mockAdapter, AMOUNT);
        vm.prank(mockAdapter);
        usdt0.approve(address(bridge), AMOUNT);

        uint256 customSrc = 137; // pretend Polygon
        bytes32 sourceSender = bytes32(uint256(uint160(user))); // authenticated far-chain sender

        // Register a route for the custom (Polygon, RGB) pair — the adapter
        // overload simply forwards whatever sourceChainId the composeMsg
        // carries; both directions need real routes wired in the registry.
        vm.prank(deployer);
        routeRegistry.setRoute(customSrc, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // The nonce for this (sourceChainId, sourceSender) starts at 0.
        bytes32 expectedOpId = _deriveOpId(customSrc, sourceSender, 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // Drop the emitter filter so Forge's expectEmit scans past the token's
        // Transfer event (emitter = usdt0) and matches BridgeFundsIn by topic0.
        // FundsIn (RGB route) carries the rgbOpId; sender = the adapter.
        vm.expectEmit(true, true, false, true);
        emit FundsIn(mockAdapter, RGB_OP_ID, AMOUNT);
        vm.expectEmit(true, true, true, true);
        emit BridgeFundsIn(
            expectedOpId, sourceSender, mockAdapter, 0, AMOUNT, AMOUNT, 0, 0, customSrc, RGB_CHAIN_ID, DST_ADDR
        );

        vm.prank(mockAdapter);
        bytes32 opId = bridge.fundsIn(AMOUNT, customSrc, sourceSender, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(opId, expectedOpId, "returned id matches derivation");
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "record stored on module");
    }

    // ========================================================================
    // fundsIn — happy path (zero commission default)
    // ========================================================================

    function test_fundsIn_transfersTokens() public {
        uint256 userBefore = usdt0.balanceOf(user);

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
        assertEq(usdt0.balanceOf(user), userBefore - AMOUNT);
    }

    function test_fundsIn_storesRecordOnModule() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(rgbModule.fundsInRecords(opId), AMOUNT);
    }

    function test_fundsIn_emitsBothEvents() public {
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        bytes32 expectedOpId = _deriveOpId(SOURCE_CHAIN_ID, sourceSender, 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.expectEmit(true, true, false, true);
        emit FundsIn(user, RGB_OP_ID, AMOUNT);
        vm.expectEmit(true, true, true, true);
        emit BridgeFundsIn(
            expectedOpId, sourceSender, user, 0, AMOUNT, AMOUNT, 0, 0, SOURCE_CHAIN_ID, RGB_CHAIN_ID, DST_ADDR
        );

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_anyUserCanCall() public {
        address stranger = makeAddr("stranger");
        usdt0.mint(stranger, AMOUNT);
        vm.prank(stranger);
        usdt0.approve(address(bridge), AMOUNT);

        vm.prank(stranger);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
    }

    // ========================================================================
    // fundsIn — reverts
    // ========================================================================

    function test_fundsIn_revertsOnEmptyDestinationAddress() public {
        vm.expectRevert(IBridge.InvalidDestinationAddress.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, "", _rgbData());
    }

    function test_fundsIn_revertsOnEmptyDestinationChain() public {
        vm.expectRevert(IBridge.InvalidDestinationChainId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, 0, DST_ADDR, _rgbData());
    }

    function test_fundsIn_revertsWhenPaused() public {
        vm.prank(multisig);
        bridge.pauseInflow();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    // The operationId is derived on-chain with a per-sender nonce, so two
    // identical deposits from the same sender get DISTINCT ids and
    // both succeed — the caller can no longer force a DuplicateOperationId by
    // replaying params. The duplicate guard is exercised directly at the module
    // level (RgbSettlementModule.t.sol) instead.
    function test_fundsIn_repeatedDepositsDoNotCollide() public {
        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(opId1 != opId2, "nonce makes identical deposits distinct");
        assertEq(rgbModule.fundsInRecords(opId1), AMOUNT, "first record");
        assertEq(rgbModule.fundsInRecords(opId2), AMOUNT, "second record");
    }

    // ========================================================================
    // fundsOut — happy path
    // ========================================================================

    function test_fundsOut_transfersAndEmits() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        vm.expectEmit(true, true, false, true);
        emit BridgeFundsOut(recipient, AMOUNT, AMOUNT, 0, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR);

        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertEq(usdt0.balanceOf(recipient), AMOUNT);
        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT * 9, "90% configured bucket reserve remains");
    }

    function test_fundsOut_keepsRecordAfterRelease() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );

        // The mint ledger is permanent (proof-of-mint), not a consumable balance.
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "record unchanged after release");
    }

    function test_fundsOut_multipleFundsInIds() public {
        uint256 amount1 = 60e18;
        uint256 amount2 = 40e18;

        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(amount1, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(amount2, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));
        _ensureRgbSafetyCapacity(amount1 + amount2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = opId1;
        ids[1] = opId2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount1;
        amounts[1] = amount2;

        vm.prank(multisig);
        _fundsOut(
            recipient,
            amount1 + amount2,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(ids, amounts)
        );

        assertEq(usdt0.balanceOf(recipient), amount1 + amount2);
        // Records are a permanent proof-of-mint ledger — not consumed on release.
        assertEq(rgbModule.fundsInRecords(opId1), amount1, "record 1 unchanged");
        assertEq(rgbModule.fundsInRecords(opId2), amount2, "record 2 unchanged");
    }

    // ========================================================================
    // fundsOut — verifier reverts
    // ========================================================================

    function test_fundsOut_revertsOnUnverifiedBlock() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        // Well-formed two-pair proof, but the source block is unknown to the relay.
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown-block"), LATEST_HEIGHT, LATEST_COMMIT);

        // RGBVerifier → BtcRelay reverts with the relay's string message.
        vm.expectRevert("verify: block commitment");
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, badProof, _settlement(_ids(opId))
        );
    }

    // ========================================================================
    // fundsOut — settlement-module reverts (delegated to RgbSettlementModule
    // but surfaced through Bridge)
    // ========================================================================

    function test_fundsOutRejectsEmptySettlementRecords() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(new bytes32[](0), new uint256[](0));
        uint256 burnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);

        vm.expectRevert(RgbSettlementModule.EmptySettlementRecords.selector);
        vm.prank(multisig);
        _fundsOutWithBurnId(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "reverted release does not consume burn id");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore, "reverted release does not debit liquidity");
        assertEq(usdt0.balanceOf(recipient), 0, "reverted release transfers no tokens");
    }

    function test_fundsOut_revertsOnUnknownFundsInId() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes32 unknown = bytes32(uint256(999));
        bytes32[] memory ids = _ids(unknown);

        vm.expectRevert(abi.encodeWithSelector(RgbSettlementModule.FundsInNotFound.selector, unknown));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(ids));
    }

    function test_fundsOut_revertsOnAmountMismatch() public {
        // Record a mint of 50e18, then claim it for a different amount in
        // settlementData. The module binds operationId → exact mint amount, so
        // the mismatch must revert (surfaced through the Bridge).
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(50e18, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(50e18);

        bytes32[] memory ids = _ids(opId);
        uint256[] memory amounts = _one(60e18); // != recorded 50e18

        vm.expectRevert(
            abi.encodeWithSelector(RgbSettlementModule.AmountMismatch.selector, opId, uint256(60e18), uint256(50e18))
        );
        vm.prank(multisig);
        _fundsOut(
            recipient,
            50e18,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(ids, amounts)
        );
    }

    function test_fundsOut_revertsOnReplayedBurnId() public {
        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));
        _ensureRgbSafetyCapacity(AMOUNT);

        bytes32[] memory ids1 = _ids(opId1);
        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(ids1);
        uint256 burnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        assertTrue(bridge.consumedBurnIds(burnId), "burnId recorded");

        // Second fundsOut with the same burnId — must revert before any
        // module mutation, leaving the second record untouched.
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, burnId));
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        assertEq(rgbModule.fundsInRecords(opId2), AMOUNT, "second fundsIn record preserved");
    }

    function test_fundsOut_revertsOnInvalidDerivedBurnId() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 expectedBurnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        uint256 invalidBurnId = expectedBurnId ^ 1;

        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, invalidBurnId, expectedBurnId));
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, invalidBurnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData
        );

        assertFalse(bridge.consumedBurnIds(expectedBurnId), "expected burn id unchanged");
        assertFalse(bridge.consumedBurnIds(invalidBurnId), "invalid burn id unchanged");
    }

    function test_fundsOut_revertsWhenProofChangesAfterBurnIdDerivation() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        bytes memory signedProof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 signedBurnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, signedProof, settlementData);

        bytes memory changedProof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, keccak256("changed-proof"));
        uint256 expectedBurnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, changedProof, settlementData);

        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, signedBurnId, expectedBurnId));
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, signedBurnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, changedProof, settlementData
        );

        assertFalse(bridge.consumedBurnIds(signedBurnId), "signed burn id unchanged");
    }

    function test_fundsOut_revertsWhenSettlementDataChangesAfterBurnIdDerivation() public {
        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));

        bytes memory proof = _proof();
        bytes memory signedSettlementData = _settlement(_ids(opId1));
        bytes memory changedSettlementData = _settlement(_ids(opId2));
        uint256 signedBurnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, signedSettlementData);
        uint256 expectedBurnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, changedSettlementData);

        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, signedBurnId, expectedBurnId));
        vm.prank(multisig);
        _fundsOutWithBurnId(
            recipient, AMOUNT, signedBurnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, changedSettlementData
        );

        assertFalse(bridge.consumedBurnIds(signedBurnId), "signed burn id unchanged");
        assertEq(rgbModule.fundsInRecords(opId1), AMOUNT, "first record unchanged");
        assertEq(rgbModule.fundsInRecords(opId2), AMOUNT, "second record unchanged");
    }

    function test_fundsOut_reusedPermanentRecordCannotExceedRollingLimit() public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );

        // The settlement module no longer consumes records (the mint proof is
        // permanent and may back another distinct burn intent), so let the
        // configurable bucket refill while the first spend remains inside the
        // rolling window.
        bytes32 altLatestCommit = keccak256("test-btc-alt-latest-commitment");
        btcRelay.setBlock(LATEST_HEIGHT + 1, altLatestCommit, LATEST_CONFIRMATIONS);
        bytes memory altProof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT + 1, altLatestCommit);

        vm.warp(block.timestamp + bridge.BUCKET_REFILL_WINDOW() + 1);
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID + 1, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, altProof, _settlement(_ids(opId))
        );

        // Two 10% bucket bursts have now consumed the immutable 20% allowance.
        // A third distinct intent cannot reuse the permanent proof to move more.
        vm.warp(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBridge.ChainSafetyLimitExceeded.selector, RGB_CHAIN_ID, uint256(1), AMOUNT * 2, AMOUNT * 2
            )
        );
        vm.prank(multisig);
        _fundsOut(recipient, 1, BURN_ID + 1, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, altProof, _settlement(_ids(opId)));
    }

    // ========================================================================
    // Isolated liquidity
    //
    // fundsIn credits lockedLiquidity[destinationChainId] by netAmount; fundsOut
    // debits lockedLiquidity[sourceChainId] by gross amount. A release can never
    // draw more than was bridged toward that chain, and one chain's bucket can
    // never be drained from another chain's release.
    // ========================================================================

    function test_isolatedLiquidity_fundsInCreditsNetAmount() public {
        // No commission in setUp → net == gross.
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT, "bucket credited net amount");
    }

    function test_isolatedLiquidity_tokenCommissionCreditsNetNotGross() public {
        _setFundsInTokenRule(400); // 4%
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 fee = cm.calculateStableFee(AMOUNT, 400, 100);
        assertGt(fee, 0, "sanity: positive fee");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT - fee, "bucket credits net, not gross");
    }

    function test_isolatedLiquidity_fundsOutDebitsGrossAmount() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        uint256 release = 40e18;
        _ensureRgbSafetyCapacity(release);
        uint256 liquidityBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            release,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(_ids(opId)) // settlement amount = recorded AMOUNT
        );
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), liquidityBefore - release, "bucket debited by gross release");
    }

    function test_isolatedLiquidity_chainCannotConsumeAnotherChainsLiquidity() public {
        // Fund only the RGB bucket.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // A different source chain has no isolated liquidity. This guard runs
        // before its bucket, so the missing liquidity is the precise blocker.
        uint256 otherChain = 777;
        vm.prank(deployer);
        routeRegistry.setRoute(otherChain, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // Bridge holds AMOUNT (from the RGB deposit), but it is locked for RGB,
        // not for `otherChain`. The release must fail on isolated liquidity.
        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT, "pool has balance");
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.InsufficientChainLiquidity.selector, otherChain, AMOUNT, uint256(0))
        );
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, BURN_ID, otherChain, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId)));
    }

    function test_isolatedLiquidity_revertRollsBackDebit() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // Bad proof → verifier reverts downstream of the liquidity debit.
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown"));
        vm.expectRevert();
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, badProof, _settlement(_ids(opId))
        );
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT, "debit rolled back on revert");
    }

    /// @dev Fuzz the interaction between isolated liquidity and the immutable
    ///      rolling ceiling: overdraw still fails on isolated liquidity, while
    ///      a full-bucket release fails and a release inside both limits
    ///      succeeds.
    function testFuzz_isolatedLiquidity_andSafetyLimit(uint256 amount) public {
        // Bound to the user's funded balance and above the dust floor; no
        // commission in setUp so net == gross.
        amount = bound(amount, 1 ether, AMOUNT * 10);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), amount, "credited");

        // Mint an unlocked buffer so the pool balance exceeds the locked amount;
        // this isolates the per-chain liquidity guard from the raw balance guard
        // (a direct mint does not credit lockedLiquidity).
        usdt0.mint(address(bridge), amount + 1);

        // One unit over the locked amount reverts on the per-chain liquidity guard.
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.InsufficientChainLiquidity.selector, RGB_CHAIN_ID, amount + 1, amount)
        );
        vm.prank(multisig);
        _fundsOut(
            recipient,
            amount + 1,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(_ids(opId), _one(amount))
        );

        // Releasing the whole chain balance is 100% of the reference, i.e. one
        // full SHARE_UNIT, against the configured 10% burst capacity.
        _configureMaxSafeBuckets();
        uint256 shareUnit = bridge.SHARE_UNIT();
        uint256 bucketLimit = amount * MAX_BURST_BPS / bridge.BPS_DENOMINATOR();
        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.TokenRequestAboveCapacity.selector,
                MAX_BURST_BPS * shareUnit / bridge.BPS_DENOMINATOR(),
                shareUnit,
                address(usdt0)
            )
        );
        vm.prank(multisig);
        _fundsOut(
            recipient,
            amount,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(_ids(opId), _one(amount))
        );

        vm.prank(multisig);
        _fundsOut(
            recipient,
            bucketLimit,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(_ids(opId), _one(amount))
        );
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), amount - bucketLimit, "configured 10% burst debited");
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

    function test_outflow_fullBucketAllowsCapacityRejectsOverByOne() public {
        _seedRGB(1000 ether);
        uint256 cap = 100 ether;
        _setRGBBucket(cap, cap); // reconfig down → available == cap

        _releaseRGB(cap, BURN_ID);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "capacity fully spent");

        // One unit over the (now empty) bucket but still within capacity → rate-limited.
        vm.expectPartialRevert(OutflowRateLimiter.TokenOutflowThrottled.selector);
        _releaseRGB(1, BURN_ID + 1);
    }

    function test_outflow_releaseAboveCapacityReverts() public {
        _seedRGB(1000 ether);
        uint256 cap = 100 ether;
        _setRGBBucket(cap, cap);

        // Full bucket, but the request exceeds capacity entirely → a different,
        // more-specific error than the rate-limit one.
        vm.expectPartialRevert(OutflowRateLimiter.TokenRequestAboveCapacity.selector);
        _releaseRGB(cap + 1, BURN_ID);
    }

    function test_outflow_refillAccruesOverTime() public {
        _seedRGB(1000 ether);
        uint256 cap = 100 ether;
        _setRGBBucket(cap, cap);

        _releaseRGB(cap, BURN_ID);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "drained");

        // `cap` is restored over one full BUCKET_REFILL_WINDOW, so half a window
        // accrues half of it (to within the per-second share truncation).
        vm.warp(block.timestamp + 12 hours);
        uint256 refilled = bridge.availableOutflow(RGB_CHAIN_ID);
        assertApproxEqRel(refilled, cap / 2, 1e12, "partial linear refill"); // 1e-6 relative

        _releaseRGB(refilled - 1, BURN_ID + 1); // the refilled allowance is spendable
    }

    function test_outflow_noDoubleCapBurstOverShortGap() public {
        _seedRGB(1000 ether);
        uint256 cap = 100 ether;
        _setRGBBucket(cap, cap);

        _releaseRGB(cap, BURN_ID);
        vm.warp(block.timestamp + 1); // one second later

        uint256 accrued = bridge.availableOutflow(RGB_CHAIN_ID);
        assertApproxEqRel(accrued, cap / (24 hours), 1e12, "only one second of refill accrued");
        assertLt(accrued, cap, "not a fresh cap");
        bytes32 altLatestCommit = keccak256("test-btc-short-gap-latest-commitment");
        btcRelay.setBlock(LATEST_HEIGHT + 1, altLatestCommit, LATEST_CONFIRMATIONS);
        bytes memory altProof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT + 1, altLatestCommit);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = _seedOpId;

        vm.expectPartialRevert(OutflowRateLimiter.TokenOutflowThrottled.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            cap,
            BURN_ID + 1,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            altProof,
            _settlementWithAmounts(ids, _one(_seedAmt))
        );
    }

    function test_outflow_perChainIsolation() public {
        uint256 other = 888;
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, other, true, address(rgbVerifier), address(rgbModule));
        vm.prank(deployer);
        routeRegistry.setRoute(other, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        usdt0.mint(user, 500 ether);
        vm.prank(user);
        bridge.fundsIn(500 ether, other, DST_ADDR, _rgbData(RGB_OP_ID + 888));

        uint256 otherBps = _bpsOfChain(other, 50 ether);
        vm.prank(multisig);
        bridge.setOutflowLimit(other, otherBps, otherBps);

        _seedRGB(1000 ether);
        _setRGBBucket(100 ether, 100 ether);
        _releaseRGB(100 ether, BURN_ID); // drain RGB bucket to 0

        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "RGB drained");
        assertEq(bridge.availableOutflow(other), 50 ether, "other chain bucket untouched");
    }

    function test_outflow_globalBucketBoundsAggregate() public {
        _seedRGB(1000 ether);
        // Keep the per-chain bucket large; tighten only the global bucket.
        uint256 globalBps = _bpsOfGlobal(100 ether);
        vm.prank(multisig);
        bridge.setGlobalOutflowLimit(globalBps, globalBps);

        _releaseRGB(100 ether, BURN_ID); // consumes the whole global allowance
        assertEq(bridge.availableGlobalOutflow(), 0, "global drained");

        // The per-chain bucket still has room, but the global aggregate trips.
        vm.expectPartialRevert(OutflowRateLimiter.AggregateOutflowThrottled.selector);
        _releaseRGB(1, BURN_ID + 1);
    }

    function test_outflow_reconfigPreservesAvailableNoGift() public {
        _seedRGB(1000 ether);
        _setRGBBucket(100 ether, 100 ether);
        _releaseRGB(60 ether, BURN_ID); // available 40 ether
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 40 ether, "pre");

        // Raising capacity must NOT gift a fresh full bucket.
        _setRGBBucket(200 ether, 200 ether);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 40 ether, "available preserved, not gifted");
    }

    function test_outflow_reconfigClampsOnDecrease() public {
        _seedRGB(1_000 ether);
        _setRGBBucket(100 ether, 100 ether); // available 100 ether
        _setRGBBucket(30 ether, 30 ether); // clamp down
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 30 ether, "clamped to new capacity");
    }

    function test_outflow_failsClosedWhenChainBucketUnconfigured() public {
        uint256 unconfigured = 999;
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, unconfigured, true, address(rgbVerifier), address(rgbModule));
        vm.prank(deployer);
        routeRegistry.setRoute(unconfigured, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // Fund the unconfigured chain's isolated liquidity so only the missing
        // (disabled) bucket blocks the release.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(100 ether, unconfigured, DST_ADDR, _rgbData());

        bytes32[] memory ids = _ids(opId);
        vm.expectRevert(OutflowRateLimiter.LimitNotConfigured.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            100 ether,
            BURN_ID,
            unconfigured,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlementWithAmounts(ids, _one(100 ether))
        );
    }

    function test_outflow_downstreamRevertRestoresBuckets() public {
        _seedRGB(1000 ether);
        _setRGBBucket(100 ether, 100 ether);

        uint256 globalBefore = bridge.availableGlobalOutflow();
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown"));
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = _seedOpId;

        vm.expectRevert();
        vm.prank(multisig);
        _fundsOut(
            recipient,
            50 ether,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            badProof,
            _settlementWithAmounts(ids, _one(_seedAmt))
        );

        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 100 ether, "per-chain restored");
        assertEq(bridge.availableGlobalOutflow(), globalBefore, "global restored");
    }

    // ========================================================================
    // Immutable TVL-relative rolling safety limit
    // ========================================================================

    function test_usageCannotExpireBefore24Hours_andNewLimitUsesLowerTVL() public {
        // Align to a ring slot boundary so expiry happens exactly at H+25.
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);
        uint256 bucketBurst = 100 ether;
        _seedRGB(bucketBurst); // deposits 1000 ether; bucket 10%, hard limit 20%

        assertEq(bridge.totalLockedLiquidity(), 1_000 ether);
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 200 ether);
        assertEq(bridge.availableGlobalSafetyOutflow(), 200 ether);

        _releaseRGBTo(makeAddr("rolling-window-first"), bucketBurst, BURN_ID);
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 100 ether);
        assertEq(bridge.availableGlobalSafetyOutflow(), 100 ether);

        // Hour-slot rounding is deliberately conservative: usage is still
        // counted at exactly 24 hours, preventing a boundary double-spend.
        vm.warp(block.timestamp + bridge.OUTFLOW_SAFETY_WINDOW());
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 100 ether);
        assertEq(bridge.availableGlobalSafetyOutflow(), 100 ether);

        // One extra second fully restores the slightly conservative, integer-
        // rounded bucket refill while the first rolling-window spend remains.
        vm.warp(block.timestamp + 1);
        _releaseRGBTo(makeAddr("rolling-window-second"), bucketBurst, BURN_ID + 1);
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 0);
        assertEq(bridge.availableGlobalSafetyOutflow(), 0);

        // At H+25 the first spend expires but the second remains. Reference is
        // remaining liquidity (800) plus still-counted spend (100) = 900, so the
        // new 20% limit is 180 with 100 already consumed: 80 remains.
        vm.warp(block.timestamp + 1 hours - 1);
        uint256 nextWindowLimit = 80 ether;
        assertEq(bridge.chainOutflowReference(RGB_CHAIN_ID), 900 ether, "reference follows rolling lower TVL");
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), nextWindowLimit);
        assertEq(bridge.availableGlobalSafetyOutflow(), nextWindowLimit);

        // Liveness: after the second spend also expires, the bucket has refilled
        // and a new 10%-of-current-liquidity tranche can leave.
        vm.warp(block.timestamp + bridge.OUTFLOW_SAFETY_WINDOW());
        assertEq(bridge.chainOutflowReference(RGB_CHAIN_ID), 800 ether);
        assertEq(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), nextWindowLimit);
        _releaseRGBTo(makeAddr("rolling-window-third"), nextWindowLimit, BURN_ID + 2);
        assertEq(bridge.totalLockedLiquidity(), 720 ether);
    }

    function test_directTokenDonationCannotInflateGlobalSafetyAllowance() public {
        _seedRGB(100 ether); // accounted TVL 1000 ether; global hard limit 200
        uint256 beforeAllowance = bridge.availableGlobalSafetyOutflow();

        usdt0.mint(address(bridge), 10_000 ether);

        assertEq(bridge.totalLockedLiquidity(), 1_000 ether, "donation excluded from accounted TVL");
        assertEq(
            bridge.availableGlobalSafetyOutflow(),
            beforeAllowance,
            "unaccounted token donation cannot increase the security allowance"
        );
    }

    /// @dev However the attacker splits the drain, the total leaving inside one
    ///      rolling window never exceeds 20% of the window's reference. The two
    ///      parts are not required to sum to exactly the cap: converting each
    ///      release into shares rounds up, so splitting can cost a sub-share more
    ///      than one combined release. That is the conservative direction, and
    ///      the aggregate bound is what this asserts.
    function testFuzz_arbitrarySplitCannotExceedRollingLimit(uint96 firstPartSeed) public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);
        _seedRGB(100 ether); // chain liquidity 1000; bucket burst 100; hard limit 200
        uint256 poolBefore = usdt0.balanceOf(address(bridge));
        uint256 hardLimit = bridge.availableChainSafetyOutflow(RGB_CHAIN_ID); // 20% of reference
        uint256 initialBucketAllowance = bridge.effectiveAvailableOutflow(RGB_CHAIN_ID);

        uint256 firstPart = bound(uint256(firstPartSeed), 1, initialBucketAllowance);

        // Vary recipients so every split has a distinct canonical burn intent,
        // even when two fuzzed amounts happen to be equal.
        _releaseRGBTo(makeAddr("rolling-limit-first"), firstPart, BURN_ID);

        // The reference does not move inside the window, so the remaining
        // immutable allowance is exactly the complement of the first part.
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), hardLimit - firstPart, "complement remains");
        assertEq(bridge.availableGlobalSafetyOutflow(), hardLimit - firstPart, "global complement remains");

        // Refill the configurable bucket while the first spend is still inside
        // the conservative rolling window, then take everything still permitted.
        vm.warp(block.timestamp + bridge.BUCKET_REFILL_WINDOW() + 1);
        uint256 secondPart = bridge.effectiveAvailableOutflow(RGB_CHAIN_ID);
        if (secondPart != 0) _releaseRGBTo(makeAddr("rolling-limit-second"), secondPart, BURN_ID + 1);

        // However the drain is split, the pool never loses more than 20% of the
        // window's reference, and nothing further may leave.
        assertLe(firstPart + secondPart, hardLimit, "rolling cap never exceeded");
        assertEq(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), 0, "allowance exhausted");
        assertGe(usdt0.balanceOf(address(bridge)), poolBefore - hardLimit, "at least 80% of the pool remains");

        // Which layer refuses the next unit depends on where the sub-share
        // rounding lands, so that is asserted deterministically instead in
        // `test_usageCannotExpireBefore24Hours_andNewLimitUsesLowerTVL` (bucket)
        // and `MultisigProxy.t.sol::test_splitTransactions...` (immutable limiter).
    }

    /// @dev The global rolling window aggregates physical outflow from every
    ///      source chain. Two chains may each consume their own allowance, but
    ///      splitting a drain across chains cannot bypass the global accounting.
    function test_globalRollingUsageAggregatesAcrossSourceChains() public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);

        uint256 otherChain = 888;
        vm.startPrank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, otherChain, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(otherChain, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        vm.stopPrank();

        usdt0.mint(user, 1_000 ether);
        vm.prank(user);
        bytes32 otherOpId = bridge.fundsIn(1_000 ether, otherChain, DST_ADDR, _rgbData(RGB_OP_ID + otherChain));

        _seedRGB(100 ether); // 1000 RGB + 1000 other; 10% bucket bursts
        vm.prank(multisig);
        bridge.setOutflowLimit(otherChain, MAX_BURST_BPS, MAX_REFILL_BPS);

        assertEq(bridge.availableGlobalOutflow(), 200 ether, "global bucket is 10% of aggregate TVL");
        assertEq(bridge.availableGlobalSafetyOutflow(), 400 ether, "global hard cap is 20% of aggregate TVL");

        bytes32[] memory otherIds = _ids(otherOpId);
        bytes memory otherSettlement = _settlementWithAmounts(otherIds, _one(1_000 ether));

        _releaseRGBTo(makeAddr("aggregate-rgb-1"), 100 ether, BURN_ID);
        vm.prank(multisig);
        _fundsOut(
            makeAddr("aggregate-other-1"),
            100 ether,
            BURN_ID + 1,
            otherChain,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            otherSettlement
        );

        assertEq(bridge.availableGlobalOutflow(), 0, "both chains consume one global bucket");
        assertEq(bridge.availableGlobalSafetyOutflow(), 200 ether, "aggregate hard allowance tracks both chains");

        // Buckets refill after 24h, but the aligned rolling window retains both
        // first releases until H+25. A second 100 from each chain exhausts the
        // immutable aggregate and per-chain allowances without exceeding them.
        vm.warp(block.timestamp + bridge.BUCKET_REFILL_WINDOW() + 1);
        _releaseRGBTo(makeAddr("aggregate-rgb-2"), 100 ether, BURN_ID + 2);
        vm.prank(multisig);
        _fundsOut(
            makeAddr("aggregate-other-2"),
            100 ether,
            BURN_ID + 3,
            otherChain,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            otherSettlement
        );

        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 0, "RGB rolling allowance exhausted");
        assertEq(bridge.availableChainSafetyOutflow(otherChain), 0, "other rolling allowance exhausted");
        assertEq(bridge.availableGlobalSafetyOutflow(), 0, "aggregate rolling allowance exhausted");
        assertEq(bridge.totalLockedLiquidity(), 1_600 ether, "at most 20% of aggregate reference left the bridge");

        vm.warp(block.timestamp + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBridge.ChainSafetyLimitExceeded.selector,
                RGB_CHAIN_ID,
                uint256(1),
                uint256(200 ether),
                uint256(200 ether)
            )
        );
        _releaseRGBTo(makeAddr("aggregate-rgb-blocked"), 1, BURN_ID + 4);
    }

    function test_setOutflowLimit_revertsOnZeroChainId() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidOutflowLimit.selector);
        bridge.setOutflowLimit(0, 500, 1_500);
    }

    function test_setOutflowLimit_revertsOnZeroBurst() public {
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, uint256(0), uint256(1_500), uint256(2_000))
        );
        bridge.setOutflowLimit(RGB_CHAIN_ID, 0, 1_500);
    }

    function test_setOutflowLimit_revertsOnZeroRefill() public {
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, uint256(500), uint256(0), uint256(2_000))
        );
        bridge.setOutflowLimit(RGB_CHAIN_ID, 500, 0);
    }

    /// @dev The federation must not be able to configure a bucket that covers
    ///      TVL. `burstBps` is bounded by the immutable
    ///      `MAX_CHAIN_OUTFLOW_BPS`, so no policy authorises more than 20% of
    ///      reference liquidity in one release — at any liquidity level.
    function test_setOutflowLimit_rejectsBurstAboveImmutableCeiling() public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, maxBps + 1, uint256(1), maxBps));
        bridge.setOutflowLimit(RGB_CHAIN_ID, maxBps + 1, 1);
    }

    function test_setOutflowLimit_rejectsRefillAboveImmutableCeiling() public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, uint256(500), maxBps + 1, maxBps));
        bridge.setOutflowLimit(RGB_CHAIN_ID, 500, maxBps + 1);
    }

    /// @dev A policy whose combined burst and refill equals the immutable
    ///      ceiling is accepted.
    function test_setOutflowLimit_acceptsCombinedCeiling() public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();
        uint256 burstBps = 750;
        uint256 refillBps = maxBps - burstBps;

        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, refillBps);

        (,,, uint128 capacity,) = bridge.chainBuckets(RGB_CHAIN_ID);
        assertEq(capacity, burstBps * bridge.SHARE_UNIT() / bridge.BPS_DENOMINATOR(), "burst stored as shares");
    }

    function test_setOutflowLimit_rejectsCombinedPolicyAboveCeiling() public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();
        uint256 burstBps = 1_001;
        uint256 refillBps = 1_000;

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, burstBps, refillBps, maxBps));
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, refillBps);
    }

    function test_setOutflowLimit_rejectsFullTvlPolicy() public {
        uint256 denominator = bridge.BPS_DENOMINATOR();
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, denominator, denominator, maxBps));
        bridge.setOutflowLimit(RGB_CHAIN_ID, denominator, denominator);
    }

    function test_setGlobalOutflowLimit_rejectsFullTvlPolicy() public {
        uint256 denominator = bridge.BPS_DENOMINATOR();
        uint256 maxBps = bridge.MAX_GLOBAL_OUTFLOW_BPS();

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, denominator, uint256(1), maxBps));
        bridge.setGlobalOutflowLimit(denominator, 1);
    }

    function test_setGlobalOutflowLimit_rejectsCombinedPolicyAboveCeiling() public {
        uint256 maxBps = bridge.MAX_GLOBAL_OUTFLOW_BPS();
        uint256 burstBps = 1_200;
        uint256 refillBps = 801;

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, burstBps, refillBps, maxBps));
        bridge.setGlobalOutflowLimit(burstBps, refillBps);
    }

    /// @dev Deployment ergonomics: policy validation is liquidity-independent, so
    ///      both buckets can be configured before the first deposit exists. This
    ///      is what lets a deployment install every parameter in one pass instead
    ///      of "deploy → seed liquidity → come back and configure buckets".
    function test_outflowPolicyConfigurableAtZeroLiquidity() public {
        // `setUp` deploys the Bridge and configures routes but makes no deposit.
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 0, "no chain liquidity yet");
        assertEq(bridge.totalLockedLiquidity(), 0, "no global liquidity yet");

        vm.startPrank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, 500, 1_500);
        bridge.setGlobalOutflowLimit(800, 1_200);
        vm.stopPrank();

        // Configured, but nothing is spendable until liquidity backs it — the
        // percentage has no absolute meaning at zero reference.
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, "no allowance without liquidity");
        assertEq(bridge.availableGlobalOutflow(), 0, "no global allowance without liquidity");
        assertEq(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), 0, "nothing can leave");
    }

    /// @dev The same policy scales with liquidity and needs no governance touch:
    ///      5% burst is 5 ether at 100 ether TVL and 50 ether at 1000 ether TVL.
    function test_outflowPolicyScalesWithLiquidity() public {
        vm.startPrank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, 500, 1_500);
        bridge.setGlobalOutflowLimit(500, 1_500);
        vm.stopPrank();

        usdt0.mint(user, 1_100 ether);
        vm.prank(user);
        bridge.fundsIn(100 ether, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 4_001));
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 5 ether, "5% of 100 ether");

        vm.prank(user);
        bridge.fundsIn(900 ether, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 4_002));
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 50 ether, "5% of 1000 ether, no reconfiguration");
    }

    function test_setOutflowLimit_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setOutflowLimit(RGB_CHAIN_ID, 500, 1_500);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setGlobalOutflowLimit(500, 1_500);
    }

    function test_setOutflowLimit_emitsEvent() public {
        _seedRGB(100 ether); // chain liquidity 1000 ether
        uint256 burstBps = 500; // 5% → 50 ether
        uint256 refillBps = 1_500;
        uint256 expectedShares = burstBps * bridge.SHARE_UNIT() / bridge.BPS_DENOMINATOR();

        // RGB already uses a 10% balanced policy; reconfiguring to 5% clamps
        // the accrued allowance to the new burst.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit OutflowLimitUpdated(RGB_CHAIN_ID, burstBps, refillBps, expectedShares);
        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, refillBps);
    }

    /// @dev Fuzz the refill formula end-to-end through the live preview: reconfig
    ///      RGB to a fuzzed bps policy, drain a fuzzed fraction, warp a fuzzed
    ///      time, and assert availableOutflow matches an independent
    ///      recomputation of the library's min(capacity, tokens + elapsed*rate).
    ///      The recomputation runs in share space, where the arithmetic is exact,
    ///      and is converted to tokens exactly once — mirroring the view.
    function testFuzz_outflow_previewMatchesRefillFormula(
        uint256 burstBps,
        uint256 refillBps,
        uint256 drainBps,
        uint256 elapsed
    ) public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();
        burstBps = bound(burstBps, 1, MAX_BURST_BPS);
        refillBps = bound(refillBps, 1, maxBps - burstBps);
        drainBps = bound(drainBps, 1, burstBps);
        elapsed = bound(elapsed, 0, 4_000 days);

        _seedRGB(1_000 ether);

        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, refillBps);

        uint256 drain = bridge.chainOutflowReference(RGB_CHAIN_ID) * drainBps / bridge.BPS_DENOMINATOR();
        vm.assume(drain > 0);
        _releaseRGB(drain, BURN_ID);

        vm.warp(block.timestamp + elapsed);

        // Read the reference AFTER the warp: it is invariant while the release is
        // still counted in the window, then steps down to plain `lockedLiquidity`
        // once the window expires. The view converts against the live value.
        uint256 refLiquidity = bridge.chainOutflowReference(RGB_CHAIN_ID);

        (uint128 tokens,,, uint128 capacity, uint128 rate) = bridge.chainBuckets(RGB_CHAIN_ID);
        uint256 expectedShares = uint256(tokens) + elapsed * uint256(rate);
        if (expectedShares > capacity) expectedShares = capacity;

        uint256 shareUnit = bridge.SHARE_UNIT();
        assertEq(
            bridge.availableOutflow(RGB_CHAIN_ID),
            expectedShares * refLiquidity / shareUnit,
            "preview matches library refill"
        );
        assertLe(
            bridge.availableOutflow(RGB_CHAIN_ID),
            uint256(capacity) * refLiquidity / shareUnit,
            "never exceeds capacity"
        );
    }

    /// @dev A release within the live allowance debits exactly that amount, up to
    ///      the one-share ceiling applied when converting the amount into shares.
    function testFuzz_outflow_releaseDebitsAvailable(uint256 burstBps, uint256 amountBps) public {
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();
        burstBps = bound(burstBps, 1, MAX_BURST_BPS);
        amountBps = bound(amountBps, 1, burstBps);

        _seedRGB(1_000 ether);
        // No warp in this test, so the reference stays constant across the release.
        uint256 refLiquidity = bridge.chainOutflowReference(RGB_CHAIN_ID);

        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, burstBps, maxBps - burstBps);

        uint256 amount = refLiquidity * amountBps / bridge.BPS_DENOMINATOR();
        vm.assume(amount > 0);

        uint256 available = bridge.availableOutflow(RGB_CHAIN_ID);
        _releaseRGB(amount, BURN_ID);

        // One share is worth `refLiquidity / SHARE_UNIT` tokens; the ceiling can
        // debit at most that much more than the nominal amount.
        uint256 oneShare = refLiquidity / bridge.SHARE_UNIT() + 1;
        assertApproxEqAbs(
            bridge.availableOutflow(RGB_CHAIN_ID), available - amount, oneShare, "debited to within one share"
        );
        assertLe(bridge.availableOutflow(RGB_CHAIN_ID), available - amount, "never debits less than the amount");
    }

    // ========================================================================
    // fundsOut — other reverts
    // ========================================================================

    function test_fundsOut_revertsIfNotOwner() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );
    }

    function test_fundsOut_revertsOnZeroRecipient() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.expectRevert(BridgeBase.InvalidRecipientAddress.selector);
        vm.prank(multisig);
        _fundsOut(
            address(0), AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );
    }

    function test_fundsOut_revertsIfAmountExceedsPool() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.expectRevert(BridgeBase.AmountExceedBridgePool.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT + 1, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );
    }

    // ========================================================================
    // Commission — fundsIn TOKEN
    // ========================================================================

    function test_fundsIn_tokenCommission_routesToCM() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100;
        uint256 expectedNet = AMOUNT - expectedCommission;

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), expectedNet, "bridge net");
        assertEq(usdt0.balanceOf(address(cm)), expectedCommission, "cm pool");
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "cm recorded");
        assertEq(rgbModule.fundsInRecords(opId), expectedNet, "record = net");
    }

    // The flat `baseFee` rides the same path as the proportional part: it is
    // deducted from the deposit, forwarded to the CommissionManager pool, and
    // the settlement record is written against the resulting net.
    function test_fundsIn_baseFeeRoutesToCMOnTopOfPercentage() public {
        uint256 percent = 400; // 4%
        uint256 baseFee = 1e18;

        // The harness floor is 1 wei-unit, which no flat fee can sit under.
        // Raise it to a realistic value first: at a 10e18 floor the combined fee
        // is 0.4e18 + 1e18, comfortably below it.
        vm.prank(bridge.owner());
        bridge.setMinFundsInAmount(10e18);

        vm.prank(deployer);
        cm.setCommissionRule(
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                baseFee: baseFee,
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100 + baseFee;
        uint256 expectedNet = AMOUNT - expectedCommission;

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), expectedNet, "bridge net");
        assertEq(usdt0.balanceOf(address(cm)), expectedCommission, "cm pool holds percentage + flat");
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "cm recorded");
        assertEq(rgbModule.fundsInRecords(opId), expectedNet, "record = net");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), expectedNet, "liquidity credited net");
    }

    // A token already donated directly to the CommissionManager is NOT absorbed
    // as commission. Bridge measures the delta of its own transfer,
    // so the pool grows by exactly the real fee; the donation stays a stray balance.
    function test_fundsIn_tokenCommission_doesNotAbsorbCmDonation() public {
        _setFundsInTokenRule(400); // 4%
        uint256 expectedCommission = (AMOUNT * 400) / 100 / 100;

        // Unsolicited direct transfer into the CommissionManager.
        address donor = makeAddr("cmDonor");
        uint256 donation = 5e18;
        usdt0.mint(donor, donation);
        vm.prank(donor);
        usdt0.transfer(address(cm), donation);

        assertEq(cm.tokenCommissionPool(address(usdt0)), 0, "pre pool (donation not counted)");
        assertEq(usdt0.balanceOf(address(cm)), donation, "pre cm balance holds donation");

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // Pool grew by exactly the real commission — the donation was not folded in.
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "pool grew only by real commission");
        assertEq(usdt0.balanceOf(address(cm)), donation + expectedCommission, "donation still present as stray balance");
    }

    // ========================================================================
    // Commission — fundsIn NATIVE
    // ========================================================================

    function test_fundsIn_nativeCommission_routesToCM() public {
        uint256 percent = 100; // 1%
        _setFundsInNativeRule(percent);

        (uint256 tokenC, uint256 nativeC, uint256 net) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertEq(tokenC, 0);
        assertGt(nativeC, 0);
        assertEq(net, AMOUNT);

        vm.deal(user, nativeC);
        vm.prank(user);
        bytes32 opId = bridge.fundsIn{value: nativeC}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
        assertEq(address(cm).balance, nativeC);
        assertEq(cm.nativeCommissionPool(), nativeC);
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT);
    }

    // ========================================================================
    // Commission — fundsOut TOKEN
    // ========================================================================

    function test_fundsOut_tokenCommission_routesToCM() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        uint256 percent = 500; // 5%
        _setFundsOutTokenRule(percent);

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100;
        uint256 expectedNet = AMOUNT - expectedCommission;

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );

        assertEq(usdt0.balanceOf(recipient), expectedNet, "recipient net");
        assertEq(usdt0.balanceOf(address(cm)), expectedCommission, "cm pool");
        assertEq(cm.tokenCommissionPool(address(usdt0)), expectedCommission, "cm recorded");
    }

    // ========================================================================
    // Commission — NATIVE + FUNDS_OUT rejected at config time
    // ========================================================================

    /// @dev The invalid (NATIVE, FUNDS_OUT) shape is rejected by the
    ///      CommissionManager setter, so it can never reach and brick fundsOut.
    function test_setCommissionRule_nativeFundsOut_reverts() public {
        vm.expectRevert(ICommissionManager.NativeCommissionNotAllowedOnFundsOut.selector);
        _setFundsOutNativeRule(100); // setCommissionRule(... NATIVE, FUNDS_OUT ...)
    }

    // ========================================================================
    // Commission — bounded native quote drift
    // ========================================================================

    function test_fundsIn_revertsOnNativeValueMismatch_zeroRuleButValueSent() public {
        vm.deal(user, 1 ether);
        vm.expectRevert(IBridge.NativeValueMismatch.selector);
        vm.prank(user);
        bridge.fundsIn{value: 1 ether}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_fundsIn_revertsOnNativeValueMismatch_nativeRuleButNoValue() public {
        _setFundsInNativeRule(100);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _directNativeBounds(quote);

        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, uint256(0), minimum, maximum)
        );
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    // ========================================================================
    // Native commission drift band
    //
    // Direct deposits: attach the quote plus optional headroom; exactly the
    // fresh quote is charged and the remainder refunded, so the protocol never
    // under-collects and the caller is never overcharged.
    // Adapter deposits: the source-chain payer is unreachable, so the band is
    // symmetric and whatever arrives inside it is collected in full.
    // ========================================================================

    function test_direct_exactQuoteChargedInFull() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        assertGt(quote, 0, "native fee quoted");

        vm.deal(user, quote);
        uint256 poolBefore = cm.nativeCommissionPool();

        vm.prank(user);
        bytes32 opId = bridge.fundsIn{value: quote}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), poolBefore + quote, "pool credited exactly the quote");
        assertEq(user.balance, 0, "nothing to refund");
        assertEq(address(bridge).balance, 0, "no native stranded in bridge");
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "deposit completed");
    }

    /// @dev A caller who attaches more than the quote is charged only the quote
    ///      and refunded the surplus.
    function test_direct_surplusIsRefundedNotCollected() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        uint256 attached = quote + (quote * 400) / 10_000; // +4%, inside the band

        vm.deal(user, attached);
        uint256 poolBefore = cm.nativeCommissionPool();

        vm.prank(user);
        bridge.fundsIn{value: attached}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), poolBefore + quote, "protocol collected ONLY the quote");
        assertEq(user.balance, attached - quote, "caller refunded the whole surplus");
        assertEq(address(bridge).balance, 0, "no native stranded in bridge");
    }

    function test_direct_upperBoundaryRefunded() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        (, uint256 maximum) = _directNativeBounds(quote);

        vm.deal(user, maximum);
        vm.prank(user);
        bridge.fundsIn{value: maximum}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), quote, "still only the quote is collected");
        assertEq(user.balance, maximum - quote, "full headroom refunded");
    }

    function test_direct_revertsBelowQuote() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _directNativeBounds(quote);
        uint256 provided = minimum - 1;

        vm.deal(user, provided);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(user);
        bridge.fundsIn{value: provided}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    function test_direct_revertsAboveUpperBoundary() public {
        _setFundsInNativeRule(100);
        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _directNativeBounds(quote);
        uint256 provided = maximum + 1;

        vm.deal(user, provided);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(user);
        bridge.fundsIn{value: provided}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    /// @dev The scenario from the finding: quote, then the price moves against
    ///      the caller before the tx mines. The attached buffer absorbs it and
    ///      the deposit succeeds, charged at the FRESH (higher) quote.
    function test_direct_adverseDriftAbsorbedByBuffer() public {
        _setFundsInNativeRule(100);
        uint256 quotedAtSubmit = _nativeQuote(AMOUNT);
        uint256 attached = quotedAtSubmit + (quotedAtSubmit * 400) / 10_000; // +4% buffer

        // ETH depreciates ~3%: the same fee costs more wei than first quoted,
        // but less than the 4% buffer the caller attached.
        ethUsdFeed.setAnswer(1_940e8);
        uint256 freshQuote = _nativeQuote(AMOUNT);
        assertGt(freshQuote, quotedAtSubmit, "drift moved against the caller");
        assertLe(freshQuote, attached, "the buffer covers the drift, so no revert");

        vm.deal(user, attached);
        vm.prank(user);
        bridge.fundsIn{value: attached}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), freshQuote, "charged the fresh quote, not the stale one");
        assertEq(user.balance, attached - freshQuote, "remaining buffer refunded");
    }

    /// @dev Favorable drift simply returns more: the caller is charged the fresh
    ///      (lower) quote, never the stale higher one.
    function test_direct_favorableDriftRefundsMore() public {
        _setFundsInNativeRule(100);
        uint256 quotedAtSubmit = _nativeQuote(AMOUNT);

        ethUsdFeed.setAnswer(2_090e8); // ETH appreciates: the fee costs less wei
        uint256 freshQuote = _nativeQuote(AMOUNT);
        assertLt(freshQuote, quotedAtSubmit, "drift moved in the caller's favour");

        vm.deal(user, quotedAtSubmit);
        vm.prank(user);
        bridge.fundsIn{value: quotedAtSubmit}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(cm.nativeCommissionPool(), freshQuote, "charged the fresh, lower quote");
        assertEq(user.balance, quotedAtSubmit - freshQuote, "difference refunded");
    }

    /// @dev The protocol cannot be systematically under-paid: every deposit
    ///      credits exactly the quote in force at execution.
    function test_direct_noSystematicUnderCollection() public {
        _setFundsInNativeRule(100);
        uint256 expected;

        for (uint256 i; i < 3; i++) {
            uint256 quote = _nativeQuote(AMOUNT);
            (, uint256 maximum) = _directNativeBounds(quote);
            vm.deal(user, maximum);
            vm.prank(user);
            bridge.fundsIn{value: maximum}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 900 + i));
            expected += quote;
        }

        assertEq(cm.nativeCommissionPool(), expected, "collected exactly the sum of the quotes");
    }

    /// @dev A caller that cannot accept native value must send the exact quote;
    ///      attaching a buffer it cannot be refunded reverts cleanly.
    function test_direct_nonPayableCallerMustSendExactQuote() public {
        _setFundsInNativeRule(100);
        NonPayableDepositor depositor = new NonPayableDepositor(bridge, usdt0);
        usdt0.mint(address(depositor), AMOUNT * 2);
        depositor.approveBridge(AMOUNT * 2);

        uint256 quote = _nativeQuote(AMOUNT);

        // Exact quote: nothing to refund, so the deposit goes through.
        vm.deal(address(depositor), quote);
        depositor.deposit(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(), quote);
        assertEq(cm.nativeCommissionPool(), quote, "exact quote accepted from a non-payable caller");

        // With a buffer the refund cannot land, and the deposit reverts.
        uint256 attached = quote + (quote * 200) / 10_000;
        vm.deal(address(depositor), attached);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeRefundFailed.selector, address(depositor), attached - quote)
        );
        depositor.deposit(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 951), attached);
    }

    function test_adapter_symmetricBandCollectedInFull() public {
        _setFundsInNativeRule(100);

        address adapter = makeAddr("lz-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        usdt0.mint(adapter, AMOUNT * 2);
        vm.prank(adapter);
        usdt0.approve(address(bridge), AMOUNT * 2);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _adapterNativeBounds(quote);
        assertLt(minimum, quote, "adapter band extends BELOW the quote");

        // Below the quote is accepted here — and collected in full, since the
        // source-chain payer cannot be refunded.
        vm.deal(adapter, minimum);
        vm.prank(adapter);
        bridge.fundsIn{value: minimum}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        assertEq(cm.nativeCommissionPool(), minimum, "source-agreed value collected in full");
        assertEq(adapter.balance, 0, "adapter is not refunded");

        // Above the quote is likewise collected in full, not refunded.
        vm.deal(adapter, maximum);
        vm.prank(adapter);
        bridge.fundsIn{value: maximum}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + 961)
        );
        assertEq(cm.nativeCommissionPool(), minimum + maximum, "upper bound also collected in full");
        assertEq(adapter.balance, 0, "adapter still not refunded");
        assertEq(address(bridge).balance, 0, "no native stranded in bridge");
    }

    function test_adapter_revertsBelowLowerBoundary() public {
        _setFundsInNativeRule(100);

        address adapter = makeAddr("lz-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _adapterNativeBounds(quote);
        uint256 provided = minimum - 1;
        vm.deal(adapter, provided);

        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(adapter);
        bridge.fundsIn{value: provided}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
    }

    function test_adapter_revertsAboveUpperBoundary() public {
        _setFundsInNativeRule(100);

        address adapter = makeAddr("lz-adapter");
        vm.prank(multisig);
        bridge.setLZAdapter(adapter);

        uint256 quote = _nativeQuote(AMOUNT);
        (uint256 minimum, uint256 maximum) = _adapterNativeBounds(quote);
        uint256 provided = maximum + 1;
        vm.deal(adapter, provided);

        vm.expectRevert(
            abi.encodeWithSelector(IBridge.NativeCommissionOutOfBounds.selector, provided, minimum, maximum)
        );
        vm.prank(adapter);
        bridge.fundsIn{value: provided}(
            AMOUNT, SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
    }

    // ========================================================================
    // pause / unpause / renounceOwnership
    // ========================================================================

    function test_pause_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.pauseInflow();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(multisig);
        bridge.pauseInflow();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.unpauseInflow();
    }

    function test_renounceOwnership_alwaysReverts() public {
        vm.expectRevert(BridgeBase.RenounceOwnershipBlocked.selector);
        vm.prank(multisig);
        bridge.renounceOwnership();
    }

    // ========================================================================
    // views
    // ========================================================================

    function test_getContractBalance() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(bridge.getContractBalance(), AMOUNT);
    }

    function test_getChainId() public view {
        assertEq(bridge.getChainId(), block.chainid);
    }

    // ========================================================================
    // Fuzz
    // ========================================================================

    function testFuzz_fundsIn_validAmount(uint128 amount) public {
        vm.assume(amount > 0);
        usdt0.mint(user, amount);

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(address(bridge)), amount);
        assertEq(rgbModule.fundsInRecords(opId), amount);
    }

    // ========================================================================
    // fundsIn — full-flow state snapshots
    // ========================================================================

    function test_fundsIn_tokenCommission_fullFlowStateSnapshot() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);

        // Snapshot every balance/pool/record this TOKEN-commission flow should touch.
        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 userEthBefore = user.balance;
        uint256 bridgeEthBefore = address(bridge).balance;
        uint256 cmEthBefore = address(cm).balance;
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, 0, "pre record");

        vm.expectEmit(true, true, false, true);
        emit FundsIn(user, RGB_OP_ID, netAmount);
        vm.expectEmit(true, true, true, true);
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            netAmount,
            tokenCommission,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        // Execute the real direct fundsIn path: user → Bridge → RouteRegistry → RGB module → CM.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId, expectedOpId, "returned id matches derivation");

        assertEq(usdt0.balanceOf(user), userBefore - AMOUNT, "user gross spent");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + netAmount, "bridge net delta");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, "cm fee delta");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, "cm pool delta");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(user.balance, userEthBefore, "user native unchanged");
        assertEq(address(bridge).balance, bridgeEthBefore, "bridge native unchanged");
        assertEq(address(cm).balance, cmEthBefore, "cm native unchanged");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore + netAmount, "record delta = net");

        // Gross USDT0 is conserved between Bridge liquidity and CM commission custody.
        assertEq(
            (usdt0.balanceOf(address(bridge)) - bridgeBefore) + (usdt0.balanceOf(address(cm)) - cmBefore),
            AMOUNT,
            "gross token conserved"
        );
    }

    function test_fundsIn_nativeCommission_fullFlowStateSnapshot() public {
        uint256 percent = 100; // 1%
        _setFundsInNativeRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertEq(tokenCommission, 0, "token fee is zero");
        assertGt(nativeCommission, 0, "native fee quoted");
        assertEq(netAmount, AMOUNT, "net token amount");

        vm.deal(user, nativeCommission);

        // Snapshot token/native balances, pools, and RGB record touched by native-fee fundsIn.
        uint256 userTokenBefore = usdt0.balanceOf(user);
        uint256 bridgeTokenBefore = usdt0.balanceOf(address(bridge));
        uint256 cmTokenBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 userEthBefore = user.balance;
        uint256 bridgeEthBefore = address(bridge).balance;
        uint256 cmEthBefore = address(cm).balance;
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(bridgeTokenBefore, 0, "pre bridge token");
        assertEq(cmTokenBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre token pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, 0, "pre record");

        vm.expectEmit(true, true, false, true);
        emit FundsIn(user, RGB_OP_ID, netAmount);
        vm.expectEmit(true, true, true, true);
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            netAmount,
            0,
            nativeCommission,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        // Execute exact-value native commission path; token principal stays whole.
        vm.prank(user);
        bytes32 opId = bridge.fundsIn{value: nativeCommission}(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId, expectedOpId, "returned id matches derivation");

        assertEq(usdt0.balanceOf(user), userTokenBefore - AMOUNT, "user token gross spent");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeTokenBefore + netAmount, "bridge token delta");
        assertEq(usdt0.balanceOf(address(cm)), cmTokenBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "token pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore + nativeCommission, "native pool delta");
        assertEq(user.balance, userEthBefore - nativeCommission, "user native paid");
        assertEq(address(bridge).balance, bridgeEthBefore, "bridge native unchanged");
        assertEq(address(cm).balance, cmEthBefore + nativeCommission, "cm native delta");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore + netAmount, "record delta = net");

        // Native fee is conserved in CM custody while the full USDT0 principal stays in Bridge.
        assertEq(usdt0.balanceOf(address(bridge)) - bridgeTokenBefore, AMOUNT, "gross token in bridge");
        assertEq(address(cm).balance - cmEthBefore, nativeCommission, "native fee conserved");
    }

    // ========================================================================
    // fundsOut — full-flow state snapshots
    // ========================================================================

    function test_fundsOut_snapshot_tokenCommission_partialRelease() public {
        uint256 releaseAmount = 60e18;
        uint256 percent = 500; // 5%

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(releaseAmount);
        _setFundsOutTokenRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(usdt0), releaseAmount);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");
        assertEq(netAmount, releaseAmount - tokenCommission, "net recipient amount");

        bytes32[] memory ids = _ids(opId);

        // Snapshot the Bridge fundsOut state after a larger RGB record exists.
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore = usdt0.balanceOf(recipient);
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(opId);

        assertEq(bridgeBefore, releaseAmount * 10, "pre bridge pool satisfies configured 10% burst");
        assertEq(recipientBefore, 0, "pre recipient token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, AMOUNT, "pre record");

        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(ids);
        uint256 burnId =
            _deriveBurnId(recipient, releaseAmount, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);
        assertFalse(bridge.consumedBurnIds(burnId), "pre burn id");

        vm.expectEmit(true, true, false, true);
        emit BridgeFundsOut(
            recipient, releaseAmount, netAmount, tokenCommission, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR
        );

        // Release less than the recorded mint. The settlement module no longer
        // consumes records (the proof-of-mint ledger is permanent), so the
        // record is left intact regardless of the release amount; solvency for
        // the partial release is enforced by Bridge.lockedLiquidity.
        vm.prank(multisig);
        _fundsOut(recipient, releaseAmount, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertTrue(bridge.consumedBurnIds(burnId), "burn id consumed");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore - releaseAmount, "bridge gross debit");
        assertEq(usdt0.balanceOf(recipient), recipientBefore + netAmount, "recipient net delta");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, "cm fee delta");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, "cm pool delta");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore, "record unchanged (proof-of-mint permanent)");

        // The gross Bridge debit splits into recipient net payout and CM token commission.
        assertEq(
            (usdt0.balanceOf(recipient) - recipientBefore) + (usdt0.balanceOf(address(cm)) - cmBefore),
            releaseAmount,
            "gross fundsOut conserved"
        );
    }

    // ========================================================================
    // fundsIn — rollback snapshots
    // ========================================================================

    function test_fundsIn_routeModuleRevertRollsBackTokenPullAndEvents() public {
        MockSettlementModule revertingModule = new MockSettlementModule();
        revertingModule.setShouldRevertOnFundsIn(true);

        // Route is intentionally rewired to a module that reverts after Bridge
        // has already pulled tokens and before commission forwarding can run.
        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(revertingModule));

        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(recordBefore, 0, "pre rgb record");
        assertEq(revertingModule.onFundsInCount(), 0, "pre module calls");

        // Bridge emits FundsIn/BridgeFundsIn only after route dispatch, so this
        // module revert prevents successful Bridge events from persisting.
        vm.expectRevert(MockSettlementModule.MockModuleForcedRevert.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore, "user token unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore, "bridge token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(expectedOpId), recordBefore, "rgb record unchanged");
        assertEq(revertingModule.onFundsInCount(), 0, "module state unchanged");
    }

    function test_fundsIn_commissionForwardingRevertRollsBackSettlementRecord() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertLt(netAmount, AMOUNT, "net below gross");

        // Misconfigure only the CM bridge guard so the route/RGB write happens
        // before commission forwarding fails in receiveTokenCommission().
        // Deploy the stub BEFORE the prank — as a call argument it would consume it.
        address wrongBridge = _wrongBridgeWithFloor();
        vm.prank(deployer);
        cm.setBridgeAddress(wrongBridge);

        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(recordBefore, 0, "pre rgb record");

        // FundsIn/BridgeFundsIn emit after commission forwarding, so this
        // late revert prevents successful Bridge events from persisting.
        vm.expectRevert(ICommissionManager.OnlyBridge.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore, "user token unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore, "bridge token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(expectedOpId), recordBefore, "rgb record unchanged");
    }

    // ========================================================================
    // fundsOut — rollback snapshots
    // ========================================================================

    function test_fundsOut_verifierRevertRollsBackBurnIdAndRecords() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        // Well-formed two-pair proof, but the source block is unknown to the relay.
        bytes memory badProof = abi.encode(uint256(999_999), keccak256("unknown-block"), LATEST_HEIGHT, LATEST_COMMIT);

        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore = usdt0.balanceOf(recipient);
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(opId);
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId =
            _deriveBurnId(recipient, AMOUNT, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, badProof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "pre burn id");
        assertEq(bridgeBefore, AMOUNT * 10, "pre bridge pool includes bucket reserve");
        assertEq(recipientBefore, 0, "pre recipient token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, AMOUNT, "pre rgb record");

        // fundsOut marks the burn id before verifier dispatch. This verifier
        // failure rolls that mark back and short-circuits before RGB records
        // can be consumed.
        vm.expectRevert("verify: block commitment");
        vm.prank(multisig);
        _fundsOut(recipient, AMOUNT, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, badProof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "burn id unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore, "bridge token unchanged");
        assertEq(usdt0.balanceOf(recipient), recipientBefore, "recipient token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore, "rgb record unchanged");
    }

    function test_fundsOut_settlementRevertRollsBackBurnIdAndRecords() public {
        uint256 amount1 = 50e18;
        uint256 amount2 = 50e18;
        uint256 releaseAmount = 50e18;

        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(amount1, RGB_CHAIN_ID, DST_ADDR, _rgbData(1));
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(amount2, RGB_CHAIN_ID, DST_ADDR, _rgbData(2));
        _ensureRgbSafetyCapacity(releaseAmount);

        // Reference opId1 with a deliberately wrong amount so the settlement
        // module reverts (AmountMismatch) after the Bridge has already marked
        // the burn id and debited liquidity — exercising the rollback.
        bytes32[] memory ids = _ids(opId1);
        uint256[] memory badAmounts = _one(amount1 + 1);

        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore = usdt0.balanceOf(recipient);
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 record1Before = rgbModule.fundsInRecords(opId1);
        uint256 record2Before = rgbModule.fundsInRecords(opId2);
        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(ids, badAmounts);
        uint256 burnId =
            _deriveBurnId(recipient, releaseAmount, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "pre burn id");
        assertEq(bridgeBefore, releaseAmount * 10, "pre bridge pool includes bucket reserve");
        assertEq(recipientBefore, 0, "pre recipient token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(record1Before, amount1, "pre record 1");
        assertEq(record2Before, amount2, "pre record 2");

        // The module reverts on the amount mismatch; the surrounding fundsOut
        // must atomically roll back the burn-id mark and the liquidity debit.
        // (Records are view-only now, so they are trivially unchanged.)
        vm.expectRevert(
            abi.encodeWithSelector(RgbSettlementModule.AmountMismatch.selector, opId1, amount1 + 1, amount1)
        );
        vm.prank(multisig);
        _fundsOut(recipient, releaseAmount, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        assertFalse(bridge.consumedBurnIds(burnId), "burn id unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore, "bridge token unchanged");
        assertEq(usdt0.balanceOf(recipient), recipientBefore, "recipient token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId1), record1Before, "record 1 unchanged");
        assertEq(rgbModule.fundsInRecords(opId2), record2Before, "record 2 unchanged");
    }

    function test_fundsOutVerifierProofStillNotRouteContextAware() public {
        address alternateRecipient = makeAddr("alternateRecipient");
        uint256 releaseAmount = 37e18;
        // Isolated liquidity and the outflow limit gate the `sourceChainId`
        // dimension: a release can only draw from a funded and rate-limited
        // source chain. This reproduction keeps the source on the funded RGB
        // chain. The burnId binds the release intent and exact proof, but
        // RGBVerifier itself still validates only BTC block commitments; it does
        // not parse route/business context from the proof.
        uint256 alternateSourceChainId = RGB_CHAIN_ID;
        uint256 alternateDestinationChainId = SOURCE_CHAIN_ID + 77;
        string memory alternateSourceAddress = "rgb:unbound/source/utxo999";

        vm.prank(deployer);
        routeRegistry.setRoute(
            alternateSourceChainId, alternateDestinationChainId, true, address(rgbVerifier), address(rgbModule)
        );

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(releaseAmount);

        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore = usdt0.balanceOf(alternateRecipient);
        uint256 recordBefore = rgbModule.fundsInRecords(opId);

        assertEq(bridgeBefore, releaseAmount * 10, "pre bridge pool satisfies configured 10% burst");
        assertEq(recipientBefore, 0, "pre recipient token");
        assertEq(recordBefore, AMOUNT, "pre record");
        bytes memory proof = _proof();
        bytes memory settlementData = _settlement(_ids(opId));
        uint256 burnId = _deriveBurnId(
            alternateRecipient,
            releaseAmount,
            alternateSourceChainId,
            alternateDestinationChainId,
            alternateSourceAddress,
            proof,
            settlementData
        );
        assertFalse(bridge.consumedBurnIds(burnId), "pre burn id");

        // Current verifier behavior: this is an authorized fundsOut call with a
        // matching Bridge-derived burnId, but RGBVerifier checks only the encoded
        // BTC block commitments. If the RGB proof later carries enough context
        // for verifier-level binding, invert this to expect a verifier revert.
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BridgeFundsOut(
            alternateRecipient,
            releaseAmount,
            releaseAmount,
            0,
            burnId,
            alternateSourceChainId,
            alternateDestinationChainId,
            alternateSourceAddress
        );

        vm.prank(multisig);
        _fundsOut(
            alternateRecipient,
            releaseAmount,
            burnId,
            alternateSourceChainId,
            alternateDestinationChainId,
            alternateSourceAddress,
            proof,
            settlementData
        );

        assertTrue(bridge.consumedBurnIds(burnId), "burn id consumed");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore - releaseAmount, "bridge debit");
        assertEq(usdt0.balanceOf(alternateRecipient), recipientBefore + releaseAmount, "recipient credited");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore, "record unchanged (proof-of-mint permanent)");
    }

    // The pre-emption attack is closed because operationId is derived on-chain
    // from the authenticated `sourceSender` plus a per-sender
    // nonce, so an attacker cannot compute (let alone occupy) a victim's id by
    // copying the RGB OpId out of the mempool. A preemptor sharing the same
    // rgbOpId lands on a DIFFERENT derived id, and the victim's deposit still
    // succeeds under its own id.
    function test_fundsIn_preemptorCannotBlockVictimDeposit() public {
        address preemptor = makeAddr("operationIdPreemptor");
        uint256 preemptAmount = 25e18;

        usdt0.mint(preemptor, preemptAmount);
        vm.prank(preemptor);
        usdt0.approve(address(bridge), preemptAmount);

        // Preemptor deposits first, reusing the SAME rgbOpId the victim will use.
        vm.prank(preemptor);
        bytes32 preemptOpId = bridge.fundsIn(preemptAmount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(preemptOpId), preemptAmount, "preemptor record");

        uint256 victimBefore = usdt0.balanceOf(user);

        // Victim's deposit with identical params + identical rgbOpId still
        // succeeds: its derived id binds the victim's sourceSender, so it cannot
        // collide with the preemptor's id.
        vm.prank(user);
        bytes32 victimOpId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(victimOpId != preemptOpId, "victim id distinct from preemptor id");
        assertEq(rgbModule.fundsInRecords(victimOpId), AMOUNT, "victim record created");
        assertEq(usdt0.balanceOf(user), victimBefore - AMOUNT, "victim deposit went through");
    }

    // A plain ERC20 transfer can change Bridge's raw balance,
    // but it does not enter the Bridge.fundsIn accounting path.
    function test_directTokenTransferDoesNotCreateFundsInAccounting() public {
        address donor = makeAddr("directTransferDonor");
        uint256 directAmount = 17e18;
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );

        usdt0.mint(donor, directAmount);

        uint256 donorBefore = usdt0.balanceOf(donor);
        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(donorBefore, directAmount, "pre donor token");
        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(recordBefore, 0, "pre record");

        vm.prank(donor);
        usdt0.transfer(address(bridge), directAmount);

        assertEq(usdt0.balanceOf(donor), donorBefore - directAmount, "donor direct transfer spent");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + directAmount, "bridge raw balance increased");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(expectedOpId), recordBefore, "record not created");

        vm.expectEmit(true, true, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, AMOUNT);
        vm.expectEmit(true, true, true, true, address(bridge));
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            AMOUNT,
            0,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore - AMOUNT, "user fundsIn spent");
        assertEq(
            usdt0.balanceOf(address(bridge)),
            bridgeBefore + directAmount + AMOUNT,
            "bridge includes direct plus fundsIn"
        );
        assertEq(rgbModule.fundsInRecords(opId), recordBefore + AMOUNT, "record created only by fundsIn");
    }

    // Bridge only rejects an empty destination address, so a
    // non-empty string is accepted and emitted without format validation.
    function test_fundsIn_acceptsInvalidButNonEmptyDestinationAddress() public {
        string memory invalidDestination = "not-rgb-destination";
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, invalidDestination, _rgbData()
        );

        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(recordBefore, 0, "pre record");

        vm.expectEmit(true, true, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, AMOUNT);
        vm.expectEmit(true, true, true, true, address(bridge));
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            AMOUNT,
            0,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            invalidDestination
        );

        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, invalidDestination, _rgbData());

        assertEq(usdt0.balanceOf(user), userBefore - AMOUNT, "user fundsIn spent");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + AMOUNT, "bridge credited");
        assertEq(rgbModule.fundsInRecords(opId), recordBefore + AMOUNT, "record created");
    }

    // The token commission is forwarded before the onFundsIn hook, so a
    // settlement module reading getContractBalance during the hook
    // observes only the net the Bridge retains — never the in-flight commission.
    function test_onFundsInHookSeesNetBalanceNotFutureCommission() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");

        MockSettlementModule observingModule = new MockSettlementModule();
        observingModule.setFundsInBalanceProbe(address(usdt0), address(bridge));
        // Return a non-zero external id so Bridge emits the RGB-only FundsIn event.
        observingModule.setExternalIdToReturn(RGB_OP_ID);

        vm.prank(deployer);
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(observingModule));

        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));

        assertEq(bridgeBefore, 0, "pre bridge token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");

        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );

        vm.expectEmit(true, true, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, netAmount);
        vm.expectEmit(true, true, true, true, address(bridge));
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            AMOUNT,
            netAmount,
            tokenCommission,
            nativeCommission,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(observingModule.onFundsInCount(), 1, "module called once");
        assertEq(observingModule.lastNetAmount(), netAmount, "module got net amount");
        assertEq(
            observingModule.lastObservedBalanceOnFundsIn(),
            bridgeBefore + netAmount,
            "hook sees only the retained net, not the in-flight commission"
        );
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + netAmount, "final bridge net");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, "cm token delta");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, "cm pool delta");
    }

    // fundsIn — fuzz/property rollback coverage

    // All selected failure paths must leave balances, commission pools, and RGB
    // accounting unchanged. Feed failures are pre-pull; route/module/commission
    // failures exercise post-pull rollback.
    function testFuzz_fundsIn_revertPathsLeaveStateUnchanged(
        uint128 amountSeed,
        uint128 /* operationSalt */
    )
        public
    {
        // Lower bound keeps commission/native fee nonzero so intended reverts fire.
        uint256 amount = bound(uint256(amountSeed), 100, AMOUNT);

        for (uint8 failureMode = 0; failureMode < 5; failureMode++) {
            uint256 snapshotId = vm.snapshotState();
            _assertFundsInRevertPathLeavesStateUnchanged(amount, failureMode);
            assertTrue(vm.revertToStateAndDelete(snapshotId), "scenario snapshot restored");
        }
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

        uint256 userTokenBefore = usdt0.balanceOf(user);
        uint256 bridgeTokenBefore = usdt0.balanceOf(address(bridge));
        uint256 cmTokenBefore = usdt0.balanceOf(address(cm));
        uint256 userNativeBefore = user.balance;
        uint256 bridgeNativeBefore = address(bridge).balance;
        uint256 cmNativeBefore = address(cm).balance;
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, amount, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );
        uint256 recordBefore = rgbModule.fundsInRecords(expectedOpId);

        vm.expectRevert(expectedRevert);
        vm.prank(user);
        bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(usdt0.balanceOf(user), userTokenBefore, "user token unchanged");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeTokenBefore, "bridge token unchanged");
        assertEq(usdt0.balanceOf(address(cm)), cmTokenBefore, "cm token unchanged");
        assertEq(user.balance, userNativeBefore, "user native unchanged");
        assertEq(address(bridge).balance, bridgeNativeBefore, "bridge native unchanged");
        assertEq(address(cm).balance, cmNativeBefore, "cm native unchanged");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(expectedOpId), recordBefore, "rgb record unchanged");

        if (failureMode == 1) {
            assertEq(revertingModule.onFundsInCount(), 0, "module state unchanged");
        }
    }

    // A positive-net RGB deposit records net under its DERIVED operationId. A
    // repeated identical deposit does not collide because the per-sender nonce
    // yields a distinct id, so the second deposit creates a second record. The
    // module-level DuplicateOperationId guard is covered in
    // RgbSettlementModule.t.sol.
    function testFuzz_fundsIn_positiveNetDepositCreatesRecordAndDistinctRepeat(uint128 amountSeed, uint16 percentSeed)
        public
    {
        uint256 amount = bound(uint256(amountSeed), 100, AMOUNT);
        uint256 percent = bound(uint256(percentSeed), 100, 9_000);

        _setFundsInTokenRule(percent);

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), amount);

        assertGt(tokenCommission, 0, "pre positive token fee");
        assertGt(netAmount, 0, "pre positive net");

        uint256 userBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();

        bytes32 expectedOpId = _deriveOpId(
            SOURCE_CHAIN_ID, bytes32(uint256(uint160(user))), 0, amount, RGB_CHAIN_ID, DST_ADDR, _rgbData()
        );

        vm.expectEmit(true, true, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, netAmount);
        vm.expectEmit(true, true, true, true, address(bridge));
        emit BridgeFundsIn(
            expectedOpId,
            bytes32(uint256(uint160(user))),
            user,
            0,
            amount,
            netAmount,
            tokenCommission,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        vm.prank(user);
        bytes32 opId1 = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId1, expectedOpId, "returned id matches derivation");

        assertEq(usdt0.balanceOf(user), userBefore - amount, "user spent gross once");
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + netAmount, "bridge got net");
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, "cm got fee");
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, "cm pool recorded fee");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(opId1), netAmount, "record = net");
        assertEq(
            (usdt0.balanceOf(address(bridge)) - bridgeBefore) + (usdt0.balanceOf(address(cm)) - cmBefore),
            amount,
            "gross token conserved"
        );

        // Repeat identical deposit — nonce increments, so a DISTINCT id is
        // derived and the deposit succeeds (no DuplicateOperationId).
        vm.prank(user);
        bytes32 opId2 = bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(opId2 != opId1, "repeat deposit gets a distinct id");
        assertEq(rgbModule.fundsInRecords(opId1), netAmount, "first record unchanged");
        assertEq(rgbModule.fundsInRecords(opId2), netAmount, "second record created");
    }

    /// @dev A 100% fee shape is rejected before it can become an active route
    ///      rule and create zero-net records.
    function test_hundredPercentRouteRuleCannotBeConfigured() public {
        CommissionConfig memory cfg = CommissionConfig({
            stablePercent: 8_100,
            baseFee: 0,
            multiplier: 90,
            side: CommissionSide.FUNDS_IN,
            currency: CommissionCurrency.TOKEN,
            isSet: true
        });

        vm.expectRevert(
            abi.encodeWithSelector(ICommissionManager.InvalidFeeShape.selector, cfg.stablePercent, cfg.multiplier)
        );
        vm.prank(deployer);
        cm.setCommissionRule(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), cfg);

        CommissionConfig memory stored = cm.getCommissionRule(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0));
        assertFalse(stored.isSet, "invalid rule was not stored");
    }

    // ========================================================================
    // On-chain-derived, unpredictable operationId
    // ========================================================================

    /// @dev The id is derived on-chain from the authenticated sender; two
    ///      different senders with otherwise-identical deposits produce
    ///      different ids, so an attacker cannot reproduce a victim's id.
    function test_fundsIn_derivesUnpredictableOperationId_notCallerControlled() public {
        address attacker = makeAddr("attacker");
        usdt0.mint(attacker, AMOUNT);
        vm.prank(attacker);
        usdt0.approve(address(bridge), AMOUNT);

        vm.prank(user);
        bytes32 victimId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        vm.prank(attacker);
        bytes32 attackerId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(victimId != attackerId, "ids bound to distinct senders differ");
        // The attacker's id equals the on-chain derivation for the attacker's
        // sender — it cannot be any value the attacker freely chose.
        assertEq(
            attackerId,
            _deriveOpId(
                SOURCE_CHAIN_ID, bytes32(uint256(uint160(attacker))), 0, AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData()
            ),
            "attacker id is the derived value"
        );
    }

    /// @dev Same sender, identical params twice: distinct ids (nonce), and the
    ///      per-(chain,sender) nonce advances to 2.
    function test_fundsIn_repeatedIdenticalDepositsGetDistinctIds() public {
        bytes32 sourceSender = bytes32(uint256(uint160(user)));
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 0, "nonce starts at 0");

        vm.prank(user);
        bytes32 id1 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        vm.prank(user);
        bytes32 id2 = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertTrue(id1 != id2, "nonce makes identical deposits distinct");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 2, "nonce incremented to 2");
    }

    /// @dev A downstream revert must roll back the nonce increment: the nonce
    ///      stays 0 and a later successful deposit gets the nonce-0 id.
    function test_fundsIn_nonceRollsBackOnRevert() public {
        bytes32 sourceSender = bytes32(uint256(uint160(user)));

        // Amount below the (raised) minimum reverts before the nonce is consumed.
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(999), uint256(1000)));
        vm.prank(user);
        bridge.fundsIn(999, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 0, "nonce not consumed on revert");

        // A subsequent successful deposit gets the nonce-0 id.
        bytes32 expectedNonce0Id =
            _deriveOpId(SOURCE_CHAIN_ID, sourceSender, 0, 1000, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(1000, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(opId, expectedNonce0Id, "first success uses nonce 0");
        assertEq(bridge.sourceSenderNonces(SOURCE_CHAIN_ID, sourceSender), 1, "nonce now 1");
    }

    /// @dev RGB deposit with a zero rgbOpId reverts in the settlement module.
    function test_fundsIn_zeroRgbOpIdReverts() public {
        vm.expectRevert(RgbSettlementModule.InvalidRgbOpId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(0));
    }

    /// @dev The RGB route emits FundsIn carrying the rgbOpId and net amount.
    function test_fundsIn_rgbRouteEmitsFundsInWithRgbOpId() public {
        vm.expectEmit(true, true, false, true, address(bridge));
        emit FundsIn(user, RGB_OP_ID, AMOUNT); // no commission → net == gross == AMOUNT
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    /// @dev The returned bytes32 is the key under which the module records net.
    function test_fundsIn_returnedOperationIdKeysTheRecord() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(rgbModule.fundsInRecords(opId), AMOUNT, "returned id keys the record");
    }

    /// @dev Full deposit → fundsOut happy path using the captured bytes32 in the
    ///      release settlement data.
    function test_fundsOut_referencesDerivedOperationId() public {
        vm.prank(user);
        bytes32 opId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        _ensureRgbSafetyCapacity(AMOUNT);

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), _settlement(_ids(opId))
        );

        assertEq(usdt0.balanceOf(recipient), AMOUNT, "release via derived id succeeds");
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
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 2);

        s.cm = new CommissionManager(predictedBridge, recipient);
        RouteRegistry feeRouteRegistry = new RouteRegistry(predictedBridge, deployer);
        s.bridge = new Bridge(address(s.token), address(feeRouteRegistry), payable(address(s.cm)), address(0), 1, 1);

        // Reuse the suite's RGB verifier (shares `btcRelay` + `_proof()`); a
        // fresh module is bound to this stack's route registry.
        s.module = new RgbSettlementModule(address(feeRouteRegistry));

        feeRouteRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(s.module));
        feeRouteRegistry.setRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(s.module));

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
        bytes memory proof,
        bytes memory settlementData
    ) internal view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    FUNDS_OUT_BURN_ID_TYPEHASH,
                    address(s.bridge),
                    block.chainid,
                    address(s.token),
                    recipient_,
                    amount,
                    sourceChainId,
                    destinationChainId,
                    keccak256(bytes(sourceAddress)),
                    keccak256(proof),
                    keccak256(settlementData)
                )
            )
        );
    }

    // --- Record/ledger/event use ACTUAL received, not nominal ---

    function test_fundsIn_feeToken_creditsActualReceivedNotNominal() public {
        FeeStack memory s = _deployFeeStack(100); // 1% fee, no commission rule

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        assertLt(received, AMOUNT, "sanity: fee token delivers less than nominal");

        bytes32 sourceSender = bytes32(uint256(uint160(user)));

        // BridgeFundsIn must carry gross `amount == AMOUNT` and `netAmount == received`.
        vm.expectEmit(true, true, false, true);
        emit FundsIn(user, RGB_OP_ID, received);
        vm.expectEmit(false, true, true, true);
        emit BridgeFundsIn(
            bytes32(0), sourceSender, user, 0, AMOUNT, received, 0, 0, SOURCE_CHAIN_ID, RGB_CHAIN_ID, DST_ADDR
        );

        vm.prank(user);
        bytes32 opId = s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(s.module.fundsInRecords(opId), received, "record credits actual received");
        assertEq(s.bridge.lockedLiquidity(RGB_CHAIN_ID), received, "lockedLiquidity credits actual received");
        assertEq(s.token.balanceOf(address(s.bridge)), received, "bridge token balance == received");
    }

    // --- With a TOKEN commission the ledger is not overstated ---

    function test_fundsIn_feeToken_ledgerNotOverstatedWithCommission() public {
        FeeStack memory s = _deployFeeStack(100); // 1% transfer fee
        // 4% FUNDS_IN TOKEN commission rule (stablePercent 400, multiplier 100).
        _setFeeStackFundsInTokenRule(s, 400, 100);

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        // Commission is quoted from the NOMINAL amount.
        uint256 tokenCommission = s.cm.calculateStableFee(AMOUNT, 400, 100);
        assertGt(tokenCommission, 0, "sanity: non-zero commission");

        vm.prank(user);
        s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        // Ledger credited from actual received minus the (nominal-quoted) commission.
        assertEq(
            s.bridge.lockedLiquidity(RGB_CHAIN_ID),
            received - tokenCommission,
            "lockedLiquidity == received - tokenCommission"
        );

        // The Bridge→CM commission hop is itself taxed by the fee token, so the
        // CM credits by its own balance delta: tokenCommission - feeOn(tokenCommission).
        assertEq(
            s.cm.tokenCommissionPool(address(s.token)),
            tokenCommission - s.token.feeOn(tokenCommission),
            "CM pool credited by its own balance delta"
        );

        // No overstate: the bridge's retained token balance equals the credited
        // lockedLiquidity exactly (bridge sent `tokenCommission` out to the CM).
        uint256 bridgeRetained = s.token.balanceOf(address(s.bridge));
        assertEq(bridgeRetained, received - tokenCommission, "bridge retained == lockedLiquidity");
        assertEq(
            s.bridge.lockedLiquidity(RGB_CHAIN_ID),
            bridgeRetained,
            "lockedLiquidity + bridge-retained invariant: credited == held"
        );
    }

    // --- The recorded (actual) amount is releasable via fundsOut ---

    function test_fundsOut_feeToken_recordedAmountIsReleasable() public {
        FeeStack memory s = _deployFeeStack(100); // 1% fee, no commission

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);

        vm.prank(user);
        bytes32 opId = s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
        assertEq(s.module.fundsInRecords(opId), received, "record == actual received");

        // Nine additional equal deposits provide the configured 90% bucket
        // reserve; the test still releases exactly the first record's amount.
        for (uint256 i = 1; i < 10; i++) {
            vm.prank(user);
            s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData(RGB_OP_ID + i));
        }

        // Ten equal deposits back the release, so `received` is ~10% of chain
        // liquidity and the balanced policy's burst covers it.
        vm.startPrank(multisig);
        s.bridge.setOutflowLimit(RGB_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        s.bridge.setGlobalOutflowLimit(MAX_BURST_BPS, MAX_REFILL_BPS);
        vm.stopPrank();

        // Release EXACTLY the recorded amount. Before the fix the record would
        // have been the nominal AMOUNT (> bridge balance `received`) and the
        // release would revert AmountExceedBridgePool.
        bytes memory proof = _proof();
        bytes memory settlementData = _settlementWithAmounts(_ids(opId), _one(received));
        uint256 burnId =
            _deriveBurnIdFor(s, recipient, received, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        uint256 recipientBefore = s.token.balanceOf(recipient);

        vm.prank(multisig);
        s.bridge
            .fundsOut(
                IBridge.FundsOutParams(
                    recipient, received, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData
                )
            );

        // The outbound transfer is also taxed, so the recipient nets
        // `received - feeOn(received)`. The payoff is that the release did NOT
        // revert and value moved.
        uint256 delta = s.token.balanceOf(recipient) - recipientBefore;
        assertGt(delta, 0, "recipient balance increased");
        assertEq(delta, received - s.token.feeOn(received), "recipient nets received minus outbound fee");
        assertEq(s.bridge.lockedLiquidity(RGB_CHAIN_ID), received * 9, "90% bucket reserve remains locked");
    }

    // --- Received <= tokenCommission reverts InsufficientReceived ---
    //
    // Token transfer fee = 9000 bps (90%) → received = 10% of AMOUNT = 10e18.
    // The commission is quoted on the NOMINAL amount, so the protocol maximum
    // rate of 90% (`_MAX_FEE_BPS`) already puts the quote at 90e18 — far above
    // the 10e18 that actually arrived, which is what this path must reject.
    function test_fundsIn_feeToken_revertsWhenFeeExceedsCommission() public {
        FeeStack memory s = _deployFeeStack(9000); // 90% transfer fee
        _setFeeStackFundsInTokenRule(s, 9000, 100); // 90% commission on nominal — the ceiling

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        uint256 tokenCommission = s.cm.calculateStableFee(AMOUNT, 9000, 100);

        assertEq(received, AMOUNT / 10, "sanity: received == 10% of nominal");
        assertGt(tokenCommission, received, "sanity: commission exceeds actual received");

        vm.expectRevert(abi.encodeWithSelector(IBridge.InsufficientReceived.selector, received, tokenCommission));
        vm.prank(user);
        s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());
    }

    /// @dev A nominally valid (<100%) commission can still consume the full
    ///      ACTUAL receipt when the token charges a transfer fee. Equality must
    ///      revert rather than recording a zero-net settlement.
    function test_fundsInFeeTokenRevertsWhenActualNetWouldBeZero() public {
        FeeStack memory s = _deployFeeStack(5000); // Bridge receives 50%
        _setFeeStackFundsInTokenRule(s, 5000, 100); // nominal commission is 50%

        uint256 received = AMOUNT - s.token.feeOn(AMOUNT);
        uint256 tokenCommission = s.cm.calculateStableFee(AMOUNT, 5000, 100);
        assertEq(received, tokenCommission, "sanity: actual receipt equals nominal commission");

        vm.expectRevert(abi.encodeWithSelector(IBridge.InsufficientReceived.selector, received, tokenCommission));
        vm.prank(user);
        s.bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, _rgbData());

        assertEq(s.bridge.lockedLiquidity(RGB_CHAIN_ID), 0, "zero-net liquidity was not recorded");
        assertEq(s.cm.tokenCommissionPool(address(s.token)), 0, "commission transfer rolled back");
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
