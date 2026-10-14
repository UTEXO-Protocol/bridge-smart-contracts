// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Bridge} from "../../src/Bridge.sol";
import {CommissionManager} from "../../src/CommissionManager.sol";
import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {RouteRegistry} from "../../src/RouteRegistry.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {RGBVerifier} from "../../src/verifiers/RGBVerifier.sol";
import {BridgeProxyTestUtils} from "../helpers/BridgeProxyTestUtils.sol";
import {BurnIdHelper} from "../helpers/BurnIdHelper.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MockBtcRelay} from "../mocks/MockBtcRelay.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared fixture and helpers for multisig tests; contains no test cases.
abstract contract MultisigProxyTestBase is Test, BridgeProxyTestUtils {
    MultisigProxy internal proxy;

    Bridge internal bridge;

    CommissionManager internal cm;

    RouteRegistry internal routeRegistry;

    RGBVerifier internal rgbVerifier;

    RgbSettlementModule internal rgbModule;

    MockERC20 internal token;

    MockBtcRelay internal btcRelay;

    // Derived operationId of the setUp() seed deposit (returned by fundsIn).
    bytes32 internal seedOpId;

    // Enclave signers (2-of-3)
    uint256 internal constant ENC_PK_1 = 0xE1;

    uint256 internal constant ENC_PK_2 = 0xE2;

    uint256 internal constant ENC_PK_3 = 0xE3;

    address internal encA1;

    address internal encA2;

    address internal encA3;

    // Federation signers (2-of-3)
    uint256 internal constant FED_PK_1 = 0xF1;

    uint256 internal constant FED_PK_2 = 0xF2;

    uint256 internal constant FED_PK_3 = 0xF3;

    address internal fedA1;

    address internal fedA2;

    address internal fedA3;

    address internal deployer = makeAddr("deployer");

    address internal user = makeAddr("user");

    address internal recipient = makeAddr("recipient");

    address internal commissionReceiver = makeAddr("commissionReceiver");

    address internal emergencyGuardian = makeAddr("emergencyGuardian");

    uint256 internal constant TIMELOCK = 1 hours;

    uint256 internal constant MIN_TIMELOCK = 1 hours; // floor passed to the proxy constructor in tests

    bytes32 internal domainSep;

    // Chain identifiers + canonical fundsOut args
    uint256 internal constant SOURCE_CHAIN_ID = 31337; // foundry block.chainid

    uint256 internal constant RGB_CHAIN_ID = 1_000_001; // backend-assigned for RGB

    string internal constant DST_ADDR = "";

    string internal constant SRC_ADDR = ""; // RGB has no source-address concept

    bytes32 internal constant SRC_BURN_TX_ID = keccak256("multisig-burn-tx-default");

    uint256 internal constant AMOUNT = 1e18;

    /// @dev Balanced policy that consumes the full configurable budget:
    ///      10% instant burst plus 10% refill per window.
    uint256 internal constant MAX_BURST_BPS = 1_000;

    uint256 internal constant MAX_REFILL_BPS = 1_000;

    uint256 internal constant RGB_OP_ID = 0xABCDEF;

    uint256 internal constant LZ_NATIVE_FEE = 0.01 ether;

    uint32 internal constant DST_EID = 30110;

    bytes32 internal constant LZ_RECIPIENT = bytes32(uint256(uint160(0xBEEF)));

    // BtcRelay test data. RGB proof = two (height, commit) pairs: a deep
    // source block (RGB burn/lock) and a fresh latest block. gap = 6 - 1 = 5.
    uint256 internal constant BLOCK_HEIGHT = 850_000; // source block

    bytes32 internal constant COMMITMENT_HASH = keccak256("test-btc-block-commitment");

    uint256 internal constant BTC_CONFIRMATIONS = 6; // source confirmations

    uint256 internal constant LATEST_HEIGHT = 850_005;

    bytes32 internal constant LATEST_COMMIT = keccak256("test-btc-latest-commitment");

    uint256 internal constant LATEST_CONFIRMATIONS = 1;

    function setUp() public virtual {
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

        // DeployAll-style with predicted Bridge address. Deployer tx order:
        //   nonce n      → CommissionManager (uses predicted Bridge)
        //   nonce n+1    → RouteRegistry     (uses predicted Bridge; deployer
        //                                     stays owner for initial route
        //                                     registration, then transfers to
        //                                     proxy)
        //   nonce n+2    → Bridge implementation
        //   nonce n+3    → BridgeProxy (initialized with RouteRegistry and CM)
        //   nonce n+4    → RGBVerifier
        //   nonce n+5    → RgbSettlementModule
        //   nonce n+6    → MultisigProxy
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

        // Register both directions of the RGB route while deployer still owns
        // the registry. Inbound (SOURCE → RGB) never calls verify; outbound
        // (RGB → SOURCE) runs the BtcRelay check.
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
            address(bridge), address(cm), emergencyGuardian, enc, 2, RGB_CHAIN_ID, fed, 2, TIMELOCK, MIN_TIMELOCK
        );

        // Production-flow ownership transfer.
        bridge.transferOwnership(address(proxy));
        cm.transferOwnership(address(proxy));
        routeRegistry.transferOwnership(address(proxy));
        vm.stopPrank();

        // Ownable2Step: the proxy accepts ownership of all three (prank shortcut;
        // the real governance-driven accept path is covered by a dedicated test).
        vm.prank(address(proxy));
        bridge.acceptOwnership();
        vm.prank(address(proxy));
        cm.acceptOwnership();
        vm.prank(address(proxy));
        routeRegistry.acceptOwnership();

        domainSep = proxy.DOMAIN_SEPARATOR();

        // Fund user, lock tokens into the bridge so fundsOut has a pool.
        // Keep a separate user balance for tests that make follow-up deposits
        // or fund the CommissionManager after the 10x seed deposit.
        token.mint(user, AMOUNT * 20);
        vm.prank(user);
        token.approve(address(bridge), type(uint256).max);
        // Policies are percentages of reference liquidity, so they are installed
        // before the deposit — the order a deployment uses. `burstBps +
        // refillBpsPerWindow` is capped at 20%. This balanced policy spends the
        // full configurable budget: 10% available up front, 10% refill/window.
        vm.startPrank(address(proxy));
        bridge.setOutflowLimit(RGB_CHAIN_ID, MAX_BURST_BPS, MAX_REFILL_BPS);
        bridge.setGlobalOutflowLimit(MAX_BURST_BPS, MAX_REFILL_BPS);
        vm.stopPrank();

        vm.prank(user);
        seedOpId = bridge.fundsIn(AMOUNT * 10, RGB_CHAIN_ID, DST_ADDR, abi.encode(RGB_OP_ID));
    }

    function _encSigSet2of3() internal pure returns (uint256[] memory pks, uint256 bitmap) {
        pks = new uint256[](2);
        pks[0] = ENC_PK_1;
        pks[1] = ENC_PK_2;
        bitmap = 0x3;
    }

    function _fedSigSet2of3() internal pure returns (uint256[] memory pks, uint256 bitmap) {
        pks = new uint256[](2);
        pks[0] = FED_PK_1;
        pks[1] = FED_PK_2;
        bitmap = 0x3;
    }

    function _fundsInIds() internal view returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = seedOpId;
    }

    /// @dev Build `settlementData` for RgbSettlementModule, which
    ///      expects `(bytes32[] operationIds, uint256[] amounts)` and checks
    ///      each id exists with an EXACTLY matching amount (no consumption).
    ///      The amount is derived from the on-chain mint record so an exact
    ///      match is guaranteed for the common path; ids with no record resolve
    ///      to amount 0 (the module then reverts FundsInNotFound first).
    function _settlementFromRecords(bytes32[] memory ids) internal view returns (bytes memory) {
        uint256[] memory amounts = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            amounts[i] = rgbModule.fundsInRecords(ids[i]);
        }
        return abi.encode(ids, amounts);
    }

    /// @dev Valid 2-of-2 enclave quorum for constructor tests.
    function _validEnc() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = encA1;
        a[1] = encA2;
    }

    function _validFed() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = fedA1;
        a[1] = fedA2;
    }

    /// @dev Standard single-release params (recipient = `recipient`, AMOUNT, canonical burnId).
    function _fundsOutParams() internal view returns (IBridge.FundsOutParams memory) {
        return _fundsOutParams(recipient, AMOUNT, SRC_BURN_TX_ID);
    }

    function _fundsOutParams(address payoutRecipient, uint256 amount, bytes32 sourceBurnTxId)
        internal
        view
        returns (IBridge.FundsOutParams memory)
    {
        bytes memory proof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
        bytes memory settlementData = _settlementFromRecords(_fundsInIds());
        uint256 derivedBurnId = _deriveBurnId(amount, RGB_CHAIN_ID, SRC_ADDR, sourceBurnTxId);

        return IBridge.FundsOutParams({
            recipient: payoutRecipient,
            amount: amount,
            burnId: derivedBurnId,
            sourceChainId: RGB_CHAIN_ID,
            destinationChainId: SOURCE_CHAIN_ID,
            sourceAddress: SRC_ADDR,
            proof: proof,
            settlementData: settlementData,
            sourceBurnTxId: sourceBurnTxId
        });
    }

    /// @dev LayerZero release params. The Bridge recipient is forced to the
    ///      adapter on-chain, so it is not part of these params; `recipient`
    ///      here is the bytes32 destination on the far chain.
    function _lzFundsOutParams(uint256 amount, bytes32 sourceBurnTxId, bytes32[] memory ids)
        internal
        view
        returns (IMultisigProxy.LzFundsOutParams memory)
    {
        bytes memory proof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
        bytes memory settlementData = _settlementFromRecords(ids);
        uint256 derivedBurnId = _deriveBurnId(amount, RGB_CHAIN_ID, SRC_ADDR, sourceBurnTxId);

        return IMultisigProxy.LzFundsOutParams({
            amount: amount,
            burnId: derivedBurnId,
            sourceChainId: RGB_CHAIN_ID,
            destinationChainId: SOURCE_CHAIN_ID,
            sourceAddress: SRC_ADDR,
            proof: proof,
            settlementData: settlementData,
            dstEid: DST_EID,
            recipient: LZ_RECIPIENT,
            minAmountLD: 0,
            extraOptions: hex"0003010011010000000000000000000000000000ea60",
            sourceBurnTxId: sourceBurnTxId
        });
    }

    /// @dev Sign an lz release with the 2-of-3 enclave set at the live teeNonce.
    ///      Returns the nonce/bitmap/sigs so the heavy snapshot tests keep fewer
    ///      locals live (avoids via_ir stack-too-deep with the optimizer off).
    function _signLzEnclave(IMultisigProxy.LzFundsOutParams memory params, uint256 deadline)
        internal
        view
        returns (uint256 nonce, uint256 bitmap, bytes[] memory sigs)
    {
        nonce = proxy.teeNonce(RGB_CHAIN_ID);
        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks;
        (pks, bitmap) = _encSigSet2of3();
        sigs = MultisigHelper.signAll(vm, digest, pks);
    }

    /// @dev Set the proxy's `lzAdapter` via the timelocked governance path so the
    ///      typed `lzFundsOutCall` flow can run end-to-end.
    function _setLzAdapter(address adapter) internal {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateLZAdapter(domainSep, adapter, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id =
            proxy.proposeUpdateLZAdapter(adapter, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks));
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(adapter));
    }

    /// @dev Rebalance params over the registered (RGB → SOURCE) route: debit
    ///      leg is burn-backed (BtcRelay proof + seed record check), credit leg
    ///      writes a record and threads a fresh RGB OpId. Canonical burnId is
    ///      derived purely from the intent (no nonce), mirroring the Bridge formula.
    function _rebalanceParams() internal view returns (IBridge.RebalanceParams memory p) {
        bytes memory proof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
        p = IBridge.RebalanceParams({
            amount: AMOUNT,
            burnId: 0,
            sourceChainId: RGB_CHAIN_ID,
            destinationChainId: SOURCE_CHAIN_ID,
            sourceAddress: SRC_ADDR,
            destinationAddress: DST_ADDR,
            proof: proof,
            settlementDataOut: _settlementFromRecords(_fundsInIds()),
            settlementDataIn: abi.encode(RGB_OP_ID + 7),
            sourceBurnTxId: SRC_BURN_TX_ID
        });

        p.burnId = _deriveRebalanceBurnId(p);
    }

    function _deriveRebalanceBurnId(IBridge.RebalanceParams memory p) internal view returns (uint256) {
        return BurnIdHelper.derive(
            address(bridge), block.chainid, address(token), p.amount, p.sourceChainId, p.sourceAddress, p.sourceBurnTxId
        );
    }

    function _slice(uint256[] memory a, uint256 k) internal pure returns (uint256[] memory r) {
        r = new uint256[](k);
        for (uint256 i = 0; i < k; i++) {
            r[i] = a[i];
        }
    }

    function _bitmapFor(uint256 k) internal pure returns (uint256 b) {
        for (uint256 i = 0; i < k; i++) {
            b |= (uint256(1) << i);
        }
    }

    /// @dev Deterministic signer addresses and retained private keys for rotations.
    function _signerSetFromPrivateKeys(uint256 base, uint256 n)
        internal
        pure
        returns (address[] memory addrs, uint256[] memory pks)
    {
        addrs = new address[](n);
        pks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            pks[i] = base + i;
            addrs[i] = vm.addr(pks[i]);
        }
    }

    /// @dev Rotate the federation set, signing with the *current* federation pks,
    ///      returning the gas consumed by executeProposal (the disjoint-loop leg).
    function _rotateFedMeasured(address[] memory newAddrs, uint256 newThr, uint256[] memory curPks, uint256 curBitmap)
        internal
        returns (uint256 gasUsed)
    {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeUpdateFederationSigners(domainSep, newAddrs, newThr, nonce, deadline);
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, curPks);
        bytes32 id = proxy.proposeUpdateFederationSigners(newAddrs, newThr, nonce, deadline, curBitmap, sigs);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        uint256 g0 = gasleft();
        proxy.executeProposal(id, abi.encode(newAddrs, newThr));
        gasUsed = g0 - gasleft();
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
