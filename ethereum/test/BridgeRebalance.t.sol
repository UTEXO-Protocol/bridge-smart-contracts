// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, Vm} from "forge-std/Test.sol";

import {Bridge} from "../src/Bridge.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {CommissionManager} from "../src/CommissionManager.sol";
import {RouteRegistry} from "../src/RouteRegistry.sol";
import {IRouteRegistry} from "../src/interfaces/IRouteRegistry.sol";
import {RGBVerifier} from "../src/verifiers/RGBVerifier.sol";
import {NullVerifier} from "../src/verifiers/NullVerifier.sol";
import {RgbSettlementModule} from "../src/settlement/RgbSettlementModule.sol";
import {RgbOutboundSettlementModule} from "../src/settlement/RgbOutboundSettlementModule.sol";
import {NullSettlementModule} from "../src/settlement/NullSettlementModule.sol";
import {BridgeBaseUpgradeable} from "../src/BridgeBaseUpgradeable.sol";
import {OutflowRateLimiter} from "../src/libraries/OutflowRateLimiter.sol";
import {FundsInContext, FundsOutContext} from "../src/interfaces/RouteTypes.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBtcRelay} from "./mocks/MockBtcRelay.sol";
import {BridgeProxyTestUtils} from "./mocks/BridgeProxyTestUtils.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice `Bridge.rebalanceLiquidity` — accounting-only liquidity migration
///         between chain buckets — plus the `RgbOutboundSettlementModule`
///         plugin it pairs with on RGB-debit routes.
///
/// Route fixture (hub model: every non-EVM ↔ non-EVM move settles here):
///   (SOURCE → RGB)   deposits toward RGB      — RGBVerifier + RgbSettlementModule
///   (SOURCE → ARCH)  deposits toward Arch     — NullVerifier + NullSettlementModule
///   (ARCH → RGB)     rebalance, credit-RGB    — NullVerifier + RgbSettlementModule
///                    (debit check vacuous: empty (ids, amounts) arrays;
///                     credit leg writes the mint record + FundsIn event)
///   (RGB → ARCH)     rebalance, debit-RGB     — RGBVerifier + RgbOutboundSettlementModule
///                    (burn-backed: BtcRelay proof + record check; credit leg
///                     writes nothing and emits no FundsIn)
contract BridgeRebalanceTest is Test, BridgeProxyTestUtils {
    event FundsIn(address indexed sender, uint256 rgbOpId, uint64 amount);
    event BridgeRebalance(
        bytes32 indexed operationId,
        uint256 indexed burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        uint256 amount,
        string sourceAddress,
        string destinationAddress,
        bytes settlementDataOut,
        bytes settlementDataIn
    );

    Bridge bridge;
    MockERC20 usdt0;
    MockBtcRelay btcRelay;
    CommissionManager cm;
    RouteRegistry routeRegistry;
    RGBVerifier rgbVerifier;
    NullVerifier nullVerifier;
    RgbSettlementModule rgbModule;
    RgbOutboundSettlementModule outboundModule;
    NullSettlementModule nullModule;

    address deployer = makeAddr("deployer");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address multisig = makeAddr("multisig");

    uint256 constant SOURCE_CHAIN_ID = 31337; // foundry block.chainid
    uint256 constant RGB_CHAIN_ID = 1_000_001; // primary RGB mint/burn network
    uint256 constant ARCH_CHAIN_ID = 1_000_002; // backend-assigned for Arch
    uint256 constant SECONDARY_RGB_CHAIN_ID = 1_000_003; // second RGB mint/burn network (shared canonical ledger)
    uint256 constant PRODUCTION_RGB_MINT_BURN_CHAIN_ID = 96;
    string constant RGB_DST_ADDR = "";
    string constant ARCH_DST_ADDR = "arch:bridge-wallet";
    string constant RGB_SRC_ADDR = ""; // RGB has no source-address concept
    string constant ARCH_SRC_ADDR = "arch:burner";
    bytes32 constant SRC_BURN_TX_ID = keccak256("rebalance-burn-tx-default");
    uint256 constant AMOUNT = 1e18;

    /// @dev Balanced policy that consumes the full configurable budget:
    ///      10% instant burst plus 10% refill per window.
    uint256 constant MAX_BURST_BPS = 1_000;
    uint256 constant MAX_REFILL_BPS = 1_000;
    uint256 constant RGB_OP_ID = 0xABCDEF;

    // BtcRelay test data: deep source block (the RGB burn) + fresh latest block.
    uint256 constant BLOCK_HEIGHT = 850_000;
    bytes32 constant COMMITMENT_HASH = keccak256("test-btc-block-commitment");
    uint256 constant CONFIRMATIONS = 6;
    uint256 constant LATEST_HEIGHT = 850_005;
    bytes32 constant LATEST_COMMIT = keccak256("test-btc-latest-commitment");
    uint256 constant LATEST_CONFIRMATIONS = 1;

    // Seed deposit ids from two distinct RGB mint/burn networks.
    bytes32 rgbSeedOpId;
    bytes32 secondaryRgbSeedOpId;

    function setUp() public {
        usdt0 = new MockERC20("Mock USDT0", "USDT0");
        btcRelay = new MockBtcRelay();
        // The real relay never stores a header below its initialisation
        // checkpoint; mirror that here so a proof this suite accepts is one
        // the deployed relay would also accept.
        btcRelay.setCheckpointHeight(BLOCK_HEIGHT);
        btcRelay.setBlock(BLOCK_HEIGHT, COMMITMENT_HASH, CONFIRMATIONS);
        btcRelay.setBlock(LATEST_HEIGHT, LATEST_COMMIT, LATEST_CONFIRMATIONS);

        // DeployAll-style deploy with predicted Bridge address (see Bridge.t.sol).
        vm.startPrank(deployer);
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 3);

        cm = new CommissionManager(predictedBridge, deployer);
        routeRegistry = new RouteRegistry(predictedBridge, deployer);
        bridge = _deployBridge(address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1, 1, deployer);

        rgbVerifier = new RGBVerifier(address(btcRelay), 6, 1, 5);
        nullVerifier = new NullVerifier();
        rgbModule = new RgbSettlementModule(address(routeRegistry));
        outboundModule = new RgbOutboundSettlementModule(address(routeRegistry), address(rgbModule));
        nullModule = new NullSettlementModule();

        // Deposit routes.
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(SOURCE_CHAIN_ID, ARCH_CHAIN_ID, true, address(nullVerifier), address(nullModule));
        // Rebalance routes (hub model).
        routeRegistry.setRoute(ARCH_CHAIN_ID, RGB_CHAIN_ID, true, address(nullVerifier), address(rgbModule));
        routeRegistry.setRoute(RGB_CHAIN_ID, ARCH_CHAIN_ID, true, address(rgbVerifier), address(outboundModule));

        // A second mint/burn network shares the canonical ledger. Both
        // rebalance directions verify a burn against the source network tag.
        routeRegistry.setRoute(SOURCE_CHAIN_ID, SECONDARY_RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(SECONDARY_RGB_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(RGB_CHAIN_ID, SECONDARY_RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // Production mint/burn network: physical EVM releases and RGB -> Arch
        // rebalances share the same source burn namespace.
        routeRegistry.setRoute(
            SOURCE_CHAIN_ID, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, true, address(rgbVerifier), address(rgbModule)
        );
        routeRegistry.setRoute(
            PRODUCTION_RGB_MINT_BURN_CHAIN_ID, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule)
        );
        routeRegistry.setRoute(
            PRODUCTION_RGB_MINT_BURN_CHAIN_ID, ARCH_CHAIN_ID, true, address(rgbVerifier), address(outboundModule)
        );

        bridge.transferOwnership(multisig);
        vm.stopPrank();

        vm.prank(multisig);
        bridge.acceptOwnership();

        // Outflow policies are percentages of reference liquidity, so they are
        // installed here — before any deposit exists — exactly as a deployment
        // would. Nothing about the configuration depends on current TVL.
        vm.startPrank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setOutflowLimit(ARCH_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setOutflowLimit(SECONDARY_RGB_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setOutflowLimit(PRODUCTION_RGB_MINT_BURN_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setGlobalOutflowLimit(MAX_BURST_BPS, MAX_REFILL_BPS);
        vm.stopPrank();

        // Fund both buckets with real deposits so rebalances have liquidity.
        usdt0.mint(user, AMOUNT * 30);
        vm.prank(user);
        usdt0.approve(address(bridge), type(uint256).max);
        vm.prank(user);
        rgbSeedOpId = bridge.fundsIn(AMOUNT * 10, RGB_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID));
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 10, ARCH_CHAIN_ID, ARCH_DST_ADDR, "");
        vm.prank(user);
        secondaryRgbSeedOpId =
            bridge.fundsIn(AMOUNT * 10, SECONDARY_RGB_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 100));
    }

    // ========================================================================
    // helpers
    // ========================================================================

    /// @dev Empty `(bytes32[], uint256[])` settlement payload — the vacuous
    ///      debit-side check for rebalances with no RGB burn behind them.
    function _emptySettlement() internal pure returns (bytes memory) {
        return abi.encode(new bytes32[](0), new uint256[](0));
    }

    /// @dev `(ids, amounts)` settlement payload with amounts read from the
    ///      canonical RGB ledger, so the exact-match check passes.
    function _settlement(bytes32 id) internal view returns (bytes memory) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = rgbModule.fundsInRecords(id);
        return abi.encode(ids, amounts);
    }

    function _proof() internal pure returns (bytes memory) {
        return abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
    }

    /// @dev Mirror of `Bridge._deriveRebalanceBurnId`. Shares `BURN_TYPEHASH`
    ///      with `fundsOut`: the debit-leg blob and the source burn id are what
    ///      make the key distinct, the credit-leg fields are not part of it.
    function _deriveRebalanceBurnId(IBridge.RebalanceParams memory p) internal view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    bridge.BURN_TYPEHASH(),
                    address(bridge),
                    block.chainid,
                    address(usdt0),
                    p.amount,
                    p.sourceChainId,
                    keccak256(bytes(p.sourceAddress)),
                    keccak256(p.settlementDataOut),
                    p.sourceBurnTxId
                )
            )
        );
    }

    /// @dev Mirror of `Bridge._deriveRebalanceOperationId` (no nonce; folds in
    ///      the canonical burnId so distinct intents get distinct ids).
    function _deriveRebalanceOpId(IBridge.RebalanceParams memory p) internal view returns (bytes32) {
        bytes32 sourceSender = keccak256(bytes(p.sourceAddress));
        return keccak256(
            abi.encode(
                bridge.REBALANCE_OPERATION_TYPEHASH(),
                address(bridge),
                p.sourceChainId,
                sourceSender,
                address(usdt0),
                p.amount,
                p.destinationChainId,
                keccak256(bytes(p.destinationAddress)),
                keccak256(p.settlementDataIn),
                p.burnId,
                block.chainid
            )
        );
    }

    /// @dev Arch → RGB rebalance params (credit-RGB: mint record + FundsIn),
    ///      canonical burnId filled in from the intent.
    function _archToRgbParams(uint256 amount, uint256 rgbOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: ARCH_CHAIN_ID,
            destinationChainId: RGB_CHAIN_ID,
            sourceAddress: ARCH_SRC_ADDR,
            destinationAddress: RGB_DST_ADDR,
            proof: "",
            settlementDataOut: _emptySettlement(),
            settlementDataIn: abi.encode(rgbOpId),
            sourceBurnTxId: bytes32(rgbOpId)
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    /// @dev RGB → Arch rebalance params (debit-RGB: burn-backed), canonical
    ///      burnId filled in from the shared settlement replay fields.
    function _rgbToArchParams(uint256 amount, bytes32 referencedOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: RGB_CHAIN_ID,
            destinationChainId: ARCH_CHAIN_ID,
            sourceAddress: RGB_SRC_ADDR,
            destinationAddress: ARCH_DST_ADDR,
            proof: _proof(),
            settlementDataOut: _settlement(referencedOpId),
            settlementDataIn: "",
            sourceBurnTxId: referencedOpId
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    /// @dev Burn-backed rebalance between two RGB mint/burn networks sharing
    ///      one canonical ledger. The source record is checked before minting
    ///      a new destination record with its own RGB OpId.
    function _secondaryRgbToRgbParams(uint256 amount, bytes32 referencedOpId, uint256 rgbOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: SECONDARY_RGB_CHAIN_ID,
            destinationChainId: RGB_CHAIN_ID,
            sourceAddress: RGB_SRC_ADDR,
            destinationAddress: RGB_DST_ADDR,
            proof: _proof(),
            settlementDataOut: _settlement(referencedOpId),
            settlementDataIn: abi.encode(rgbOpId),
            sourceBurnTxId: referencedOpId
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    /// @dev Reverse mint/burn rebalance, with a burn-backed primary-network debit.
    function _rgbToSecondaryRgbParams(uint256 amount, uint256 rgbOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: RGB_CHAIN_ID,
            destinationChainId: SECONDARY_RGB_CHAIN_ID,
            sourceAddress: RGB_SRC_ADDR,
            destinationAddress: RGB_DST_ADDR,
            proof: _proof(),
            settlementDataOut: _settlement(rgbSeedOpId),
            settlementDataIn: abi.encode(rgbOpId),
            sourceBurnTxId: rgbSeedOpId
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    /// @dev `len` bytes of 0x61: non-zero, so a 32-byte prefix decodes as a
    ///      non-zero word.
    function _filledBytes(uint256 len) internal pure returns (bytes memory b) {
        b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = 0x61;
        }
    }

    function _rebalance(IBridge.RebalanceParams memory p) internal {
        vm.prank(multisig);
        bridge.rebalanceLiquidity(p);
    }

    function _productionRgbToArchParams(uint256 amount, bytes32 referencedOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: PRODUCTION_RGB_MINT_BURN_CHAIN_ID,
            destinationChainId: ARCH_CHAIN_ID,
            sourceAddress: RGB_SRC_ADDR,
            destinationAddress: ARCH_DST_ADDR,
            proof: _proof(),
            settlementDataOut: _settlement(referencedOpId),
            settlementDataIn: "",
            sourceBurnTxId: referencedOpId
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    // ========================================================================
    // Success paths
    // ========================================================================

    function test_rebalance_archToRgb_movesBucketsAndWritesRecord() public {
        uint256 srcBefore = bridge.lockedLiquidity(ARCH_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 mintOpId = RGB_OP_ID + 1;

        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, mintOpId);
        bytes32 expectedOpId = _deriveRebalanceOpId(p);

        // Credit-RGB rebalance emits the standard FundsIn (the RGB side needs
        // no rebalance awareness) plus the canonical BridgeRebalance.
        vm.expectEmit(true, false, false, true);
        emit FundsIn(multisig, mintOpId, uint64(AMOUNT));
        vm.expectEmit(true, true, false, true);
        emit BridgeRebalance(
            expectedOpId,
            p.burnId,
            ARCH_CHAIN_ID,
            RGB_CHAIN_ID,
            AMOUNT,
            ARCH_SRC_ADDR,
            RGB_DST_ADDR,
            p.settlementDataOut,
            p.settlementDataIn
        );

        _rebalance(p);

        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), srcBefore - AMOUNT, "source bucket debited");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), dstBefore + AMOUNT, "destination bucket credited");
        assertEq(rgbModule.fundsInRecords(expectedOpId), AMOUNT, "mint record written for the credit leg");
        assertTrue(bridge.consumedBurnIds(p.burnId), "replay key consumed");
    }

    function test_rebalance_rgbCreditRejectsAmountAboveUint64WithoutChangingAccounting() public {
        uint256 amount = uint256(type(uint64).max) + 1;
        uint256 additionalLiquidity = amount * 10;

        // The non-RGB deposit leg may hold a uint256 amount. It provides enough
        // source liquidity and bucket capacity to reach the RGB event boundary.
        usdt0.mint(user, additionalLiquidity);
        vm.prank(user);
        bridge.fundsIn(additionalLiquidity, ARCH_CHAIN_ID, ARCH_DST_ADDR, "");

        IBridge.RebalanceParams memory p = _archToRgbParams(amount, RGB_OP_ID + 9_000);
        bytes32 operationId = _deriveRebalanceOpId(p);
        uint256 sourceBefore = bridge.lockedLiquidity(ARCH_CHAIN_ID);
        uint256 destinationBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);

        vm.expectRevert(abi.encodeWithSelector(BridgeBaseUpgradeable.AmountExceedsUint64.selector, amount));
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), sourceBefore, "source debit rolled back");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), destinationBefore, "destination credit rolled back");
        assertEq(rgbModule.fundsInRecords(operationId), 0, "RGB settlement write rolled back");
        assertFalse(bridge.consumedBurnIds(p.burnId), "burn id remains unused");
    }

    function test_rebalance_rgbToArch_burnBacked_noFundsInEvent() public {
        uint256 srcBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(ARCH_CHAIN_ID);

        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);

        vm.recordLogs();
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), srcBefore - AMOUNT, "source bucket debited");
        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), dstBefore + AMOUNT, "destination bucket credited");

        // The credit leg wrote nothing and returned 0, so no RGB-only FundsIn
        // event may appear — only BridgeRebalance.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 fundsInTopic = keccak256("FundsIn(address,uint256,uint64)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != fundsInTopic, "no FundsIn event on a non-RGB credit leg");
        }
    }

    function test_rebalance_movesNoTokens() public {
        uint256 bridgeBalanceBefore = usdt0.balanceOf(address(bridge));
        _rebalance(_archToRgbParams(AMOUNT, RGB_OP_ID + 1));
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBalanceBefore, "custody unchanged");
    }

    // ========================================================================
    // Mint/burn ↔ mint/burn (two RGB networks, one canonical ledger)
    // ========================================================================

    function test_rebalance_secondaryRgbToRgb_checksSourceLedgerWritesDestLedger() public {
        uint256 srcBefore = bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 destinationOpId = RGB_OP_ID + 200;

        IBridge.RebalanceParams memory p = _secondaryRgbToRgbParams(AMOUNT, secondaryRgbSeedOpId, destinationOpId);
        bytes32 expectedOpId = _deriveRebalanceOpId(p);

        // Both sides are RGB: the debit leg verifies the mint/burn record and the
        // credit leg writes a NEW destination record + emits FundsIn — all on the one
        // shared module, no composite module or privileged writer.
        vm.expectEmit(true, false, false, true);
        emit FundsIn(multisig, destinationOpId, uint64(AMOUNT));
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID), srcBefore - AMOUNT, "secondary RGB bucket debited");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), dstBefore + AMOUNT, "primary RGB bucket credited");
        assertEq(rgbModule.fundsInRecords(expectedOpId), AMOUNT, "destination mint record written by credit leg");
        assertEq(rgbModule.fundsInRecordChainIds(expectedOpId), RGB_CHAIN_ID, "record tagged with primary RGB network");
    }

    function test_rebalance_rgbToSecondaryRgb_burnBacked() public {
        uint256 srcBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID);
        uint256 inflateOpId = RGB_OP_ID + 300;

        IBridge.RebalanceParams memory p = _rgbToSecondaryRgbParams(AMOUNT, inflateOpId);
        bytes32 expectedOpId = _deriveRebalanceOpId(p);

        // Both sides use mint/burn: the source burn is verified and the credit
        // creates a new record tagged with the secondary RGB network.
        vm.expectEmit(true, false, false, true);
        emit FundsIn(multisig, inflateOpId, uint64(AMOUNT));
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), srcBefore - AMOUNT, "primary RGB bucket debited");
        assertEq(bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID), dstBefore + AMOUNT, "secondary RGB bucket credited");
        assertEq(rgbModule.fundsInRecords(expectedOpId), AMOUNT, "mint/burn record written by credit leg");
        assertEq(
            rgbModule.fundsInRecordChainIds(expectedOpId),
            SECONDARY_RGB_CHAIN_ID,
            "record tagged with the mint/burn network"
        );
    }

    function test_rebalance_secondaryRgbToRgb_revertsOnCrossNetworkRecord() public {
        // A secondary-network burn cannot cite a primary-network mint record.
        // The shared canonical ledger must enforce the source network tag.
        uint256 destinationOpId = RGB_OP_ID + 201;
        IBridge.RebalanceParams memory p = _secondaryRgbToRgbParams(AMOUNT, rgbSeedOpId, destinationOpId);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbSettlementModule.FundsInRecordChainMismatch.selector,
                rgbSeedOpId,
                SECONDARY_RGB_CHAIN_ID,
                RGB_CHAIN_ID
            )
        );
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_rgbToArch_revertsOnCrossNetworkRecord() public {
        // The outbound module rejects a primary-network burn citing a record
        // from the secondary RGB mint/burn network.
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, secondaryRgbSeedOpId);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbOutboundSettlementModule.FundsInRecordChainMismatch.selector,
                secondaryRgbSeedOpId,
                RGB_CHAIN_ID,
                SECONDARY_RGB_CHAIN_ID
            )
        );
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_preservesTotalLockedLiquidity() public {
        uint256 totalBefore = bridge.lockedLiquidity(RGB_CHAIN_ID) + bridge.lockedLiquidity(ARCH_CHAIN_ID)
            + bridge.lockedLiquidity(SOURCE_CHAIN_ID) + bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID);
        uint256 accountedTotalBefore = bridge.totalLockedLiquidity();

        _rebalance(_archToRgbParams(AMOUNT, RGB_OP_ID + 1));

        uint256 totalAfter = bridge.lockedLiquidity(RGB_CHAIN_ID) + bridge.lockedLiquidity(ARCH_CHAIN_ID)
            + bridge.lockedLiquidity(SOURCE_CHAIN_ID) + bridge.lockedLiquidity(SECONDARY_RGB_CHAIN_ID);
        assertEq(totalAfter, totalBefore, "sum(lockedLiquidity) preserved exactly");
        assertEq(bridge.totalLockedLiquidity(), accountedTotalBefore, "accounted global TVL preserved exactly");
        assertEq(bridge.totalLockedLiquidity(), totalAfter, "global TVL matches isolated liquidity sum");
    }

    function test_rebalance_spendsChainBucketNotGlobal() public {
        uint256 chainBefore = bridge.availableOutflow(ARCH_CHAIN_ID);
        uint256 globalBefore = bridge.availableGlobalOutflow();

        _rebalance(_archToRgbParams(AMOUNT, RGB_OP_ID + 1));

        assertEq(bridge.availableOutflow(ARCH_CHAIN_ID), chainBefore - AMOUNT, "source chain bucket spent");
        assertEq(bridge.availableGlobalOutflow(), globalBefore, "global bucket untouched (no token egress)");
    }

    function test_rebalanceBucketCapacityDoesNotDecayWhenRollingUsageExpires() public {
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);
        uint256 startedAt = block.timestamp;

        _rebalance(_archToRgbParams(AMOUNT, RGB_OP_ID + 1));
        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), AMOUNT * 9, "actual source liquidity debited");

        vm.warp(startedAt + 24 hours + 1 minutes);
        assertEq(bridge.chainOutflowReference(ARCH_CHAIN_ID), AMOUNT * 9, "pre-expiry bucket reference");
        assertEq(bridge.availableOutflow(ARCH_CHAIN_ID), AMOUNT * 9 / 10, "pre-expiry full bucket");

        // The old rolling-inclusive reference incorrectly exposed AMOUNT here,
        // allowing an intent that became permanently above-capacity at expiry.
        // With the actual-liquidity reference it is rejected immediately.
        IBridge.RebalanceParams memory oversized = _archToRgbParams(AMOUNT, RGB_OP_ID + 2);
        uint256 capacityShares = MAX_BURST_BPS * bridge.SHARE_UNIT() / bridge.BPS_DENOMINATOR();
        uint256 requestedShares = (AMOUNT * bridge.SHARE_UNIT() + AMOUNT * 9 - 1) / (AMOUNT * 9);
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.TokenRequestAboveCapacity.selector, capacityShares, requestedShares, address(usdt0)
            )
        );
        bridge.rebalanceLiquidity(oversized);

        vm.warp(startedAt + 25 hours);
        uint256 validAmount = AMOUNT * 9 / 10;
        assertEq(bridge.chainOutflowReference(ARCH_CHAIN_ID), AMOUNT * 9, "post-expiry bucket reference");
        assertEq(bridge.availableOutflow(ARCH_CHAIN_ID), validAmount, "post-expiry full bucket unchanged");

        _rebalance(_archToRgbParams(validAmount, RGB_OP_ID + 3));
        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), AMOUNT * 81 / 10, "valid tranche executes after expiry");
    }

    function test_rebalance_distinctMints_differInDestinationOpId() public {
        // Legitimately distinct credit-side rebalances differ in the destination
        // RGB OpId (settlementDataIn), which alone makes their canonical ids
        // distinct — no nonce needed. Both execute.
        IBridge.RebalanceParams memory first = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        bytes32 firstOpId = _deriveRebalanceOpId(first);
        _rebalance(first);

        IBridge.RebalanceParams memory second = _archToRgbParams(AMOUNT, RGB_OP_ID + 2);
        bytes32 secondOpId = _deriveRebalanceOpId(second);
        assertTrue(first.burnId != second.burnId, "distinct burnId per destination OpId");
        assertTrue(firstOpId != secondOpId, "distinct operationId per destination OpId");

        // Restore the source liquidity so the same absolute amount remains 10%
        // of the live bucket reference. This test isolates destination OpId as
        // the only intent difference rather than relying on rolling usage to
        // preserve a stale, higher reference.
        usdt0.mint(user, AMOUNT);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, ARCH_CHAIN_ID, ARCH_DST_ADDR, "");
        vm.warp(block.timestamp + bridge.BUCKET_REFILL_WINDOW() + 1);
        _rebalance(second);

        assertEq(rgbModule.fundsInRecords(firstOpId), AMOUNT);
        assertEq(rgbModule.fundsInRecords(secondOpId), AMOUNT);
    }

    function test_rebalance_revert_identicalIntentReplay() public {
        // An identical rebalance intent derives the SAME burnId (no nonce), so
        // the second attempt is rejected as a consumed replay — matching
        // fundsOut's replay model exactly.
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        _rebalance(p);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_revert_burnBackedIdenticalIntentReplay() public {
        // Same on-chain replay protection as fundsOut: an identical canonical
        // debit intent derives the same burnId, regardless of the moving proof,
        // so the consumed guard rejects the second attempt. Enclaves own the
        // trust assumption that all included fields are reconstructed
        // canonically from the validated consignment.
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        _rebalance(p);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_operationId_uniquePerBurnEvenWithEmptySettlementIn() public {
        // Two RGB→Arch rebalances identical on the credit side (same source,
        // amount, destination, empty settlementDataIn) but backed by DIFFERENT
        // burns (different sourceBurnTxId + referenced records) must NOT collide on
        // operationId — the event that drives the Arch destination flow.
        // operationId folds in burnId, so debit-side differences propagate.

        // Second RGB deposit → a distinct record to reference for the 2nd burn.
        usdt0.mint(user, AMOUNT);
        vm.prank(user);
        bytes32 secondSeedOpId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 50));

        IBridge.RebalanceParams memory first = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        IBridge.RebalanceParams memory second = _rgbToArchParams(AMOUNT, secondSeedOpId);
        // Differ only on the debit side: distinct referenced records → distinct proof? No,
        // same proof; the settlementDataOut differs → distinct burnId.
        assertTrue(first.burnId != second.burnId, "distinct burnId per referenced burn");
        assertTrue(
            _deriveRebalanceOpId(first) != _deriveRebalanceOpId(second),
            "operationId must differ when only the debit side differs"
        );

        // Capture the emitted operationIds and assert they are distinct.
        vm.recordLogs();
        _rebalance(first);
        vm.warp(block.timestamp + bridge.BUCKET_REFILL_WINDOW() + 1);
        _rebalance(second);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 rebalanceTopic =
            keccak256("BridgeRebalance(bytes32,uint256,uint256,uint256,uint256,string,string,bytes,bytes)");
        bytes32 firstOpId;
        bytes32 secondOpId;
        bool haveFirst;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == rebalanceTopic) {
                if (!haveFirst) {
                    firstOpId = logs[i].topics[1];
                    haveFirst = true;
                } else {
                    secondOpId = logs[i].topics[1];
                }
            }
        }
        assertTrue(haveFirst && secondOpId != bytes32(0), "two BridgeRebalance events captured");
        assertTrue(firstOpId != secondOpId, "emitted operationIds distinct");
    }

    function test_rebalance_worksDuringInflowOnlyPause() public {
        // Inflow-only pause is documented as "withdrawals stay open for
        // liquidity migration" — rebalance IS a liquidity migration.
        vm.prank(multisig);
        bridge.pauseInflow();
        uint256 destinationBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        _rebalance(_archToRgbParams(AMOUNT, RGB_OP_ID + 1));
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), destinationBefore + AMOUNT);
    }

    // ========================================================================
    // Revert paths — Bridge
    // ========================================================================

    function test_rebalance_revert_notOwner() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_revert_invalidBurnId() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        uint256 expected = p.burnId;
        p.burnId = expected + 1;
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidBurnId.selector, expected + 1, expected));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_revert_insufficientChainLiquidity() public {
        uint256 available = bridge.lockedLiquidity(ARCH_CHAIN_ID);
        IBridge.RebalanceParams memory p = _archToRgbParams(available + 1, RGB_OP_ID + 1);
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(IBridge.InsufficientChainLiquidity.selector, ARCH_CHAIN_ID, available + 1, available)
        );
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_revert_zeroAmount() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.amount = 0;
        vm.prank(multisig);
        vm.expectRevert(IBridge.ZeroAmount.selector);
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_revert_sameChain() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.destinationChainId = ARCH_CHAIN_ID;
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.RebalanceSameChain.selector, ARCH_CHAIN_ID));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_revert_zeroChainIds() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.sourceChainId = 0;
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidSourceChainId.selector);
        bridge.rebalanceLiquidity(p);

        p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.destinationChainId = 0;
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidDestinationChainId.selector);
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_revert_settlementDataOutTooLong() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        uint256 max = bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH();
        p.settlementDataOut = _filledBytes(max + 1);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.SettlementDataTooLong.selector, max + 1, max));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_settlementDataOutAtMaxLengthPassesLengthGuard() public {
        // The arbitrary blob does not decode as (bytes32[], uint256[]), so the
        // call reverts later; the guard is isolated by asserting the revert is
        // NOT SettlementDataTooLong.
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.settlementDataOut = _filledBytes(bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH());
        p.burnId = _deriveRebalanceBurnId(p);
        vm.prank(multisig);
        try bridge.rebalanceLiquidity(p) {}
        catch (bytes memory reason) {
            assertTrue(
                bytes4(reason) != IBridge.SettlementDataTooLong.selector,
                "max-length settlementDataOut must clear the length guard"
            );
        }
    }

    function test_rebalance_revert_settlementDataInTooLong() public {
        // The credit leg shares the outbound cap, not the deposit one.
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        uint256 max = bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH();
        p.settlementDataIn = _filledBytes(max + 1);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.SettlementDataTooLong.selector, max + 1, max));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_acceptsSettlementDataInAtMaxLength() public {
        // A max-length blob still decodes as a non-zero RGB OpId (its first
        // 32 bytes), so the credit leg records normally. The length is far
        // above the deposit cap: the rebalance credit leg is not bound by it.
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.settlementDataIn = _filledBytes(bridge.MAX_SETTLEMENT_DATA_OUT_LENGTH());
        assertGt(p.settlementDataIn.length, bridge.MAX_SETTLEMENT_DATA_IN_LENGTH());
        bytes32 expectedOperationId = _deriveRebalanceOpId(p);

        _rebalance(p);

        assertEq(rgbModule.fundsInRecords(expectedOperationId), AMOUNT, "credit at the outbound cap is recorded");
    }

    function test_rebalance_rgbCreditAcceptsEmptyDestinationAddress() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.destinationAddress = "";
        bytes32 expectedOperationId = _deriveRebalanceOpId(p);

        _rebalance(p);

        assertEq(rgbModule.fundsInRecords(expectedOperationId), AMOUNT, "empty-address RGB credit recorded");
        assertEq(
            rgbModule.fundsInRecordChainIds(expectedOperationId), RGB_CHAIN_ID, "record tagged with RGB destination"
        );
    }

    function test_rebalance_revert_routeNotEnabled() public {
        // (ARCH → SOURCE) was never registered as a route.
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.destinationChainId = SOURCE_CHAIN_ID;
        p.burnId = _deriveRebalanceBurnId(p);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IRouteRegistry.RouteNotEnabled.selector, ARCH_CHAIN_ID, SOURCE_CHAIN_ID));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_revert_whenOutflowPaused() public {
        vm.prank(multisig);
        bridge.emergencyPauseAll();
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        vm.prank(multisig);
        vm.expectRevert(BridgeBaseUpgradeable.OutflowEnforcedPause.selector);
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_revert_chainBucketThrottled() public {
        // ARCH holds AMOUNT * 10, so a 500 bps burst is AMOUNT / 2 — less than
        // the AMOUNT being migrated. The rebalance must hit the same per-chain
        // outflow throttle a release would.
        vm.prank(multisig);
        bridge.setOutflowLimit(ARCH_CHAIN_ID, 500, 1);

        uint256 shareUnit = bridge.SHARE_UNIT();
        uint256 capacityShares = 500 * shareUnit / bridge.BPS_DENOMINATOR();
        uint256 requestedShares = AMOUNT * shareUnit / bridge.lockedLiquidity(ARCH_CHAIN_ID);

        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.TokenRequestAboveCapacity.selector, capacityShares, requestedShares, address(usdt0)
            )
        );
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_revert_verifierRejectsBadProof() public {
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        p.proof = abi.encode(BLOCK_HEIGHT + 1, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT); // unknown block
        p.burnId = _deriveRebalanceBurnId(p);
        vm.prank(multisig);
        vm.expectRevert(); // MockBtcRelay reverts on an unknown height
        bridge.rebalanceLiquidity(p);
    }

    // ========================================================================
    // RgbOutboundSettlementModule
    // ========================================================================

    function test_outboundModule_revertsOnEmptyArrays() public {
        FundsOutContext memory ctx = FundsOutContext({
            token: address(usdt0),
            recipient: address(bridge),
            amount: AMOUNT,
            burnId: 1,
            sourceChainId: RGB_CHAIN_ID,
            destChainId: ARCH_CHAIN_ID,
            sourceAddress: RGB_SRC_ADDR,
            isRebalance: true,
            sourceBurnTxId: SRC_BURN_TX_ID
        });

        vm.prank(address(routeRegistry));
        vm.expectRevert(RgbOutboundSettlementModule.EmptySettlementRecords.selector);
        outboundModule.beforeFundsOut(ctx, _emptySettlement());
    }

    function test_outboundModule_revert_unknownRecord() public {
        bytes32 bogus = keccak256("no-such-record");
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bogus;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;
        p.settlementDataOut = abi.encode(ids, amounts);
        p.burnId = _deriveRebalanceBurnId(p);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(RgbOutboundSettlementModule.FundsInNotFound.selector, bogus));
        bridge.rebalanceLiquidity(p);
    }

    function test_outboundModule_revert_amountMismatch() public {
        uint256 recorded = rgbModule.fundsInRecords(rgbSeedOpId);
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = rgbSeedOpId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = recorded - 1;
        p.settlementDataOut = abi.encode(ids, amounts);
        p.burnId = _deriveRebalanceBurnId(p);
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbOutboundSettlementModule.AmountMismatch.selector, rgbSeedOpId, recorded - 1, recorded
            )
        );
        bridge.rebalanceLiquidity(p);
    }

    function test_outboundModule_revert_lengthMismatch() public {
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        p.settlementDataOut = abi.encode(new bytes32[](2), new uint256[](1));
        p.burnId = _deriveRebalanceBurnId(p);
        vm.prank(multisig);
        vm.expectRevert(RgbOutboundSettlementModule.SettlementDataLengthMismatch.selector);
        bridge.rebalanceLiquidity(p);
    }

    function test_outboundModule_revert_notRouteRegistry() public {
        vm.expectRevert(RgbOutboundSettlementModule.NotRouteRegistry.selector);
        outboundModule.beforeFundsOut(
            FundsOutContext({
                token: address(usdt0),
                recipient: address(bridge),
                amount: AMOUNT,
                burnId: 1,
                sourceChainId: RGB_CHAIN_ID,
                destChainId: ARCH_CHAIN_ID,
                sourceAddress: RGB_SRC_ADDR,
                isRebalance: true,
                sourceBurnTxId: SRC_BURN_TX_ID
            }),
            _emptySettlement()
        );

        vm.expectRevert(RgbOutboundSettlementModule.NotRouteRegistry.selector);
        outboundModule.onFundsIn(
            FundsInContext({
                token: address(usdt0),
                sender: address(this),
                sourceSender: bytes32(0),
                grossAmount: AMOUNT,
                netAmount: AMOUNT,
                operationId: bytes32(0),
                senderNonce: 0,
                sourceChainId: RGB_CHAIN_ID,
                destChainId: ARCH_CHAIN_ID,
                destAddress: ARCH_DST_ADDR
            }),
            ""
        );
    }

    function test_outboundModule_constructor_rejectsZeroArgs() public {
        vm.expectRevert(RgbOutboundSettlementModule.InvalidRouteRegistry.selector);
        new RgbOutboundSettlementModule(address(0), address(rgbModule));
        vm.expectRevert(RgbOutboundSettlementModule.InvalidRgbModule.selector);
        new RgbOutboundSettlementModule(address(routeRegistry), address(0));
    }

    // ========================================================================
    // shared replay namespace across fundsOut and rebalanceLiquidity
    //
    // Both paths derive `burnId` under the same `BURN_TYPEHASH` from the same
    // fields, so one source-chain burn settles at most once no matter which
    // path is used. Before this, the two derivations used separate typehashes
    // and the same burn could be settled twice.
    // ========================================================================

    /// @notice A rebalance and a release describing the same burn derive the
    ///         same `burnId`, so the second one is rejected as a replay.
    function test_sameBurnCannotSettleViaBothRebalanceAndFundsOut() public {
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        _rebalance(p);
        assertTrue(bridge.consumedBurnIds(p.burnId), "rebalance consumed the id");

        // Same burn, same amount, same route — now as a physical release.
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        vm.prank(multisig);
        bridge.fundsOut(
            IBridge.FundsOutParams({
                recipient: recipient,
                amount: p.amount,
                burnId: p.burnId,
                sourceChainId: p.sourceChainId,
                destinationChainId: p.destinationChainId,
                sourceAddress: p.sourceAddress,
                proof: p.proof,
                settlementData: p.settlementDataOut,
                sourceBurnTxId: p.sourceBurnTxId
            })
        );
    }

    /// @notice One RGB mint/burn-network burn, migrated to Arch (96 -> Arch)
    ///         and then released to EVM (96 -> EVM). The two
    ///         paths carry different `destinationChainId`s, so the key must not
    ///         include it — otherwise the same burn settles once on each path.
    function test_sameBurnCannotSettleViaRebalanceThenFundsOutToAnotherDestination() public {
        (IBridge.RebalanceParams memory p, IBridge.FundsOutParams memory release) = _seedMintBurnBurnOnBothPaths();

        _rebalance(p);
        assertTrue(bridge.consumedBurnIds(p.burnId), "rebalance consumed the id");

        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        vm.prank(multisig);
        bridge.fundsOut(release);
    }

    /// @notice Reverse order of the test above: a physical release first, then a
    ///         rebalance of the same burn toward a different destination bucket.
    function test_sameBurnCannotSettleViaFundsOutThenRebalanceToAnotherDestination() public {
        (IBridge.RebalanceParams memory p, IBridge.FundsOutParams memory release) = _seedMintBurnBurnOnBothPaths();

        vm.prank(multisig);
        bridge.fundsOut(release);
        assertTrue(bridge.consumedBurnIds(release.burnId), "fundsOut consumed the id");

        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        _rebalance(p);
    }

    /// @dev One 96 burn described twice: as a 96 -> Arch rebalance and as a
    ///      96 -> EVM release. Every key field matches; only the destination
    ///      differs, and both carry the rebalance-derived `burnId`.
    function _seedMintBurnBurnOnBothPaths()
        internal
        returns (IBridge.RebalanceParams memory p, IBridge.FundsOutParams memory release)
    {
        usdt0.mint(user, AMOUNT * 19);
        vm.prank(user);
        bytes32 backingOperationId =
            bridge.fundsIn(AMOUNT, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 3_000));
        // Headroom under the 10% bucket burst; each deposit stays within uint64.
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 9, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 3_001));
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 9, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 3_002));

        p = _productionRgbToArchParams(AMOUNT, backingOperationId);
        release = IBridge.FundsOutParams({
            recipient: recipient,
            amount: p.amount,
            burnId: p.burnId,
            sourceChainId: p.sourceChainId,
            destinationChainId: SOURCE_CHAIN_ID,
            sourceAddress: p.sourceAddress,
            proof: p.proof,
            settlementData: p.settlementDataOut,
            sourceBurnTxId: p.sourceBurnTxId
        });
        assertTrue(release.destinationChainId != p.destinationChainId, "paths credit different destinations");
    }

    /// @notice The credit-leg blob is deliberately outside the key: it says where
    ///         value goes, not which burn produced it. Two rebalances of the same
    ///         burn therefore collide even with different destination OpIds.
    function test_rebalanceBurnIdIgnoresCreditLegData() public view {
        IBridge.RebalanceParams memory a = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        IBridge.RebalanceParams memory b = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        b.settlementDataIn = abi.encode(uint256(0xFEED));
        assertEq(_deriveRebalanceBurnId(b), a.burnId, "credit-leg data does not change the key");
    }

    /// @notice Distinct burns stay distinct: the source burn id is what separates
    ///         them once `proof` and the credit-leg fields are out of the key.
    function test_rebalanceBurnIdSeparatesDistinctBurns() public view {
        IBridge.RebalanceParams memory a = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        IBridge.RebalanceParams memory b = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        b.sourceBurnTxId = keccak256("a-different-rgb-burn");
        assertTrue(_deriveRebalanceBurnId(b) != a.burnId, "a different burn derives a different id");
    }

    /// @notice Bridge refuses a settlement that does not name its source burn.
    ///         The guard is route-agnostic on purpose: every chain supplies a
    ///         burn id, and it is the only field that keeps `burnId` distinct on
    ///         routes whose `settlementData` is empty.
    function test_rebalanceRevertsOnZeroSourceBurnTxId() public {
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        p.sourceBurnTxId = bytes32(0);
        p.burnId = _deriveRebalanceBurnId(p);

        vm.expectRevert(IBridge.ZeroSourceBurnTxId.selector);
        _rebalance(p);
    }

    /// @notice An empty `sourceAddress` hashes to keccak256 of the empty byte
    ///         string, not to zero. Pinned so an off-chain signer that encodes it
    ///         differently fails here rather than on-chain with InvalidBurnId.
    function test_emptySourceAddressHashesToKnownConstant() public pure {
        assertEq(
            keccak256(bytes("")),
            bytes32(0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470),
            "empty string hash"
        );
    }
}
