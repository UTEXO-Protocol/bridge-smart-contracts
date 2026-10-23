// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Bridge} from "../../src/Bridge.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {RouteRegistry} from "../../src/RouteRegistry.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {NullSettlementModule} from "../../src/settlement/NullSettlementModule.sol";
import {RgbOutboundSettlementModule} from "../../src/settlement/RgbOutboundSettlementModule.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {NullVerifier} from "../../src/verifiers/NullVerifier.sol";
import {RGBVerifier} from "../../src/verifiers/RGBVerifier.sol";
import {BridgeProxyTestUtils} from "../helpers/BridgeProxyTestUtils.sol";
import {BurnIdHelper} from "../helpers/BurnIdHelper.sol";
import {MockBtcRelay} from "../mocks/MockBtcRelay.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared Bridge fixture for accounting-only rebalances across RGB and chain A.
/// @dev SOURCE -> RGB: RGBVerifier + RgbSettlementModule, creates a mint record.
///      SOURCE -> chain A: NullVerifier + NullSettlementModule, credits liquidity.
///      chain A -> RGB: NullVerifier + RgbSettlementModule, accepts empty debit
///      records and creates a destination record plus FundsIn event.
///      RGB -> chain A: RGBVerifier + RgbOutboundSettlementModule, verifies the
///      burn and exact debit records; creates neither a mint nor FundsIn event.
///      Secondary and mint/burn fixture routes share the canonical record ledger
///      and source-burn replay namespace.
abstract contract BridgeRebalanceTestBase is Test, BridgeProxyTestUtils {
    Bridge internal bridge;

    MockERC20 internal usdt0;

    MockBtcRelay internal btcRelay;

    CommissionManager internal cm;

    RouteRegistry internal routeRegistry;

    RGBVerifier internal rgbVerifier;

    NullVerifier internal nullVerifier;

    RgbSettlementModule internal rgbModule;

    RgbOutboundSettlementModule internal outboundModule;

    NullSettlementModule internal nullModule;

    address internal deployer = makeAddr("deployer");

    address internal user = makeAddr("user");

    address internal multisig = makeAddr("multisig");

    uint256 internal constant SOURCE_CHAIN_ID = 31337; // foundry block.chainid

    uint256 internal constant RGB_CHAIN_ID = 1_000_001; // primary RGB mint/burn network

    uint256 internal constant CHAIN_A_ID = 1_000_002; // synthetic chain A fixture

    // Secondary RGB fixture sharing the canonical ledger.
    uint256 internal constant SECONDARY_RGB_CHAIN_ID = 1_000_003;

    // Synthetic fixture id; the production RGB network id is 827166.
    uint256 internal constant MINT_BURN_FIXTURE_CHAIN_ID = 96;

    string internal constant RGB_DST_ADDR = "";

    string internal constant CHAIN_A_DST_ADDR = "chain-a:bridge-wallet";

    string internal constant RGB_SRC_ADDR = ""; // RGB sourceAddress is supplied as an empty string

    string internal constant CHAIN_A_SRC_ADDR = "chain-a:burner";

    uint256 internal constant AMOUNT = 1e18;

    /// @dev Balanced policy that consumes the full configurable budget:
    ///      10% instant burst plus 10% refill per window.
    uint256 internal constant MAX_BURST_BPS = 1_000;

    uint256 internal constant MAX_REFILL_BPS = 1_000;

    uint256 internal constant RGB_OP_ID = 0xABCDEF;

    // BtcRelay test data: deep source block (the RGB burn) + fresh latest block.
    uint256 internal constant BLOCK_HEIGHT = 850_000;

    bytes32 internal constant COMMITMENT_HASH = keccak256("test-btc-block-commitment");

    uint256 internal constant CONFIRMATIONS = 6;

    uint256 internal constant LATEST_HEIGHT = 850_005;

    bytes32 internal constant LATEST_COMMIT = keccak256("test-btc-latest-commitment");

    uint256 internal constant LATEST_CONFIRMATIONS = 1;

    // Seed deposit ids from two distinct RGB mint/burn networks.
    bytes32 internal rgbSeedOpId;

    bytes32 internal secondaryRgbSeedOpId;

    function setUp() public virtual {
        usdt0 = new MockERC20("Mock USDT0", "USDT0");
        btcRelay = new MockBtcRelay();
        // Reject queried heights below the configured checkpoint, as the
        // deployed relay does.
        btcRelay.setCheckpointHeight(BLOCK_HEIGHT);
        btcRelay.setBlock(BLOCK_HEIGHT, COMMITMENT_HASH, CONFIRMATIONS);
        btcRelay.setBlock(LATEST_HEIGHT, LATEST_COMMIT, LATEST_CONFIRMATIONS);

        // Predict the BridgeProxy address after deploying the manager, registry
        // and Bridge implementation.
        vm.startPrank(deployer);
        uint64 currentNonce = vm.getNonce(deployer);
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 3);

        cm = new CommissionManager(predictedBridge, deployer);
        routeRegistry = new RouteRegistry(predictedBridge, deployer);
        bridge = _deployBridge(address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1, 1, deployer);

        rgbVerifier =
            new RGBVerifier(address(btcRelay), CONFIRMATIONS, LATEST_CONFIRMATIONS, LATEST_HEIGHT - BLOCK_HEIGHT);
        nullVerifier = new NullVerifier();
        rgbModule = new RgbSettlementModule(address(routeRegistry));
        outboundModule = new RgbOutboundSettlementModule(address(routeRegistry), address(rgbModule));
        nullModule = new NullSettlementModule();

        // Deposit routes.
        routeRegistry.setRoute(SOURCE_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(SOURCE_CHAIN_ID, CHAIN_A_ID, true, address(nullVerifier), address(nullModule));
        // Rebalance routes (hub model).
        routeRegistry.setRoute(CHAIN_A_ID, RGB_CHAIN_ID, true, address(nullVerifier), address(rgbModule));
        routeRegistry.setRoute(RGB_CHAIN_ID, CHAIN_A_ID, true, address(rgbVerifier), address(outboundModule));

        // A second mint/burn network shares the canonical ledger. Both
        // rebalance directions verify a burn against the source network tag.
        routeRegistry.setRoute(SOURCE_CHAIN_ID, SECONDARY_RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(SECONDARY_RGB_CHAIN_ID, RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        routeRegistry.setRoute(RGB_CHAIN_ID, SECONDARY_RGB_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));

        // Mint/burn fixture: physical EVM releases and RGB -> chain A
        // rebalances share the same source burn namespace.
        routeRegistry.setRoute(
            SOURCE_CHAIN_ID, MINT_BURN_FIXTURE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule)
        );
        routeRegistry.setRoute(
            MINT_BURN_FIXTURE_CHAIN_ID, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule)
        );
        routeRegistry.setRoute(
            MINT_BURN_FIXTURE_CHAIN_ID, CHAIN_A_ID, true, address(rgbVerifier), address(outboundModule)
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
        bridge.setOutflowLimit(CHAIN_A_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setOutflowLimit(SECONDARY_RGB_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setOutflowLimit(MINT_BURN_FIXTURE_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setGlobalOutflowLimit(MAX_BURST_BPS, MAX_REFILL_BPS);
        vm.stopPrank();

        // Fund the RGB, chain A and secondary RGB buckets with real deposits.
        usdt0.mint(user, AMOUNT * 30);
        vm.prank(user);
        usdt0.approve(address(bridge), type(uint256).max);
        vm.prank(user);
        rgbSeedOpId = bridge.fundsIn(AMOUNT * 10, RGB_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID));
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 10, CHAIN_A_ID, CHAIN_A_DST_ADDR, "");
        vm.prank(user);
        secondaryRgbSeedOpId =
            bridge.fundsIn(AMOUNT * 10, SECONDARY_RGB_CHAIN_ID, RGB_DST_ADDR, abi.encode(RGB_OP_ID + 100));
    }

    /// @dev Empty `(bytes32[], uint256[])` settlement payload — the vacuous
    ///      debit-side check for rebalances with no RGB burn behind them.
    function _emptySettlement() internal pure returns (bytes memory) {
        return abi.encode(new bytes32[](0), new uint256[](0));
    }

    /// @dev `(ids, amounts)` settlement payload with amounts read from the
    ///      canonical RGB ledger, so the exact-match check passes.
    function _settlementFromRecord(bytes32 id) internal view returns (bytes memory) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = rgbModule.fundsInRecords(id);
        return abi.encode(ids, amounts);
    }

    function _proof() internal pure returns (bytes memory) {
        return abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
    }

    function _deriveRebalanceBurnId(IBridge.RebalanceParams memory p) internal view returns (uint256) {
        return BurnIdHelper.derive(
            address(bridge), block.chainid, address(usdt0), p.amount, p.sourceChainId, p.sourceAddress, p.sourceBurnTxId
        );
    }

    function _deriveRebalanceOpId(IBridge.RebalanceParams memory p) internal view returns (bytes32) {
        if (p.destinationChainId == RGB_CHAIN_ID || p.destinationChainId == SECONDARY_RGB_CHAIN_ID) {
            return keccak256(
                abi.encode(
                    keccak256(
                        "UtexoRgbMintDeposit(address bridge,uint256 chainId,address token,uint256 rgbNetwork,uint256 rgbOpId,uint256 netAmount)"
                    ),
                    address(bridge),
                    block.chainid,
                    address(usdt0),
                    p.destinationChainId,
                    abi.decode(p.settlementDataIn, (uint256)),
                    p.amount
                )
            );
        }
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

    /// @dev chain A → RGB rebalance params (credit-RGB: mint record + FundsIn),
    ///      canonical burnId filled in from the intent.
    function _chainAToRgbParams(uint256 amount, uint256 rgbOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: CHAIN_A_ID,
            destinationChainId: RGB_CHAIN_ID,
            sourceAddress: CHAIN_A_SRC_ADDR,
            destinationAddress: RGB_DST_ADDR,
            proof: "",
            settlementDataOut: _emptySettlement(),
            settlementDataIn: abi.encode(rgbOpId),
            sourceBurnTxId: bytes32(rgbOpId)
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    /// @dev RGB → chain A rebalance params (debit-RGB: burn-backed), canonical
    ///      burnId filled in from the shared settlement replay fields.
    function _rgbToChainAParams(uint256 amount, bytes32 referencedOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: RGB_CHAIN_ID,
            destinationChainId: CHAIN_A_ID,
            sourceAddress: RGB_SRC_ADDR,
            destinationAddress: CHAIN_A_DST_ADDR,
            proof: _proof(),
            settlementDataOut: _settlementFromRecord(referencedOpId),
            settlementDataIn: "",
            sourceBurnTxId: referencedOpId
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }

    function _rebalance(IBridge.RebalanceParams memory p) internal {
        vm.prank(multisig);
        bridge.rebalanceLiquidity(p);
    }

    function _mintBurnToChainAParams(uint256 amount, bytes32 referencedOpId)
        internal
        view
        returns (IBridge.RebalanceParams memory p)
    {
        p = IBridge.RebalanceParams({
            amount: amount,
            burnId: 0,
            sourceChainId: MINT_BURN_FIXTURE_CHAIN_ID,
            destinationChainId: CHAIN_A_ID,
            sourceAddress: RGB_SRC_ADDR,
            destinationAddress: CHAIN_A_DST_ADDR,
            proof: _proof(),
            settlementDataOut: _settlementFromRecord(referencedOpId),
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
            settlementDataOut: _settlementFromRecord(referencedOpId),
            settlementDataIn: abi.encode(rgbOpId),
            sourceBurnTxId: referencedOpId
        });
        p.burnId = _deriveRebalanceBurnId(p);
    }
}
