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
import {RgbPoolSettlementModule} from "../src/settlement/RgbPoolSettlementModule.sol";
import {NullSettlementModule} from "../src/settlement/NullSettlementModule.sol";
import {BridgeBase} from "../src/BridgeBase.sol";
import {OutflowRateLimiter} from "../src/libraries/OutflowRateLimiter.sol";
import {FundsInContext, FundsOutContext} from "../src/interfaces/RouteTypes.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBtcRelay} from "./mocks/MockBtcRelay.sol";

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
contract BridgeRebalanceTest is Test {
    event FundsIn(address indexed sender, uint256 indexed rgbOpId, uint256 amount);
    event BridgeRebalance(
        bytes32 indexed operationId,
        uint256 indexed burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        uint256 amount,
        string sourceAddress,
        string destinationAddress
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
    RgbPoolSettlementModule poolModule;
    NullSettlementModule nullModule;

    address deployer = makeAddr("deployer");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address multisig = makeAddr("multisig");

    uint256 constant SOURCE_CHAIN_ID = 31337; // foundry block.chainid
    uint256 constant RGB_CHAIN_ID = 1_000_001; // RGB pool network
    uint256 constant ARCH_CHAIN_ID = 1_000_002; // backend-assigned for Arch
    uint256 constant RGB_MINTBURN_CHAIN_ID = 1_000_003; // RGB mint/burn network (variant C: same module)
    uint256 constant PRODUCTION_RGB_MINT_BURN_CHAIN_ID = 96;
    uint256 constant PRODUCTION_RGB_POOL_CHAIN_ID = 97;
    string constant RGB_DST_ADDR = "rgb:asset1qp0y3mq6h5k8d9f2e4j7n6c3w/utxo1abc123";
    string constant ARCH_DST_ADDR = "arch:bridge-wallet";
    string constant RGB_SRC_ADDR = "rgb:burner/utxo1burn";
    string constant ARCH_SRC_ADDR = "arch:burner";
    uint256 constant AMOUNT = 100e18;

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
    bytes32 constant FUNDS_OUT_BURN_ID_TYPEHASH = keccak256(
        "UtexoFundsOutBurnId(address bridge,uint256 chainId,address token,address recipient,uint256 amount,uint256 sourceChainId,uint256 destinationChainId,bytes32 sourceAddressHash,bytes32 proofHash,bytes32 settlementDataHash)"
    );

    // Seed deposit ids (captured in setUp): RGB-pool and RGB-mint/burn deposits.
    bytes32 rgbSeedOpId;
    bytes32 mintBurnSeedOpId;

    function setUp() public {
        usdt0 = new MockERC20("Mock USDT0", "USDT0");
        btcRelay = new MockBtcRelay();
        btcRelay.setBlock(BLOCK_HEIGHT, COMMITMENT_HASH, CONFIRMATIONS);
        btcRelay.setBlock(LATEST_HEIGHT, LATEST_COMMIT, LATEST_CONFIRMATIONS);

        // DeployAll-style deploy with predicted Bridge address (see Bridge.t.sol).
        vm.startPrank(deployer);
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 2);

        cm = new CommissionManager(predictedBridge, deployer);
        routeRegistry = new RouteRegistry(predictedBridge, deployer);
        bridge = new Bridge(address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1, 1);

        rgbVerifier = new RGBVerifier(address(btcRelay), 6, 1, 5);
        nullVerifier = new NullVerifier();
        rgbModule = new RgbSettlementModule(address(routeRegistry));
        outboundModule = new RgbOutboundSettlementModule(address(routeRegistry), address(rgbModule));
        poolModule = new RgbPoolSettlementModule(
            address(routeRegistry), address(rgbModule), PRODUCTION_RGB_POOL_CHAIN_ID, PRODUCTION_RGB_MINT_BURN_CHAIN_ID
        );
        nullModule = new NullSettlementModule();

        // Deposit routes.
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(SOURCE_CHAIN_ID, ARCH_CHAIN_ID, true, address(nullVerifier), address(nullModule));
        // Rebalance routes (hub model).
        routeRegistry.setRoute(ARCH_CHAIN_ID, RGB_CHAIN_ID, true, address(nullVerifier), address(rgbModule));
        routeRegistry.setRoute(RGB_CHAIN_ID, ARCH_CHAIN_ID, true, address(rgbVerifier), address(outboundModule));

        // Second RGB network (mint/burn) served by the SAME canonical module —
        // one ledger, records network-tagged (variant C). Deposit + both
        // rebalance directions between the two RGB networks.
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_MINTBURN_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        // MintBurn → Pool (scenario B): burn-backed on the mint/burn side → RGBVerifier.
        routeRegistry.setRoute(RGB_MINTBURN_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        // Pool → MintBurn (scenario A): operational, no external burn → NullVerifier.
        routeRegistry.setRoute(RGB_CHAIN_ID, RGB_MINTBURN_CHAIN_ID, true, address(nullVerifier), address(rgbModule));

        // Production topology:
        //   42161-like EVM <-> 96 (mint/burn) — canonical ledger + RGB event
        //   42161-like EVM <-> 97 (pool)      — no pool record / RGB event;
        //                                      pool releases read 96's ledger
        //   96 -> 97 rebalance               — check 96, write nothing for 97
        //   97 -> 96 rebalance               — accounting-only pool debit,
        //                                      canonical write + RGB event for 96
        routeRegistry.setRoute(
            SOURCE_CHAIN_ID, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, true, address(rgbVerifier), address(rgbModule)
        );
        routeRegistry.setRoute(
            PRODUCTION_RGB_MINT_BURN_CHAIN_ID, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule)
        );
        routeRegistry.setRoute(
            SOURCE_CHAIN_ID, PRODUCTION_RGB_POOL_CHAIN_ID, true, address(nullVerifier), address(poolModule)
        );
        routeRegistry.setRoute(
            PRODUCTION_RGB_POOL_CHAIN_ID, SOURCE_CHAIN_ID, true, address(nullVerifier), address(poolModule)
        );
        routeRegistry.setRoute(
            PRODUCTION_RGB_MINT_BURN_CHAIN_ID,
            PRODUCTION_RGB_POOL_CHAIN_ID,
            true,
            address(rgbVerifier),
            address(outboundModule)
        );
        routeRegistry.setRoute(
            PRODUCTION_RGB_POOL_CHAIN_ID,
            PRODUCTION_RGB_MINT_BURN_CHAIN_ID,
            true,
            address(nullVerifier),
            address(rgbModule)
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
        bridge.setOutflowLimit(RGB_MINTBURN_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setOutflowLimit(PRODUCTION_RGB_MINT_BURN_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setOutflowLimit(PRODUCTION_RGB_POOL_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
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
        mintBurnSeedOpId = bridge.fundsIn(AMOUNT * 10, RGB_MINTBURN_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 100));
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

    /// @dev Mirror of `Bridge._deriveRebalanceBurnId` (no nonce — derived purely
    ///      from the rebalance intent).
    function _deriveRebalanceBurnId(IBridge.RebalanceParams memory p) internal view returns (uint256) {
        return uint256(
            keccak256(
                bytes.concat(
                    abi.encode(
                        bridge.REBALANCE_BURN_ID_TYPEHASH(),
                        address(bridge),
                        block.chainid,
                        address(usdt0),
                        p.amount,
                        p.sourceChainId,
                        p.destinationChainId
                    ),
                    abi.encode(
                        keccak256(bytes(p.sourceAddress)),
                        keccak256(bytes(p.destinationAddress)),
                        keccak256(p.proof),
                        keccak256(p.settlementDataOut),
                        keccak256(p.settlementDataIn)
                    )
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
            settlementDataIn: abi.encode(rgbOpId)
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    /// @dev RGB → Arch rebalance params (debit-RGB: burn-backed), canonical
    ///      burnId filled in from the full intent.
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
            settlementDataIn: ""
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    /// @dev MintBurn → Pool rebalance params (both sides RGB, one module):
    ///      debit checks the mint/burn ledger (burn-backed), credit writes the
    ///      pool ledger + emits FundsIn. `referencedOpId` must be a mint/burn
    ///      record; `poolRgbOpId` is the pool-side inflate OpId.
    function _mintBurnToPoolParams(uint256 amount, bytes32 referencedOpId, uint256 poolRgbOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: RGB_MINTBURN_CHAIN_ID,
            destinationChainId: RGB_CHAIN_ID,
            sourceAddress: RGB_SRC_ADDR,
            destinationAddress: RGB_DST_ADDR,
            proof: _proof(),
            settlementDataOut: _settlement(referencedOpId),
            settlementDataIn: abi.encode(poolRgbOpId)
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    /// @dev Pool → MintBurn rebalance params (scenario A, operational): no
    ///      external burn, empty proof + empty debit settlement (NullVerifier
    ///      route). Credit writes the mint/burn ledger + emits FundsIn.
    ///      `mintBurnRgbOpId` is the mint/burn-side inflate OpId.
    function _poolToMintBurnParams(uint256 amount, uint256 mintBurnRgbOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: RGB_CHAIN_ID,
            destinationChainId: RGB_MINTBURN_CHAIN_ID,
            sourceAddress: RGB_SRC_ADDR,
            destinationAddress: RGB_DST_ADDR,
            proof: "",
            settlementDataOut: _emptySettlement(),
            settlementDataIn: abi.encode(mintBurnRgbOpId)
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    function _rebalance(IBridge.RebalanceParams memory p) internal {
        vm.prank(multisig);
        bridge.rebalanceLiquidity(p);
    }

    function _productionMintBurnToPoolParams(uint256 amount, bytes32 referencedOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: PRODUCTION_RGB_MINT_BURN_CHAIN_ID,
            destinationChainId: PRODUCTION_RGB_POOL_CHAIN_ID,
            sourceAddress: RGB_SRC_ADDR,
            destinationAddress: RGB_DST_ADDR,
            proof: _proof(),
            settlementDataOut: _settlement(referencedOpId),
            settlementDataIn: ""
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    function _productionPoolToMintBurnParams(uint256 amount, uint256 rgbOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: PRODUCTION_RGB_POOL_CHAIN_ID,
            destinationChainId: PRODUCTION_RGB_MINT_BURN_CHAIN_ID,
            sourceAddress: RGB_SRC_ADDR,
            destinationAddress: RGB_DST_ADDR,
            proof: "",
            settlementDataOut: _emptySettlement(),
            settlementDataIn: abi.encode(rgbOpId)
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    function _deriveFundsOutBurnId(
        address recipient_,
        uint256 amount,
        uint256 sourceChainId,
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
                    SOURCE_CHAIN_ID,
                    keccak256(bytes(RGB_SRC_ADDR)),
                    keccak256(proof),
                    keccak256(settlementData)
                )
            )
        );
    }

    function _countBridgeLogs(Vm.Log[] memory logs, bytes32 topic0) internal view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(bridge) && logs[i].topics[0] == topic0) count++;
        }
    }

    // ========================================================================
    // Success paths
    // ========================================================================

    function test_productionTopology_poolFundsInEmitsOnlyBridgeFundsInAndWritesNoRecord() public {
        usdt0.mint(user, AMOUNT);

        vm.recordLogs();
        vm.prank(user);
        bytes32 operationId = bridge.fundsIn(AMOUNT, PRODUCTION_RGB_POOL_CHAIN_ID, RGB_DST_ADDR, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(rgbModule.fundsInRecords(operationId), 0, "pool deposit creates no mint/burn record");
        assertEq(
            _countBridgeLogs(logs, keccak256("FundsIn(address,uint256,uint256)")),
            0,
            "pool deposit emits no RGB FundsIn"
        );
        assertEq(
            _countBridgeLogs(
                logs,
                keccak256(
                    "BridgeFundsIn(bytes32,bytes32,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,string)"
                )
            ),
            1,
            "pool deposit emits one canonical BridgeFundsIn"
        );
    }

    function test_productionTopology_poolFundsOutReadsMintBurnLedger() public {
        usdt0.mint(user, AMOUNT * 11);

        vm.prank(user);
        bytes32 backingOperationId =
            bridge.fundsIn(AMOUNT, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 1_000));
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 10, PRODUCTION_RGB_POOL_CHAIN_ID, RGB_DST_ADDR, "");

        bytes memory settlementData = _settlement(backingOperationId);
        bytes memory proof = "";
        uint256 burnId = _deriveFundsOutBurnId(recipient, AMOUNT, PRODUCTION_RGB_POOL_CHAIN_ID, proof, settlementData);

        vm.prank(multisig);
        bridge.fundsOut(
            IBridge.FundsOutParams({
                recipient: recipient,
                amount: AMOUNT,
                burnId: burnId,
                sourceChainId: PRODUCTION_RGB_POOL_CHAIN_ID,
                destinationChainId: SOURCE_CHAIN_ID,
                sourceAddress: RGB_SRC_ADDR,
                proof: proof,
                settlementData: settlementData
            })
        );

        assertEq(usdt0.balanceOf(recipient), AMOUNT, "pool-backed fundsOut releases tokens");
        assertEq(rgbModule.fundsInRecords(backingOperationId), AMOUNT, "backing record remains permanent");
    }

    function test_productionTopology_mintBurnToPoolRebalanceWritesNoPoolRecordOrFundsInEvent() public {
        usdt0.mint(user, AMOUNT * 10);
        vm.prank(user);
        bytes32 backingOperationId =
            bridge.fundsIn(AMOUNT, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 2_000));
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 9, PRODUCTION_RGB_MINT_BURN_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 2_001));

        IBridge.RebalanceParams memory p = _productionMintBurnToPoolParams(AMOUNT, backingOperationId);
        bytes32 rebalanceOperationId = _deriveRebalanceOpId(p);

        vm.recordLogs();
        _rebalance(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(rgbModule.fundsInRecords(rebalanceOperationId), 0, "pool credit writes no canonical record");
        assertEq(
            _countBridgeLogs(logs, keccak256("FundsIn(address,uint256,uint256)")), 0, "pool credit emits no RGB FundsIn"
        );
    }

    function test_productionTopology_poolToMintBurnRebalanceWritesCanonicalRecordAndFundsInEvent() public {
        usdt0.mint(user, AMOUNT * 10);
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 10, PRODUCTION_RGB_POOL_CHAIN_ID, RGB_DST_ADDR, "");

        uint256 rgbOpId = RGB_OP_ID + 3_000;
        IBridge.RebalanceParams memory p = _productionPoolToMintBurnParams(AMOUNT, rgbOpId);
        bytes32 rebalanceOperationId = _deriveRebalanceOpId(p);

        vm.expectEmit(true, true, false, true);
        emit FundsIn(multisig, rgbOpId, AMOUNT);
        _rebalance(p);

        assertEq(rgbModule.fundsInRecords(rebalanceOperationId), AMOUNT, "mint/burn credit creates record");
        assertEq(
            rgbModule.fundsInRecordChainIds(rebalanceOperationId),
            PRODUCTION_RGB_MINT_BURN_CHAIN_ID,
            "mint/burn record has network 96 tag"
        );
    }

    function test_rebalance_archToRgb_movesBucketsAndWritesRecord() public {
        uint256 srcBefore = bridge.lockedLiquidity(ARCH_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 mintOpId = RGB_OP_ID + 1;

        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, mintOpId);
        bytes32 expectedOpId = _deriveRebalanceOpId(p);

        // Credit-RGB rebalance emits the standard FundsIn (the RGB side needs
        // no rebalance awareness) plus the canonical BridgeRebalance.
        vm.expectEmit(true, true, false, true);
        emit FundsIn(multisig, mintOpId, AMOUNT);
        vm.expectEmit(true, true, false, true);
        emit BridgeRebalance(expectedOpId, p.burnId, ARCH_CHAIN_ID, RGB_CHAIN_ID, AMOUNT, ARCH_SRC_ADDR, RGB_DST_ADDR);

        _rebalance(p);

        assertEq(bridge.lockedLiquidity(ARCH_CHAIN_ID), srcBefore - AMOUNT, "source bucket debited");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), dstBefore + AMOUNT, "destination bucket credited");
        assertEq(rgbModule.fundsInRecords(expectedOpId), AMOUNT, "mint record written for the credit leg");
        assertTrue(bridge.consumedBurnIds(p.burnId), "replay key consumed");
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
        bytes32 fundsInTopic = keccak256("FundsIn(address,uint256,uint256)");
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
    // MintBurn ↔ Pool (variant C: one module, two RGB networks, one ledger)
    // ========================================================================

    function test_rebalance_mintBurnToPool_checksSourceLedgerWritesDestLedger() public {
        uint256 srcBefore = bridge.lockedLiquidity(RGB_MINTBURN_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 poolOpId = RGB_OP_ID + 200;

        IBridge.RebalanceParams memory p = _mintBurnToPoolParams(AMOUNT, mintBurnSeedOpId, poolOpId);
        bytes32 expectedOpId = _deriveRebalanceOpId(p);

        // Both sides are RGB: the debit leg verifies the mint/burn record and the
        // credit leg writes a NEW pool record + emits FundsIn — all on the one
        // shared module, no composite module or privileged writer.
        vm.expectEmit(true, true, false, true);
        emit FundsIn(multisig, poolOpId, AMOUNT);
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(RGB_MINTBURN_CHAIN_ID), srcBefore - AMOUNT, "mint/burn bucket debited");
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), dstBefore + AMOUNT, "pool bucket credited");
        assertEq(rgbModule.fundsInRecords(expectedOpId), AMOUNT, "pool record written by credit leg");
        assertEq(rgbModule.fundsInRecordChainIds(expectedOpId), RGB_CHAIN_ID, "pool record tagged with pool network");
    }

    function test_rebalance_poolToMintBurn_operationalNoProof() public {
        uint256 srcBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(RGB_MINTBURN_CHAIN_ID);
        uint256 inflateOpId = RGB_OP_ID + 300;

        IBridge.RebalanceParams memory p = _poolToMintBurnParams(AMOUNT, inflateOpId);
        bytes32 expectedOpId = _deriveRebalanceOpId(p);

        // Scenario A: operational, no external burn → NullVerifier, empty proof
        // and empty debit settlement. The credit leg writes the mint/burn record
        // (tagged with the mint/burn network) and emits the inflate FundsIn.
        vm.expectEmit(true, true, false, true);
        emit FundsIn(multisig, inflateOpId, AMOUNT);
        _rebalance(p);

        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), srcBefore - AMOUNT, "pool bucket debited");
        assertEq(bridge.lockedLiquidity(RGB_MINTBURN_CHAIN_ID), dstBefore + AMOUNT, "mint/burn bucket credited");
        assertEq(rgbModule.fundsInRecords(expectedOpId), AMOUNT, "mint/burn record written by credit leg");
        assertEq(
            rgbModule.fundsInRecordChainIds(expectedOpId),
            RGB_MINTBURN_CHAIN_ID,
            "record tagged with the mint/burn network"
        );
    }

    function test_rebalance_mintBurnToPool_revertsOnCrossNetworkRecord() public {
        // A MintBurn→Pool burn tries to cite a POOL-minted record (rgbSeedOpId)
        // as its proof-of-mint. The debit source is the mint/burn network, so the
        // network-scoped check must reject it — records cannot cross-satisfy.
        uint256 poolOpId = RGB_OP_ID + 201;
        IBridge.RebalanceParams memory p = _mintBurnToPoolParams(AMOUNT, rgbSeedOpId, poolOpId);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbSettlementModule.FundsInRecordChainMismatch.selector,
                rgbSeedOpId,
                RGB_MINTBURN_CHAIN_ID,
                RGB_CHAIN_ID
            )
        );
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_rgbToArch_revertsOnCrossNetworkRecord() public {
        // The outbound module enforces the same network scope: an RGB(pool)→Arch
        // burn citing a mint/burn-network record is rejected.
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, mintBurnSeedOpId);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(
                RgbOutboundSettlementModule.FundsInRecordChainMismatch.selector,
                mintBurnSeedOpId,
                RGB_CHAIN_ID,
                RGB_MINTBURN_CHAIN_ID
            )
        );
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_preservesTotalLockedLiquidity() public {
        uint256 totalBefore = bridge.lockedLiquidity(RGB_CHAIN_ID) + bridge.lockedLiquidity(ARCH_CHAIN_ID)
            + bridge.lockedLiquidity(SOURCE_CHAIN_ID) + bridge.lockedLiquidity(RGB_MINTBURN_CHAIN_ID);
        uint256 accountedTotalBefore = bridge.totalLockedLiquidity();

        _rebalance(_archToRgbParams(AMOUNT, RGB_OP_ID + 1));

        uint256 totalAfter = bridge.lockedLiquidity(RGB_CHAIN_ID) + bridge.lockedLiquidity(ARCH_CHAIN_ID)
            + bridge.lockedLiquidity(SOURCE_CHAIN_ID) + bridge.lockedLiquidity(RGB_MINTBURN_CHAIN_ID);
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
        // Same on-chain replay protection as fundsOut: an IDENTICAL burn-backed
        // intent (same proof + referenced records + all fields) derives the same
        // burnId → consumed guard reverts. Before the nonce was removed,
        // incrementing it re-enabled this replay.
        //
        // NB: this does NOT prove single-real-burn uniqueness (same Bitcoin burn
        // reused via a DIFFERENT intent, or across fundsOut+rebalance) — that is
        // the documented enclave-trust residual, not enforceable on-chain.
        IBridge.RebalanceParams memory p = _rgbToArchParams(AMOUNT, rgbSeedOpId);
        _rebalance(p);

        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, p.burnId));
        bridge.rebalanceLiquidity(p);
    }

    function test_rebalance_operationId_uniquePerBurnEvenWithEmptySettlementIn() public {
        // Two RGB→Arch rebalances identical on the credit side (same source,
        // amount, destination, empty settlementDataIn) but backed by DIFFERENT
        // burns (different proof + referenced records) must NOT collide on
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
        bytes32 rebalanceTopic = keccak256("BridgeRebalance(bytes32,uint256,uint256,uint256,uint256,string,string)");
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

    function test_rebalance_revert_emptyDestinationAddress() public {
        IBridge.RebalanceParams memory p = _archToRgbParams(AMOUNT, RGB_OP_ID + 1);
        p.destinationAddress = "";
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidDestinationAddress.selector);
        bridge.rebalanceLiquidity(p);
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
        vm.expectRevert(BridgeBase.OutflowEnforcedPause.selector);
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
            isRebalance: true
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
                isRebalance: true
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
}
