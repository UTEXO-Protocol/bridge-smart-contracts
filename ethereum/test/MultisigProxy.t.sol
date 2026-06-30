// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from 'forge-std/Test.sol';
import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';

import { MultisigProxy }  from '../src/MultisigProxy.sol';
import { IMultisigProxy } from '../src/interfaces/IMultisigProxy.sol';
import { IBridge }        from '../src/interfaces/IBridge.sol';
import { Bridge }              from '../src/Bridge.sol';
import { BridgeBase }          from '../src/BridgeBase.sol';
import { Pausable }            from '@openzeppelin/contracts/utils/Pausable.sol';
import { CommissionManager }   from '../src/CommissionManager.sol';
import { RouteRegistry }       from '../src/RouteRegistry.sol';
import { IRouteRegistry }      from '../src/interfaces/IRouteRegistry.sol';
import { RGBVerifier }         from '../src/verifiers/RGBVerifier.sol';
import { RgbSettlementModule } from '../src/settlement/RgbSettlementModule.sol';
import { RouteConfig }         from '../src/interfaces/RouteTypes.sol';
import {
    CommissionConfig,
    CommissionSide,
    CommissionCurrency,
    ICommissionManager
} from '../src/interfaces/ICommissionManager.sol';

import { MockERC20 }       from './mocks/MockERC20.sol';
import { MockBtcRelay }    from './mocks/MockBtcRelay.sol';
import { MultisigHelper }  from './mocks/MultisigHelper.sol';

contract MockOutboundLZAdapter {
    MockERC20 public immutable token;
    address   public immutable oft;
    address   public immutable multisigProxy;
    uint256   public immutable nativeFee;
    uint256   public sendOutCalls;

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
    ) external payable {
        require(msg.sender == multisigProxy, 'only proxy');
        require(msg.value == nativeFee, 'native fee');
        require(amount != 0, 'zero amount');
        require(recipient != bytes32(0), 'zero recipient');
        require(minAmountLD <= amount, 'min too high');

        sendOutCalls++;
        token.transfer(oft, amount);
        (bool ok, ) = oft.call{ value: msg.value }('');
        require(ok, 'oft fee');
        emit SendOut(keccak256(abi.encode('mock-send-out', dstEid, recipient, amount)), dstEid, recipient, amount);
    }
}

