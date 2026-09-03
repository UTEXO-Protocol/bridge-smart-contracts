// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MultisigProxy} from "../src/MultisigProxy.sol";
import {IMultisigProxy} from "../src/interfaces/IMultisigProxy.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {Bridge} from "../src/Bridge.sol";
import {BridgeBase} from "../src/BridgeBase.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {CommissionManager} from "../src/CommissionManager.sol";
import {RouteRegistry} from "../src/RouteRegistry.sol";
import {IRouteRegistry} from "../src/interfaces/IRouteRegistry.sol";
import {RGBVerifier} from "../src/verifiers/RGBVerifier.sol";
import {RgbSettlementModule} from "../src/settlement/RgbSettlementModule.sol";
import {OutflowRateLimiter} from "../src/libraries/OutflowRateLimiter.sol";
import {RouteConfig} from "../src/interfaces/RouteTypes.sol";
import {
    CommissionConfig,
    CommissionSide,
    CommissionCurrency,
    ICommissionManager
} from "../src/interfaces/ICommissionManager.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBtcRelay} from "./mocks/MockBtcRelay.sol";
import {MultisigHelper} from "./mocks/MultisigHelper.sol";
import {EmergencyPause} from "../script/interact/EmergencyPause.s.sol";
import {EmergencyUnpause} from "../script/interact/EmergencyUnpause.s.sol";

/// @dev Exposes the exact nonce/digest preparation used by the production
///      scripts so tests cannot pass against a duplicated implementation.
contract EmergencyPauseHarness is EmergencyPause {
    function prepare(MultisigProxy proxy, uint256 deadline) external view returns (uint256 nonce, bytes32 digest) {
        return _prepareEmergencyPause(proxy, deadline);
    }
}

contract EmergencyUnpauseHarness is EmergencyUnpause {
    function prepare(MultisigProxy proxy, uint256 deadline) external view returns (uint256 nonce, bytes32 digest) {
        return _prepareEmergencyUnpause(proxy, deadline);
    }
}

contract MockOutboundLZAdapter {
    MockERC20 public immutable token;
    address public immutable oft;
    address public immutable multisigProxy;
    uint256 public immutable nativeFee;
    uint256 public sendOutCalls;

    event SendOut(bytes32 indexed guid, uint32 dstEid, bytes32 recipient, uint256 amountLD);

    constructor(address token_, address oft_, address multisigProxy_, uint256 nativeFee_) {
        token = MockERC20(token_);
        oft = oft_;
        multisigProxy = multisigProxy_;
        nativeFee = nativeFee_;
    }

    function sendOut(
        uint32 dstEid,
        bytes32 recipient,
        uint256 amount,
        uint256 minAmountLD,
        bytes calldata /* extraOptions */
    )
        external
        payable
    {
        require(msg.sender == multisigProxy, "only proxy");
        require(msg.value == nativeFee, "native fee");
        require(amount != 0, "zero amount");
        require(recipient != bytes32(0), "zero recipient");
        require(minAmountLD <= amount, "min too high");

        sendOutCalls++;
        token.transfer(oft, amount);
        (bool ok,) = oft.call{value: msg.value}("");
        require(ok, "oft fee");
        emit SendOut(keccak256(abi.encode("mock-send-out", dstEid, recipient, amount)), dstEid, recipient, amount);
    }
}