contract MultisigProxyTest is Test {
    using MultisigHelper for bytes32;

    // ---- Re-declared events ------------------------------------------------
    event FundsOutExecuted(uint256 indexed nonce, uint256 enclaveBitmap);
    event LzFundsOutExecuted(
        uint256 indexed nonce,
        uint256 enclaveBitmap,
        uint32  dstEid,
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
    event EnclaveSignersUpdated(address[] newSigners, uint256 newThreshold);
    event FederationSignersUpdated(address[] newSigners, uint256 newThreshold);
    event BridgeAddressUpdated(address indexed oldBridge, address indexed newBridge);
    event CommissionManagerUpdated(address indexed oldCm, address indexed newCm);
    event TimelockDurationUpdated(uint256 newDuration);
    event CommissionWithdrawn(address indexed token, uint256 amount, address indexed recipient);
    event TokenCommissionWithdrawn(address indexed token, address indexed to, uint256 amount);
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event RouteRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event BatchExecuted(uint256 indexed nonce, uint256 enclaveBitmap, address[] targets, bytes4[] selectors);
    event SendOut(bytes32 indexed guid, uint32 dstEid, bytes32 recipient, uint256 amountLD);
    event BridgeFundsOut(
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  sourceAddress
    );
    event RouteSet(
        uint256 indexed sourceChainId,
        uint256 indexed destChainId,
        bool            enabled,
        address         finalityVerifier,
        address         settlementModule
    );

    MultisigProxy       proxy;
    Bridge              bridge;
    CommissionManager   cm;
    RouteRegistry       routeRegistry;
    RGBVerifier         rgbVerifier;
    RgbSettlementModule rgbModule;
    MockERC20           token;
    MockBtcRelay        btcRelay;

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

    address deployer           = makeAddr('deployer');
    address user               = makeAddr('user');
    address recipient          = makeAddr('recipient');
    address commissionReceiver = makeAddr('commissionReceiver');

    uint256 constant TIMELOCK     = 1 hours;
    uint256 constant MIN_TIMELOCK = 1 hours; // floor passed to the proxy constructor in tests

    bytes32 domainSep;

    // Chain identifiers + canonical fundsOut args
    uint256 constant SOURCE_CHAIN_ID = 31337;     // foundry block.chainid
    uint256 constant RGB_CHAIN_ID    = 1_000_001; // backend-assigned for RGB
    string  constant DST_ADDR        = 'rgb:asset/utxo1abc';
    string  constant SRC_ADDR        = 'rgb:sender/utxo1src';
    uint256 constant AMOUNT  = 100e18;
    uint256 constant TX_ID   = 42;
    uint256 constant BURN_ID = 9_001;
    uint256 constant LZ_NATIVE_FEE = 0.01 ether;
    uint32  constant DST_EID = 30110;
    bytes32 constant LZ_RECIPIENT = bytes32(uint256(uint160(0xBEEF)));

    // BtcRelay test data
    uint256 constant BLOCK_HEIGHT      = 850_000;
    bytes32 constant COMMITMENT_HASH   = keccak256('test-btc-block-commitment');
    uint256 constant BTC_CONFIRMATIONS = 6;

    function setUp() public {
        encA1 = vm.addr(encPk1);
        encA2 = vm.addr(encPk2);
        encA3 = vm.addr(encPk3);
        fedA1 = vm.addr(fedPk1);
        fedA2 = vm.addr(fedPk2);
        fedA3 = vm.addr(fedPk3);

        token    = new MockERC20('Mock USDT0', 'USDT0');
        btcRelay = new MockBtcRelay();
        btcRelay.setBlock(BLOCK_HEIGHT, COMMITMENT_HASH, BTC_CONFIRMATIONS);

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

        uint64  currentNonce    = vm.getNonce(deployer);
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 2);

        cm            = new CommissionManager(predictedBridge);
        routeRegistry = new RouteRegistry(predictedBridge, deployer);
        bridge        = new Bridge(
            address(token),
            address(routeRegistry),
            payable(address(cm)),
            address(0),
            1 // minFundsInAmount: smallest non-zero floor for tests
        );

        rgbVerifier = new RGBVerifier(address(btcRelay));
        rgbModule   = new RgbSettlementModule(address(routeRegistry));

        // Register both directions of the RGB route while deployer still owns
        // the registry. Inbound (SOURCE → RGB) never calls verify; outbound
        // (RGB → SOURCE) runs the BtcRelay check.
        routeRegistry.setRoute(
            SOURCE_CHAIN_ID, RGB_CHAIN_ID,
            true, address(rgbVerifier), address(rgbModule)
        );
        routeRegistry.setRoute(
            RGB_CHAIN_ID, SOURCE_CHAIN_ID,
            true, address(rgbVerifier), address(rgbModule)
        );

        address[] memory enc = new address[](3);
        enc[0] = encA1; enc[1] = encA2; enc[2] = encA3;
        address[] memory fed = new address[](3);
        fed[0] = fedA1; fed[1] = fedA2; fed[2] = fedA3;

        proxy = new MultisigProxy(
            address(bridge),
            address(cm),
            enc, 2,
            fed, 2,
            commissionReceiver,
            TIMELOCK,
            MIN_TIMELOCK
        );

        // Production-flow ownership transfer.
        bridge.transferOwnership(address(proxy));
        cm.transferOwnership(address(proxy));
        routeRegistry.transferOwnership(address(proxy));
        vm.stopPrank();

        domainSep = proxy.DOMAIN_SEPARATOR();

        // Fund user, lock tokens into the bridge so fundsOut has a pool.
        token.mint(user, AMOUNT * 10);
        vm.prank(user);
        token.approve(address(bridge), type(uint256).max);
        vm.prank(user);
        bridge.fundsIn(AMOUNT * 5, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
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

    function _fundsInIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = TX_ID;
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

    /// @dev Standard single-release params (recipient = `recipient`, AMOUNT, BURN_ID).
    function _fundsOutParams() internal view returns (IBridge.FundsOutParams memory) {
        return _fundsOutParams(recipient, AMOUNT, BURN_ID);
    }

    function _fundsOutParams(address payoutRecipient, uint256 amount, uint256 burnId)
        internal
        view
        returns (IBridge.FundsOutParams memory)
    {
        return IBridge.FundsOutParams({
            recipient:          payoutRecipient,
            amount:             amount,
            burnId:             burnId,
            sourceChainId:      RGB_CHAIN_ID,
            destinationChainId: SOURCE_CHAIN_ID,
            sourceAddress:      SRC_ADDR,
            proof:              abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH),
            settlementData:     abi.encode(_fundsInIds())
        });
    }

    /// @dev Flow-4 LZ release params. The Bridge recipient is forced to the
    ///      adapter on-chain, so it is not part of these params; `recipient`
    ///      here is the bytes32 destination on the far chain.
    function _lzFundsOutParams(uint256 amount, uint256 burnId, uint256[] memory ids)
        internal
        view
        returns (IMultisigProxy.LzFundsOutParams memory)
    {
        return IMultisigProxy.LzFundsOutParams({
            amount:             amount,
            burnId:             burnId,
            sourceChainId:      RGB_CHAIN_ID,
            destinationChainId: SOURCE_CHAIN_ID,
            sourceAddress:      SRC_ADDR,
            proof:              abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH),
            settlementData:     abi.encode(ids),
            dstEid:             DST_EID,
            recipient:          LZ_RECIPIENT,
            minAmountLD:        0,
            extraOptions:       hex'0003010011010000000000000000000000000000ea60'
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
        nonce = proxy.teeNonce();
        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks;
        (pks, bitmap) = _encSigSet2of3();
        sigs = MultisigHelper.signAll(vm, digest, pks);
    }

    /// @dev Set the proxy's `lzAdapter` via the timelocked governance path so the
    ///      typed `lzFundsOutCall` flow can run end-to-end.
    function _setLzAdapter(address adapter) internal {
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest   = MultisigHelper.digestProposeUpdateLZAdapter(domainSep, adapter, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposeUpdateLZAdapter(adapter, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks));
        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(adapter));
    }

    // ========================================================================
    // Constructor
    // ========================================================================

    function test_constructor_setsState() public view {
        assertEq(proxy.bridge(), address(bridge));
        assertEq(proxy.commissionManager(), address(cm));
        assertEq(proxy.enclaveThreshold(), 2);
        assertEq(proxy.federationThreshold(), 2);
        assertEq(proxy.commissionRecipient(), commissionReceiver);
        assertEq(proxy.timelockDuration(), TIMELOCK);
        assertEq(proxy.proposalNonce(), 0);
        assertEq(proxy.teeNonce(),      0);

        address[] memory enc = proxy.getEnclaveSigners();
        assertEq(enc.length, 3);
        assertEq(enc[0], encA1);

        address[] memory fed = proxy.getFederationSigners();
        assertEq(fed.length, 3);
    }

    function test_constructor_revertsOnZeroBridge() public {
        address[] memory enc = new address[](1); enc[0] = encA1;
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.ZeroBridge.selector);
        new MultisigProxy(address(0), address(cm), enc, 1, fed, 1, commissionReceiver, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_revertsOnZeroCommissionManager() public {
        address[] memory enc = new address[](1); enc[0] = encA1;
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.ZeroCommissionManager.selector);
        new MultisigProxy(address(bridge), address(0), enc, 1, fed, 1, commissionReceiver, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_revertsOnNoEnclaveSigners() public {
        address[] memory enc = new address[](0);
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.NoSigners.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 1, fed, 1, commissionReceiver, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_revertsOnBadEnclaveThreshold() public {
        address[] memory enc = new address[](2); enc[0] = encA1; enc[1] = encA2;
        address[] memory fed = new address[](1); fed[0] = fedA1;
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 3, fed, 1, commissionReceiver, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_revertsOnZeroCommission() public {
        vm.expectRevert(IMultisigProxy.ZeroCommissionRecipient.selector);
        new MultisigProxy(address(bridge), address(cm), _validEnc(), 2, _validFed(), 2, address(0), TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_revertsOnTimelockTooLong() public {
        vm.expectRevert(IMultisigProxy.TimelockTooLong.selector);
        new MultisigProxy(address(bridge), address(cm), _validEnc(), 2, _validFed(), 2, commissionReceiver, 30 days, MIN_TIMELOCK);
    }

    // ---- R-W-11: MIN_TIMELOCK floor (post-fix) ----

    /// @dev UT-FIX-13: deploying with a timelock below the requested floor reverts.
    function test_constructor_revertsOnTimelockBelowMinTimelock() public {
        // timelock (1h) is below the requested floor (2h) -> TimelockTooShort
        vm.expectRevert(IMultisigProxy.TimelockTooShort.selector);
        new MultisigProxy(address(bridge), address(cm), _validEnc(), 2, _validFed(), 2, commissionReceiver, 1 hours, 2 hours);
    }

    /// @dev A zero floor is rejected — it would defeat the purpose of the fix.
    function test_constructor_revertsOnZeroMinTimelock() public {
        vm.expectRevert(IMultisigProxy.InvalidMinTimelock.selector);
        new MultisigProxy(address(bridge), address(cm), _validEnc(), 2, _validFed(), 2, commissionReceiver, TIMELOCK, 0);
    }

    /// @dev A floor at/above the upper bound leaves no valid range — rejected.
    function test_constructor_revertsOnMinTimelockTooLong() public {
        vm.expectRevert(IMultisigProxy.InvalidMinTimelock.selector);
        new MultisigProxy(address(bridge), address(cm), _validEnc(), 2, _validFed(), 2, commissionReceiver, TIMELOCK, 30 days);
    }

    function test_minTimelock_returnsConfiguredFloor() public view {
        assertEq(proxy.MIN_TIMELOCK(), MIN_TIMELOCK);
    }

    function test_constructor_revertsOnDuplicateSigner() public {
        // Duplicate enclave signer with an otherwise-valid 2-of-2 threshold, so
        // the call clears the threshold guard and reverts in _validateSigners.
        address[] memory enc = new address[](2); enc[0] = encA1; enc[1] = encA1;
        vm.expectRevert(IMultisigProxy.DuplicateSigner.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 2, _validFed(), 2, commissionReceiver, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_revertsOnZeroAddressSigner() public {
        // Zero-address enclave signer in a 2-signer set with a valid 2-of-2
        // threshold, so the call clears the threshold guard and reverts in
        // _validateSigners.
        address[] memory enc = new address[](2); enc[0] = address(0); enc[1] = encA2;
        vm.expectRevert(IMultisigProxy.ZeroAddressSigner.selector);
        new MultisigProxy(address(bridge), address(cm), enc, 2, _validFed(), 2, commissionReceiver, TIMELOCK, MIN_TIMELOCK);
    }

    // ========================================================================
    // Strict-majority signer threshold floor (R-W-12 / UT-FIX-14)
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
        new MultisigProxy(address(bridge), address(cm), _signers(3), 1, _validFed(), 2, commissionReceiver, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_rejectsOneOfOne_enclave() public {
        // n < 2 — single-key set, rejected even though 2*1 > 1.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(address(bridge), address(cm), _signers(1), 1, _validFed(), 2, commissionReceiver, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_rejectsSubMajority_enclave() public {
        // 2-of-4: 2*2 == 4, not a strict majority.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(address(bridge), address(cm), _signers(4), 2, _validFed(), 2, commissionReceiver, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_rejectsOneOfThree_federation() public {
        // Enclave valid, federation 1-of-3 — the floor applies to both sets.
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        new MultisigProxy(address(bridge), address(cm), _validEnc(), 2, _signers(3), 1, commissionReceiver, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_acceptsTwoOfTwo() public {
        MultisigProxy p = new MultisigProxy(
            address(bridge), address(cm), _signers(2), 2, _signersB(2), 2, commissionReceiver, TIMELOCK, MIN_TIMELOCK
        );
        assertEq(p.enclaveThreshold(),    2);
        assertEq(p.federationThreshold(), 2);
    }

    function test_constructor_acceptsThreeOfFour() public {
        // Strict majority with a non-trivial set (2*3 > 4).
        MultisigProxy p = new MultisigProxy(
            address(bridge), address(cm), _signers(4), 3, _signersB(4), 3, commissionReceiver, TIMELOCK, MIN_TIMELOCK
        );
        assertEq(p.enclaveThreshold(),    3);
        assertEq(p.federationThreshold(), 3);
    }

    // ---- Signer update (validated at executeProposal) ----

    function test_proposeUpdateEnclaveSigners_rejectsOneOfNAtExecute() public {
        address[] memory newSigners = _signers(3);
        uint256 badThreshold = 1; // 1-of-3
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, newSigners, badThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        // Propose succeeds — threshold validity is enforced on execution.
        bytes32 id = proxy.proposeUpdateEnclaveSigners(newSigners, badThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        proxy.executeProposal(id, abi.encode(newSigners, badThreshold));
    }

    function test_proposeUpdateFederationSigners_rejectsSubMajorityAtExecute() public {
        address[] memory newSigners = _signers(4);
        uint256 badThreshold = 2; // 2-of-4, sub-majority
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateFederationSigners(
            domainSep, newSigners, badThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateFederationSigners(newSigners, badThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.InvalidThreshold.selector);
        proxy.executeProposal(id, abi.encode(newSigners, badThreshold));
    }

    function test_proposeUpdateFederationSigners_acceptsStrictMajority() public {
        address[] memory newSigners = _signers(3);
        uint256 newThreshold = 2; // 2-of-3
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateFederationSigners(
            domainSep, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateFederationSigners(newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(newSigners, newThreshold));
        assertEq(proxy.federationThreshold(), 2);
        assertEq(proxy.getFederationSigners().length, 3);
    }

    // ========================================================================
    // Disjoint signer sets (R-W-14 / UT-FIX-16)
    //
    // The enclave and federation sets must not share an address, at construction
    // and on signer-update (validated at executeProposal). The setUp sets are
    // already disjoint (encA* vs fedA*).
    // ========================================================================

    function test_constructor_rejectsOverlappingSignerSets() public {
        // encA1 is present in both the enclave and the federation set.
        address[] memory enc = new address[](2); enc[0] = encA1; enc[1] = encA2;
        address[] memory fed = new address[](2); fed[0] = encA1; fed[1] = fedA2;
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.SignerSetsOverlap.selector, encA1));
        new MultisigProxy(address(bridge), address(cm), enc, 2, fed, 2, commissionReceiver, TIMELOCK, MIN_TIMELOCK);
    }

    function test_constructor_acceptsDisjointSignerSets() public {
        MultisigProxy p = new MultisigProxy(
            address(bridge), address(cm), _signers(2), 2, _signersB(2), 2, commissionReceiver, TIMELOCK, MIN_TIMELOCK
        );
        assertEq(p.getEnclaveSigners().length,    2);
        assertEq(p.getFederationSigners().length, 2);
    }

    function test_proposeUpdateEnclaveSigners_rejectsOverlapWithFederationAtExecute() public {
        // New enclave set includes fedA1, a current federation signer.
        address[] memory newSigners = new address[](2); newSigners[0] = fedA1; newSigners[1] = encA2;
        uint256 newThreshold = 2;
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateEnclaveSigners(newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.SignerSetsOverlap.selector, fedA1));
        proxy.executeProposal(id, abi.encode(newSigners, newThreshold));
    }

    function test_proposeUpdateFederationSigners_rejectsOverlapWithEnclaveAtExecute() public {
        // New federation set includes encA1, a current enclave signer.
        address[] memory newSigners = new address[](2); newSigners[0] = encA1; newSigners[1] = fedA2;
        uint256 newThreshold = 2;
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateFederationSigners(
            domainSep, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateFederationSigners(newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.SignerSetsOverlap.selector, encA1));
        proxy.executeProposal(id, abi.encode(newSigners, newThreshold));
    }

    // ========================================================================
    // Signer-set size cap (R-I-06 / UT-FIX-27)
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
            address(bridge), address(cm), enc, encThreshold, _validFed(), 2, commissionReceiver, TIMELOCK, MIN_TIMELOCK
        );
    }

    function test_constructor_acceptsSignersAtMax() public {
        uint256 max = proxy.MAX_SIGNERS();
        uint256 threshold = max / 2 + 1; // 11-of-20 strict majority

        MultisigProxy p = new MultisigProxy(
            address(bridge), address(cm), _signers(max), threshold, _signersB(max), threshold, commissionReceiver, TIMELOCK, MIN_TIMELOCK
        );
        assertEq(p.getEnclaveSigners().length,    max);
        assertEq(p.getFederationSigners().length, max);
    }

    function test_proposeUpdateEnclaveSigners_rejectsTooManySignersAtExecute() public {
        uint256 max = proxy.MAX_SIGNERS();
        address[] memory newSigners = _signers(max + 1);
        uint256 newThreshold = (max + 1) / 2 + 1; // valid strict majority
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateEnclaveSigners(newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(abi.encodeWithSelector(IMultisigProxy.TooManySigners.selector, max + 1, max));
        proxy.executeProposal(id, abi.encode(newSigners, newThreshold));
    }

    // ========================================================================
    // TEE fundsOutCall — happy path
    // ========================================================================

    function test_fundsOutCall_releasesViaBridge() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(true, false, false, true);
        emit FundsOutExecuted(nonce, bitmap);

        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);

        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(proxy.teeNonce(), nonce + 1);
    }

    function test_fundsOutCall_revertsOnExpired() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce();
        uint256 deadline = block.timestamp - 1;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    // ========================================================================
    // TEE deadline upper bound (R-I-01 / UT-FIX-23)
    //
    // fundsOutCall / lzFundsOutCall reject a signed deadline further than
    // MAX_TEE_DEADLINE into the future, so a leaked or pre-signed payload cannot
    // stay executable indefinitely. The boundary (exactly now + MAX_TEE_DEADLINE)
    // is still accepted — the guard is a strict `>`.
    // ========================================================================

    function test_fundsOutCall_revertsOnDeadlineTooFar() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce();
        uint256 deadline = block.timestamp + proxy.MAX_TEE_DEADLINE() + 1;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
    }

    function test_fundsOutCall_acceptsDeadlineAtMaxBoundary() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce();
        uint256 deadline = block.timestamp + proxy.MAX_TEE_DEADLINE(); // exact boundary, strict `>` lets it through

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);
        assertEq(token.balanceOf(recipient), AMOUNT, 'executes at the exact deadline ceiling');
    }

    function test_lzFundsOutCall_revertsOnDeadlineTooFar() public {
        address mockOft = makeAddr('mockOft');
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        uint256 nonce    = proxy.teeNonce();
        uint256 deadline = block.timestamp + proxy.MAX_TEE_DEADLINE() + 1;

        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.deal(address(this), LZ_NATIVE_FEE);
        vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
        proxy.lzFundsOutCall{ value: LZ_NATIVE_FEE }(params, nonce, deadline, bitmap, sigs);
    }

    function test_lzFundsOutCall_acceptsDeadlineAtMaxBoundary() public {
        address mockOft = makeAddr('mockOft');
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        uint256 nonce    = proxy.teeNonce();
        uint256 deadline = block.timestamp + proxy.MAX_TEE_DEADLINE(); // exact boundary

        bytes32 digest = MultisigHelper.digestTeeLzFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{ value: LZ_NATIVE_FEE }(params, nonce, deadline, bitmap, sigs);
        assertEq(token.balanceOf(mockOft), AMOUNT, 'lz release executes at the exact deadline ceiling');
        assertEq(proxy.teeNonce(),         nonce + 1, 'teeNonce incremented');
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
    // TEE fundsOutCall — signature / bitmap reverts
    // ========================================================================

    function test_fundsOutCall_revertsOnBelowThreshold() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks = new uint256[](1); pks[0] = encPk1;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.BelowThreshold.selector);
        proxy.fundsOutCall(params, nonce, deadline, 0x1, sigs);
    }

    function test_fundsOutCall_revertsOnBadSignature() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce();
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
        uint256 nonce = proxy.teeNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        uint256[] memory pks = new uint256[](3);
        pks[0] = encPk1; pks[1] = encPk2; pks[2] = encPk3;
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.SigCountMismatch.selector);
        proxy.fundsOutCall(params, nonce, deadline, 0x3, sigs);
    }

    function test_fundsOutCall_revertsOnBitmapOutOfRange() public {
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks,) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.BitmapOutOfRange.selector);
        proxy.fundsOutCall(params, nonce, deadline, 0x100, sigs);
    }

    function test_lzFundsOutCall_revertsIfAdapterUnset() public {
        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        uint256 nonce    = proxy.teeNonce();
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
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(false, false, false, true);
        emit EmergencyPaused(nonce, bitmap);

        proxy.emergencyPause(nonce, deadline, bitmap, sigs);

        assertTrue(bridge.paused());
        assertEq(proxy.proposalNonce(), nonce + 1);
    }

    function test_emergencyPause_revertsOnExpired() public {
        uint256 nonce = proxy.proposalNonce();
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

        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = MultisigHelper.digestEmergencyUnpause(domainSep, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(false, false, false, true);
        emit EmergencyUnpaused(nonce, bitmap);

        proxy.emergencyUnpause(nonce, deadline, bitmap, sigs);
        assertFalse(bridge.paused());
    }

    // ========================================================================
    // R-W-05 — two-tier pause (integration via MultisigProxy)
    // ========================================================================

    /// @dev After R-W-05, the no-timelock emergency pause freezes the OUTFLOW
    ///      path too — including the enclave/TEE release, which routes through
    ///      Bridge.fundsOut. A signed fundsOut executed straight after
    ///      emergencyPause must revert OutflowEnforcedPause, and inbound deposits
    ///      must be frozen as well.
    function test_emergencyPause_freezesEnclaveFundsOut() public {
        // Federation triggers the emergency freeze (both paths).
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest   = MultisigHelper.digestEmergencyPause(domainSep, nonce, deadline);
        (uint256[] memory fpks, uint256 fbitmap) = _fedSigSet2of3();
        proxy.emergencyPause(nonce, deadline, fbitmap, MultisigHelper.signAll(vm, digest, fpks));

        assertTrue(bridge.paused(),        'inflow frozen');
        assertTrue(bridge.outflowPaused(), 'outflow frozen');

        // Inbound deposits are frozen.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID + 1, '');

        // Enclave-signed release is frozen too — the revert propagates from
        // Bridge.fundsOut through proxy.fundsOutCall.
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 encNonce      = proxy.teeNonce();
        bytes32 encDigest     = MultisigHelper.digestTeeFundsOut(domainSep, params, encNonce, deadline);
        (uint256[] memory epks, uint256 ebitmap) = _encSigSet2of3();
        bytes[] memory esigs   = MultisigHelper.signAll(vm, encDigest, epks);

        vm.expectRevert(BridgeBase.OutflowEnforcedPause.selector);
        proxy.fundsOutCall(params, encNonce, deadline, ebitmap, esigs);
    }

    /// @dev The planned inflow-only pause runs through the timelocked
    ///      propose -> execute path and blocks deposits while leaving the
    ///      enclave release path open (liquidity migration scenario).
    function test_proposePauseInflow_blocksFundsInButAllowsFundsOut() public {
        uint256 t = block.timestamp; // read once; derive all timing from it (via_ir-safe)

        // Propose the inflow-only pause (federation signed).
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = t + 1 days;
        bytes32 digest   = MultisigHelper.digestProposePauseInflow(domainSep, nonce, deadline);
        (uint256[] memory fpks, uint256 fbitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposePauseInflow(nonce, deadline, fbitmap, MultisigHelper.signAll(vm, digest, fpks));

        // Execute it after the timelock (no payload).
        vm.warp(t + TIMELOCK + 1);
        proxy.executeProposal(id, '');

        assertTrue(bridge.paused(),         'inflow frozen');
        assertFalse(bridge.outflowPaused(), 'outflow stays open');

        // Deposits are frozen...
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID + 1, '');

        // ...but the enclave release still executes.
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 encNonce      = proxy.teeNonce();
        bytes32 encDigest     = MultisigHelper.digestTeeFundsOut(domainSep, params, encNonce, t + 1 days);
        (uint256[] memory epks, uint256 ebitmap) = _encSigSet2of3();
        bytes[] memory esigs   = MultisigHelper.signAll(vm, encDigest, epks);

        proxy.fundsOutCall(params, encNonce, t + 1 days, ebitmap, esigs);
        assertEq(token.balanceOf(recipient), AMOUNT, 'withdrawal succeeded while inflow paused');
    }

    // ========================================================================
    // Propose + Execute — UpdateBridge
    // ========================================================================

    function test_proposeUpdateBridge_andExecuteAfterTimelock() public {
        address newBridge = makeAddr('newBridge');
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

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr('nb'), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.Expired.selector);
        proxy.proposeUpdateBridge(makeAddr('nb'), nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateBridge_revertsOnDeadlineTooFar() public {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 31 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr('nb'), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DeadlineTooFar.selector);
        proxy.proposeUpdateBridge(makeAddr('nb'), nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateBridge_revertsOnDeadlineBeforeTimelock() public {
        uint256 nonce    = proxy.proposalNonce();
        // One second short of the timelock window → dead on arrival.
        uint256 deadline = block.timestamp + proxy.timelockDuration() - 1;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr('nb'), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.DeadlineBeforeTimelock.selector);
        proxy.proposeUpdateBridge(makeAddr('nb'), nonce, deadline, bitmap, sigs);
    }

    function test_proposeUpdateBridge_acceptsDeadlineAtTimelockBoundary() public {
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + proxy.timelockDuration(); // exact boundary, `==` allowed

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, makeAddr('nb'), nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 proposalId = proxy.proposeUpdateBridge(makeAddr('nb'), nonce, deadline, bitmap, sigs);
        assertEq(
            uint8(proxy.getProposal(proposalId).status),
            uint8(IMultisigProxy.ProposalStatus.Pending),
            'proposal at the exact boundary is created'
        );
    }

    function test_proposeUpdateBridge_executableAtTimelockBoundary() public {
        address newBridge = makeAddr('boundaryBridge');
        uint256 nonce     = proxy.proposalNonce();
        uint256 timelock  = proxy.timelockDuration();
        uint256 deadline  = block.timestamp + timelock; // deadline == proposedAt + timelock

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 proposalId = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        // Execute at the single instant where block.timestamp == proposedAt +
        // timelock == deadline: timelock has just elapsed and the deadline has
        // not yet passed (both checks use strict comparisons).
        vm.warp(block.timestamp + timelock);
        proxy.executeProposal(proposalId, abi.encode(newBridge));
        assertEq(proxy.bridge(), newBridge, 'boundary proposal executes at the exact instant');
    }

    // ========================================================================
    // Propose + Execute — UpdateEnclaveSigners
    // ========================================================================

    function test_proposeUpdateEnclaveSigners_execute() public {
        address newSigner = makeAddr('newEncSigner');
        address[] memory newSigners = new address[](2);
        newSigners[0] = encA1; newSigners[1] = newSigner;
        uint256 newThreshold = 2;

        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateEnclaveSigners(newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(newSigners, newThreshold));

        address[] memory after_ = proxy.getEnclaveSigners();
        assertEq(after_.length, 2);
        assertEq(after_[1], newSigner);
        assertEq(proxy.enclaveThreshold(), newThreshold);
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

    /// @dev UT-FIX-13: a SetTimelockDuration proposal below the immutable
    ///      MIN_TIMELOCK floor is rejected at execution; the floor holds.
    function test_proposeSetTimelockDuration_revertsBelowMinTimelock_afterFix() public {
        uint256 t           = block.timestamp;
        uint256 newDuration = MIN_TIMELOCK - 1; // just under the floor
        uint256 nonce       = proxy.proposalNonce();
        uint256 deadline    = t + 1 days;

        bytes32 digest = MultisigHelper.digestProposeSetTimelockDuration(domainSep, newDuration, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposeSetTimelockDuration(newDuration, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks));

        vm.warp(t + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.TimelockTooShort.selector);
        proxy.executeProposal(id, abi.encode(newDuration));

        assertEq(proxy.timelockDuration(), TIMELOCK, 'timelock unchanged');
    }

    /// @dev A value exactly at MIN_TIMELOCK is still accepted (boundary).
    function test_proposeSetTimelockDuration_acceptsAtMinTimelock_afterFix() public {
        uint256 t           = block.timestamp;
        uint256 newDuration = MIN_TIMELOCK; // exactly the floor
        uint256 nonce       = proxy.proposalNonce();
        uint256 deadline    = t + 1 days;

        bytes32 digest = MultisigHelper.digestProposeSetTimelockDuration(domainSep, newDuration, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes32 id = proxy.proposeSetTimelockDuration(newDuration, nonce, deadline, bitmap, MultisigHelper.signAll(vm, digest, pks));

        vm.warp(t + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(newDuration));
        assertEq(proxy.timelockDuration(), newDuration);
    }

    // ========================================================================
    // Propose + Execute — AdminExecute
    // ========================================================================

    function test_proposeAdminExecute_canCallBridge() public {
        bytes memory callData = abi.encodeWithSignature('pauseInflow()');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecute(
            domainSep, bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecute(callData, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, callData);

        assertTrue(bridge.paused());
    }

    // ========================================================================
    // Propose + Execute — UpdateCommissionManager
    // ========================================================================

    function test_proposeUpdateCommissionManager_execute() public {
        address newCm = makeAddr('newCm');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateCommissionManager(domainSep, newCm, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateCommissionManager(newCm, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, false);
        emit CommissionManagerUpdated(address(cm), newCm);

        proxy.executeProposal(id, abi.encode(newCm));
        assertEq(proxy.commissionManager(), newCm);
    }

    // ========================================================================
    // Propose + Execute — WithdrawTokenCommissionCM
    // ========================================================================

    function test_proposeWithdrawTokenCommissionCM_execute() public {
        // Seed commission by setting a fundsIn TOKEN rule and doing a deposit.
        vm.prank(address(proxy));
        cm.setCommissionRule(
            SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(token),
            CommissionConfig({
                stablePercent: 400, // 4%
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        uint256 depositAmount = 100e18;
        vm.prank(user);
        bridge.fundsIn(depositAmount, RGB_CHAIN_ID, DST_ADDR, TX_ID + 1, '');

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

        bytes32 id = proxy.proposeWithdrawTokenCommissionCM(
            address(token), expectedCommission, nonce, deadline, bitmap, sigs
        );

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
        address newBridge = makeAddr('newBridge');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        uint256 cNonce = proxy.proposalNonce();
        uint256 cDeadline = block.timestamp + 1 hours;
        bytes32 cDigest = MultisigHelper.digestCancelProposal(domainSep, id, cNonce, cDeadline);
        bytes[] memory cSigs = MultisigHelper.signAll(vm, cDigest, pks);

        vm.expectEmit(true, false, false, false);
        emit ProposalCancelled(id);
        proxy.cancelProposal(id, cNonce, cDeadline, bitmap, cSigs);

        IMultisigProxy.Proposal memory p = proxy.getProposal(id);
        assertEq(uint8(p.status), uint8(IMultisigProxy.ProposalStatus.Cancelled));

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.executeProposal(id, abi.encode(newBridge));
    }

    function test_cancelProposal_revertsOnNotPending() public {
        bytes32 id = keccak256('ghost');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestCancelProposal(domainSep, id, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.cancelProposal(id, nonce, deadline, bitmap, sigs);
    }

    // ========================================================================
    // executeProposal reverts
    // ========================================================================

    function test_executeProposal_revertsOnDataMismatch() public {
        address newBridge = makeAddr('newBridge');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeUpdateBridge(domainSep, newBridge, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateBridge(newBridge, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        proxy.executeProposal(id, abi.encode(makeAddr('different')));
    }

    function test_executeProposal_revertsOnExpiredDeadline() public {
        address newBridge = makeAddr('newBridge');
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
        bytes32 digest = keccak256('msg');
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(encPk1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertTrue(proxy.verifyEnclaveSignature(digest, sig, 0));
        assertFalse(proxy.verifyEnclaveSignature(digest, sig, 1));
    }

    function test_verifyEnclaveSignature_revertsOutOfRange() public {
        bytes32 digest = keccak256('msg');
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(encPk1, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(IMultisigProxy.IndexOutOfRange.selector);
        proxy.verifyEnclaveSignature(digest, sig, 99);
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
        address newAdapter = makeAddr('lzAdapter');
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, false);
        emit LZAdapterUpdated(address(0), newAdapter);

        proxy.executeProposal(id, abi.encode(newAdapter));
        assertEq(proxy.lzAdapter(), newAdapter);
    }

    function test_proposeUpdateLZAdapter_canRotateToZero() public {
        address newAdapter = makeAddr('lzAdapter');
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);
        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(id, abi.encode(newAdapter));
        assertEq(proxy.lzAdapter(), newAdapter);

        bytes32 id2 = _proposeUpdateLZAdapter(address(0));
        vm.warp(block.timestamp + 2 * TIMELOCK + 2);

        proxy.executeProposal(id2, abi.encode(address(0)));
        assertEq(proxy.lzAdapter(), address(0));
    }

    function test_proposeUpdateLZAdapter_revertsOnDataMismatch() public {
        address newAdapter = makeAddr('lzAdapter');
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        proxy.executeProposal(id, abi.encode(makeAddr('different')));
    }

    function test_proposeUpdateLZAdapter_canBeCancelled() public {
        address newAdapter = makeAddr('lzAdapter');
        bytes32 id = _proposeUpdateLZAdapter(newAdapter);

        uint256 cNonce = proxy.proposalNonce();
        uint256 cDeadline = block.timestamp + 1 hours;
        bytes32 cDigest = MultisigHelper.digestCancelProposal(domainSep, id, cNonce, cDeadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory cSigs = MultisigHelper.signAll(vm, cDigest, pks);

        vm.expectEmit(true, false, false, false);
        emit ProposalCancelled(id);
        proxy.cancelProposal(id, cNonce, cDeadline, bitmap, cSigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.NotPending.selector);
        proxy.executeProposal(id, abi.encode(newAdapter));
        assertEq(proxy.lzAdapter(), address(0));
    }

    // ========================================================================
    // Propose + Execute — AdminExecuteAdapter
    // ========================================================================

    function test_proposeAdminExecuteAdapter_revertsIfAdapterUnset() public {
        bytes memory callData = abi.encodeWithSignature('mint(address,uint256)', user, 1e18);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteAdapter(
            domainSep, bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.ZeroTarget.selector);
        proxy.executeProposal(id, callData);
    }

    function test_proposeAdminExecuteAdapter_executesCallOnAdapter() public {
        MockERC20 adapter = new MockERC20('LZ Stub', 'LZS');
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

        bytes memory callData = abi.encodeWithSignature('mint(address,uint256)', recipient, 1e18);
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = firstExec + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteAdapter(
            domainSep, bytes4(callData), callData, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);

        vm.warp(firstExec + TIMELOCK + 1);
        proxy.executeProposal(id, callData);

        assertEq(adapter.balanceOf(recipient), 1e18);
    }

    function test_proposeAdminExecuteAdapter_revertsOnEmptyCallData() public {
        bytes memory callData = '';
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = new bytes[](pks.length);
        for (uint256 i = 0; i < pks.length; i++) sigs[i] = new bytes(65);

        vm.expectRevert(IMultisigProxy.CallDataTooShort.selector);
        proxy.proposeAdminExecuteAdapter(callData, nonce, deadline, bitmap, sigs);
    }

    function test_proposeAdminExecuteAdapter_propagatesAdapterRevert() public {
        MockERC20 adapter = new MockERC20('LZ Stub', 'LZS');
        bytes32 idSet = _proposeUpdateLZAdapter(address(adapter));
        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(idSet, abi.encode(address(adapter)));

        bytes memory callData = abi.encodeWithSignature('nonExistent()');
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = MultisigHelper.digestProposeAdminExecuteAdapter(
            domainSep, bytes4(callData), callData, nonce, deadline
        );
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

    function _proposeSetRoute(
        uint256 srcId,
        uint256 dstId,
        bool    enabled,
        address verifier,
        address module
    ) internal returns (bytes32 id) {
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest   = MultisigHelper.digestProposeSetRoute(
            domainSep, srcId, dstId, enabled, verifier, module, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        id = proxy.proposeSetRoute(
            srcId, dstId, enabled, verifier, module,
            nonce, deadline, bitmap, sigs
        );
    }

    function test_proposeSetRoute_addsBrandNewRoute() public {
        // Register a fresh (1234, 5678) route via governance.
        uint256 newSrc = 1234;
        uint256 newDst = 5678;
        bytes32 id = _proposeSetRoute(
            newSrc, newDst, true, address(rgbVerifier), address(rgbModule)
        );

        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, false, true, address(routeRegistry));
        emit RouteSet(newSrc, newDst, true, address(rgbVerifier), address(rgbModule));

        proxy.executeProposal(
            id,
            abi.encode(newSrc, newDst, true, address(rgbVerifier), address(rgbModule))
        );

        RouteConfig memory cfg = routeRegistry.getRoute(newSrc, newDst);
        assertTrue(cfg.enabled);
        assertEq(cfg.finalityVerifier, address(rgbVerifier));
        assertEq(cfg.settlementModule, address(rgbModule));
    }

    function test_proposeSetRoute_updatesExistingRoute() public {
        // Re-point the existing RGB→SOURCE route at a brand new module
        // (verifier stays). Validates governance can rotate plugins in place.
        RgbSettlementModule newModule = new RgbSettlementModule(address(routeRegistry));

        bytes32 id = _proposeSetRoute(
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, true,
            address(rgbVerifier), address(newModule)
        );

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(
            id,
            abi.encode(RGB_CHAIN_ID, SOURCE_CHAIN_ID, true,
                      address(rgbVerifier), address(newModule))
        );

        RouteConfig memory cfg = routeRegistry.getRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID);
        assertEq(cfg.settlementModule, address(newModule), 'module rotated');
        assertEq(cfg.finalityVerifier, address(rgbVerifier), 'verifier unchanged');
    }

    function test_proposeSetRoute_canPauseRoute() public {
        // Existing RGB→SOURCE route is enabled. Flip enabled = false in place.
        bytes32 id = _proposeSetRoute(
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, false,
            address(rgbVerifier), address(rgbModule)
        );

        vm.warp(block.timestamp + TIMELOCK + 1);
        proxy.executeProposal(
            id,
            abi.encode(RGB_CHAIN_ID, SOURCE_CHAIN_ID, false,
                      address(rgbVerifier), address(rgbModule))
        );

        RouteConfig memory cfg = routeRegistry.getRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID);
        assertFalse(cfg.enabled, 'route paused');
        assertEq(cfg.finalityVerifier, address(rgbVerifier), 'verifier kept');
        assertEq(cfg.settlementModule, address(rgbModule),   'module kept');
    }

    function test_proposeSetRoute_revertsOnZeroVerifier() public {
        bytes32 id = _proposeSetRoute(
            1234, 5678, true, address(0), address(rgbModule)
        );

        vm.warp(block.timestamp + TIMELOCK + 1);
        // Registry guard: ZeroFinalityVerifier propagates up through proxy.
        vm.expectRevert(IRouteRegistry.ZeroFinalityVerifier.selector);
        proxy.executeProposal(
            id,
            abi.encode(uint256(1234), uint256(5678), true, address(0), address(rgbModule))
        );
    }

    function test_proposeSetRoute_revertsOnDataMismatch() public {
        bytes32 id = _proposeSetRoute(
            1234, 5678, true, address(rgbVerifier), address(rgbModule)
        );

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        // Wrong destChainId in opData.
        proxy.executeProposal(
            id,
            abi.encode(uint256(1234), uint256(9999), true, address(rgbVerifier), address(rgbModule))
        );
    }

    // ========================================================================
    // Propose + Execute — UpdateRouteRegistry
    // ========================================================================

    function _proposeUpdateRouteRegistry(address newRegistry) internal returns (bytes32 id) {
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest   = MultisigHelper.digestProposeUpdateRouteRegistry(
            domainSep, newRegistry, nonce, deadline
        );
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
        address bogus = makeAddr('bogus');
        bytes32 id = _proposeUpdateRouteRegistry(bogus);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        proxy.executeProposal(id, abi.encode(makeAddr('different')));
    }

    function test_domainSeparator_matchesHelper() public view {
        assertEq(proxy.DOMAIN_SEPARATOR(), MultisigHelper.domainSeparator(address(proxy), block.chainid));
    }

    // ========================================================================
    // Domain separator rebuild on chain-id change (R-W-13 / UT-FIX-15)
    //
    // The separator is cached at deploy with the chain id. After a chain-id
    // change (e.g. a hard fork) it is rebuilt, so a signature made before the
    // fork no longer verifies on the forked chain (no cross-fork replay).
    // ========================================================================

    function test_domainSeparator_rebuiltOnChainIdChange_afterFix() public {
        uint256 originalChainId = block.chainid;
        bytes32 dsBefore = proxy.DOMAIN_SEPARATOR();
        assertEq(dsBefore, MultisigHelper.domainSeparator(address(proxy), originalChainId), 'cached on original chain');

        uint256 forkedChainId = originalChainId + 1;
        vm.chainId(forkedChainId);

        bytes32 dsAfter = proxy.DOMAIN_SEPARATOR();
        assertTrue(dsAfter != dsBefore, 'separator rebuilt after chain-id change');
        assertEq(dsAfter, MultisigHelper.domainSeparator(address(proxy), forkedChainId), 'rebuilt over new chain id');
    }

    function test_fundsOutCallSignatureNotReplayableAfterChainIdChange_afterFix() public {
        // Sign a valid TEE fundsOut on the original chain (domainSep was cached
        // at setUp for block.chainid).
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce();
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
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, 'token fee quoted');
        assertEq(nativeCommission, 0, 'native fee is zero');
        assertEq(netAmount, AMOUNT - tokenCommission, 'net recipient amount');

        // Prepare signed TEE execution and snapshot proxy + Bridge accounting.
        IBridge.FundsOutParams memory params = _fundsOutParams();
        uint256 nonce = proxy.teeNonce();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        uint256 bridgeBefore    = token.balanceOf(address(bridge));
        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 cmBefore        = token.balanceOf(address(cm));
        uint256 cmPoolBefore    = cm.tokenCommissionPool(address(token));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore    = rgbModule.fundsInRecords(TX_ID);

        assertEq(bridgeBefore,     AMOUNT * 5, 'pre bridge pool');
        assertEq(recipientBefore,  0,          'pre recipient token');
        assertEq(cmBefore,         0,          'pre cm token');
        assertEq(cmPoolBefore,     0,          'pre cm pool');
        assertEq(nativePoolBefore, 0,          'pre native pool');
        assertEq(recordBefore,     AMOUNT * 5, 'pre record');
        assertFalse(bridge.consumedBurnIds(BURN_ID), 'pre burn id');

        vm.expectEmit(true, false, false, true);
        emit BridgeFundsOut(
            recipient,
            AMOUNT,
            netAmount,
            tokenCommission,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR
        );
        vm.expectEmit(true, false, false, true);
        emit FundsOutExecuted(nonce, bitmap);

        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(), nonce + 1, 'nonce incremented');
        assertTrue(bridge.consumedBurnIds(BURN_ID), 'burn id consumed');
        assertEq(token.balanceOf(address(bridge)), bridgeBefore - AMOUNT,        'bridge gross debit');
        assertEq(token.balanceOf(recipient),       recipientBefore + netAmount, 'recipient net delta');
        assertEq(token.balanceOf(address(cm)),     cmBefore + tokenCommission,  'cm fee delta');
        assertEq(
            cm.tokenCommissionPool(address(token)),
            cmPoolBefore + tokenCommission,
            'cm pool delta'
        );
        assertEq(cm.nativeCommissionPool(),        nativePoolBefore,             'native pool unchanged');
        assertEq(rgbModule.fundsInRecords(TX_ID),  recordBefore - AMOUNT,        'record consumed');

        // The signed Bridge gross debit splits into recipient net payout and CM token commission.
        assertEq(
            (token.balanceOf(recipient) - recipientBefore) +
            (token.balanceOf(address(cm)) - cmBefore),
            AMOUNT,
            'gross fundsOut conserved'
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
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, 'token fee quoted');
        assertEq(nativeCommission, 0, 'native fee is zero');
        assertEq(netAmount, AMOUNT - tokenCommission, 'net adapter amount');

        address mockOft = makeAddr('mockOft');
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        uint256 bridgeBefore    = token.balanceOf(address(bridge));
        uint256 adapterBefore   = token.balanceOf(address(adapter));
        uint256 oftBefore       = token.balanceOf(mockOft);
        uint256 cmBefore        = token.balanceOf(address(cm));
        uint256 cmPoolBefore    = cm.tokenCommissionPool(address(token));
        uint256 recordBefore    = rgbModule.fundsInRecords(TX_ID);
        uint256 proxyEthBefore  = address(proxy).balance;
        uint256 adapterEthBefore = address(adapter).balance;
        uint256 oftEthBefore    = mockOft.balance;

        assertEq(bridgeBefore,   AMOUNT * 5, 'pre bridge pool');
        assertEq(adapterBefore,  0,          'pre adapter token');
        assertEq(oftBefore,      0,          'pre oft token');
        assertEq(cmBefore,       0,          'pre cm token');
        assertEq(cmPoolBefore,   0,          'pre cm pool');
        assertEq(recordBefore,   AMOUNT * 5, 'pre record');
        assertEq(adapterEthBefore, 0,        'pre adapter native');
        assertEq(oftEthBefore,     0,        'pre oft native');
        assertFalse(bridge.consumedBurnIds(BURN_ID), 'pre burn id');

        bytes32 sendOutGuid = keccak256(abi.encode('mock-send-out', DST_EID, LZ_RECIPIENT, netAmount));

        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeFundsOut(
            address(adapter),
            AMOUNT,
            netAmount,
            tokenCommission,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR
        );
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, netAmount);
        vm.expectEmit(true, false, false, true, address(proxy));
        emit LzFundsOutExecuted(nonce, bitmap, DST_EID, LZ_RECIPIENT, netAmount);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{ value: LZ_NATIVE_FEE }(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(), nonce + 1, 'tee nonce incremented');
        assertTrue(bridge.consumedBurnIds(BURN_ID), 'burn id consumed');
        assertEq(token.balanceOf(address(bridge)),  bridgeBefore - AMOUNT,          'bridge gross debit');
        assertEq(token.balanceOf(address(cm)),      cmBefore + tokenCommission,     'cm fee delta');
        assertEq(cm.tokenCommissionPool(address(token)), cmPoolBefore + tokenCommission, 'cm pool delta');
        assertEq(rgbModule.fundsInRecords(TX_ID),   recordBefore - AMOUNT,          'record consumed');
        assertEq(token.balanceOf(address(adapter)), adapterBefore,                  'adapter no residue');
        assertEq(token.balanceOf(mockOft),          oftBefore + netAmount,          'oft receives net');
        assertEq(address(proxy).balance,            proxyEthBefore,                 'proxy native no residue');
        assertEq(address(adapter).balance,           adapterEthBefore,               'adapter native no residue');
        assertEq(mockOft.balance,                    oftEthBefore + LZ_NATIVE_FEE,   'oft receives native fee');
        assertEq(
            (token.balanceOf(mockOft) - oftBefore) +
            (token.balanceOf(address(cm)) - cmBefore),
            AMOUNT,
            'gross batch payout conserved'
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
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission,) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, 'token fee quoted');
        assertEq(nativeCommission, 0, 'native fee is zero');

        address mockOft = makeAddr('mockOft');
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        // Snapshot all state touched by the first Bridge leg and the failed adapter leg.
        uint256 bridgeBefore     = token.balanceOf(address(bridge));
        uint256 adapterBefore    = token.balanceOf(address(adapter));
        uint256 oftBefore        = token.balanceOf(mockOft);
        uint256 cmBefore         = token.balanceOf(address(cm));
        uint256 cmPoolBefore     = cm.tokenCommissionPool(address(token));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore     = rgbModule.fundsInRecords(TX_ID);
        uint256 proxyEthBefore   = address(proxy).balance;
        uint256 adapterEthBefore = address(adapter).balance;
        uint256 oftEthBefore     = mockOft.balance;

        assertEq(bridgeBefore,     AMOUNT * 5, 'pre bridge pool');
        assertEq(adapterBefore,    0,          'pre adapter token');
        assertEq(oftBefore,        0,          'pre oft token');
        assertEq(cmBefore,         0,          'pre cm token');
        assertEq(cmPoolBefore,     0,          'pre cm pool');
        assertEq(nativePoolBefore, 0,          'pre native pool');
        assertEq(recordBefore,     AMOUNT * 5, 'pre record');
        assertFalse(bridge.consumedBurnIds(BURN_ID), 'pre burn id');

        // An underfunded native fee reverts in sendOut, after Bridge.fundsOut
        // already ran inside the same lzFundsOutCall transaction.
        vm.deal(address(this), LZ_NATIVE_FEE - 1);
        vm.expectRevert(bytes('native fee'));
        proxy.lzFundsOutCall{ value: LZ_NATIVE_FEE - 1 }(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(),                nonce,            'tee nonce unchanged');
        assertFalse(bridge.consumedBurnIds(BURN_ID),                'burn id unchanged');
        assertEq(token.balanceOf(address(bridge)), bridgeBefore,    'bridge token unchanged');
        assertEq(token.balanceOf(address(adapter)), adapterBefore,  'adapter token unchanged');
        assertEq(token.balanceOf(mockOft),          oftBefore,      'oft token unchanged');
        assertEq(token.balanceOf(address(cm)),      cmBefore,       'cm token unchanged');
        assertEq(cm.tokenCommissionPool(address(token)), cmPoolBefore, 'cm pool unchanged');
        assertEq(cm.nativeCommissionPool(),         nativePoolBefore,  'native pool unchanged');
        assertEq(rgbModule.fundsInRecords(TX_ID),   recordBefore,      'record unchanged');
        assertEq(address(proxy).balance,            proxyEthBefore,    'proxy native unchanged');
        assertEq(address(adapter).balance,          adapterEthBefore,  'adapter native unchanged');
        assertEq(mockOft.balance,                   oftEthBefore,      'oft native unchanged');
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
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, 'token fee quoted');
        assertEq(nativeCommission, 0, 'native fee is zero');

        address mockOft = makeAddr('mockOft');
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        // A proof that the verifier rejects, so Bridge.fundsOut reverts before
        // the adapter send can run.
        params.proof = abi.encode(uint256(999_999), keccak256('unknown-block'));

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        // The adapter is funded; only the Bridge verifier failure should stop dispatch.
        uint256 bridgeBefore     = token.balanceOf(address(bridge));
        uint256 adapterBefore    = token.balanceOf(address(adapter));
        uint256 oftBefore        = token.balanceOf(mockOft);
        uint256 cmBefore         = token.balanceOf(address(cm));
        uint256 cmPoolBefore     = cm.tokenCommissionPool(address(token));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore     = rgbModule.fundsInRecords(TX_ID);
        uint256 proxyEthBefore   = address(proxy).balance;
        uint256 adapterEthBefore = address(adapter).balance;
        uint256 oftEthBefore     = mockOft.balance;

        assertEq(bridgeBefore,     AMOUNT * 5, 'pre bridge pool');
        assertEq(adapterBefore,    0,          'pre adapter token');
        assertEq(oftBefore,        0,          'pre oft token');
        assertEq(cmBefore,         0,          'pre cm token');
        assertEq(cmPoolBefore,     0,          'pre cm pool');
        assertEq(nativePoolBefore, 0,          'pre native pool');
        assertEq(recordBefore,     AMOUNT * 5, 'pre record');
        assertEq(adapter.sendOutCalls(), 0,    'pre adapter calls');
        assertFalse(bridge.consumedBurnIds(BURN_ID), 'pre burn id');

        vm.deal(address(this), LZ_NATIVE_FEE);
        vm.expectRevert(bytes('verify: block commitment'));
        proxy.lzFundsOutCall{ value: LZ_NATIVE_FEE }(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(),                nonce,            'tee nonce unchanged');
        assertFalse(bridge.consumedBurnIds(BURN_ID),                'burn id unchanged');
        assertEq(adapter.sendOutCalls(),           0,               'adapter not called');
        assertEq(token.balanceOf(address(bridge)), bridgeBefore,    'bridge token unchanged');
        assertEq(token.balanceOf(address(adapter)), adapterBefore,  'adapter token unchanged');
        assertEq(token.balanceOf(mockOft),          oftBefore,      'oft token unchanged');
        assertEq(token.balanceOf(address(cm)),      cmBefore,       'cm token unchanged');
        assertEq(cm.tokenCommissionPool(address(token)), cmPoolBefore, 'cm pool unchanged');
        assertEq(cm.nativeCommissionPool(),         nativePoolBefore,  'native pool unchanged');
        assertEq(rgbModule.fundsInRecords(TX_ID),   recordBefore,      'record unchanged');
        assertEq(address(proxy).balance,            proxyEthBefore,    'proxy native unchanged');
        assertEq(address(adapter).balance,          adapterEthBefore,  'adapter native unchanged');
        assertEq(mockOft.balance,                   oftEthBefore,      'oft native unchanged');
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
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, 'token fee quoted');
        assertEq(nativeCommission, 0, 'native fee is zero');

        address mockOft = makeAddr('mockOft');
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        uint256[] memory duplicateIds = new uint256[](2);
        duplicateIds[0] = TX_ID;
        duplicateIds[1] = TX_ID;

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, duplicateIds);

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        // The duplicate id is only safe in this shape because the first entry is
        // partially consumed and the settlement loop breaks before reading it again.
        uint256 bridgeBefore     = token.balanceOf(address(bridge));
        uint256 adapterBefore    = token.balanceOf(address(adapter));
        uint256 oftBefore        = token.balanceOf(mockOft);
        uint256 cmBefore         = token.balanceOf(address(cm));
        uint256 cmPoolBefore     = cm.tokenCommissionPool(address(token));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore     = rgbModule.fundsInRecords(TX_ID);
        uint256 proxyEthBefore   = address(proxy).balance;
        uint256 adapterEthBefore = address(adapter).balance;
        uint256 oftEthBefore     = mockOft.balance;

        assertEq(bridgeBefore,     AMOUNT * 5, 'pre bridge pool');
        assertEq(adapterBefore,    0,          'pre adapter token');
        assertEq(oftBefore,        0,          'pre oft token');
        assertEq(cmBefore,         0,          'pre cm token');
        assertEq(cmPoolBefore,     0,          'pre cm pool');
        assertEq(nativePoolBefore, 0,          'pre native pool');
        assertEq(recordBefore,     AMOUNT * 5, 'pre record allows partial consume');
        assertEq(adapter.sendOutCalls(), 0,    'pre adapter calls');
        assertFalse(bridge.consumedBurnIds(BURN_ID), 'pre burn id');

        bytes32 sendOutGuid = keccak256(abi.encode('mock-send-out', DST_EID, LZ_RECIPIENT, netAmount));

        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeFundsOut(
            address(adapter),
            AMOUNT,
            netAmount,
            tokenCommission,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR
        );
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, netAmount);
        vm.expectEmit(true, false, false, true, address(proxy));
        emit LzFundsOutExecuted(nonce, bitmap, DST_EID, LZ_RECIPIENT, netAmount);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{ value: LZ_NATIVE_FEE }(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(),                nonce + 1,        'tee nonce incremented');
        assertTrue(bridge.consumedBurnIds(BURN_ID),                  'burn id consumed');
        assertEq(adapter.sendOutCalls(),           1,               'adapter called once');
        assertEq(token.balanceOf(address(bridge)), bridgeBefore - AMOUNT, 'bridge token debit');
        assertEq(token.balanceOf(address(adapter)), adapterBefore,  'adapter no residue');
        assertEq(token.balanceOf(mockOft),          oftBefore + netAmount, 'oft token delta');
        assertEq(token.balanceOf(address(cm)),      cmBefore + tokenCommission, 'cm token delta');
        assertEq(cm.tokenCommissionPool(address(token)), cmPoolBefore + tokenCommission, 'cm pool delta');
        assertEq(cm.nativeCommissionPool(),         nativePoolBefore,  'native pool unchanged');
        assertEq(rgbModule.fundsInRecords(TX_ID),   recordBefore - AMOUNT, 'record consumed once');
        assertEq(address(proxy).balance,            proxyEthBefore,  'proxy native unchanged');
        assertEq(address(adapter).balance,          adapterEthBefore, 'adapter native unchanged');
        assertEq(mockOft.balance,                   oftEthBefore + LZ_NATIVE_FEE, 'oft native fee');
    }

    // Flow-4 success coverage for duplicate RGB settlement ids when the first
    // occurrence fully satisfies the Bridge fundsOut amount.
    function test_lzFundsOutCall_duplicateSettlementIdsFullConsume_succeedsAndIgnoresDuplicate() public {
        uint256 duplicateRecordId = TX_ID + 1;
        uint256 burnId = BURN_ID + 1;

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, duplicateRecordId, '');

        uint256 percent = 500; // 5%
        vm.prank(address(proxy));
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: percent,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0, 'token fee quoted');
        assertEq(nativeCommission, 0, 'native fee is zero');

        address mockOft = makeAddr('mockOft');
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        uint256[] memory duplicateIds = new uint256[](2);
        duplicateIds[0] = duplicateRecordId;
        duplicateIds[1] = duplicateRecordId;

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, burnId, duplicateIds);

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        // Exact full consumption triggers the module's remaining == 0 break.
        // Without that break, the duplicate id would be read after delete.
        uint256 bridgeBefore     = token.balanceOf(address(bridge));
        uint256 adapterBefore    = token.balanceOf(address(adapter));
        uint256 oftBefore        = token.balanceOf(mockOft);
        uint256 cmBefore         = token.balanceOf(address(cm));
        uint256 cmPoolBefore     = cm.tokenCommissionPool(address(token));
        uint256 originalRecordBefore  = rgbModule.fundsInRecords(TX_ID);
        uint256 duplicateRecordBefore = rgbModule.fundsInRecords(duplicateRecordId);
        uint256 proxyEthBefore   = address(proxy).balance;
        uint256 adapterEthBefore = address(adapter).balance;
        uint256 oftEthBefore     = mockOft.balance;

        assertEq(bridgeBefore,            AMOUNT * 6, 'pre bridge pool');
        assertEq(adapterBefore,           0,          'pre adapter token');
        assertEq(oftBefore,               0,          'pre oft token');
        assertEq(cmBefore,                0,          'pre cm token');
        assertEq(cmPoolBefore,            0,          'pre cm pool');
        assertEq(originalRecordBefore,    AMOUNT * 5, 'pre original record');
        assertEq(duplicateRecordBefore,   AMOUNT,     'pre duplicate record');
        assertEq(adapter.sendOutCalls(),  0,          'pre adapter calls');
        assertFalse(bridge.consumedBurnIds(burnId), 'pre burn id');

        bytes32 sendOutGuid = keccak256(abi.encode('mock-send-out', DST_EID, LZ_RECIPIENT, netAmount));

        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeFundsOut(
            address(adapter),
            AMOUNT,
            netAmount,
            tokenCommission,
            burnId,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR
        );
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, netAmount);
        vm.expectEmit(true, false, false, true, address(proxy));
        emit LzFundsOutExecuted(nonce, bitmap, DST_EID, LZ_RECIPIENT, netAmount);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{ value: LZ_NATIVE_FEE }(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(),                nonce + 1,        'tee nonce incremented');
        assertTrue(bridge.consumedBurnIds(burnId),                  'burn id consumed');
        assertEq(adapter.sendOutCalls(),           1,               'adapter called once');
        assertEq(token.balanceOf(address(bridge)), bridgeBefore - AMOUNT, 'bridge token debit');
        assertEq(token.balanceOf(address(adapter)), adapterBefore,  'adapter no residue');
        assertEq(token.balanceOf(mockOft),          oftBefore + netAmount, 'oft token delta');
        assertEq(token.balanceOf(address(cm)),      cmBefore + tokenCommission, 'cm token delta');
        assertEq(cm.tokenCommissionPool(address(token)), cmPoolBefore + tokenCommission, 'cm pool delta');
        assertEq(rgbModule.fundsInRecords(TX_ID),   originalRecordBefore, 'original record untouched');
        assertEq(rgbModule.fundsInRecords(duplicateRecordId), 0,     'duplicate record consumed once');
        assertEq(address(proxy).balance,            proxyEthBefore,  'proxy native unchanged');
        assertEq(address(adapter).balance,          adapterEthBefore, 'adapter native unchanged');
        assertEq(mockOft.balance,                   oftEthBefore + LZ_NATIVE_FEE, 'oft native fee');
    }

    // ========================================================================
    // R-M-03 / UT-FIX-05 — typed enclave methods are the only TEE entry points
    //
    // The generic enclave `execute`/`executeBatch` + `teeAllowedCalls` allowlist
    // were removed. The enclave (TEE) quorum can now only trigger Bridge.fundsOut
    // via fundsOutCall/lzFundsOutCall. Privileged calldata can still be run, but
    // exclusively through the FEDERATION-gated, timelocked proposeAdminExecute
    // path. This proves a compromised enclave quorum cannot reach any privileged
    // function: enclave signatures over an admin-execute proposal are rejected.
    // ========================================================================

    function test_enclaveKeysCannotDriveAdminExecute_afterFix() public {
        // A privileged call the TEE quorum might want to smuggle through.
        bytes memory callData = abi.encodeWithSignature('pauseInflow()');
        uint256 nonce    = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;

        // Same proposal digest the federation would sign...
        bytes32 digest = MultisigHelper.digestProposeAdminExecute(
            domainSep, bytes4(callData), callData, nonce, deadline
        );
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
    // R-W-16 / UT-FIX-18 — lzFundsOutCall binds the release and send-out legs
    //
    // Flow-4 release and the cross-chain send are bound on-chain in one signed
    // operation: the Bridge recipient is forced to the adapter (no params field
    // for it), and the amount handed to adapter.sendOut is the balance the
    // adapter ACTUALLY received, measured on-chain — not params.amount. A token
    // commission makes gross != net, which is what distinguishes the bound
    // (net delivered) amount from the signed gross amount.
    // ========================================================================

    function test_lzFundsOutCall_sendsNetDeliveredNotGross_afterFix() public {
        // 5% FUNDS_OUT token commission so gross (AMOUNT) != net (delivered).
        vm.prank(address(proxy));
        cm.setCommissionRule(
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            address(token),
            CommissionConfig({
                stablePercent: 500, // 5%
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(token), AMOUNT);
        assertGt(tokenCommission, 0,                  'fee makes gross != net');
        assertEq(netAmount, AMOUNT - tokenCommission, 'net = gross - fee');

        address mockOft = makeAddr('mockOft');
        MockOutboundLZAdapter adapter =
            new MockOutboundLZAdapter(address(token), mockOft, address(proxy), LZ_NATIVE_FEE);
        _setLzAdapter(address(adapter));

        IMultisigProxy.LzFundsOutParams memory params = _lzFundsOutParams(AMOUNT, BURN_ID, _fundsInIds());
        uint256 deadline = block.timestamp + 1 hours;
        (uint256 nonce, uint256 bitmap, bytes[] memory sigs) = _signLzEnclave(params, deadline);

        // Leg 1: the Bridge recipient is forced to the adapter (not in params).
        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeFundsOut(
            address(adapter),
            AMOUNT,
            netAmount,
            tokenCommission,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR
        );
        // Leg 2: sendOut carries the NET delivered amount, not the gross AMOUNT.
        bytes32 sendOutGuid = keccak256(abi.encode('mock-send-out', DST_EID, LZ_RECIPIENT, netAmount));
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SendOut(sendOutGuid, DST_EID, LZ_RECIPIENT, netAmount);

        vm.deal(address(this), LZ_NATIVE_FEE);
        proxy.lzFundsOutCall{ value: LZ_NATIVE_FEE }(params, nonce, deadline, bitmap, sigs);

        // The send-out amount is bound to what the adapter received: it forwarded
        // exactly the net (leaving no residue) and that net differs from gross.
        assertEq(token.balanceOf(address(adapter)), 0,         'adapter forwarded everything it received');
        assertEq(token.balanceOf(mockOft),          netAmount, 'oft received exactly the net delivered');
        assertTrue(netAmount != AMOUNT,                        'bound amount is distinct from signed gross');
    }

    // ========================================================================
    // Current behavior reproduction
    // ========================================================================

    function test_enclaveSignedFundsOutCanDrainPool_currentBehavior() public {
        address drainRecipient = makeAddr('drainRecipient');

        // The TEE path checks signatures, but it does not impose an on-chain
        // amount cap on the signed Bridge fundsOut.
        uint256 bridgeBefore    = token.balanceOf(address(bridge));
        uint256 recipientBefore = token.balanceOf(drainRecipient);
        uint256 recordBefore    = rgbModule.fundsInRecords(TX_ID);

        assertEq(bridgeBefore,    AMOUNT * 5, 'pre bridge pool');
        assertEq(recipientBefore, 0,          'pre recipient token');
        assertEq(recordBefore,    bridgeBefore, 'pre record backs full pool');
        assertFalse(bridge.consumedBurnIds(BURN_ID), 'pre burn id');

        // Current behavior: if an on-chain amount cap or rate limit is added
        // later, this test should be inverted to expect a revert.
        IBridge.FundsOutParams memory params = _fundsOutParams(drainRecipient, bridgeBefore, BURN_ID);
        uint256 nonce = proxy.teeNonce();
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = MultisigHelper.digestTeeFundsOut(domainSep, params, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _encSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeFundsOut(
            drainRecipient,
            bridgeBefore,
            bridgeBefore,
            0,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR
        );
        vm.expectEmit(true, false, false, true, address(proxy));
        emit FundsOutExecuted(nonce, bitmap);

        proxy.fundsOutCall(params, nonce, deadline, bitmap, sigs);

        assertEq(proxy.teeNonce(), nonce + 1, 'nonce incremented');
        assertTrue(bridge.consumedBurnIds(BURN_ID), 'burn id consumed');
        assertEq(token.balanceOf(address(bridge)), 0, 'bridge pool drained');
        assertEq(token.balanceOf(drainRecipient), recipientBefore + bridgeBefore, 'recipient got full pool');
        assertEq(rgbModule.fundsInRecords(TX_ID), 0, 'record fully consumed');
    }

    function test_governanceCanRotateEnclaveToUnattestedEOA_currentBehavior() public {
        address[] memory newSigners = new address[](3);
        newSigners[0] = makeAddr('unattestedEnc1');
        newSigners[1] = makeAddr('unattestedEnc2');
        newSigners[2] = makeAddr('unattestedEnc3');
        uint256 newThreshold = 2;

        address[] memory before_ = proxy.getEnclaveSigners();
        assertEq(before_.length, 3, 'pre enclave count');
        assertEq(before_[0], encA1, 'pre signer 0');
        assertEq(before_[1], encA2, 'pre signer 1');
        assertEq(before_[2], encA3, 'pre signer 2');
        assertEq(proxy.enclaveThreshold(), 2, 'pre enclave threshold');

        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = MultisigHelper.digestProposeUpdateEnclaveSigners(
            domainSep, newSigners, newThreshold, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeUpdateEnclaveSigners(newSigners, newThreshold, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);

        // Current behavior: the normal rotation path is already covered above;
        // this case documents that only address shape and threshold are checked,
        // with no on-chain enclave attestation evidence. If attestation is
        // enforced later, this test should be inverted to expect a revert.
        vm.expectEmit(false, false, false, true, address(proxy));
        emit EnclaveSignersUpdated(newSigners, newThreshold);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit ProposalExecuted(id, IMultisigProxy.OperationType.UpdateEnclaveSigners);

        proxy.executeProposal(id, abi.encode(newSigners, newThreshold));

        address[] memory after_ = proxy.getEnclaveSigners();
        assertEq(after_.length, 3, 'post enclave count');
        assertEq(after_[0], newSigners[0], 'post signer 0');
        assertEq(after_[1], newSigners[1], 'post signer 1');
        assertEq(after_[2], newSigners[2], 'post signer 2');
        assertEq(proxy.enclaveThreshold(), newThreshold, 'post enclave threshold');
    }

    function test_proposalUsesSnapshottedTimelock_afterFix() public {
        uint256 proposedAt  = block.timestamp;
        address newBridge   = makeAddr('snapshotTimelockBridge');
        uint256 newDuration = 2 hours;          // raise above the 1h in force at creation
        uint256 deadline    = proposedAt + 1 days;

        assertEq(proxy.timelockDuration(), TIMELOCK, 'pre timelock');

        // Proposal A — created while timelockDuration == TIMELOCK (1h).
        uint256 bridgeNonce = proxy.proposalNonce();
        bytes32 bridgeDigest = MultisigHelper.digestProposeUpdateBridge(
            domainSep, newBridge, bridgeNonce, deadline
        );
        (uint256[] memory bridgePks, uint256 bridgeBitmap) = _fedSigSet2of3();
        bytes[] memory bridgeSigs = MultisigHelper.signAll(vm, bridgeDigest, bridgePks);
        bytes32 bridgeProposalId =
            proxy.proposeUpdateBridge(newBridge, bridgeNonce, deadline, bridgeBitmap, bridgeSigs);

        assertEq(
            proxy.getProposal(bridgeProposalId).timelockSnapshot,
            TIMELOCK,
            'timelock snapshotted at creation'
        );

        // Raise the live timelock to 2h via its own proposal.
        uint256 timelockNonce = proxy.proposalNonce();
        bytes32 timelockDigest = MultisigHelper.digestProposeSetTimelockDuration(
            domainSep, newDuration, timelockNonce, deadline
        );
        (uint256[] memory timelockPks, uint256 timelockBitmap) = _fedSigSet2of3();
        bytes[] memory timelockSigs = MultisigHelper.signAll(vm, timelockDigest, timelockPks);
        bytes32 timelockProposalId = proxy.proposeSetTimelockDuration(
            newDuration, timelockNonce, deadline, timelockBitmap, timelockSigs
        );

        // At proposedAt + 1h + 1: both proposals' creation-time snapshot (1h)
        // has elapsed. Execute the timelock raise first.
        vm.warp(proposedAt + TIMELOCK + 1);
        proxy.executeProposal(timelockProposalId, abi.encode(newDuration));
        assertEq(proxy.timelockDuration(), newDuration, 'live timelock raised to 2h');

        // Proposal A uses its 1h snapshot, so it is mature now and executes —
        // the raised live timelock (2h) does NOT re-lock it. Under the pre-fix
        // live-timelock check this would revert TimelockActive.
        proxy.executeProposal(bridgeProposalId, abi.encode(newBridge));
        assertEq(proxy.bridge(), newBridge, 'snapshotted proposal executes despite the live timelock raise');
    }

    // Current behavior: emergency actions and regular proposals share
    // proposalNonce, so an emergency pause can stale an already signed regular
    // proposal before it is submitted on-chain.
    function test_emergencyAndRegularProposalNonceCollide_currentBehavior() public {
        address newBridge = makeAddr('nonceCollisionBridge');
        uint256 regularNonce = proxy.proposalNonce();
        uint256 regularDeadline = block.timestamp + 1 days;

        bytes32 regularDigest = MultisigHelper.digestProposeUpdateBridge(
            domainSep, newBridge, regularNonce, regularDeadline
        );
        (uint256[] memory regularPks, uint256 regularBitmap) = _fedSigSet2of3();
        bytes[] memory regularSigs = MultisigHelper.signAll(vm, regularDigest, regularPks);

        uint256 emergencyDeadline = block.timestamp + 1 hours;
        bytes32 emergencyDigest = MultisigHelper.digestEmergencyPause(domainSep, regularNonce, emergencyDeadline);
        (uint256[] memory emergencyPks, uint256 emergencyBitmap) = _fedSigSet2of3();
        bytes[] memory emergencySigs = MultisigHelper.signAll(vm, emergencyDigest, emergencyPks);

        assertFalse(bridge.paused(), 'pre bridge active');
        assertEq(proxy.proposalNonce(), regularNonce, 'pre proposal nonce');
        assertEq(proxy.bridge(), address(bridge), 'pre bridge target');

        vm.expectEmit(false, false, false, true, address(proxy));
        emit EmergencyPaused(regularNonce, emergencyBitmap);

        proxy.emergencyPause(regularNonce, emergencyDeadline, emergencyBitmap, emergencySigs);

        assertTrue(bridge.paused(), 'bridge paused by emergency action');
        assertEq(proxy.proposalNonce(), regularNonce + 1, 'emergency consumed proposal nonce');

        vm.expectRevert(IMultisigProxy.InvalidNonce.selector);
        proxy.proposeUpdateBridge(newBridge, regularNonce, regularDeadline, regularBitmap, regularSigs);

        assertEq(proxy.proposalNonce(), regularNonce + 1, 'stale proposal leaves nonce unchanged');
        assertEq(proxy.bridge(), address(bridge), 'stale proposal leaves bridge unchanged');
    }

    // Current behavior: generic Bridge admin execution can call standard
    // Ownable transferOwnership directly. A wrong nonzero owner leaves the
    // proxy unable to execute future Bridge owner-only operations.
    function test_singleStepOwnershipTransferCanOrphanGovernance_currentBehavior() public {
        address wrongOwner = makeAddr('wrongBridgeOwner');
        uint256 startTime = block.timestamp;

        bytes memory transferCallData = abi.encodeWithSignature('transferOwnership(address)', wrongOwner);
        uint256 transferNonce = proxy.proposalNonce();
        uint256 transferDeadline = startTime + 1 days;
        bytes32 transferDigest = MultisigHelper.digestProposeAdminExecute(
            domainSep,
            bytes4(transferCallData),
            transferCallData,
            transferNonce,
            transferDeadline
        );
        (uint256[] memory transferPks, uint256 transferBitmap) = _fedSigSet2of3();
        bytes[] memory transferSigs = MultisigHelper.signAll(vm, transferDigest, transferPks);

        address routeRegistryBefore = bridge.routeRegistry();

        assertEq(bridge.owner(), address(proxy), 'pre bridge owner');
        assertFalse(bridge.paused(), 'pre bridge active');
        assertEq(routeRegistryBefore, address(routeRegistry), 'pre route registry');

        bytes32 transferProposalId =
            proxy.proposeAdminExecute(transferCallData, transferNonce, transferDeadline, transferBitmap, transferSigs);

        uint256 transferReadyAt = startTime + TIMELOCK + 1;
        vm.warp(transferReadyAt);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit OwnershipTransferred(address(proxy), wrongOwner);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit ProposalExecuted(transferProposalId, IMultisigProxy.OperationType.AdminExecute);

        proxy.executeProposal(transferProposalId, transferCallData);

        assertEq(bridge.owner(), wrongOwner, 'bridge owner moved away from proxy');

        address replacementRegistry = makeAddr('replacementRouteRegistry');
        bytes memory registryCallData = abi.encodeWithSignature('setRouteRegistry(address)', replacementRegistry);
        uint256 registryNonce = proxy.proposalNonce();
        uint256 registryDeadline = transferReadyAt + 1 days;
        bytes32 registryDigest = MultisigHelper.digestProposeAdminExecute(
            domainSep,
            bytes4(registryCallData),
            registryCallData,
            registryNonce,
            registryDeadline
        );
        (uint256[] memory registryPks, uint256 registryBitmap) = _fedSigSet2of3();
        bytes[] memory registrySigs = MultisigHelper.signAll(vm, registryDigest, registryPks);

        bytes32 registryProposalId =
            proxy.proposeAdminExecute(registryCallData, registryNonce, registryDeadline, registryBitmap, registrySigs);

        vm.warp(transferReadyAt + TIMELOCK + 1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(proxy)));
        proxy.executeProposal(registryProposalId, registryCallData);

        assertEq(bridge.owner(), wrongOwner, 'wrong owner remains');
        assertEq(bridge.routeRegistry(), routeRegistryBefore, 'proxy cannot update bridge config');
    }

    // The typed commission-withdraw path pins the recipient to
    // commissionRecipient, while generic CM admin execution forwards arbitrary
    // calldata and lets the encoded withdrawal recipient win.
    function test_adminExecuteCommissionManagerBypassesRecipientPin_currentBehavior() public {
        address arbitraryRecipient = makeAddr('arbitraryCommissionRecipient');

        vm.prank(address(proxy));
        cm.setCommissionRule(
            SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(token),
            CommissionConfig({
                stablePercent: 400, // 4%
                multiplier: 100,
                side: CommissionSide.FUNDS_IN,
                currency: CommissionCurrency.TOKEN,
                isSet: true
            })
        );

        uint256 depositAmount = 100e18;
        vm.prank(user);
        bridge.fundsIn(depositAmount, RGB_CHAIN_ID, DST_ADDR, TX_ID + 777, '');

        uint256 expectedCommission = (depositAmount * 400) / 100 / 100;
        uint256 poolBefore = cm.tokenCommissionPool(address(token));
        uint256 pinnedRecipientBefore = token.balanceOf(commissionReceiver);
        uint256 arbitraryRecipientBefore = token.balanceOf(arbitraryRecipient);

        assertEq(poolBefore, expectedCommission, 'pre cm pool');
        assertEq(pinnedRecipientBefore, 0, 'pre pinned recipient');
        assertEq(arbitraryRecipientBefore, 0, 'pre arbitrary recipient');

        bytes memory callData = abi.encodeWithSignature(
            'withdrawTokenCommission(address,address,uint256)',
            address(token),
            arbitraryRecipient,
            expectedCommission
        );
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = MultisigHelper.digestProposeAdminExecuteCM(
            domainSep,
            bytes4(callData),
            callData,
            nonce,
            deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);

        bytes32 id = proxy.proposeAdminExecuteCommissionManager(callData, nonce, deadline, bitmap, sigs);

        vm.warp(block.timestamp + TIMELOCK + 1);

        // Current behavior: generic CM admin execution emits only the
        // CommissionManager withdrawal event and sends funds to the calldata
        // recipient, not to the proxy's pinned commissionRecipient.
        vm.expectEmit(true, true, false, true, address(cm));
        emit TokenCommissionWithdrawn(address(token), arbitraryRecipient, expectedCommission);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit ProposalExecuted(id, IMultisigProxy.OperationType.AdminExecuteCommissionManager);

        proxy.executeProposal(id, callData);

        assertEq(cm.tokenCommissionPool(address(token)), 0, 'cm pool drained');
        assertEq(token.balanceOf(commissionReceiver), pinnedRecipientBefore, 'pinned recipient unchanged');
        assertEq(
            token.balanceOf(arbitraryRecipient),
            arbitraryRecipientBefore + expectedCommission,
            'arbitrary recipient credited'
        );
    }
}