contract MultisigProxyTest is Test {
    using MultisigHelper for bytes32;

    // ---- Re-declared events ------------------------------------------------
    event FundsOutExecuted(uint256 indexed sourceChainId, uint256 indexed nonce, uint256 enclaveBitmap);
    event RebalanceExecuted(
        uint256 indexed sourceChainId, uint256 indexed destinationChainId, uint256 nonce, uint256 enclaveBitmap
    );
    event LzFundsOutExecuted(
        uint256 indexed sourceChainId,
        uint256 indexed nonce,
        uint256 enclaveBitmap,
        uint32 dstEid,
        bytes32 recipient,
        uint256 amount
    );
    event EmergencyPaused(uint256 nonce, uint256 fedBitmap);
    event EmergencyUnpaused(uint256 nonce, uint256 fedBitmap);
    event ProposalCreated(
        bytes32 indexed proposalId,
        IMultisigProxy.OperationType indexed opType,
        bytes operationData,
        uint256 nonce,
        uint256 deadline,
        uint256 fedBitmap
    );
    event ProposalCancelled(bytes32 indexed proposalId);
    event ProposalExecuted(bytes32 indexed proposalId, IMultisigProxy.OperationType indexed opType);
    event EnclaveSignersUpdated(uint256 indexed sourceChainId, address[] newSigners, uint256 newThreshold);
    event FederationSignersUpdated(address[] newSigners, uint256 newThreshold);
    event BridgeAddressUpdated(address indexed oldBridge, address indexed newBridge);
    event CommissionManagerUpdated(address indexed oldCm, address indexed newCm);
    event TimelockDurationUpdated(uint256 newDuration);
    event CommissionWithdrawn(address indexed token, uint256 amount, address indexed recipient);
    event TokenCommissionWithdrawn(address indexed token, address indexed to, uint256 amount);
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event LZAdapterDisabled(address indexed oldAdapter);
    event RouteRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event BatchExecuted(uint256 indexed nonce, uint256 enclaveBitmap, address[] targets, bytes4[] selectors);
    event SendOut(bytes32 indexed guid, uint32 dstEid, bytes32 recipient, uint256 amountLD);
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
    event RouteSet(
        uint256 indexed sourceChainId,
        uint256 indexed destChainId,
        bool enabled,
        address finalityVerifier,
        address settlementModule
    );

    MultisigProxy proxy;
    Bridge bridge;
    CommissionManager cm;
    RouteRegistry routeRegistry;
    RGBVerifier rgbVerifier;
    RgbSettlementModule rgbModule;
    MockERC20 token;
    MockBtcRelay btcRelay;

    // Derived operationId of the setUp() seed deposit (returned by fundsIn).
    bytes32 seedOpId;

    // Enclave signers (3-of-N with threshold 2)
    uint256 encPk1 = 0xE1;
    uint256 encPk2 = 0xE2;
    uint256 encPk3 = 0xE3;
    address encA1;
    address encA2;
    address encA3;

    // Federation signers (3-of-N with threshold 2)
    uint256 fedPk1 = 0xF1;
    uint256 fedPk2 = 0xF2;
    uint256 fedPk3 = 0xF3;
    address fedA1;
    address fedA2;
    address fedA3;

    address deployer = makeAddr("deployer");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");
    address commissionReceiver = makeAddr("commissionReceiver");

    uint256 constant TIMELOCK = 1 hours;
    uint256 constant MIN_TIMELOCK = 1 hours; // floor passed to the proxy constructor in tests

    bytes32 domainSep;

    // Chain identifiers + canonical fundsOut args
    uint256 constant SOURCE_CHAIN_ID = 31337; // foundry block.chainid
    uint256 constant RGB_CHAIN_ID = 1_000_001; // backend-assigned for RGB
    string constant DST_ADDR = "rgb:asset/utxo1abc";
    string constant SRC_ADDR = "rgb:sender/utxo1src";
    uint256 constant AMOUNT = 100e18;

    /// @dev Balanced policy that consumes the full configurable budget:
    ///      10% instant burst plus 10% refill per window.
    uint256 constant MAX_BURST_BPS = 1_000;
    uint256 constant MAX_REFILL_BPS = 1_000;
    uint256 constant TX_ID = 42;
    uint256 constant RGB_OP_ID = 0xABCDEF;
    uint256 constant BURN_ID = 9_001;
    bytes32 constant FUNDS_OUT_BURN_ID_TYPEHASH = keccak256(
        "UtexoFundsOutBurnId(address bridge,uint256 chainId,address token,address recipient,uint256 amount,uint256 sourceChainId,uint256 destinationChainId,bytes32 sourceAddressHash,bytes32 proofHash,bytes32 settlementDataHash)"
    );
    uint256 constant LZ_NATIVE_FEE = 0.01 ether;
    uint32 constant DST_EID = 30110;
    bytes32 constant LZ_RECIPIENT = bytes32(uint256(uint160(0xBEEF)));

    // BtcRelay test data. RGB proof = two (height, commit) pairs: a deep
    // source block (RGB burn/lock) and a fresh latest block. gap = 6 - 1 = 5.
    uint256 constant BLOCK_HEIGHT = 850_000; // source block
    bytes32 constant COMMITMENT_HASH = keccak256("test-btc-block-commitment");
    uint256 constant BTC_CONFIRMATIONS = 6; // source confirmations
    uint256 constant LATEST_HEIGHT = 850_005;
    bytes32 constant LATEST_COMMIT = keccak256("test-btc-latest-commitment");
    uint256 constant LATEST_CONFIRMATIONS = 1;

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

        // DeployAll-style with predicted Bridge address. Deployer tx order:
        //   nonce n      → CommissionManager (uses predicted Bridge)
        //   nonce n+1    → RouteRegistry     (uses predicted Bridge; deployer
        //                                     stays owner for initial route
        //                                     registration, then transfers to
        //                                     proxy)
        //   nonce n+2    → Bridge            (uses RouteRegistry, CM)
        //   nonce n+3    → RGBVerifier
        //   nonce n+4    → RgbSettlementModule
        //   nonce n+5    → MultisigProxy
        vm.startPrank(deployer);

        uint64 currentNonce = vm.getNonce(deployer);
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 2);

        cm = new CommissionManager(predictedBridge, commissionReceiver);
        routeRegistry = new RouteRegistry(predictedBridge, deployer);
        bridge = new Bridge(
            address(token),
            address(routeRegistry),
            payable(address(cm)),
            address(0),
            1, // minFundsInAmount: smallest non-zero floor for tests
            1 // minFundsOutAmount: smallest non-zero floor for tests
        );

        rgbVerifier = new RGBVerifier(address(btcRelay), 6, 1, 5);
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

        proxy = new MultisigProxy(address(bridge), address(cm), enc, 2, RGB_CHAIN_ID, fed, 2, TIMELOCK, MIN_TIMELOCK);

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

    // ========================================================================
    // helpers
    // ========================================================================

    function _encSigSet2of3() internal pure returns (uint256[] memory pks, uint256 bitmap) {
        pks = new uint256[](2);
        pks[0] = 0xE1;
        pks[1] = 0xE2;
        bitmap = 0x3;
    }

    function _fedSigSet2of3() internal pure returns (uint256[] memory pks, uint256 bitmap) {
        pks = new uint256[](2);
        pks[0] = 0xF1;
        pks[1] = 0xF2;
        bitmap = 0x3;
    }

    function _fundsInIds() internal view returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = seedOpId;
    }

    /// @dev Build `settlementData` for the reworked RgbSettlementModule, which
    ///      expects `(bytes32[] operationIds, uint256[] amounts)` and checks
    ///      each id exists with an EXACTLY matching amount (no consumption).
    ///      The amount is derived from the on-chain mint record so an exact
    ///      match is guaranteed for the common path; ids with no record resolve
    ///      to amount 0 (the module then reverts FundsInNotFound first).
    function _settlement(bytes32[] memory ids) internal view returns (bytes memory) {
        uint256[] memory amounts = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            amounts[i] = rgbModule.fundsInRecords(ids[i]);
        }
        return abi.encode(ids, amounts);
    }

    function _deriveBurnId(
        address bridgeRecipient,
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
                    address(token),
                    bridgeRecipient,
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

    /// @dev Valid strict-majority signer sets (2-of-2) used as filler in
    ///      constructor-revert tests that target a non-threshold revert.
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
        return _fundsOutParams(recipient, AMOUNT, BURN_ID);
    }

    function _fundsOutParams(
        address payoutRecipient,
        uint256 amount,
        uint256 /* burnId */
    )
        internal
        view
        returns (IBridge.FundsOutParams memory)
    {
        bytes memory proof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
        bytes memory settlementData = _settlement(_fundsInIds());
        uint256 derivedBurnId =
            _deriveBurnId(payoutRecipient, amount, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

        return IBridge.FundsOutParams({
            recipient: payoutRecipient,
            amount: amount,
            burnId: derivedBurnId,
            sourceChainId: RGB_CHAIN_ID,
            destinationChainId: SOURCE_CHAIN_ID,
            sourceAddress: SRC_ADDR,
            proof: proof,
            settlementData: settlementData
        });
    }

    /// @dev Flow-4 LZ release params. The Bridge recipient is forced to the
    ///      adapter on-chain, so it is not part of these params; `recipient`
    ///      here is the bytes32 destination on the far chain.
    function _lzFundsOutParams(
        uint256 amount,
        uint256,
        /* burnId */
        bytes32[] memory ids
    )
        internal
        view
        returns (IMultisigProxy.LzFundsOutParams memory)
    {
        bytes memory proof = abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH, LATEST_HEIGHT, LATEST_COMMIT);
        bytes memory settlementData = _settlement(ids);
        uint256 derivedBurnId =
            _deriveBurnId(proxy.lzAdapter(), amount, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, proof, settlementData);

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
            extraOptions: hex"0003010011010000000000000000000000000000ea60"
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
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateLZAdapter(domainSep, adapter, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id =
            proxy.proposeUpdateLZAdapter(adapter, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks));
        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(adapter));
    }

    // ========================================================================
    // Constructor
    // ========================================================================

    function test_constructor_setsState() public view {
        assertEq(proxy.bridge(), address(bridge));
        assertEq(proxy.commissionManager(), address(cm));
        assertEq(proxy.enclaveThreshold(RGB_CHAIN_ID), 2);
        assertEq(proxy.federationThreshold(), 2);
        assertEq(proxy.commissionRecipient(), commissionReceiver);
        assertEq(proxy.timelockDuration(), TIMELOCK);
        assertEq(proxy.proposalNonce(), 0);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), 0);

        address[] memory enc = proxy.getEnclaveSigners(RGB_CHAIN_ID);
        assertEq(enc.length, 3);
        assertEq(enc[0], encA1);

        address[] memory fed = proxy.getFederationSigners();
        assertEq(fed.length, 3);
    }

    function test_constructor_revertsOnZeroBridge() public {
        address[] memory enc = new address[](1);
        enc[0] = encA1;
        address[] memory fed = new address[](1);
        fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.ZeroBridge.selector);
        new MultisigProxy(address(0), address(cm), enc, 1, RGB_CHAIN_ID, fed, 1, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_revertsOnZeroCommissionManager() public {
        address[] memory enc = new address[](1);
        enc[0] = encA1;
        address[] memory fed = new address[](1);
        fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.ZeroCommissionManager.selector);
        new MultisigProxy(address(bridge), address(0), enc, 1, RGB_CHAIN_ID, fed, 1, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_revertsOnNoEnclaveSigners() public {
        address[] memory enc = new address[](0);
        address[] memory fed = new address[](1);
        fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.NoSigners.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 1, RGB_CHAIN_ID, fed, 1, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_revertsOnBadEnclaveThreshold() public {
        address[] memory enc = new address[](2);
        enc[0] = encA1;
        enc[1] = encA2;
        address[] memory fed = new address[](1);
        fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 3, RGB_CHAIN_ID, fed, 1, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_revertsOnTimelockTooLong() public {
        vm.expectRevert(IMultisigProxy.TimelockTooLong.selector);
        new MultisigProxy(
            address(bridge), address(cm), _validEnc(), 2, RGB_CHAIN_ID, _validFed(), 2, 30 days, MIN_TIMELOCK
        );
    }

    // ---- MIN_TIMELOCK floor ----

    /// @dev Deploying with a timelock below the requested floor reverts.
    function test_constructor_revertsOnTimelockBelowMinTimelock() public {
        // timelock (1h) is below the requested floor (2h) -> TimelockTooShort
        vm.expectRevert(IMultisigProxy.TimelockTooShort.selector);
        new MultisigProxy(address(bridge), address(cm), _validEnc(), 2, RGB_CHAIN_ID, _validFed(), 2, 1 hours, 2 hours);
    }

    /// @dev A zero floor is rejected — it would defeat the purpose of the fix.
    function test_constructor_revertsOnZeroMinTimelock() public {
        vm.expectRevert(IMultisigProxy.InvalidMinTimelock.selector);
        new MultisigProxy(address(bridge), address(cm), _validEnc(), 2, RGB_CHAIN_ID, _validFed(), 2, TIMELOCK, 0);
    }

    /// @dev A floor at/above the upper bound leaves no valid range — rejected.
    function test_constructor_revertsOnMinTimelockTooLong() public {
        vm.expectRevert(IMultisigProxy.InvalidMinTimelock.selector);
        new MultisigProxy(address(bridge), address(cm), _validEnc(), 2, RGB_CHAIN_ID, _validFed(), 2, TIMELOCK, 30 days);
    }

    function test_minTimelock_returnsConfiguredFloor() public view {
        assertEq(proxy.MIN_TIMELOCK(), MIN_TIMELOCK);
    }

    function test_constructor_revertsOnDuplicateSigner() public {
        // Duplicate enclave signer with an otherwise-valid 2-of-2 threshold, so
        // the call clears the threshold guard and reverts in _validateSigners.
        address[] memory enc = new address[](2);
        enc[0] = encA1;
        enc[1] = encA1;
        vm.expectRevert(IMultisigProxy.DuplicateSigner.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 2, RGB_CHAIN_ID, _validFed(), 2, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_revertsOnZeroAddressSigner() public {
        // Zero-address enclave signer in a 2-signer set with a valid 2-of-2
        // threshold, so the call clears the threshold guard and reverts in
        // _validateSigners.
        address[] memory enc = new address[](2);
        enc[0] = address(0);
        enc[1] = encA2;
        vm.expectRevert(IMultisigProxy.ZeroAddressSigner.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 2, RGB_CHAIN_ID, _validFed(), 2, TIMELOCK, MIN_TIMELOCK);
    }

    // ========================================================================
    // Strict-majority signer threshold floor
    //
    // Both signer sets, at construction and on signer-update, must be a strict
    // majority of at least 2 signers: n >= 2, threshold >= 2, threshold <= n,
    // 2*threshold > n. Rejects 1-of-N, the degenerate 1-of-1, and sub-majority
    // quorums; the smallest valid sets are 2-of-2 and 2-of-3. Signer-update
    // validation runs at executeProposal time (in _executeByType), so the bad
    // proposal is created successfully and reverts only on execution.
    // ========================================================================

    /// @dev Build an n-element signer array from a seed (distinct non-zero addrs).
    function _signers(uint256 n) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = address(uint160(0xA000 + i));
        }
    }

    /// @dev A second n-element signer array disjoint from `_signers` — used as
    ///      the counterpart set so the two trust domains do not overlap.
    function _signersB(uint256 n) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = address(uint160(0xB000 + i));
        }
    }

    // ---- Constructor ----

    function test_constructor_rejectsOneOfThree_enclave() public {
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(
            address(bridge), address(cm), _signers(3), 1, RGB_CHAIN_ID, _validFed(), 2, TIMELOCK, MIN_TIMELOCK
        );
    }

    function test_constructor_rejectsOneOfOne_enclave() public {
        // n < 2 — single-key set, rejected even though 2*1 > 1.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(
            address(bridge), address(cm), _signers(1), 1, RGB_CHAIN_ID, _validFed(), 2, TIMELOCK, MIN_TIMELOCK
        );
    }

    function test_constructor_rejectsSubMajority_enclave() public {
        // 2-of-4: 2*2 == 4, not a strict majority.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(
            address(bridge), address(cm), _signers(4), 2, RGB_CHAIN_ID, _validFed(), 2, TIMELOCK, MIN_TIMELOCK
        );
    }

    function test_constructor_rejectsOneOfThree_federation() public {
        // Enclave valid, federation 1-of-3 — the floor applies to both sets.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(
            address(bridge), address(cm), _validEnc(), 2, RGB_CHAIN_ID, _signers(3), 1, TIMELOCK, MIN_TIMELOCK
        );
    }

    function test_constructor_acceptsTwoOfTwo() public {
        MultisigProxy p = new MultisigProxy(
            address(bridge), address(cm), _signers(2), 2, RGB_CHAIN_ID, _signersB(2), 2, TIMELOCK, MIN_TIMELOCK
        );
        assertEq(p.enclaveThreshold(RGB_CHAIN_ID), 2);
        assertEq(p.federationThreshold(), 2);
    }

    function test_constructor_acceptsThreeOfFour() public {
        // Strict majority with a non-trivial set (2*3 > 4).
        MultisigProxy p = new MultisigProxy(
            address(bridge), address(cm), _signers(4), 3, RGB_CHAIN_ID, _signersB(4), 3, TIMELOCK, MIN_TIMELOCK
        );
        assertEq(p.enclaveThreshold(RGB_CHAIN_ID), 3);
        assertEq(p.federationThreshold(), 3);
    }

    // ---- Signer update (validated at executeProposal) ----

    function test_proposeUpdateEnclaveSigners_rejectsOneOfNAtPropose() public {
        address[] memory newSigners = _signers(3);
        uint256 badThreshold = 1; // 1-of-3
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, badThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // Threshold validity is now enforced up front, at propose time.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, badThreshold, nonce, deadline, bitmap, sigs);
    }

    // ---- Intrinsic set validation runs at propose time ----
    // (empty / zero-address / duplicate paths; threshold and MAX_SIGNERS are
    //  covered by the *AtPropose tests above. Disjointness stays deferred to
    //  execute — see the *OverlapWith*AtExecute tests.)

    function test_proposeUpdateEnclaveSigners_rejectsEmptySetAtPropose() public {
        address[] memory newSigners = new address[](0);
        uint256 threshold = 2;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, threshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.NoSigners.selector);
        proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, threshold, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateEnclaveSigners_rejectsZeroAddressSignerAtPropose() public {
        address[] memory newSigners = _signers(3);
        newSigners[1] = address(0);
        uint256 threshold = 2;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, threshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.ZeroAddressSigner.selector);
        proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, threshold, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateEnclaveSigners_rejectsDuplicateSignerAtPropose() public {
        address[] memory newSigners = _signers(3);
        newSigners[2] = newSigners[0]; // duplicate
        uint256 threshold = 2;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, threshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DuplicateSigner.selector);
        proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, threshold, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateFederationSigners_rejectsEmptySetAtPropose() public {
        address[] memory newSigners = new address[](0);
        uint256 threshold = 2;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeUpdateFederationSigners(domainSep, newSigners, threshold, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.NoSigners.selector);
        proxy.proposeUpdateFederationSigners(newSigners, threshold, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateFederationSigners_rejectsSubMajorityAtPropose() public {
        address[] memory newSigners = _signers(4);
        uint256 badThreshold = 2; // 2-of-4, sub-majority
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeUpdateFederationSigners(domainSep, newSigners, badThreshold, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // Threshold validity is now enforced up front, at propose time.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        proxy.proposeUpdateFederationSigners(newSigners, badThreshold, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateFederationSigners_acceptsStrictMajority() public {
        address[] memory newSigners = _signers(3);
        uint256 newThreshold = 2; // 2-of-3
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeUpdateFederationSigners(domainSep, newSigners, newThreshold, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateFederationSigners(newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(newSigners, newThreshold));
        assertEq(proxy.federationThreshold(), 2);
        assertEq(proxy.getFederationSigners().length, 3);
    }

    // ========================================================================
    // Disjoint signer sets
    //
    // The enclave and federation sets must not share an address, at construction
    // and on signer-update (validated at executeProposal). The setUp sets are
    // already disjoint (encA* vs fedA*).
    // ========================================================================

    function test_constructor_rejectsOverlappingSignerSets() public {
        // encA1 is present in both the enclave and the federation set.
        address[] memory enc = new address[](2);
        enc[0] = encA1;
        enc[1] = encA2;
        address[] memory fed = new address[](2);
        fed[0] = encA1;
        fed[1] = fedA2;
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.SignerSetsOverlap.selector, encA1));
        new MultisigProxy(address(bridge), address(cm), enc, 2, RGB_CHAIN_ID, fed, 2, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_acceptsDisjointSignerSets() public {
        MultisigProxy p = new MultisigProxy(
            address(bridge), address(cm), _signers(2), 2, RGB_CHAIN_ID, _signersB(2), 2, TIMELOCK, MIN_TIMELOCK
        );
        assertEq(p.getEnclaveSigners(RGB_CHAIN_ID).length, 2);
        assertEq(p.getFederationSigners().length, 2);
    }

    function test_proposeUpdateEnclaveSigners_rejectsOverlapWithFederationAtExecute() public {
        // New enclave set includes fedA1, a current federation signer.
        address[] memory newSigners = new address[](2);
        newSigners[0] = fedA1;
        newSigners[1] = encA2;
        uint256 newThreshold = 2;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id =
            proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.SignerSetsOverlap.selector, fedA1));
        proxy.executeProposal(id, abi.encode(RGB_CHAIN_ID, newSigners, newThreshold));
    }

    function test_proposeUpdateFederationSigners_rejectsOverlapWithEnclaveAtExecute() public {
        // New federation set includes encA1, a current enclave signer.
        address[] memory newSigners = new address[](2);
        newSigners[0] = encA1;
        newSigners[1] = fedA2;
        uint256 newThreshold = 2;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeUpdateFederationSigners(domainSep, newSigners, newThreshold, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateFederationSigners(newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.SignerSetsOverlap.selector, encA1));
        proxy.executeProposal(id, abi.encode(newSigners, newThreshold));
    }

    // ========================================================================
    // Signer-set size cap
    //
    // Either set is capped at MAX_SIGNERS, at construction and on signer-update
    // (validated in _validateSigners at executeProposal). The cap bounds the
    // O(N^2) scan and keeps every index within the uint256 signature bitmap.
    // ========================================================================

    function test_constructor_rejectsTooManySigners() public {
        uint256 max = proxy.MAX_SIGNERS();
        address[] memory enc = _signers(max + 1); // 21 distinct enclave signers
        uint256 encThreshold = (max + 1) / 2 + 1; // strict majority, so it clears the threshold guard

        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.TooManySigners.selector, max + 1, max));
        new MultisigProxy(
            address(bridge), address(cm), enc, encThreshold, RGB_CHAIN_ID, _validFed(), 2, TIMELOCK, MIN_TIMELOCK
        );
    }

    function test_constructor_acceptsSignersAtMax() public {
        uint256 max = proxy.MAX_SIGNERS();
        uint256 threshold = max / 2 + 1; // 11-of-20 strict majority

        MultisigProxy p = new MultisigProxy(
            address(bridge),
            address(cm),
            _signers(max),
            threshold,
            RGB_CHAIN_ID,
            _signersB(max),
            threshold,
            TIMELOCK,
            MIN_TIMELOCK
        );
        assertEq(p.getEnclaveSigners(RGB_CHAIN_ID).length, max);
        assertEq(p.getFederationSigners().length, max);
    }

    function test_proposeUpdateEnclaveSigners_rejectsTooManySignersAtPropose() public {
        uint256 max = proxy.MAX_SIGNERS();
        address[] memory newSigners = _signers(max + 1);
        uint256 newThreshold = (max + 1) / 2 + 1; // valid strict majority
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // Signer-set size is now enforced up front, at propose time.
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.TooManySigners.selector, max + 1, max));
        proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline, bitmap, sigs);
    }

    // ========================================================================
    // TEE fundsOutCall — happy path
    // ========================================================================

    function test_fundsOutCall_releasesViaBridge() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(true, true, false, true);
        emit FundsOutExecuted(RGB_CHAIN_ID, nonce, bitmap);

        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);

        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1);
    }

    function test_fundsOutCall_revertsOnExpired() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp - 1;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    // ========================================================================
    // TEE deadline upper bound
    //
    // fundsOutCall / lzFundsOutCall reject a signed deadline further than
    // MAX_TEE_DEADLINE into the future, so a leaked or pre-signed payload cannot
    // stay executable indefinitely. The boundary (exactly now + MAX_TEE_DEADLINE)
    // is still accepted — the guard is a strict `>`.
    // ========================================================================

    function test_fundsOutCall_revertsOnDeadlineTooFar() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + proxy.MAX_TEE_DEADLINE() + 1;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    function test_fundsOutCall_acceptsDeadlineAtMaxBoundary() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + proxy.MAX_TEE_DEADLINE(); // exact boundary, strict `>` lets it through

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
        assertEq(token.balanceOf(recipient), AMOUNT, "executes at the exact deadline ceiling");
    }

    function test_lzFundsOutCall_revertsOnDeadlineTooFar() public {
        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + proxy.MAX_TEE_DEADLINE() + 1;

        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.deal(address(this), LZ_NATIVE_FEE);
        vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);
    }

    function test_lzFundsOutCall_acceptsDeadlineAtMaxBoundary() public {
        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + proxy.MAX_TEE_DEADLINE(); // exact boundary

        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);
        assertEq(token.balanceOf(mockOft), AMOUNT, "lz release executes at the exact deadline ceiling");
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "teeNonce incremented");
    }

    function test_fundsOutCall_revertsOnWrongNonce() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = 99;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    // ========================================================================
    // TEE rebalanceCall
    // ========================================================================

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
            settlementDataOut: _settlement(_fundsInIds()),
            settlementDataIn: abi.encode(RGB_OP_ID + 7)
        });

        p.burnId = uint256(
            keccak256(
                bytes.concat(
                    abi.encode(
                        bridge.REBALANCE_BURN_ID_TYPEHASH(),
                        address(bridge),
                        block.chainid,
                        address(token),
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

    function test_rebalanceCall_executesViaBridge() public {
        IBridge.RebalanceParams memory params = _rebalanceParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeRebalance(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        uint256 srcBefore = bridge.lockedLiquidity(RGB_CHAIN_ID);
        uint256 dstBefore = bridge.lockedLiquidity(SOURCE_CHAIN_ID);
        uint256 custodyBefore = token.balanceOf(address(bridge));

        vm.expectEmit(true, true, false, true);
        emit RebalanceExecuted(RGB_CHAIN_ID, SOURCE_CHAIN_ID, nonce, bitmap);

        proxy.rebalanceCall(params, nonce, deadline, bitmap, sigs);

        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), srcBefore - AMOUNT, "source bucket debited");
        assertEq(bridge.lockedLiquidity(SOURCE_CHAIN_ID), dstBefore + AMOUNT, "destination bucket credited");
        assertEq(token.balanceOf(address(bridge)), custodyBefore, "no tokens moved");
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "shared teeNonce stream advanced");
    }

    function test_rebalanceCall_revertsOnWrongNonce() public {
        IBridge.RebalanceParams memory params = _rebalanceParams();
        uint256 nonce = 99;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeRebalance(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.rebalanceCall(params, nonce, deadline, bitmap, sigs);
    }

    function test_rebalanceCall_revertsOnUnknownSourceChain() public {
        IBridge.RebalanceParams memory params = _rebalanceParams();
        params.sourceChainId = 555; // no enclave set registered for this chain
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeRebalance(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, 555));
        proxy.rebalanceCall(params, nonce, deadline, bitmap, sigs);
    }

    function test_rebalanceCall_revertsOnBelowThreshold() public {
        IBridge.RebalanceParams memory params = _rebalanceParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeRebalance(domainSep, params, nonce, deadline);
        uint256[] memory pks = new uint256[](1);
        pks[0] = encPk1;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.BelowThreshold.selector);
        proxy.rebalanceCall(params, nonce, deadline, 0x1, sigs);
    }

    // ========================================================================
    // TEE fundsOutCall — signature / bitmap reverts
    // ========================================================================

    function test_fundsOutCall_revertsOnBelowThreshold() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks = new uint256[](1);
        pks[0] = encPk1;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.BelowThreshold.selector);
        proxy.fundsOutCall(params, nonce, deadline, 0x1, sigs);
    }

    function test_fundsOutCall_revertsOnBadSignature() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks = new uint256[](2);
        pks[0] = encPk1;
        pks[1] = 0xBADBAD;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.fundsOutCall(params, nonce, deadline, 0x3, sigs);
    }

    function test_fundsOutCall_revertsOnSigCountMismatch() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks = new uint256[](3);
        pks[0] = encPk1;
        pks[1] = encPk2;
        pks[2] = encPk3;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.SigCountMismatch.selector);
        proxy.fundsOutCall(params, nonce, deadline, 0x3, sigs);
    }

    function test_fundsOutCall_revertsOnBitmapOutOfRange() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks,) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.BitmapOutOfRange.selector);
        proxy.fundsOutCall(params, nonce, deadline, 0x100, sigs);
    }

    function test_lzFundsOutCall_revertsIfAdapterUnset() public {
        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.LZAdapterNotSet.selector);
        proxy.lzFundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    // ========================================================================
    // Emergency pause / unpause
    // ========================================================================

    function test_emergencyPause_works() public {
        uint256 nonce = proxy.emergencyNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(false, false, false, true);
        emit EmergencyPaused(nonce, bitmap);

        proxy.emergencyPause(nonce, deadline, bitmap, sigs);

        assertTrue(bridge.paused());
        assertEq(proxy.emergencyNonce(), nonce + 1, "emergency lane advanced");
        assertEq(proxy.proposalNonce(), 0, "proposal lane untouched by emergency");
    }

    function test_emergencyPause_revertsOnExpired() public {
        uint256 nonce = proxy.emergencyNonce();
        uint256 deadline = block.timestamp - 1;

        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.emergencyPause(nonce, deadline, bitmap, sigs);
    }

    function test_emergencyPause_revertsOnWrongNonce() public {
        uint256 nonce = 99;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.emergencyPause(nonce, deadline, bitmap, sigs);
    }

    function test_emergencyUnpause_works() public {
        test_emergencyPause_works();

        uint256 nonce = proxy.emergencyNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestEmergencyUnpause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(false, false, false, true);
        emit EmergencyUnpaused(nonce, bitmap);

        proxy.emergencyUnpause(nonce, deadline, bitmap, sigs);
        assertFalse(bridge.paused());
    }

    /// @dev Known-answer regression for the production pause script.
    ///      A regular proposal first advances only `proposalNonce`, reproducing
    ///      the state in which the old script selected the wrong nonce lane.
    function test_emergencyPauseScriptUsesEmergencyNonceAfterLanesDiverge() public {
        uint256 regularNonce = proxy.proposalNonce();
        uint256 regularDeadline = block.timestamp + 1 days;
        address newBridge = makeAddr("emergency-pause-regular-proposal");
        bytes32 regularDigest =
            MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, regularNonce, regularDeadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        proxy.proposeUpdateBridge(
            newBridge, regularNonce, regularDeadline, bitmap, MultisigHelper.signAll(vm, regularDigest, pks)
        );

        assertEq(proxy.proposalNonce(), 1, "regular lane advanced");
        assertEq(proxy.emergencyNonce(), 0, "emergency lane untouched");

        uint256 deadline = block.timestamp + 1 hours;

        // Negative control: the pre-fix script read proposalNonce(), producing
        // a correctly signed emergency digest for the wrong nonce.
        uint256 wrongNonce = proxy.proposalNonce();
        bytes32 wrongDigest = MultisigHelper.digestEmergencyPause(domainSep, wrongNonce, deadline);
        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.emergencyPause(wrongNonce, deadline, bitmap, MultisigHelper.signAll(vm, wrongDigest, pks));

        // Exercise the exact preparation function called by EmergencyPause.run().
        EmergencyPauseHarness harness = new EmergencyPauseHarness();
        (uint256 scriptNonce, bytes32 scriptDigest) = harness.prepare(proxy, deadline);
        bytes32 expectedStructHash =
            keccak256(abi.encode(keccak256("EmergencyPause(uint256 nonce,uint256 deadline)"), uint256(0), deadline));
        bytes32 expectedDigest = keccak256(abi.encodePacked("\x19\x01", domainSep, expectedStructHash));

        assertEq(scriptNonce, 0, "script reads emergency lane");
        assertEq(scriptDigest, expectedDigest, "script produces canonical pause digest");

        proxy.emergencyPause(scriptNonce, deadline, bitmap, MultisigHelper.signAll(vm, scriptDigest, pks));

        assertTrue(bridge.paused(), "emergency pause succeeds");
        assertEq(proxy.emergencyNonce(), 1, "emergency lane advanced");
        assertEq(proxy.proposalNonce(), 1, "regular lane unchanged");
    }

    /// @dev Known-answer regression for the production unpause script.
    ///      Both lanes are deliberately non-equal before digest construction.
    function test_emergencyUnpauseScriptUsesEmergencyNonceAfterLanesDiverge() public {
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();

        uint256 pauseNonce = proxy.emergencyNonce();
        uint256 pauseDeadline = block.timestamp + 1 hours;
        bytes32 pauseDigest = MultisigHelper.digestEmergencyPause(domainSep, pauseNonce, pauseDeadline);
        proxy.emergencyPause(pauseNonce, pauseDeadline, bitmap, MultisigHelper.signAll(vm, pauseDigest, pks));
        assertTrue(bridge.paused(), "precondition: bridge paused");

        // Advance the regular lane twice so proposalNonce=2, emergencyNonce=1.
        for (uint256 i = 0; i < 2; i++) {
            uint256 regularNonce = proxy.proposalNonce();
            uint256 regularDeadline = block.timestamp + 1 days;
            address newBridge = makeAddr(string.concat("emergency-unpause-regular-proposal-", vm.toString(i)));
            bytes32 regularDigest =
                MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, regularNonce, regularDeadline);
            proxy.proposeUpdateBridge(
                newBridge, regularNonce, regularDeadline, bitmap, MultisigHelper.signAll(vm, regularDigest, pks)
            );
        }

        assertEq(proxy.proposalNonce(), 2, "regular lane advanced independently");
        assertEq(proxy.emergencyNonce(), 1, "pause advanced emergency lane once");

        uint256 deadline = block.timestamp + 1 hours;
        EmergencyUnpauseHarness harness = new EmergencyUnpauseHarness();
        (uint256 scriptNonce, bytes32 scriptDigest) = harness.prepare(proxy, deadline);
        bytes32 expectedStructHash =
            keccak256(abi.encode(keccak256("EmergencyUnpause(uint256 nonce,uint256 deadline)"), uint256(1), deadline));
        bytes32 expectedDigest = keccak256(abi.encodePacked("\x19\x01", domainSep, expectedStructHash));

        assertEq(scriptNonce, 1, "script reads emergency lane");
        assertEq(scriptDigest, expectedDigest, "script produces canonical unpause digest");

        proxy.emergencyUnpause(scriptNonce, deadline, bitmap, MultisigHelper.signAll(vm, scriptDigest, pks));

        assertFalse(bridge.paused(), "emergency unpause succeeds");
        assertEq(proxy.emergencyNonce(), 2, "emergency lane advanced");
        assertEq(proxy.proposalNonce(), 2, "regular lane unchanged");
    }

    // ========================================================================
    // Two-tier pause (integration via MultisigProxy)
    // ========================================================================

    /// @dev The no-timelock emergency pause freezes the OUTFLOW path too —
    ///      including the enclave/TEE release, which routes through
    ///      Bridge.fundsOut. A signed fundsOut executed straight after
    ///      emergencyPause must revert OutflowEnforcedPause, and inbound deposits
    ///      must be frozen as well.
    function test_emergencyPause_freezesEnclaveFundsOut() public {
        // Federation triggers the emergency freeze (both paths).
        uint256 nonce = proxy.emergencyNonce();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory fpks, uint256 fbitmap) = _fedSigSet2of3();
        proxy.emergencyPause(nonce, deadline, fbitmap, MultisigHelper.signAll(vm, digest, fpks));

        assertTrue(bridge.paused(), "inflow frozen");
        assertTrue(bridge.outflowPaused(), "outflow frozen");

        // Inbound deposits are frozen.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, abi.encode(RGB_OP_ID));

        // Enclave-signed release is frozen too — the revert propagates from
        // Bridge.fundsOut through proxy.fundsOutCall.
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 encNonce = proxy.teeNonce(RGB_CHAIN_ID);
        bytes32 encDigest = MultisigHelper.digestTeeFundsOut(domainSep, params, encNonce, deadline);
        (uint256[] memory epks, uint256 ebitmap) = _encSigSet2of3();
        bytes[] memory esigs = MultisigHelper.signAll(vm, encDigest, epks);

        vm.expectRevert(BridgeBase.OutflowEnforcedPause.selector);
        proxy.fundsOutCall(params, encNonce, deadline, ebitmap, esigs);
    }

    /// @dev The planned inflow-only pause runs through the timelocked
    ///      propose -> execute path and blocks deposits while leaving the
    ///      enclave release path open (liquidity migration scenario).
    function test_proposePauseInflow_blocksFundsInButAllowsFundsOut() public {
        uint256 t = block.timestamp; // read once; derive all timing from it (via_ir-safe)

        // Propose the inflow-only pause (federation signed).
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = t + 1 days;
        bytes32 digest = MultisigHelper.digestProposePauseInflow(domainSep, nonce, deadline);
        (uint256[] memory fpks, uint256 fbitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposePauseInflow(nonce, deadline, fbitmap, MultisigHelper.signAll(vm, digest, fpks));

        // Execute it after the timelock (no payload).
        vm.warp(t + TIMELOCK + 1);
        proxy.executeProposal(id, "");

        assertTrue(bridge.paused(), "inflow frozen");
        assertFalse(bridge.outflowPaused(), "outflow stays open");

        // Deposits are frozen...
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, abi.encode(RGB_OP_ID));

        // ...but the enclave release still executes.
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 encNonce = proxy.teeNonce(RGB_CHAIN_ID);
        bytes32 encDigest = MultisigHelper.digestTeeFundsOut(domainSep, params, encNonce, t + 1 days);
        (uint256[] memory epks, uint256 ebitmap) = _encSigSet2of3();
        bytes[] memory esigs = MultisigHelper.signAll(vm, encDigest, epks);

        proxy.fundsOutCall(params, encNonce, t + 1 days, ebitmap, esigs);
        assertEq(token.balanceOf(recipient), AMOUNT, "withdrawal succeeded while inflow paused");
    }

    // ========================================================================
    // Propose + Execute — UpdateBridge
    // ========================================================================

    function test_proposeUpdateBridge_andExecuteAfterTimelock() public {
        address newBridge = makeAddr("newBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 proposalId = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        vm.expectRevert(IMultisigProxy.TimelockActive.selector);
        proxy.executeProposal(proposalId, abi.encode(newBridge));

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, false);
        emit BridgeAddressUpdated(address(bridge), newBridge);

        proxy.executeProposal(proposalId, abi.encode(newBridge));
        assertEq(proxy.bridge(), newBridge);
    }

    function test_proposeUpdateBridge_revertsOnExpired() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp - 1;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr("nb"), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.proposeUpdateBridge(makeAddr("nb"), nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateBridge_revertsOnDeadlineTooFar() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 31 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr("nb"), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
        proxy.proposeUpdateBridge(makeAddr("nb"), nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateBridge_revertsOnDeadlineBeforeTimelock() public {
        uint256 nonce = proxy.proposalNonce();
        // One second short of the timelock window → dead on arrival.
        uint256 deadline = block.timestamp + proxy.timelockDuration() - 1;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr("nb"), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DeadlineBeforeTimelock.selector);
        proxy.proposeUpdateBridge(makeAddr("nb"), nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateBridge_acceptsDeadlineAtTimelockBoundary() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + proxy.timelockDuration(); // exact boundary, `==` allowed

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr("nb"), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 proposalId = proxy.proposeUpdateBridge(makeAddr("nb"), nonce, deadline, bitmap, sigs);
        assertEq(
            uint8(proxy.getProposal(proposalId).status),
            uint8(IMultisigProxy.ProposalStatus.Pending),
            "proposal at the exact boundary is created"
        );
    }

    function test_proposeUpdateBridge_executableAtTimelockBoundary() public {
        address newBridge = makeAddr("boundaryBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 timelock = proxy.timelockDuration();
        uint256 deadline = block.timestamp + timelock; // deadline == proposedAt + timelock

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 proposalId = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        // Execute at the single instant where block.timestamp == proposedAt +
        // timelock == deadline: timelock has just elapsed and the deadline has
        // not yet passed (both checks use strict comparisons).
        vm.warp(block.timestamp + timelock);
        proxy.executeProposal(proposalId, abi.encode(newBridge));
        assertEq(proxy.bridge(), newBridge, "boundary proposal executes at the exact instant");
    }

    // ========================================================================
    // Propose + Execute — UpdateEnclaveSigners
    // ========================================================================

    function test_proposeUpdateEnclaveSigners_execute() public {
        address newSigner = makeAddr("newEncSigner");
        address[] memory newSigners = new address[](2);
        newSigners[0] = encA1;
        newSigners[1] = newSigner;
        uint256 newThreshold = 2;

        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id =
            proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(RGB_CHAIN_ID, newSigners, newThreshold));

        address[] memory after_ = proxy.getEnclaveSigners(RGB_CHAIN_ID);
        assertEq(after_.length, 2);
        assertEq(after_[1], newSigner);
        assertEq(proxy.enclaveThreshold(RGB_CHAIN_ID), newThreshold);
    }

    // ========================================================================
    // Propose + Execute — SetTimelockDuration
    // ========================================================================

    function test_proposeSetTimelockDuration_execute() public {
        uint256 newDuration = 2 hours;
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeSetTimelockDuration(domainSep, newDuration, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeSetTimelockDuration(newDuration, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(false, false, false, true);
        emit TimelockDurationUpdated(newDuration);
        proxy.executeProposal(id, abi.encode(newDuration));

        assertEq(proxy.timelockDuration(), newDuration);
    }

    /// @dev A SetTimelockDuration proposal below the immutable MIN_TIMELOCK
    ///      floor is rejected at execution; the floor holds.
    function test_proposeSetTimelockDuration_revertsBelowMinTimelock() public {
        uint256 t = block.timestamp;
        uint256 newDuration = MIN_TIMELOCK - 1; // just under the floor
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = t + 1 days;

        bytes32 digest = MultisigHelper.digestProposeSetTimelockDuration(domainSep, newDuration, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposeSetTimelockDuration(
            newDuration, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks)
        );

        vm.warp(t + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.TimelockTooShort.selector);
        proxy.executeProposal(id, abi.encode(newDuration));

        assertEq(proxy.timelockDuration(), TIMELOCK, "timelock unchanged");
    }

    /// @dev A value exactly at MIN_TIMELOCK is still accepted (boundary).
    function test_proposeSetTimelockDuration_acceptsAtMinTimelock() public {
        uint256 t = block.timestamp;
        uint256 newDuration = MIN_TIMELOCK; // exactly the floor
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = t + 1 days;

        bytes32 digest = MultisigHelper.digestProposeSetTimelockDuration(domainSep, newDuration, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposeSetTimelockDuration(
            newDuration, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks)
        );

        vm.warp(t + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(newDuration));
        assertEq(proxy.timelockDuration(), newDuration);
    }

    // ========================================================================
    // Propose + Execute — AdminExecute
    // ========================================================================

    function test_proposeAdminExecute_canCallBridge() public {
        bytes memory callData = abi.encodeWithSignature("pauseInflow()");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeAdminExecute(domainSep, bytes4(callData), callData, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecute(callData, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, callData);

        assertTrue(bridge.paused());
    }

    /// @dev Assert that a protected selector is rejected before federation
    ///      signature verification on every generic raw-call lane. Applying
    ///      each policy selector-wide closes mutable-target aliasing.
    function _assertGenericPathsRejectSelector(bytes memory callData, bytes4 errorSelector) internal {
        bytes4 selector = bytes4(callData);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes[] memory noSigs = new bytes[](0);
        bytes memory expected = abi.encodeWithSelector(errorSelector, selector);

        vm.expectRevert(expected);
        proxy.proposeAdminExecute(callData, nonce, deadline, 0, noSigs);

        vm.expectRevert(expected);
        proxy.proposeAdminExecuteCommissionManager(callData, nonce, deadline, 0, noSigs);

        vm.expectRevert(expected);
        proxy.proposeAdminExecuteRouteRegistry(callData, nonce, deadline, 0, noSigs);

        vm.expectRevert(expected);
        proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, 0, noSigs);
    }

    function test_federationGenericPathsCannotCallFundsOut() public {
        bytes memory callData = abi.encodeCall(IBridge.fundsOut, (_fundsOutParams()));
        _assertGenericPathsRejectSelector(callData, IMultisigProxy.ForbiddenBridgeReleaseSelector.selector);
    }

    function test_federationGenericPathsCannotCallRebalanceLiquidity() public {
        bytes memory callData = abi.encodeCall(IBridge.rebalanceLiquidity, (_rebalanceParams()));
        _assertGenericPathsRejectSelector(callData, IMultisigProxy.ForbiddenBridgeReleaseSelector.selector);
    }

    function test_federationGenericPathsCannotDesyncCommissionManager() public {
        bytes memory callData = abi.encodeCall(IBridge.setCommissionManager, (makeAddr("genericCm")));
        _assertGenericPathsRejectSelector(callData, IMultisigProxy.ForbiddenCommissionManagerSelector.selector);
    }

    // ========================================================================
    // Propose + Execute — UpdateCommissionManager
    // ========================================================================

    function test_proposeUpdateCommissionManager_execute() public {
        CommissionManager newCm = new CommissionManager(address(bridge), commissionReceiver);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateCommissionManager(domainSep, address(newCm), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateCommissionManager(address(newCm), nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit CommissionManagerUpdated(address(cm), address(newCm));
        vm.expectEmit(true, true, false, true, address(proxy));
        emit CommissionManagerUpdated(address(cm), address(newCm));

        proxy.executeProposal(id, abi.encode(address(newCm)));
        assertEq(proxy.commissionManager(), address(newCm));
        assertEq(address(bridge.commissionManager()), address(newCm));
    }

    // ========================================================================
    // Propose + Execute — WithdrawTokenCommissionCM
    // ========================================================================

    function test_proposeWithdrawTokenCommissionCM_execute() public {
        // Seed commission by setting a fundsIn TOKEN rule and doing a deposit.
        vm.prank(address(proxy));
        cm.setCommissionRule(
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: 400, // 4%
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        uint256 depositAmount = 100e18;
        vm.prank(user);
        bridge.fundsIn(depositAmount, RGB_CHAIN_ID, DST_ADDR, abi.encode(RGB_OP_ID));

        uint256 expectedCommission = (depositAmount * 400) / 100 / 100;
        assertEq(cm.tokenCommissionPool(address(token)), expectedCommission);

        // Propose withdrawal.
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeWithdrawTokenCommissionCM(
            domainSep, address(token), expectedCommission, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id =
            proxy.proposeWithdrawTokenCommissionCM(address(token), expectedCommission, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);

        uint256 recipientBefore = token.balanceOf(commissionReceiver);

        vm.expectEmit(true, true, false, true);
        emit CommissionWithdrawn(address(token), expectedCommission, commissionReceiver);

        proxy.executeProposal(id, abi.encode(address(token), expectedCommission));

        assertEq(token.balanceOf(commissionReceiver), recipientBefore + expectedCommission);
        assertEq(cm.tokenCommissionPool(address(token)), 0);
    }

    // ========================================================================
    // Cancel
    // ========================================================================

    function test_cancelProposal_cancels() public {
        address newBridge = makeAddr("newBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);
        uint256 proposalNonceAfterPropose = proxy.proposalNonce();

        uint256 cDeadline = block.timestamp + 1 hours;
        bytes32 cDigest = MultisigHelper.digestCancelProposal(domainSep, id, cDeadline);
        bytes[] memory cSigs = MultisigHelper.signAll(vm, cDigest, pks);

        vm.expectEmit(true, false, false, false);
        emit ProposalCancelled(id);
        proxy.cancelProposal(id, cDeadline, bitmap, cSigs);

        assertEq(proxy.proposalNonce(), proposalNonceAfterPropose, "cancel does not consume proposal nonce");
        IMultisigProxy.Proposal memory p = proxy.getProposal(id);
        assertEq(uint8(p.status), uint8(IMultisigProxy.ProposalStatus.Cancelled));

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.executeProposal(id, abi.encode(newBridge));
    }

    function test_cancelProposal_revertsOnNotPending() public {
        bytes32 id = keccak256("ghost");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestCancelProposal(domainSep, id, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.cancelProposal(id, deadline, bitmap, sigs);
    }

    /// @dev Regression for the shared-nonce veto-starvation finding. Once a
    ///      cancel is signed for a concrete proposal, unrelated proposal
    ///      traffic cannot invalidate it by advancing `proposalNonce`.
    function test_cancelProposal_survivesUnrelatedProposalNonceAdvance() public {
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();

        uint256 targetNonce = proxy.proposalNonce();
        uint256 targetDeadline = block.timestamp + 1 days;
        address targetBridge = makeAddr("targetBridge");
        bytes32 targetDigest =
            MultisigHelper.digestProposeUpdateBridge(domainSep, targetBridge, targetNonce, targetDeadline);
        bytes32 targetId = proxy.proposeUpdateBridge(
            targetBridge, targetNonce, targetDeadline, bitmap, MultisigHelper.signAll(vm, targetDigest, pks)
        );

        uint256 cancelDeadline = block.timestamp + 1 hours;
        bytes32 cancelDigest = MultisigHelper.digestCancelProposal(domainSep, targetId, cancelDeadline);
        bytes[] memory cancelSigs = MultisigHelper.signAll(vm, cancelDigest, pks);

        // A different, valid federation proposal advances the sequential
        // proposal lane after the cancel bundle has already been collected.
        uint256 unrelatedNonce = proxy.proposalNonce();
        address unrelatedBridge = makeAddr("unrelatedBridge");
        bytes32 unrelatedDigest =
            MultisigHelper.digestProposeUpdateBridge(domainSep, unrelatedBridge, unrelatedNonce, targetDeadline);
        proxy.proposeUpdateBridge(
            unrelatedBridge, unrelatedNonce, targetDeadline, bitmap, MultisigHelper.signAll(vm, unrelatedDigest, pks)
        );
        uint256 nonceAfterUnrelatedProposal = proxy.proposalNonce();
        assertEq(nonceAfterUnrelatedProposal, targetNonce + 2, "unrelated proposal advances its own lane");

        proxy.cancelProposal(targetId, cancelDeadline, bitmap, cancelSigs);

        assertEq(proxy.proposalNonce(), nonceAfterUnrelatedProposal, "cancel leaves proposal lane untouched");
        assertEq(
            uint256(proxy.getProposal(targetId).status),
            uint256(IMultisigProxy.ProposalStatus.Cancelled),
            "original cancel remains executable"
        );
    }

    function test_cancelProposal_replayRevertsOnCancelledStatus() public {
        address newBridge = makeAddr("cancelReplayBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 proposalDeadline = block.timestamp + 1 days;
        bytes32 proposalDigest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, proposalDeadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposeUpdateBridge(
            newBridge, nonce, proposalDeadline, bitmap, MultisigHelper.signAll(vm, proposalDigest, pks)
        );

        uint256 cancelDeadline = block.timestamp + 1 hours;
        bytes32 cancelDigest = MultisigHelper.digestCancelProposal(domainSep, id, cancelDeadline);
        bytes[] memory cancelSigs = MultisigHelper.signAll(vm, cancelDigest, pks);

        proxy.cancelProposal(id, cancelDeadline, bitmap, cancelSigs);

        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.cancelProposal(id, cancelDeadline, bitmap, cancelSigs);
    }

    // ========================================================================
    // executeProposal reverts
    // ========================================================================

    function test_executeProposal_revertsOnDataMismatch() public {
        address newBridge = makeAddr("newBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        proxy.executeProposal(id, abi.encode(makeAddr("different")));
    }

    function test_executeProposal_revertsOnExpiredDeadline() public {
        address newBridge = makeAddr("newBridge");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 2 hours;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        vm.warp(deadline + 1);
        vm.expectRevert(IMultisigProxy.ProposalExpired.selector);
        proxy.executeProposal(id, abi.encode(newBridge));
    }

    // ========================================================================
    // View
    // ========================================================================

    function test_verifyEnclaveSignature() public view {
        bytes32 digest = keccak256("msg");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(encPk1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertTrue(proxy.verifyEnclaveSignature(RGB_CHAIN_ID, digest, sig, 0));
        assertFalse(proxy.verifyEnclaveSignature(RGB_CHAIN_ID, digest, sig, 1));
    }

    function test_verifyEnclaveSignature_revertsOutOfRange() public {
        bytes32 digest = keccak256("msg");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(encPk1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(IMultisigProxy.IndexOutOfRange.selector);
        proxy.verifyEnclaveSignature(RGB_CHAIN_ID, digest, sig, 99);
    }

    // ========================================================================
    // Propose + Execute — UpdateLZAdapter
    // ========================================================================

    function _proposeUpdateLZAdapter(address newAdapter) internal returns (bytes32 id) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateLZAdapter(domainSep, newAdapter, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        id = proxy.proposeUpdateLZAdapter(newAdapter, nonce, deadline, bitmap, sigs);
    }

    function test_lzAdapter_defaultsToZero() public view {
        assertEq(proxy.lzAdapter(), address(0));
    }

    function test_proposeUpdateLZAdapter_executeSetsAdapter() public {
        address newAdapter = makeAddr("lzAdapter");
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, false);
        emit LZAdapterUpdated(address(0), newAdapter);

        proxy.executeProposal(id, abi.encode(newAdapter));
        assertEq(proxy.lzAdapter(), newAdapter);
    }

    function test_proposeUpdateLZAdapter_rejectsZeroAtExecute() public {
        // Proposing zero succeeds (validated at execute); execution reverts —
        // DisableLZAdapter is the explicit way to clear the routing target.
        bytes32 id = _proposeUpdateLZAdapter(address(0));
        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.InvalidLZAdapter.selector);
        proxy.executeProposal(id, abi.encode(address(0)));
    }

    function _proposeDisableLZAdapter() internal returns (bytes32 id) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = MultisigHelper.digestProposeDisableLZAdapter(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        id = proxy.proposeDisableLZAdapter(nonce, deadline, bitmap, sigs);
    }

    function test_proposeDisableLZAdapter_clearsAdapterAndEmits() public {
        // Set a non-zero adapter first.
        address newAdapter = makeAddr("lzAdapter");
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);
        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(newAdapter));
        assertEq(proxy.lzAdapter(), newAdapter);

        // Explicit disable clears it and emits LZAdapterDisabled.
        bytes32 id2 = _proposeDisableLZAdapter();
        vm.warp(block.timestamp + 2 * TIMELOCK + 2);

        vm.expectEmit(true, false, false, false);
        emit LZAdapterDisabled(newAdapter);

        proxy.executeProposal(id2, "");
        assertEq(proxy.lzAdapter(), address(0));
    }

    function test_proposeUpdateLZAdapter_revertsOnDataMismatch() public {
        address newAdapter = makeAddr("lzAdapter");
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        proxy.executeProposal(id, abi.encode(makeAddr("different")));
    }

    function test_proposeUpdateLZAdapter_canBeCancelled() public {
        address newAdapter = makeAddr("lzAdapter");
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        uint256 cDeadline = block.timestamp + 1 hours;
        bytes32 cDigest = MultisigHelper.digestCancelProposal(domainSep, id, cDeadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory cSigs = MultisigHelper.signAll(vm, cDigest, pks);

        vm.expectEmit(true, false, false, false);
        emit ProposalCancelled(id);
        proxy.cancelProposal(id, cDeadline, bitmap, cSigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.executeProposal(id, abi.encode(newAdapter));
        assertEq(proxy.lzAdapter(), address(0));
    }

    // ========================================================================
    // Propose + Execute — AdminExecuteAdapter
    // ========================================================================

    function test_proposeAdminExecuteAdapter_revertsIfAdapterUnset() public {
        bytes memory callData = abi.encodeWithSignature("mint(address,uint256)", user, 1e18);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeAdminExecuteAdapter(domainSep, bytes4(callData), callData, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.ZeroTarget.selector);
        proxy.executeProposal(id, callData);
    }

    function test_proposeAdminExecuteAdapter_executesCallOnAdapter() public {
        MockERC20 adapter = new MockERC20("LZ Stub", "LZS");
        bytes32 idSet = _proposeUpdateLZAdapter(address(adapter));
        // Read block.timestamp once and derive every warp target from it. Re-reading
        // block.timestamp after a vm.warp within the same function is unreliable under
        // via_ir: the optimizer treats TIMESTAMP as tx-invariant and may reuse a
        // pre-warp read, so a second `block.timestamp + ...` warp can collapse onto a
        // stale value and leave the timelock unexpired.
        uint256 firstExec = block.timestamp + TIMELOCK + 1;
        vm.warp(firstExec);
        proxy.executeProposal(idSet, abi.encode(address(adapter)));
        assertEq(proxy.lzAdapter(), address(adapter));

        bytes memory callData = abi.encodeWithSignature("mint(address,uint256)", recipient, 1e18);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = firstExec + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeAdminExecuteAdapter(domainSep, bytes4(callData), callData, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);

        vm.warp(firstExec + TIMELOCK + 1);
        proxy.executeProposal(id, callData);

        assertEq(adapter.balanceOf(recipient), 1e18);
    }

    function test_proposeAdminExecuteAdapter_revertsOnEmptyCallData() public {
        bytes memory callData = "";
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = new bytes[](pks.length);
        for (uint256 i = 0; i < pks.length; i++) {
            sigs[i] = new bytes(65);
        }

        vm.expectRevert(IMultisigProxy.CallDataTooShort.selector);
        proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);
    }

    function test_proposeAdminExecuteAdapter_propagatesAdapterRevert() public {
        MockERC20 adapter = new MockERC20("LZ Stub", "LZS");
        bytes32 idSet = _proposeUpdateLZAdapter(address(adapter));
        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(idSet, abi.encode(address(adapter)));

        bytes memory callData = abi.encodeWithSignature("nonExistent()");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeAdminExecuteAdapter(domainSep, bytes4(callData), callData, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert();
        proxy.executeProposal(id, callData);
    }

    // ========================================================================
    // Propose + Execute — SetRoute
    // ========================================================================

    function _proposeSetRoute(uint256 srcId, uint256 dstId, bool enabled, address verifier, address module)
        internal
        returns (bytes32 id)
    {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeSetRoute(domainSep, srcId, dstId, enabled, verifier, module, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        id = proxy.proposeSetRoute(srcId, dstId, enabled, verifier, module, nonce, deadline, bitmap, sigs);
    }

    function test_proposeSetRoute_addsBrandNewRoute() public {
        // Register a fresh (1234, 5678) route via governance.
        uint256 newSrc = 1234;
        uint256 newDst = 5678;
        bytes32 id = _proposeSetRoute(newSrc, newDst, true, address(rgbVerifier), address(rgbModule));

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, true, address(routeRegistry));
        emit RouteSet(newSrc, newDst, true, address(rgbVerifier), address(rgbModule));

        proxy.executeProposal(id, abi.encode(newSrc, newDst, true, address(rgbVerifier), address(rgbModule)));

        RouteConfig memory cfg = routeRegistry.getRoute(newSrc, newDst);
        assertTrue(cfg.enabled);
        assertEq(cfg.finalityVerifier, address(rgbVerifier));
        assertEq(cfg.settlementModule, address(rgbModule));
    }

    function test_proposeSetRoute_updatesExistingRoute() public {
        // Re-point the existing RGB→SOURCE route at a brand new module
        // (verifier stays). Validates governance can rotate plugins in place.
        RgbSettlementModule newModule = new RgbSettlementModule(address(routeRegistry));

        bytes32 id = _proposeSetRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(newModule));

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(
            id, abi.encode(RGB_CHAIN_ID, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(newModule))
        );

        RouteConfig memory cfg = routeRegistry.getRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID);
        assertEq(cfg.settlementModule, address(newModule), "module rotated");
        assertEq(cfg.finalityVerifier, address(rgbVerifier), "verifier unchanged");
    }

    function test_proposeSetRoute_canPauseRoute() public {
        // Existing RGB→SOURCE route is enabled. Flip enabled = false in place.
        bytes32 id = _proposeSetRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID, false, address(rgbVerifier), address(rgbModule));

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(
            id, abi.encode(RGB_CHAIN_ID, SOURCE_CHAIN_ID, false, address(rgbVerifier), address(rgbModule))
        );

        RouteConfig memory cfg = routeRegistry.getRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID);
        assertFalse(cfg.enabled, "route paused");
        assertEq(cfg.finalityVerifier, address(rgbVerifier), "verifier kept");
        assertEq(cfg.settlementModule, address(rgbModule), "module kept");
    }

    function test_proposeSetRoute_revertsOnZeroVerifier() public {
        bytes32 id = _proposeSetRoute(1234, 5678, true, address(0), address(rgbModule));

        vm.warp(block.timestamp + TIMELOCK + 1);
        // Registry guard: ZeroFinalityVerifier propagates up through proxy.
        vm.expectRevert(IRouteRegistry.ZeroFinalityVerifier.selector);
        proxy.executeProposal(id, abi.encode(uint256(1234), uint256(5678), true, address(0), address(rgbModule)));
    }

    function test_proposeSetRoute_revertsOnDataMismatch() public {
        bytes32 id = _proposeSetRoute(1234, 5678, true, address(rgbVerifier), address(rgbModule));

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        // Wrong destChainId in opData.
        proxy.executeProposal(
            id, abi.encode(uint256(1234), uint256(9999), true, address(rgbVerifier), address(rgbModule))
        );
    }

    // ========================================================================
    // Propose + Execute — UpdateRouteRegistry
    // ========================================================================

    function _proposeUpdateRouteRegistry(address newRegistry) internal returns (bytes32 id) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateRouteRegistry(domainSep, newRegistry, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        id = proxy.proposeUpdateRouteRegistry(newRegistry, nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateRouteRegistry_rotatesBridgePointer() public {
        // Deploy a NEW registry, owned by proxy, paired with the same Bridge.
        // In production the new registry's `bridge_` immutable MUST match the
        // live Bridge — otherwise dispatcher calls revert NotBridge.
        RouteRegistry newRegistry = new RouteRegistry(address(bridge), address(proxy));

        bytes32 id = _proposeUpdateRouteRegistry(address(newRegistry));

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, false, address(bridge));
        emit RouteRegistryUpdated(address(routeRegistry), address(newRegistry));

        proxy.executeProposal(id, abi.encode(address(newRegistry)));
        assertEq(bridge.routeRegistry(), address(newRegistry));
    }

    function test_proposeUpdateRouteRegistry_revertsOnZero() public {
        // Bridge.setRouteRegistry rejects zero — the revert propagates up
        // through `IBridge(bridge).setRouteRegistry(...)` in `_executeByType`.
        bytes32 id = _proposeUpdateRouteRegistry(address(0));

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(); // Bridge.InvalidRouteRegistryAddress (custom)
        proxy.executeProposal(id, abi.encode(address(0)));
    }

    function test_proposeUpdateRouteRegistry_revertsOnDataMismatch() public {
        address bogus = makeAddr("bogus");
        bytes32 id = _proposeUpdateRouteRegistry(bogus);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        proxy.executeProposal(id, abi.encode(makeAddr("different")));
    }

    function test_domainSeparator_matchesHelper() public view {
        assertEq(proxy.DOMAIN_SEPARATOR(), MultisigHelper.domainSeparator(address(proxy), block.chainid));
    }

    // ========================================================================
    // Domain separator rebuild on chain-id change
    //
    // The separator is cached at deploy with the chain id. After a chain-id
    // change (e.g. a hard fork) it is rebuilt, so a signature made before the
    // fork no longer verifies on the forked chain (no cross-fork replay).
    // ========================================================================

    function test_domainSeparator_rebuiltOnChainIdChange() public {
        uint256 originalChainId = block.chainid;
        bytes32 dsBefore = proxy.DOMAIN_SEPARATOR();
        assertEq(dsBefore, MultisigHelper.domainSeparator(address(proxy), originalChainId), "cached on original chain");

        uint256 forkedChainId = originalChainId + 1;
        vm.chainId(forkedChainId);

        bytes32 dsAfter = proxy.DOMAIN_SEPARATOR();
        assertTrue(dsAfter != dsBefore, "separator rebuilt after chain-id change");
        assertEq(dsAfter, MultisigHelper.domainSeparator(address(proxy), forkedChainId), "rebuilt over new chain id");
    }

    function test_fundsOutCallSignatureNotReplayableAfterChainIdChange() public {
        // Sign a valid TEE fundsOut on the original chain (domainSep was cached
        // at setUp for block.chainid).
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // Simulate a hard fork: same state/nonces, different chain id. The
        // domain separator is rebuilt, so the pre-fork signatures recover to the
        // wrong addresses and verification fails — the release cannot be replayed.
        vm.chainId(block.chainid + 1);
        vm.expectRevert();
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    // ========================================================================
    // TEE execute — full-flow state snapshots
    // ========================================================================

    function test_execute_fundsOut_snapshot_tokenCommission_success() public {
        uint256 percent = 500; // 5%
        vm.prank(address(proxy));
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");
        assertEq(netAmount, AMOUNT - tokenCommission, "net recipient amount");

        // Prepare signed TEE execution and snapshot proxy + Bridge accounting.
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        uint256 bridgeBefore = token.balanceOf(address(bridge));
        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 cmBefore = token.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(token));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(seedOpId);

        assertEq(bridgeBefore, AMOUNT * 10, "pre bridge pool");
        assertEq(recipientBefore, 0, "pre recipient token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, AMOUNT * 10, "pre record");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        vm.expectEmit(true, true, false, true);
        emit BridgeFundsOut(
            recipient, AMOUNT, netAmount, tokenCommission, params.burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR
        );
        vm.expectEmit(true, true, false, true);
        emit FundsOutExecuted(RGB_CHAIN_ID, nonce, bitmap);

        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "nonce incremented");
        assertTrue(bridge.consumedBurnIds(params.burnId), "burn id consumed");
        assertEq(token.balanceOf(address(bridge)), bridgeBefore - AMOUNT, "bridge gross debit");
        assertEq(token.balanceOf(recipient), recipientBefore + netAmount, "recipient net delta");
        assertEq(token.balanceOf(address(cm)), cmBefore + tokenCommission, "cm fee delta");
        assertEq(cm.tokenCommissionPool(address(token)), cmPoolBefore + tokenCommission, "cm pool delta");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(seedOpId), recordBefore, "record unchanged (proof-of-mint permanent)");

        // The signed Bridge gross debit splits into recipient net payout and CM token commission.
        assertEq(
            (token.balanceOf(recipient) - recipientBefore) + (token.balanceOf(address(cm)) - cmBefore),
            AMOUNT,
            "gross fundsOut conserved"
        );
    }

    // Flow-4 coverage for the typed lzFundsOutCall: Bridge fundsOut to the
    // adapter, then adapter.sendOut of the net delivered amount, in one signed op.
    // Real UtexoLZAdapter + OFT coverage belongs in a cross-repo integration test.
    function test_lzFundsOutCall_bridgeFundsOutThenAdapterSendOut_snapshot() public {
        uint256 percent = 500; // 5%
        vm.prank(address(proxy));
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");
        assertEq(netAmount, AMOUNT - tokenCommission, "net adapter amount");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        uint256 bridgeBefore = token.balanceOf(address(bridge));
        uint256 adapterBefore = token.balanceOf(address(adapter));
        uint256 oftBefore = token.balanceOf(mockOft);
        uint256 cmBefore = token.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(token));
        uint256 recordBefore = rgbModule.fundsInRecords(seedOpId);
        uint256 proxyEthBefore = address(proxy).balance;
        uint256 adapterEthBefore = address(adapter).balance;
        uint256 oftEthBefore = mockOft.balance;

        assertEq(bridgeBefore, AMOUNT * 10, "pre bridge pool");
        assertEq(adapterBefore, 0, "pre adapter token");
        assertEq(oftBefore, 0, "pre oft token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(recordBefore, AMOUNT * 10, "pre record");
        assertEq(adapterEthBefore, 0, "pre adapter native");
        assertEq(oftEthBefore, 0, "pre oft native");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        bytes32 sendOutGuid = keccak256(abi.encode("mock-send-out", DST_EID, LZ_RECIPIENT, netAmount));

        vm.expectEmit(true, true, false, true, address(bridge));
        emit BridgeFundsOut(
            address(adapter), AMOUNT, netAmount, tokenCommission, params.burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR
        );
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, netAmount);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit LzFundsOutExecuted(RGB_CHAIN_ID, nonce, bitmap, DST_EID, LZ_RECIPIENT, netAmount);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "tee nonce incremented");
        assertTrue(bridge.consumedBurnIds(params.burnId), "burn id consumed");
        assertEq(token.balanceOf(address(bridge)), bridgeBefore - AMOUNT, "bridge gross debit");
        assertEq(token.balanceOf(address(cm)), cmBefore + tokenCommission, "cm fee delta");
        assertEq(cm.tokenCommissionPool(address(token)), cmPoolBefore + tokenCommission, "cm pool delta");
        assertEq(rgbModule.fundsInRecords(seedOpId), recordBefore, "record unchanged (proof-of-mint permanent)");
        assertEq(token.balanceOf(address(adapter)), adapterBefore, "adapter no residue");
        assertEq(token.balanceOf(mockOft), oftBefore + netAmount, "oft receives net");
        assertEq(address(proxy).balance, proxyEthBefore, "proxy native no residue");
        assertEq(address(adapter).balance, adapterEthBefore, "adapter native no residue");
        assertEq(mockOft.balance, oftEthBefore + LZ_NATIVE_FEE, "oft receives native fee");
        assertEq(
            (token.balanceOf(mockOft) - oftBefore) + (token.balanceOf(address(cm)) - cmBefore),
            AMOUNT,
            "gross batch payout conserved"
        );
    }

    // Flow-4 rollback coverage: an insufficient LayerZero native fee reverts in
    // adapter.sendOut, after Bridge.fundsOut ran in the same lzFundsOutCall, so
    // the whole release rolls back.
    function test_lzFundsOutCall_sendOutInsufficientNativeFee_rollsBackBridgeState() public {
        uint256 percent = 500; // 5%
        vm.prank(address(proxy));
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission,) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        // Snapshot all state touched by the first Bridge leg and the failed adapter leg.
        uint256 bridgeBefore = token.balanceOf(address(bridge));
        uint256 adapterBefore = token.balanceOf(address(adapter));
        uint256 oftBefore = token.balanceOf(mockOft);
        uint256 cmBefore = token.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(token));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(seedOpId);
        uint256 proxyEthBefore = address(proxy).balance;
        uint256 adapterEthBefore = address(adapter).balance;
        uint256 oftEthBefore = mockOft.balance;

        assertEq(bridgeBefore, AMOUNT * 10, "pre bridge pool");
        assertEq(adapterBefore, 0, "pre adapter token");
        assertEq(oftBefore, 0, "pre oft token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, AMOUNT * 10, "pre record");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        // An underfunded native fee reverts in sendOut, after Bridge.fundsOut
        // already ran inside the same lzFundsOutCall transaction.
        vm.deal(address(this), LZ_NATIVE_FEE - 1);
        vm.expectRevert(bytes("native fee"));
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE - 1}(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce, "tee nonce unchanged");
        assertFalse(bridge.consumedBurnIds(params.burnId), "burn id unchanged");
        assertEq(token.balanceOf(address(bridge)), bridgeBefore, "bridge token unchanged");
        assertEq(token.balanceOf(address(adapter)), adapterBefore, "adapter token unchanged");
        assertEq(token.balanceOf(mockOft), oftBefore, "oft token unchanged");
        assertEq(token.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(token)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(seedOpId), recordBefore, "record unchanged");
        assertEq(address(proxy).balance, proxyEthBefore, "proxy native unchanged");
        assertEq(address(adapter).balance, adapterEthBefore, "adapter native unchanged");
        assertEq(mockOft.balance, oftEthBefore, "oft native unchanged");
    }

    // Flow-4 rollback coverage when the Bridge fundsOut leg fails before adapter send.
    // Real UtexoLZAdapter call-skipping coverage belongs in a cross-repo integration test.
    function test_lzFundsOutCall_bridgeVerifierFailure_doesNotCallAdapter() public {
        uint256 percent = 500; // 5%
        vm.prank(address(proxy));
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission,) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        // Well-formed two-pair proof whose source block is unknown to the relay,
        // so Bridge.fundsOut reverts before the adapter send can run.
        params.proof = abi.encode(uint256(999_999), keccak256("unknown-block"), LATEST_HEIGHT, LATEST_COMMIT);
        params.burnId = _deriveBurnId(
            address(adapter),
            params.amount,
            params.sourceChainId,
            params.destinationChainId,
            params.sourceAddress,
            params.proof,
            params.settlementData
        );

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        // The adapter is funded; only the Bridge verifier failure should stop dispatch.
        uint256 bridgeBefore = token.balanceOf(address(bridge));
        uint256 adapterBefore = token.balanceOf(address(adapter));
        uint256 oftBefore = token.balanceOf(mockOft);
        uint256 cmBefore = token.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(token));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(seedOpId);
        uint256 proxyEthBefore = address(proxy).balance;
        uint256 adapterEthBefore = address(adapter).balance;
        uint256 oftEthBefore = mockOft.balance;

        assertEq(bridgeBefore, AMOUNT * 10, "pre bridge pool");
        assertEq(adapterBefore, 0, "pre adapter token");
        assertEq(oftBefore, 0, "pre oft token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, AMOUNT * 10, "pre record");
        assertEq(adapter.sendOutCalls(), 0, "pre adapter calls");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        vm.deal(address(this), LZ_NATIVE_FEE);
        vm.expectRevert(bytes("verify: block commitment"));
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce, "tee nonce unchanged");
        assertFalse(bridge.consumedBurnIds(params.burnId), "burn id unchanged");
        assertEq(adapter.sendOutCalls(), 0, "adapter not called");
        assertEq(token.balanceOf(address(bridge)), bridgeBefore, "bridge token unchanged");
        assertEq(token.balanceOf(address(adapter)), adapterBefore, "adapter token unchanged");
        assertEq(token.balanceOf(mockOft), oftBefore, "oft token unchanged");
        assertEq(token.balanceOf(address(cm)), cmBefore, "cm token unchanged");
        assertEq(cm.tokenCommissionPool(address(token)), cmPoolBefore, "cm pool unchanged");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(seedOpId), recordBefore, "record unchanged");
        assertEq(address(proxy).balance, proxyEthBefore, "proxy native unchanged");
        assertEq(address(adapter).balance, adapterEthBefore, "adapter native unchanged");
        assertEq(mockOft.balance, oftEthBefore, "oft native unchanged");
    }

    // Flow-4 success coverage for duplicate RGB settlement ids when the first
    // occurrence partially satisfies the Bridge fundsOut amount.
    function test_lzFundsOutCall_duplicateSettlementIdsPartialConsume_succeedsAndIgnoresDuplicate() public {
        uint256 percent = 500; // 5%
        vm.prank(address(proxy));
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        bytes32[] memory duplicateIds = new bytes32[](2);
        duplicateIds[0] = seedOpId;
        duplicateIds[1] = seedOpId;

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, duplicateIds);

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        // Duplicate ids are harmless under the reworked module: the check is a
        // pure read, so referencing the same id twice with its (correct) amount
        // simply passes both times. Solvency is the Bridge's concern, not the
        // module's.
        uint256 bridgeBefore = token.balanceOf(address(bridge));
        uint256 adapterBefore = token.balanceOf(address(adapter));
        uint256 oftBefore = token.balanceOf(mockOft);
        uint256 cmBefore = token.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(token));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore = rgbModule.fundsInRecords(seedOpId);
        uint256 proxyEthBefore = address(proxy).balance;
        uint256 adapterEthBefore = address(adapter).balance;
        uint256 oftEthBefore = mockOft.balance;

        assertEq(bridgeBefore, AMOUNT * 10, "pre bridge pool");
        assertEq(adapterBefore, 0, "pre adapter token");
        assertEq(oftBefore, 0, "pre oft token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(nativePoolBefore, 0, "pre native pool");
        assertEq(recordBefore, AMOUNT * 10, "pre record");
        assertEq(adapter.sendOutCalls(), 0, "pre adapter calls");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        bytes32 sendOutGuid = keccak256(abi.encode("mock-send-out", DST_EID, LZ_RECIPIENT, netAmount));

        vm.expectEmit(true, true, false, true, address(bridge));
        emit BridgeFundsOut(
            address(adapter), AMOUNT, netAmount, tokenCommission, params.burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR
        );
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, netAmount);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit LzFundsOutExecuted(RGB_CHAIN_ID, nonce, bitmap, DST_EID, LZ_RECIPIENT, netAmount);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "tee nonce incremented");
        assertTrue(bridge.consumedBurnIds(params.burnId), "burn id consumed");
        assertEq(adapter.sendOutCalls(), 1, "adapter called once");
        assertEq(token.balanceOf(address(bridge)), bridgeBefore - AMOUNT, "bridge token debit");
        assertEq(token.balanceOf(address(adapter)), adapterBefore, "adapter no residue");
        assertEq(token.balanceOf(mockOft), oftBefore + netAmount, "oft token delta");
        assertEq(token.balanceOf(address(cm)), cmBefore + tokenCommission, "cm token delta");
        assertEq(cm.tokenCommissionPool(address(token)), cmPoolBefore + tokenCommission, "cm pool delta");
        assertEq(cm.nativeCommissionPool(), nativePoolBefore, "native pool unchanged");
        assertEq(rgbModule.fundsInRecords(seedOpId), recordBefore, "record unchanged (proof-of-mint permanent)");
        assertEq(address(proxy).balance, proxyEthBefore, "proxy native unchanged");
        assertEq(address(adapter).balance, adapterEthBefore, "adapter native unchanged");
        assertEq(mockOft.balance, oftEthBefore + LZ_NATIVE_FEE, "oft native fee");
    }

    // Flow-4 success coverage for duplicate RGB settlement ids: the reworked
    // module verifies each (id, amount) pair by pure read, so duplicates pass.
    function test_lzFundsOutCall_duplicateSettlementIdsFullConsume_succeedsAndIgnoresDuplicate() public {
        vm.prank(user);
        bytes32 secondOpId = bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, abi.encode(RGB_OP_ID));

        uint256 percent = 500; // 5%
        vm.prank(address(proxy));
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: percent,
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, "token fee quoted");
        assertEq(nativeCommission, 0, "native fee is zero");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        bytes32[] memory duplicateIds = new bytes32[](2);
        duplicateIds[0] = secondOpId;
        duplicateIds[1] = secondOpId;

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID + 1, duplicateIds);

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        // The reworked module never consumes records, so a duplicated id is just
        // verified twice against the same (intact) record and passes.
        uint256 bridgeBefore = token.balanceOf(address(bridge));
        uint256 adapterBefore = token.balanceOf(address(adapter));
        uint256 oftBefore = token.balanceOf(mockOft);
        uint256 cmBefore = token.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(token));
        uint256 originalRecordBefore = rgbModule.fundsInRecords(seedOpId);
        uint256 duplicateRecordBefore = rgbModule.fundsInRecords(secondOpId);
        uint256 proxyEthBefore = address(proxy).balance;
        uint256 adapterEthBefore = address(adapter).balance;
        uint256 oftEthBefore = mockOft.balance;

        assertEq(bridgeBefore, AMOUNT * 11, "pre bridge pool");
        assertEq(adapterBefore, 0, "pre adapter token");
        assertEq(oftBefore, 0, "pre oft token");
        assertEq(cmBefore, 0, "pre cm token");
        assertEq(cmPoolBefore, 0, "pre cm pool");
        assertEq(originalRecordBefore, AMOUNT * 10, "pre original record");
        assertEq(duplicateRecordBefore, AMOUNT, "pre duplicate record");
        assertEq(adapter.sendOutCalls(), 0, "pre adapter calls");
        assertFalse(bridge.consumedBurnIds(params.burnId), "pre burn id");

        bytes32 sendOutGuid = keccak256(abi.encode("mock-send-out", DST_EID, LZ_RECIPIENT, netAmount));

        vm.expectEmit(true, true, false, true, address(bridge));
        emit BridgeFundsOut(
            address(adapter), AMOUNT, netAmount, tokenCommission, params.burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR
        );
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, netAmount);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit LzFundsOutExecuted(RGB_CHAIN_ID, nonce, bitmap, DST_EID, LZ_RECIPIENT, netAmount);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "tee nonce incremented");
        assertTrue(bridge.consumedBurnIds(params.burnId), "burn id consumed");
        assertEq(adapter.sendOutCalls(), 1, "adapter called once");
        assertEq(token.balanceOf(address(bridge)), bridgeBefore - AMOUNT, "bridge token debit");
        assertEq(token.balanceOf(address(adapter)), adapterBefore, "adapter no residue");
        assertEq(token.balanceOf(mockOft), oftBefore + netAmount, "oft token delta");
        assertEq(token.balanceOf(address(cm)), cmBefore + tokenCommission, "cm token delta");
        assertEq(cm.tokenCommissionPool(address(token)), cmPoolBefore + tokenCommission, "cm pool delta");
        assertEq(rgbModule.fundsInRecords(seedOpId), originalRecordBefore, "original record untouched");
        assertEq(rgbModule.fundsInRecords(secondOpId), duplicateRecordBefore, "duplicate record unchanged");
        assertEq(address(proxy).balance, proxyEthBefore, "proxy native unchanged");
        assertEq(address(adapter).balance, adapterEthBefore, "adapter native unchanged");
        assertEq(mockOft.balance, oftEthBefore + LZ_NATIVE_FEE, "oft native fee");
    }

    // ========================================================================
    // Typed enclave methods are the only TEE entry points
    //
    // The generic enclave `execute`/`executeBatch` + `teeAllowedCalls` allowlist
    // were removed. The enclave (TEE) quorum can now only trigger Bridge.fundsOut
    // via fundsOutCall/lzFundsOutCall. Privileged calldata can still be run, but
    // exclusively through the FEDERATION-gated, timelocked proposeAdminExecute
    // path. This proves a compromised enclave quorum cannot reach any privileged
    // function: enclave signatures over an admin-execute proposal are rejected.
    // ========================================================================

    function test_enclaveKeysCannotDriveAdminExecute() public {
        // A privileged call the TEE quorum might want to smuggle through.
        bytes memory callData = abi.encodeWithSignature("pauseInflow()");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        // Same proposal digest the federation would sign...
        bytes32 digest =
            MultisigHelper.digestProposeAdminExecute(domainSep, bytes4(callData), callData, nonce, deadline);
        // ...but signed by the ENCLAVE (TEE) keys instead of the federation.
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // proposeAdminExecute verifies against the federation signer set, so the
        // recovered enclave addresses are not authorized: the proposal is never
        // created and the privileged call never reaches the timelock queue.
        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.proposeAdminExecute(callData, nonce, deadline, bitmap, sigs);
    }

    // ========================================================================
    // lzFundsOutCall binds the release and send-out legs
    //
    // Flow-4 release and the cross-chain send are bound on-chain in one signed
    // operation: the Bridge recipient is forced to the adapter (no params field
    // for it), and the amount handed to adapter.sendOut is the balance the
    // adapter ACTUALLY received, measured on-chain — not params.amount. A token
    // commission makes gross != net, which is what distinguishes the bound
    // (net delivered) amount from the signed gross amount.
    // ========================================================================

    function test_lzFundsOutCall_sendsNetDeliveredNotGross() public {
        // 5% FUNDS_OUT token commission so gross (AMOUNT) != net (delivered).
        vm.prank(address(proxy));
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: 500, // 5%
                baseFee: 0,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, "fee makes gross != net");
        assertEq(netAmount, AMOUNT - tokenCommission, "net = gross - fee");

        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        // Leg 1: the Bridge recipient is forced to the adapter (not in params).
        vm.expectEmit(true, true, false, true, address(bridge));
        emit BridgeFundsOut(
            address(adapter), AMOUNT, netAmount, tokenCommission, params.burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR
        );
        // Leg 2: sendOut carries the NET delivered amount, not the gross AMOUNT.
        bytes32 sendOutGuid = keccak256(abi.encode("mock-send-out", DST_EID, LZ_RECIPIENT, netAmount));
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, netAmount);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);

        // The send-out amount is bound to what the adapter received: it forwarded
        // exactly the net (leaving no residue) and that net differs from gross.
        assertEq(token.balanceOf(address(adapter)), 0, "adapter forwarded everything it received");
        assertEq(token.balanceOf(mockOft), netAmount, "oft received exactly the net delivered");
        assertTrue(netAmount != AMOUNT, "bound amount is distinct from signed gross");
    }

    // ========================================================================
    // Immutable TVL-relative safety limit
    // ========================================================================

    /// @dev buckets are set to a maximum-total policy, the pool is fully funded, and
    ///      a valid 2-of-3 enclave quorum signs a release of the entire pool.
    ///      It reverts. Note what the assertions now show that the audited build
    ///      could not: `availableOutflow` reports 10% of TVL, not ≥ TVL, so the
    ///      PoC's own `assertGe(availableOutflow, tvl)` premise no longer holds
    ///      either.
    function test_enclaveSignedFullPoolDrainRevertsWithMaxAllowedBuckets() public {
        address drainRecipient = makeAddr("drainRecipient");

        uint256 bridgeBefore = token.balanceOf(address(bridge));
        uint256 recordBefore = rgbModule.fundsInRecords(seedOpId);
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();

        assertEq(bridgeBefore, AMOUNT * 10, "pre bridge pool");
        assertEq(recordBefore, bridgeBefore, "pre record backs full pool");
        assertLt(bridge.availableOutflow(RGB_CHAIN_ID), bridgeBefore, "chain bucket cannot cover TVL");
        assertLt(bridge.availableGlobalOutflow(), bridgeBefore, "global bucket cannot cover TVL");
        assertEq(
            bridge.effectiveAvailableOutflow(RGB_CHAIN_ID),
            bridgeBefore * MAX_BURST_BPS / bridge.BPS_DENOMINATOR(),
            "at most the configured burst can leave, well under TVL"
        );

        IBridge.FundsOutParams memory params = _fundsOutParams(drainRecipient, bridgeBefore, BURN_ID);
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // The whole pool is 10_000 bps of the reference; the bucket's burst is
        // MAX_BURST_BPS. Requesting 100% therefore exceeds capacity outright.
        uint256 shareUnit = bridge.SHARE_UNIT();
        vm.expectRevert(
            abi.encodeWithSelector(
                OutflowRateLimiter.TokenRequestAboveCapacity.selector,
                MAX_BURST_BPS * shareUnit / bridge.BPS_DENOMINATOR(),
                shareUnit, // the full pool is exactly one SHARE_UNIT of reference
                address(token)
            )
        );
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce, "reverted release does not consume nonce");
        assertFalse(bridge.consumedBurnIds(params.burnId), "reverted release does not consume burn id");
        assertEq(token.balanceOf(address(bridge)), bridgeBefore, "entire pool remains");
        assertEq(token.balanceOf(drainRecipient), 0, "recipient receives nothing");
        assertEq(
            bridge.availableChainSafetyOutflow(RGB_CHAIN_ID),
            bridgeBefore * maxBps / bridge.BPS_DENOMINATOR(),
            "immutable allowance unchanged"
        );
    }

    /// @dev Fragmented drain: the attacker splits the release across refill
    ///      windows. At the 24-hour boundary the bucket has refilled, while the
    ///      first spend is still retained by the conservative rolling window.
    ///      The second release may consume the immutable remainder, but a third
    ///      valid 2-of-3 signed transaction cannot exceed the rolling 20% cap.
    function test_splitTransactionsCannotExceedAggregateRollingLimit() public {
        // Align to an hour boundary so the ring's 24-25h retention is exact
        // relative to the releases below rather than to an arbitrary offset.
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);

        uint256 tvl = token.balanceOf(address(bridge));
        uint256 hardLimit = tvl * bridge.MAX_CHAIN_OUTFLOW_BPS() / bridge.BPS_DENOMINATOR();

        _signedRelease(makeAddr("split-recipient-1"), hardLimit / 2, BURN_ID);
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), hardLimit / 2, "half the allowance left");
        assertEq(bridge.availableGlobalSafetyOutflow(), hardLimit / 2);

        // At 24h + 1s the share bucket is fully refilled against the lower
        // current liquidity, while the rolling limiter still counts the first
        // release against its original reference.
        vm.warp(block.timestamp + bridge.BUCKET_REFILL_WINDOW() + 1);
        uint256 secondPart = bridge.effectiveAvailableOutflow(RGB_CHAIN_ID) - 1;
        _signedRelease(makeAddr("split-recipient-2"), secondPart, BURN_ID + 1);
        uint256 totalReleased = hardLimit / 2 + secondPart;
        assertLe(totalReleased, hardLimit, "split releases stay within the immutable ceiling");
        assertEq(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), hardLimit - totalReleased);
        assertEq(bridge.availableGlobalSafetyOutflow(), hardLimit - totalReleased);

        // One second of refill cannot make the effective allowance exceed the
        // remaining immutable allowance.
        vm.warp(block.timestamp + 1);
        assertGt(bridge.availableOutflow(RGB_CHAIN_ID), 0, "bucket has accrued allowance");
        assertLe(
            bridge.effectiveAvailableOutflow(RGB_CHAIN_ID),
            hardLimit - totalReleased,
            "rolling ceiling remains authoritative"
        );

        assertEq(token.balanceOf(address(bridge)), tvl - totalReleased);
        assertGe(token.balanceOf(address(bridge)), tvl - hardLimit, "at most 20% leaves during the window");

        // Liveness: once the oldest usage expires the next tranche is releasable.
        // The ring retains for 24-25h, so 25h past the aligned start clears it.
        vm.warp(block.timestamp + 25 hours);
        assertGt(bridge.availableChainSafetyOutflow(RGB_CHAIN_ID), 0, "allowance returns in the next window");
        assertGt(bridge.effectiveAvailableOutflow(RGB_CHAIN_ID), 0, "releases resume");
    }

    /// @dev Everything a signed release needs, resolved up front. Kept separate
    ///      from submission so `vm.expectRevert` can sit immediately before the
    ///      single `fundsOutCall` — the preparation itself makes external calls
    ///      and would otherwise absorb the expectation.
    function _prepareRelease(address to, uint256 amount, uint256 burnId)
        internal
        view
        returns (
            IBridge.FundsOutParams memory params,
            uint256 nonce,
            uint256 deadline,
            uint256 bitmap,
            bytes[] memory sigs
        )
    {
        params = _fundsOutParams(to, amount, burnId);
        nonce = proxy.teeNonce(RGB_CHAIN_ID);
        deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks;
        (pks, bitmap) = _encSigSet2of3();
        sigs = MultisigHelper.signAll(vm, digest, pks);
    }

    /// @dev Sign and submit a `fundsOut` through the enclave 2-of-3 quorum.
    function _signedRelease(address to, uint256 amount, uint256 burnId) internal {
        (IBridge.FundsOutParams memory params, uint256 nonce, uint256 deadline, uint256 bitmap, bytes[] memory sigs) =
            _prepareRelease(to, amount, burnId);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    /// @dev A full-TVL bucket is not merely rejected against current liquidity;
    ///      it is unrepresentable.
    ///      The policy is a percentage, and `burstBps + refillBpsPerWindow` is
    ///      bounded by the immutable `MAX_CHAIN_OUTFLOW_BPS`, so there is no
    ///      liquidity level at which this proposal would ever succeed.
    function test_federationCannotConfigureChainBucketForFullTvl() public {
        uint256 fullTvlBps = bridge.BPS_DENOMINATOR(); // 10_000 bps == 100% of TVL
        uint256 maxBps = bridge.MAX_CHAIN_OUTFLOW_BPS();
        uint256 availableBefore = bridge.availableOutflow(RGB_CHAIN_ID);

        bytes memory callData = abi.encodeCall(IBridge.setOutflowLimit, (RGB_CHAIN_ID, fullTvlBps, uint256(1)));
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest =
            MultisigHelper.digestProposeAdminExecute(domainSep, bytes4(callData), callData, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 proposalId =
            proxy.proposeAdminExecute(callData, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks));

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(abi.encodeWithSelector(IBridge.InvalidOutflowPolicy.selector, fullTvlBps, uint256(1), maxBps));
        proxy.executeProposal(proposalId, callData);

        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), availableBefore, "safe bucket configuration unchanged");
    }

    function test_governanceCanRotateEnclaveToUnattestedEOA() public {
        address[] memory newSigners = new address[](3);
        newSigners[0] = makeAddr("unattestedEnc1");
        newSigners[1] = makeAddr("unattestedEnc2");
        newSigners[2] = makeAddr("unattestedEnc3");
        uint256 newThreshold = 2;

        address[] memory before_ = proxy.getEnclaveSigners(RGB_CHAIN_ID);
        assertEq(before_.length, 3, "pre enclave count");
        assertEq(before_[0], encA1, "pre signer 0");
        assertEq(before_[1], encA2, "pre signer 1");
        assertEq(before_[2], encA3, "pre signer 2");
        assertEq(proxy.enclaveThreshold(RGB_CHAIN_ID), 2, "pre enclave threshold");

        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id =
            proxy.proposeUpdateEnclaveSigners(RGB_CHAIN_ID, newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);

        // Current behavior: the normal rotation path is already covered above;
        // this case documents that only address shape and threshold are checked,
        // with no on-chain enclave attestation evidence. If attestation is
        // enforced later, this test should be inverted to expect a revert.
        vm.expectEmit(true, false, false, true, address(proxy));
        emit EnclaveSignersUpdated(RGB_CHAIN_ID, newSigners, newThreshold);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit ProposalExecuted(id, IMultisigProxy.OperationType.UpdateEnclaveSigners);

        proxy.executeProposal(id, abi.encode(RGB_CHAIN_ID, newSigners, newThreshold));

        address[] memory after_ = proxy.getEnclaveSigners(RGB_CHAIN_ID);
        assertEq(after_.length, 3, "post enclave count");
        assertEq(after_[0], newSigners[0], "post signer 0");
        assertEq(after_[1], newSigners[1], "post signer 1");
        assertEq(after_[2], newSigners[2], "post signer 2");
        assertEq(proxy.enclaveThreshold(RGB_CHAIN_ID), newThreshold, "post enclave threshold");
    }

    function test_proposalUsesSnapshottedTimelock() public {
        uint256 proposedAt = block.timestamp;
        address newBridge = makeAddr("snapshotTimelockBridge");
        uint256 newDuration = 2 hours; // raise above the 1h in force at creation
        uint256 deadline = proposedAt + 1 days;

        assertEq(proxy.timelockDuration(), TIMELOCK, "pre timelock");

        // Proposal A — created while timelockDuration == TIMELOCK (1h).
        uint256 bridgeNonce = proxy.proposalNonce();
        bytes32 bridgeDigest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, bridgeNonce, deadline);
        (uint256[] memory bridgePks, uint256 bridgeBitmap) = _fedSigSet2of3();
        bytes[] memory bridgeSigs = MultisigHelper.signAll(vm, bridgeDigest, bridgePks);
        bytes32 bridgeProposalId = proxy.proposeUpdateBridge(newBridge, bridgeNonce, deadline, bridgeBitmap, bridgeSigs);

        assertEq(proxy.getProposal(bridgeProposalId).timelockSnapshot, TIMELOCK, "timelock snapshotted at creation");

        // Raise the live timelock to 2h via its own proposal.
        uint256 timelockNonce = proxy.proposalNonce();
        bytes32 timelockDigest =
            MultisigHelper.digestProposeSetTimelockDuration(domainSep, newDuration, timelockNonce, deadline);
        (uint256[] memory timelockPks, uint256 timelockBitmap) = _fedSigSet2of3();
        bytes[] memory timelockSigs = MultisigHelper.signAll(vm, timelockDigest, timelockPks);
        bytes32 timelockProposalId =
            proxy.proposeSetTimelockDuration(newDuration, timelockNonce, deadline, timelockBitmap, timelockSigs);

        // At proposedAt + 1h + 1: both proposals' creation-time snapshot (1h)
        // has elapsed. Execute the timelock raise first.
        vm.warp(proposedAt + TIMELOCK + 1);
        proxy.executeProposal(timelockProposalId, abi.encode(newDuration));
        assertEq(proxy.timelockDuration(), newDuration, "live timelock raised to 2h");

        // Proposal A uses its 1h snapshot, so it is mature now and executes —
        // the raised live timelock (2h) does NOT re-lock it. Under the pre-fix
        // live-timelock check this would revert TimelockActive.
        proxy.executeProposal(bridgeProposalId, abi.encode(newBridge));
        assertEq(proxy.bridge(), newBridge, "snapshotted proposal executes despite the live timelock raise");
    }

    function test_federationRotationInvalidatesPendingProposals() public {
        assertEq(proxy.federationSignerSetVersion(), 1, "initial federation version");

        // This proposal is valid under the original federation, but remains
        // pending while a signer rotation is proposed and executed.
        address staleBridge = makeAddr("staleBridge");
        uint256 staleNonce = proxy.proposalNonce();
        uint256 commonDeadline = block.timestamp + 1 days;
        bytes32 staleDigest =
            MultisigHelper.digestProposeUpdateBridge(domainSep, staleBridge, staleNonce, commonDeadline);
        (uint256[] memory oldPks, uint256 oldBitmap) = _fedSigSet2of3();
        bytes32 staleId = proxy.proposeUpdateBridge(
            staleBridge, staleNonce, commonDeadline, oldBitmap, MultisigHelper.signAll(vm, staleDigest, oldPks)
        );
        assertEq(proxy.getProposal(staleId).federationVersion, 1, "proposal snapshots version one");

        uint256[] memory newPks = new uint256[](3);
        address[] memory newSigners = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            newPks[i] = 0xFA1 + i;
            newSigners[i] = vm.addr(newPks[i]);
        }

        uint256 rotationNonce = proxy.proposalNonce();
        bytes32 rotationDigest = MultisigHelper.digestProposeUpdateFederationSigners(
            domainSep, newSigners, 2, rotationNonce, commonDeadline
        );
        bytes32 rotationId = proxy.proposeUpdateFederationSigners(
            newSigners, 2, rotationNonce, commonDeadline, oldBitmap, MultisigHelper.signAll(vm, rotationDigest, oldPks)
        );
        assertEq(proxy.getProposal(rotationId).federationVersion, 1, "rotation uses current version");

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(rotationId, abi.encode(newSigners, uint256(2)));
        assertEq(proxy.federationSignerSetVersion(), 2, "rotation advances version");

        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.StaleFederationProposal.selector, uint256(1), uint256(2)));
        proxy.executeProposal(staleId, abi.encode(staleBridge));
        assertEq(
            uint256(proxy.getProposal(staleId).status),
            uint256(IMultisigProxy.ProposalStatus.Pending),
            "stale proposal cannot execute"
        );

        // The live federation can still cancel stale records for operational
        // cleanup; cancellation intentionally has no version restriction.
        uint256 cancelDeadline = block.timestamp + 1 days;
        bytes32 cancelDigest = MultisigHelper.digestCancelProposal(domainSep, staleId, cancelDeadline);
        uint256[] memory cancellingPks = new uint256[](2);
        cancellingPks[0] = newPks[0];
        cancellingPks[1] = newPks[1];
        proxy.cancelProposal(staleId, cancelDeadline, 3, MultisigHelper.signAll(vm, cancelDigest, cancellingPks));
        assertEq(
            uint256(proxy.getProposal(staleId).status),
            uint256(IMultisigProxy.ProposalStatus.Cancelled),
            "live federation cleans up stale proposal"
        );
    }

    // Emergency actions run on a separate `emergencyNonce`, so an emergency
    // pause does NOT stale an already-signed regular proposal.
    function test_emergencyDoesNotStaleRegularProposal() public {
        address newBridge = makeAddr("nonceCollisionBridge");
        uint256 regularNonce = proxy.proposalNonce();
        uint256 regularDeadline = block.timestamp + 1 days;

        // Pre-sign a regular proposal at the current proposal-lane nonce.
        bytes32 regularDigest =
            MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, regularNonce, regularDeadline);
        (uint256[] memory regularPks, uint256 regularBitmap) = _fedSigSet2of3();
        bytes[] memory regularSigs = MultisigHelper.signAll(vm, regularDigest, regularPks);

        // An emergency pause runs on its own lane nonce.
        uint256 emergencyLaneNonce = proxy.emergencyNonce();
        uint256 emergencyDeadline = block.timestamp + 1 hours;
        bytes32 emergencyDigest = MultisigHelper.digestEmergencyPause(domainSep, emergencyLaneNonce, emergencyDeadline);
        (uint256[] memory emergencyPks, uint256 emergencyBitmap) = _fedSigSet2of3();
        bytes[] memory emergencySigs = MultisigHelper.signAll(vm, emergencyDigest, emergencyPks);

        proxy.emergencyPause(emergencyLaneNonce, emergencyDeadline, emergencyBitmap, emergencySigs);

        assertTrue(bridge.paused(), "bridge paused by emergency action");
        assertEq(proxy.emergencyNonce(), emergencyLaneNonce + 1, "emergency advanced only its own lane");
        assertEq(proxy.proposalNonce(), regularNonce, "proposal lane untouched by emergency");

        // The pre-signed regular proposal is still valid and submits successfully.
        bytes32 id = proxy.proposeUpdateBridge(newBridge, regularNonce, regularDeadline, regularBitmap, regularSigs);
        assertTrue(id != bytes32(0), "regular proposal created despite the emergency action");
        assertEq(proxy.proposalNonce(), regularNonce + 1, "regular proposal consumed its lane nonce");
    }

    function test_genericPathsRejectTransferOwnershipSelector() public {
        bytes memory callData = abi.encodeWithSignature("transferOwnership(address)", user);
        _assertGenericPathsRejectSelector(callData, IMultisigProxy.ForbiddenOwnershipSelector.selector);
    }

    function test_transferManagedOwnership_initiatesBridgeOwnershipTransfer() public {
        address newOwner = makeAddr("newBridgeOwner");
        (bytes32 id, bytes memory opData) = _proposeManagedOwnership(address(bridge), newOwner);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, opData);

        assertEq(bridge.owner(), address(proxy), "two-step owner unchanged");
        assertEq(bridge.pendingOwner(), newOwner, "typed transfer started");
    }

    function test_transferManagedOwnership_initiatesRouteRegistryOwnershipTransfer() public {
        address newOwner = makeAddr("newRouteRegistryOwner");
        (bytes32 id, bytes memory opData) = _proposeManagedOwnership(address(routeRegistry), newOwner);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, opData);

        assertEq(routeRegistry.owner(), address(proxy), "RR owner unchanged (two-step)");
        assertEq(routeRegistry.pendingOwner(), newOwner, "typed RR transfer started");
    }

    // Standard CM withdrawals stay on the dedicated typed operations. Recipient
    // safety no longer depends on this blocklist: CM enforces it immutably.
    function test_genericPathsRejectCommissionWithdrawSelectors() public {
        bytes[] memory callDatas = new bytes[](4);
        callDatas[0] = abi.encodeWithSignature("withdrawTokenCommission(address,uint256)", address(token), uint256(1));
        callDatas[1] = abi.encodeWithSignature("withdrawNativeCommission(uint256)", uint256(1));
        callDatas[2] = abi.encodeWithSignature("withdrawAllTokenCommission(address)", address(token));
        callDatas[3] = abi.encodeWithSignature("withdrawAllNativeCommission()");

        for (uint256 i = 0; i < callDatas.length; i++) {
            _assertGenericPathsRejectSelector(callDatas[i], IMultisigProxy.ForbiddenCommissionManagerSelector.selector);
        }
    }

    // CommissionManager ownership migration remains available through the
    // typed lane, while its immutable recipient still pins all withdrawals.
    function test_transferManagedOwnership_commissionRecipientRemainsPinned() public {
        uint256 amount = 10 ether;
        token.mint(address(cm), amount);
        vm.prank(address(bridge));
        cm.receiveTokenCommission(address(token), amount);

        (bytes32 id, bytes memory opData) = _proposeManagedOwnership(address(cm), user);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, opData);

        vm.prank(user);
        cm.acceptOwnership();
        assertEq(cm.owner(), user, "typed CM ownership migration works");

        uint256 pinnedBefore = token.balanceOf(commissionReceiver);
        uint256 attackerBefore = token.balanceOf(user);
        vm.prank(user);
        cm.withdrawTokenCommission(address(token), amount);

        assertEq(token.balanceOf(commissionReceiver), pinnedBefore + amount, "immutable recipient paid");
        assertEq(token.balanceOf(user), attackerBefore, "new owner cannot redirect commission to itself");
        assertEq(proxy.commissionRecipient(), commissionReceiver, "proxy reports CM's immutable recipient");
    }

    function test_transferManagedOwnership_rejectsUnmanagedTarget() public {
        address unmanaged = makeAddr("unmanaged");
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.InvalidManagedOwnershipTarget.selector, unmanaged));
        proxy.proposeTransferManagedOwnership(unmanaged, user, 0, block.timestamp + 1 days, 0, new bytes[](0));
    }

    function test_transferManagedOwnership_rejectsZeroNewOwner() public {
        vm.expectRevert(IMultisigProxy.ZeroNewOwner.selector);
        proxy.proposeTransferManagedOwnership(
            address(bridge), address(0), 0, block.timestamp + 1 days, 0, new bytes[](0)
        );
    }

    function test_transferManagedOwnership_signatureBindsTargetAndNewOwner() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeTransferManagedOwnership(domainSep, address(bridge), user, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.proposeTransferManagedOwnership(address(cm), user, nonce, deadline, bitmap, sigs);

        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.proposeTransferManagedOwnership(
            address(bridge), makeAddr("differentOwner"), nonce, deadline, bitmap, sigs
        );
    }

    function test_transferManagedOwnership_rechecksTargetAtExecution() public {
        (bytes32 transferId, bytes memory transferData) =
            _proposeManagedOwnership(address(routeRegistry), makeAddr("newOwner"));

        RouteRegistry replacement = new RouteRegistry(address(bridge), address(proxy));
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeUpdateRouteRegistry(domainSep, address(replacement), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 updateId = proxy.proposeUpdateRouteRegistry(
            address(replacement), nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks)
        );

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(updateId, abi.encode(address(replacement)));

        vm.expectRevert(
            abi.encodeWithSelector(IMultisigProxy.InvalidManagedOwnershipTarget.selector, address(routeRegistry))
        );
        proxy.executeProposal(transferId, transferData);
    }

    function _proposeManagedOwnership(address target, address newOwner)
        internal
        returns (bytes32 id, bytes memory opData)
    {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeTransferManagedOwnership(domainSep, target, newOwner, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        id = proxy.proposeTransferManagedOwnership(
            target, newOwner, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks)
        );
        opData = abi.encode(target, newOwner);
    }

    // The generic path stays open for permitted CommissionManager setters.
    function test_adminExecuteCommissionManager_allowsConfigSelector() public {
        bytes memory callData = abi.encodeWithSignature(
            "setGlobalDefaults(uint256,uint256,uint8,uint8,uint8)",
            uint256(0),
            uint256(0),
            uint8(100),
            uint8(0),
            uint8(0)
        );
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeAdminExecuteCM(domainSep, bytes4(callData), callData, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteCommissionManager(callData, nonce, deadline, bitmap, sigs);
        assertTrue(id != bytes32(0), "CM config selector accepted on the generic path");
    }

    // Deployment compatibility: the deployer initiates CM's Ownable2Step handoff
    // directly, then the proxy must be able to propose acceptOwnership().
    function test_adminExecuteCommissionManager_allowsAcceptOwnershipSelector() public {
        bytes memory callData = abi.encodeWithSignature("acceptOwnership()");
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeAdminExecuteCM(domainSep, bytes4(callData), callData, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteCommissionManager(callData, nonce, deadline, bitmap, sigs);
        assertTrue(id != bytes32(0), "CM acceptOwnership selector accepted on the generic path");
    }

    // ========================================================================
    // Per-source-chain enclave signer sets
    // ========================================================================
    //
    // NOTE: these tests run multiple propose -> warp -> execute cycles. Time is
    // read via `vm.getBlockTimestamp()` rather than the `block.timestamp` opcode:
    // under via_ir the optimizer caches `block.timestamp` across the `vm.warp`
    // staticcall, so a later cycle would otherwise reuse a stale timestamp.

    /// @dev `n` deterministic, globally-unique signer addresses for `chainId`,
    ///      in a keccak namespace disjoint from the setUp enclave/federation
    ///      addresses and from every other chain's generated set.
    function _encSetFor(uint256 chainId, uint256 n) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = address(uint160(uint256(keccak256(abi.encode("enc-set", chainId, i)))));
        }
    }

    /// @dev Register (or rotate) an enclave set for `chainId` via the federation
    ///      propose -> timelock -> execute path (signed by the original 2-of-3
    ///      federation, which is left untouched by these helpers).
    function _govUpdateEnclave(uint256 chainId, address[] memory signers, uint256 threshold) internal {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeUpdateEnclaveSigners(domainSep, chainId, signers, threshold, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        bytes32 id = proxy.proposeUpdateEnclaveSigners(chainId, signers, threshold, nonce, deadline, bitmap, sigs);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(chainId, signers, threshold));
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

    /// @dev A federation candidate set derived from sequential private keys so
    ///      the caller retains the pks to sign the *next* rotation.
    function _fedFromPks(uint256 base, uint256 n) internal returns (address[] memory addrs, uint256[] memory pks) {
        addrs = new address[](n);
        pks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            pks[i] = base + i;
            addrs[i] = vm.addr(pks[i]);
        }
    }

    /// @dev An enclave candidate set derived from sequential private keys, so a
    ///      test can register the set AND later sign a real release with it.
    function _encFromPks(uint256 base, uint256 n) internal returns (address[] memory addrs, uint256[] memory pks) {
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

    // ---- release-path behaviour -------------------------------------------

    /// @dev `fundsOutCall` for a source chain with no registered enclave set
    ///      reverts UnknownSourceChain before touching the nonce/signatures.
    function test_perSourceChain_fundsOutRevertsForUnregisteredSourceChain() public {
        IBridge.FundsOutParams memory p = _fundsOutParams();
        p.sourceChainId = 424_242; // not registered
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, uint256(424_242)));
        proxy.fundsOutCall(p, 0, vm.getBlockTimestamp() + 1 hours, 0, new bytes[](0));
    }

    /// @dev A release for chain B signed by chain A's (RGB) enclave keys is
    ///      rejected: selection by sourceChainId verifies A's signatures against
    ///      B's set, which does not contain them.
    function test_perSourceChain_signatureFromAnotherChainRejected() public {
        uint256 chainB = 7_000_001;
        _govUpdateEnclave(chainB, _encSetFor(chainB, 3), 2);

        IBridge.FundsOutParams memory p = _fundsOutParams();
        p.sourceChainId = chainB;
        uint256 nonce = proxy.teeNonce(chainB); // 0
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, p, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3(); // RGB signers
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // Must fail at the signer check (recovered RGB signer != chainB's set),
        // NOT downstream in the Bridge — that is what proves signer-set isolation.
        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.fundsOutCall(p, nonce, deadline, bitmap, sigs);
    }

    /// @dev Each source chain has an independent teeNonce lane: an RGB release
    ///      advances only RGB's nonce, not another registered chain's.
    function test_perSourceChain_teeNonceLanesIndependent() public {
        uint256 chainB = 7_000_002;
        _govUpdateEnclave(chainB, _encSetFor(chainB, 3), 2);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), 0, "RGB nonce starts at 0");
        assertEq(proxy.teeNonce(chainB), 0, "chainB nonce starts at 0");

        IBridge.FundsOutParams memory p = _fundsOutParams();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, p, proxy.teeNonce(RGB_CHAIN_ID), deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        proxy.fundsOutCall(p, 0, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(RGB_CHAIN_ID), 1, "RGB lane advanced");
        assertEq(proxy.teeNonce(chainB), 0, "chainB lane untouched");
    }

    // ---- registration / rotation ------------------------------------------

    function test_perSourceChain_registerNewChain() public {
        uint256 chainB = 8_000_001;
        address[] memory sB = _encSetFor(chainB, 4);
        _govUpdateEnclave(chainB, sB, 3); // 2*3 > 4

        assertEq(proxy.enclaveThreshold(chainB), 3);
        address[] memory got = proxy.getEnclaveSigners(chainB);
        assertEq(got.length, 4);
        assertEq(got[0], sB[0]);

        uint256[] memory chains = proxy.getEnclaveSourceChains();
        assertEq(chains.length, 2, "RGB + chainB");
        assertEq(chains[0], RGB_CHAIN_ID);
        assertEq(chains[1], chainB);
    }

    /// @dev Federation rotation must be disjoint from *every* enclave chain.
    function test_perSourceChain_federationRotationRejectsEnclaveOverlap() public {
        uint256 chainB = 8_000_002;
        address[] memory sB = _encSetFor(chainB, 3);
        _govUpdateEnclave(chainB, sB, 2);

        address[] memory newFed = new address[](3);
        newFed[0] = sB[0]; // overlaps chainB
        newFed[1] = fedA2;
        newFed[2] = fedA3;

        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateFederationSigners(domainSep, newFed, 2, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        bytes32 id = proxy.proposeUpdateFederationSigners(newFed, 2, nonce, deadline, bitmap, sigs);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.SignerSetsOverlap.selector, sB[0]));
        proxy.executeProposal(id, abi.encode(newFed, 2));
    }

    /// @dev Different source chains may intentionally reuse the same enclave
    ///      keys. Each set remains internally unique and signatures stay bound
    ///      to their sourceChainId-specific digest and nonce lane.
    function test_perSourceChain_enclaveSetsMayReuseSameSigners() public {
        uint256 chainB = 8_000_003;
        address[] memory sB = _encSetFor(chainB, 3);
        _govUpdateEnclave(chainB, sB, 2);

        uint256 chainC = 8_000_004;
        _govUpdateEnclave(chainC, sB, 2);

        address[] memory gotB = proxy.getEnclaveSigners(chainB);
        address[] memory gotC = proxy.getEnclaveSigners(chainC);
        assertEq(gotB, sB, "chain B signer set");
        assertEq(gotC, sB, "chain C reuses signer set");
        assertEq(proxy.enclaveThreshold(chainB), 2, "chain B threshold");
        assertEq(proxy.enclaveThreshold(chainC), 2, "chain C threshold");
    }

    /// @dev A partial rotation may keep some of the chain's own keys.
    function test_perSourceChain_partialRotationSelfExclusionAllowed() public {
        address[] memory newRgb = new address[](2);
        newRgb[0] = encA1; // keep an existing RGB signer
        newRgb[1] = makeAddr("rgbFresh");
        uint256 chainsBefore = proxy.getEnclaveSourceChains().length;
        _govUpdateEnclave(RGB_CHAIN_ID, newRgb, 2);

        address[] memory got = proxy.getEnclaveSigners(RGB_CHAIN_ID);
        assertEq(got.length, 2);
        assertEq(got[0], encA1, "kept its own key via self-exclusion");
        // Rotating an existing chain must not add a duplicate registry entry.
        assertEq(proxy.getEnclaveSourceChains().length, chainsBefore, "no duplicate source-chain entry on rotation");
    }

    /// @dev Registering more than MAX_ENCLAVE_SOURCE_CHAINS source chains is
    ///      rejected at execute (bounds the cross-set disjoint loop).
    function test_perSourceChain_maxEnclaveSourceChainsCap() public {
        uint256 maxChains = proxy.MAX_ENCLAVE_SOURCE_CHAINS();
        // RGB already occupies slot 1 — fill the rest.
        for (uint256 k = 0; k < maxChains - 1; k++) {
            uint256 chainId = 6_000_000 + k;
            _govUpdateEnclave(chainId, _encSetFor(chainId, 2), 2);
        }
        assertEq(proxy.getEnclaveSourceChains().length, maxChains);

        uint256 overflowChain = 6_999_999;
        address[] memory s = _encSetFor(overflowChain, 2);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeUpdateEnclaveSigners(domainSep, overflowChain, s, 2, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        bytes32 id = proxy.proposeUpdateEnclaveSigners(overflowChain, s, 2, nonce, deadline, bitmap, sigs);
        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IMultisigProxy.TooManyEnclaveSourceChains.selector, maxChains + 1, maxChains)
        );
        proxy.executeProposal(id, abi.encode(overflowChain, s, 2));
    }

    // ---- positive per-source authorization --------------------------------

    /// @dev A per-source set's OWN keys authorize a release for that chain, and
    ///      the correct nonce lane advances. RGB is rotated to keys we control
    ///      so the full release (reusing RGB's configured route/liquidity) runs.
    function test_perSourceChain_ownKeysAuthorizeRelease() public {
        (address[] memory encAddrs, uint256[] memory encPks) = _encFromPks(0xEEE0000, 3);
        _govUpdateEnclave(RGB_CHAIN_ID, encAddrs, 2);

        uint256 balBefore = token.balanceOf(recipient);
        IBridge.FundsOutParams memory p = _fundsOutParams();
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, p, nonce, deadline);
        uint256[] memory signPks = new uint256[](2);
        signPks[0] = encPks[0];
        signPks[1] = encPks[1];
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, signPks);

        proxy.fundsOutCall(p, nonce, deadline, 0x3, sigs);

        assertGt(token.balanceOf(recipient), balBefore, "chain-owned keys authorized the release");
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "RGB nonce advanced");
    }

    /// @dev The LZ branch selects the enclave set + nonce lane by source chain:
    ///      an RGB LZ release advances only RGB's lane and emits sourceChainId.
    function test_perSourceChain_lz_selectsPerSourceLane() public {
        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter)); // fresh ts (first gov action)
        _govUpdateEnclave(7_100_001, _encSetFor(7_100_001, 3), 2); // second registered chain

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        uint256 nonce = proxy.teeNonce(RGB_CHAIN_ID);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.deal(address(this), LZ_NATIVE_FEE);
        vm.expectEmit(true, true, false, false);
        emit LzFundsOutExecuted(RGB_CHAIN_ID, nonce, bitmap, params.dstEid, params.recipient, AMOUNT);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);

        assertEq(token.balanceOf(mockOft), AMOUNT, "LZ release forwarded to OFT");
        assertEq(proxy.teeNonce(RGB_CHAIN_ID), nonce + 1, "RGB LZ lane advanced");
        assertEq(proxy.teeNonce(7_100_001), 0, "other chain LZ lane untouched");
    }

    /// @dev lzFundsOutCall for an unregistered source chain reverts UnknownSourceChain.
    function test_perSourceChain_lz_unregisteredSourceReverts() public {
        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        params.sourceChainId = 424_242; // unregistered (checked before adapter/signatures)
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, uint256(424_242)));
        proxy.lzFundsOutCall(params, 0, vm.getBlockTimestamp() + 1 hours, 0, new bytes[](0));
    }

    /// @dev An LZ release for chain B signed by RGB keys is rejected at the
    ///      signer check (per-source selection), not downstream.
    function test_perSourceChain_lz_signatureFromAnotherChainRejected() public {
        address mockOft = makeAddr("mockOft");
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));
        uint256 chainB = 7_200_001;
        _govUpdateEnclave(chainB, _encSetFor(chainB, 3), 2);

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        params.sourceChainId = chainB;
        uint256 nonce = proxy.teeNonce(chainB); // 0
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3(); // RGB signers
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.deal(address(this), LZ_NATIVE_FEE);
        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.lzFundsOutCall{value: LZ_NATIVE_FEE}(params, nonce, deadline, bitmap, sigs);
    }

    // ---- governance binding / validation -----------------------------------

    /// @dev The enclave-rotation proposal digest is bound to sourceChainId:
    ///      a digest signed for RGB cannot authorize a rotation of chain B.
    ///      Guards against regressing the sourceChainId out of the typehash.
    function test_perSourceChain_proposeUpdateEnclaveDigestBoundToSourceChain() public {
        uint256 chainB = 7_300_001;
        address[] memory sB = _encSetFor(chainB, 2);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
        // Federation signs the digest for RGB_CHAIN_ID...
        bytes32 digest =
            MultisigHelper.digestProposeUpdateEnclaveSigners(domainSep, RGB_CHAIN_ID, sB, 2, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        // ...but the proposal is submitted for chainB -> digest mismatch.
        vm.expectRevert(IMultisigProxy.InvalidSignature.selector);
        proxy.proposeUpdateEnclaveSigners(chainB, sB, 2, nonce, deadline, bitmap, sigs);
    }

    /// @dev sourceChainId == 0 is reserved (threshold 0 is the "unregistered"
    ///      sentinel), so it is rejected at construction.
    function test_perSourceChain_constructorRejectsZeroSourceChain() public {
        address[] memory enc = _validEnc();
        address[] memory fed = _validFed();
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, uint256(0)));
        new MultisigProxy(address(bridge), address(cm), enc, 2, 0, fed, 2, TIMELOCK, MIN_TIMELOCK);
    }

    /// @dev ...and rejected up front by proposeUpdateEnclaveSigners (before sigs).
    function test_perSourceChain_proposeRejectsZeroSourceChain() public {
        address[] memory sB = _encSetFor(1, 2);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
        bytes[] memory noSigs = new bytes[](0);
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.UnknownSourceChain.selector, uint256(0)));
        proxy.proposeUpdateEnclaveSigners(0, sB, 2, nonce, deadline, 0, noSigs);
    }

    // ---- gas boundary ------------------------------------------------------

    /// @dev Boundary/gas: fill the registry to MAX_ENCLAVE_SOURCE_CHAINS (32),
    ///      each with the maximum MAX_SIGNERS (20) enclave signers, then confirm
    ///      an enclave rotation and federation rotations (3/5/10 signers) still
    ///      execute well under a conservative block gas limit — the cross-set
    ///      disjoint loop is the worst case. Thresholds must be a strict majority
    ///      (2*t > n), so 20-signer sets use t=11 (t=3 would be rejected as
    ///      sub-majority); the disjoint-loop gas is independent of the threshold.
    function test_perSourceChain_gas_updateSignersAtMaxChainsAndMaxSigners() public {
        uint256 BLOCK_GAS_LIMIT = 30_000_000; // conservative; Arbitrum allows far more
        uint256 nChains = proxy.MAX_ENCLAVE_SOURCE_CHAINS(); // 32
        uint256 nSigners = proxy.MAX_SIGNERS(); // 20
        uint256 t20 = 11; // strict majority of 20

        // Rotate RGB to 20 signers, then register (nChains - 1) more 20-signer
        // chains so all 32 chains carry the maximum set.
        _govUpdateEnclave(RGB_CHAIN_ID, _encSetFor(RGB_CHAIN_ID, nSigners), t20);
        for (uint256 k = 0; k < nChains - 1; k++) {
            uint256 chainId = 5_000_000 + k;
            _govUpdateEnclave(chainId, _encSetFor(chainId, nSigners), t20);
        }
        assertEq(proxy.getEnclaveSourceChains().length, nChains, "registry filled to the cap");

        // --- enclave rotation of an existing 20-signer chain: disjoint runs
        //     over the other 31 sets (~20 * 31 * 20 comparisons) + federation.
        {
            uint256 rotChain = 5_000_000;
            address[] memory fresh = _encSetFor(9_999_999, nSigners); // disjoint namespace
            uint256 nonce = proxy.proposalNonce();
            uint256 deadline = vm.getBlockTimestamp() + TIMELOCK + 1 days;
            bytes32 digest =
                MultisigHelper.digestProposeUpdateEnclaveSigners(domainSep, rotChain, fresh, t20, nonce, deadline);
            (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
            bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
            bytes32 id = proxy.proposeUpdateEnclaveSigners(rotChain, fresh, t20, nonce, deadline, bitmap, sigs);
            vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
            uint256 g0 = gasleft();
            proxy.executeProposal(id, abi.encode(rotChain, fresh, t20));
            uint256 gEnc = g0 - gasleft();
            emit log_named_uint("gas: updateEnclaveSigners @32chains x20 (rotate)", gEnc);
            assertLt(gEnc, BLOCK_GAS_LIMIT, "enclave rotation exceeds block gas limit");
        }

        // --- federation rotations for sizes 3, 5, 10: disjoint runs over all
        //     32 enclave sets. Each rotation is signed by the current federation,
        //     so we thread the pks forward.
        (uint256[] memory origPks, uint256 origBitmap) = _fedSigSet2of3();

        (address[] memory f3, uint256[] memory p3) = _fedFromPks(0xFED30000, 3);
        uint256 g3 = _rotateFedMeasured(f3, 2, origPks, origBitmap);
        emit log_named_uint("gas: updateFederationSigners size=3 @32x20", g3);
        assertLt(g3, BLOCK_GAS_LIMIT, "fed(3) rotation exceeds block gas limit");

        (address[] memory f5, uint256[] memory p5) = _fedFromPks(0xFED50000, 5);
        uint256 g5 = _rotateFedMeasured(f5, 3, _slice(p3, 2), _bitmapFor(2)); // signed by f3 (t=2)
        emit log_named_uint("gas: updateFederationSigners size=5 @32x20", g5);
        assertLt(g5, BLOCK_GAS_LIMIT, "fed(5) rotation exceeds block gas limit");

        (address[] memory f10,) = _fedFromPks(0xFED100000, 10);
        uint256 g10 = _rotateFedMeasured(f10, 6, _slice(p5, 3), _bitmapFor(3)); // signed by f5 (t=3)
        emit log_named_uint("gas: updateFederationSigners size=10 @32x20", g10);
        assertLt(g10, BLOCK_GAS_LIMIT, "fed(10) rotation exceeds block gas limit");
    }
}
