// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Test } from 'forge-std/Test.sol';

import { Bridge }              from '../src/Bridge.sol';
import { IBridge }             from '../src/interfaces/IBridge.sol';
import { BridgeBase }          from '../src/BridgeBase.sol';
import { CommissionManager }   from '../src/CommissionManager.sol';
import { RouteRegistry }       from '../src/RouteRegistry.sol';
import { RGBVerifier }         from '../src/verifiers/RGBVerifier.sol';
import { RgbSettlementModule } from '../src/settlement/RgbSettlementModule.sol';
import {
    CommissionConfig,
    CommissionSide,
    CommissionCurrency,
    ICommissionManager
} from '../src/interfaces/ICommissionManager.sol';

import { MockERC20 }        from './mocks/MockERC20.sol';
import { MockBtcRelay }     from './mocks/MockBtcRelay.sol';
import { MockAggregatorV3 } from './mocks/MockAggregatorV3.sol';

import { Ownable }   from '@openzeppelin/contracts/access/Ownable.sol';
import { Pausable }  from '@openzeppelin/contracts/utils/Pausable.sol';

contract BridgeTest is Test {
    // Events re-declared locally for vm.expectEmit
    event FundsIn(address indexed sender, uint256 operationId, uint256 amount);
    event BridgeFundsIn(
        address indexed sender,
        uint256 operationId,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 nativeCommission,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  destinationAddress
    );
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
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event RouteRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event MinFundsInAmountUpdated(uint256 oldMinimum, uint256 newMinimum);

    Bridge              bridge;
    MockERC20           usdt0;
    MockBtcRelay        btcRelay;
    CommissionManager   cm;
    RouteRegistry       routeRegistry;
    RGBVerifier         rgbVerifier;
    RgbSettlementModule rgbModule;
    MockAggregatorV3    ethUsdFeed;

    address deployer  = makeAddr('deployer');
    address user      = makeAddr('user');
    address recipient = makeAddr('recipient');
    address multisig  = makeAddr('multisig');

    uint256 constant SOURCE_CHAIN_ID = 31337;     // foundry block.chainid
    uint256 constant RGB_CHAIN_ID    = 1_000_001; // backend-assigned for RGB
    string  constant DST_ADDR        = 'rgb:asset1qp0y3mq6h5k8d9f2e4j7n6c3w/utxo1abc123';
    string  constant SRC_ADDR        = 'rgb:sender/utxo1src';
    uint256 constant AMOUNT          = 100e18;
    uint256 constant TX_ID           = 42;
    uint256 constant BURN_ID         = 9_001;

    // BtcRelay test data
    uint256 constant BLOCK_HEIGHT     = 850_000;
    bytes32 constant COMMITMENT_HASH  = keccak256('test-btc-block-commitment');
    uint256 constant CONFIRMATIONS    = 6;

    function setUp() public {
        usdt0    = new MockERC20('Mock USDT0', 'USDT0');
        btcRelay = new MockBtcRelay();
        btcRelay.setBlock(BLOCK_HEIGHT, COMMITMENT_HASH, CONFIRMATIONS);

        // DeployAll-style deploy with predicted Bridge address:
        //   nonce n      → CommissionManager (uses predicted Bridge)
        //   nonce n+1    → RouteRegistry     (uses predicted Bridge,
        //                                     deployer = owner)
        //   nonce n+2    → Bridge            (uses RouteRegistry, CM)
        //   nonce n+3    → RGBVerifier
        //   nonce n+4    → RgbSettlementModule
        // Routes are then registered by deployer before ownership transfer.
        vm.startPrank(deployer);
        uint64  currentNonce    = vm.getNonce(deployer);
        address predictedBridge = vm.computeCreateAddress(deployer, currentNonce + 2);

        cm            = new CommissionManager(predictedBridge);
        routeRegistry = new RouteRegistry(predictedBridge, deployer);
        bridge        = new Bridge(
            address(usdt0),
            address(routeRegistry),
            payable(address(cm)),
            address(0),
            1 // minFundsInAmount: smallest non-zero floor; cases that need a higher floor deploy their own Bridge
        );

        rgbVerifier = new RGBVerifier(address(btcRelay));
        rgbModule   = new RgbSettlementModule(address(routeRegistry));

        // Both directions of the RGB route share the same verifier + module.
        routeRegistry.setRoute(
            SOURCE_CHAIN_ID, RGB_CHAIN_ID,
            true, address(rgbVerifier), address(rgbModule)
        );
        routeRegistry.setRoute(
            RGB_CHAIN_ID, SOURCE_CHAIN_ID,
            true, address(rgbVerifier), address(rgbModule)
        );

        // Wire a Chainlink ETH/USD feed ($2000 / ETH, 8 decimals, fresh) so
        // the NATIVE commission path quotes a positive value.
        ethUsdFeed = new MockAggregatorV3(8, 2_000e8, block.timestamp);
        cm.setEthUsdFeed(address(ethUsdFeed), 1 hours);

        // Production-flow ownership transfer of Bridge → multisig. CM and
        // RouteRegistry stay owned by deployer for this suite so individual
        // tests can configure commission rules and routes inline. The
        // governance-driven paths live in MultisigProxy.t.sol / Integration.t.sol.
        bridge.transferOwnership(multisig);
        vm.stopPrank();

        // fund user and approve bridge
        usdt0.mint(user, AMOUNT * 10);
        vm.prank(user);
        usdt0.approve(address(bridge), type(uint256).max);
    }

    // ========================================================================
    // helpers
    // ========================================================================

    function _singleFundsInId() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = TX_ID;
    }

    function _proof() internal pure returns (bytes memory) {
        return abi.encode(BLOCK_HEIGHT, COMMITMENT_HASH);
    }

    function _settlement(uint256[] memory ids) internal pure returns (bytes memory) {
        return abi.encode(ids);
    }

    function _setFundsInTokenRule(uint256 percent) internal {
        vm.prank(deployer);
        cm.setCommissionRule(
            SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0),
            CommissionConfig({
                stablePercent: percent,
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
            SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0),
            CommissionConfig({
                stablePercent: percent,
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
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(usdt0),
            CommissionConfig({
                stablePercent: percent,
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
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(usdt0),
            CommissionConfig({
                stablePercent: percent,
                multiplier: 100,
                side: CommissionSide.FUNDS_OUT,
                currency: CommissionCurrency.NATIVE,
                isSet: true
            })
        );
    }

    // ========================================================================
    // Constructor
    // ========================================================================

    function test_constructor_setsTokenOwnerAndRouteRegistry() public view {
        assertEq(bridge.TOKEN(),                       address(usdt0));
        assertEq(bridge.owner(),                       multisig);
        assertEq(bridge.routeRegistry(),               address(routeRegistry));
        assertEq(address(bridge.commissionManager()),  address(cm));
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(BridgeBase.InvalidTokenAddress.selector);
        new Bridge(address(0), address(routeRegistry), payable(address(cm)), address(0), 1);
    }

    function test_constructor_revertsOnZeroRouteRegistry() public {
        vm.expectRevert(IBridge.InvalidRouteRegistryAddress.selector);
        new Bridge(address(usdt0), address(0), payable(address(cm)), address(0), 1);
    }

    function test_constructor_revertsOnZeroCommissionManager() public {
        vm.expectRevert(IBridge.InvalidCommissionManagerAddress.selector);
        new Bridge(address(usdt0), address(routeRegistry), payable(address(0)), address(0), 1);
    }

    function test_constructor_storesInitialLZAdapter() public {
        address initialAdapter = makeAddr('initial-adapter');
        vm.prank(deployer);
        Bridge b = new Bridge(
            address(usdt0), address(routeRegistry), payable(address(cm)), initialAdapter, 1
        );
        assertEq(b.lzAdapter(), initialAdapter, 'lzAdapter set in constructor');
    }

    // ========================================================================
    // setLZAdapter
    // ========================================================================

    function test_setLZAdapter_ownerCanSetAndUnset() public {
        address adapter = makeAddr('adapter');

        vm.expectEmit(true, true, false, true, address(bridge));
        emit LZAdapterUpdated(address(0), adapter);

        vm.prank(multisig);
        bridge.setLZAdapter(adapter);
        assertEq(bridge.lzAdapter(), adapter, 'set');

        vm.expectEmit(true, true, false, true, address(bridge));
        emit LZAdapterUpdated(adapter, address(0));

        vm.prank(multisig);
        bridge.setLZAdapter(address(0));
        assertEq(bridge.lzAdapter(), address(0), 'unset');
    }

    function test_setLZAdapter_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setLZAdapter(makeAddr('adapter'));
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
        bridge.setRouteRegistry(makeAddr('newReg'));
    }

    // ========================================================================
    // Minimum fundsIn amount + zero-amount guards
    //
    // `minFundsInAmount` is a non-zero floor enforced on the inbound path: it
    // rejects zero-amount deposits (R-I-07) and dust whose commission would
    // round to zero (R-I-08). `fundsOut` is an authorized release and only
    // rejects amount == 0. The harness deploys with the smallest floor (1), so
    // tests that need a higher floor raise it via `setMinFundsInAmount`.
    // ========================================================================

    function test_constructor_storesMinFundsInAmount() public {
        vm.prank(deployer);
        Bridge b = new Bridge(
            address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 1234
        );
        assertEq(b.minFundsInAmount(), 1234, 'minFundsInAmount stored from constructor');
    }

    function test_constructor_revertsOnZeroMinFundsInAmount() public {
        vm.expectRevert(IBridge.InvalidMinFundsInAmount.selector);
        new Bridge(address(usdt0), address(routeRegistry), payable(address(cm)), address(0), 0);
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

    // --- R-I-07: zero amount ---

    function test_fundsIn_revertsOnZeroAmount() public {
        // Floor is 1 (setUp), so a zero deposit is below the minimum.
        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(0), uint256(1)));
        vm.prank(user);
        bridge.fundsIn(0, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
    }

    function test_fundsOut_revertsOnZeroAmount() public {
        // fundsOut has no minimum — only the zero-amount no-op guard, which
        // fires before the burn-id and balance checks.
        vm.expectRevert(IBridge.ZeroAmount.selector);
        vm.prank(multisig);
        bridge.fundsOut(
            recipient, 0, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );
    }

    // --- R-I-08: dust / below-minimum on the inbound path ---

    function test_fundsIn_revertsBelowMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(999), uint256(1000)));
        vm.prank(user);
        bridge.fundsIn(999, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
    }

    function test_fundsIn_acceptsExactlyAtMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.prank(user);
        bridge.fundsIn(1000, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
        assertEq(rgbModule.fundsInRecords(TX_ID), 1000, 'deposit at the floor is accepted');
    }

    function test_fundsIn_acceptsAboveMinimum() public {
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        vm.prank(user);
        bridge.fundsIn(1001, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
        assertEq(rgbModule.fundsInRecords(TX_ID), 1001, 'deposit above the floor is accepted');
    }

    function test_fundsIn_dustThatRoundsCommissionToZeroIsRejected() public {
        // 4% token commission. Below 25 units the fee floors to zero
        // (24 * 400 / 100 / 100 == 0) — the exact dust case R-I-08 describes.
        // A floor of 25 keeps such dust off the inbound path; at 25 the fee is
        // a non-zero 1 unit.
        _setFundsInTokenRule(400);
        vm.prank(multisig);
        bridge.setMinFundsInAmount(25);

        assertEq(cm.calculateStableFee(24, 400, 100), 0, 'sanity: 24 pays zero commission');

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(24), uint256(25)));
        vm.prank(user);
        bridge.fundsIn(24, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        // At the floor the deposit is accepted and pays a non-zero commission.
        vm.prank(user);
        bridge.fundsIn(25, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
        assertEq(rgbModule.fundsInRecords(TX_ID), 24, 'net = 25 - 1 commission');
    }

    function test_fundsInFromAdapter_revertsBelowMinimum() public {
        // The adapter overload shares `_fundsIn`, so the floor applies there too.
        address mockAdapter = makeAddr('mock-adapter');
        vm.prank(multisig);
        bridge.setLZAdapter(mockAdapter);
        vm.prank(multisig);
        bridge.setMinFundsInAmount(1000);

        usdt0.mint(mockAdapter, 999);
        vm.prank(mockAdapter);
        usdt0.approve(address(bridge), 999);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AmountBelowMinimum.selector, uint256(999), uint256(1000)));
        vm.prank(mockAdapter);
        bridge.fundsIn(999, SOURCE_CHAIN_ID, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
    }

    // ========================================================================
    // fundsIn — adapter overload (`onlyLZAdapter`)
    // ========================================================================

    function test_fundsInFromAdapter_revertsIfCallerIsNotLZAdapter() public {
        // No adapter set in setUp — caller is `user`.
        vm.prank(user);
        vm.expectRevert(IBridge.NotLZAdapter.selector);
        bridge.fundsIn(AMOUNT, 1, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
    }

    function test_fundsInFromAdapter_acceptsCustomSourceChainId() public {
        address mockAdapter = makeAddr('mock-adapter');
        vm.prank(multisig);
        bridge.setLZAdapter(mockAdapter);

        usdt0.mint(mockAdapter, AMOUNT);
        vm.prank(mockAdapter);
        usdt0.approve(address(bridge), AMOUNT);

        uint256 customSrc = 137; // pretend Polygon

        // Register a route for the custom (Polygon, RGB) pair — the adapter
        // overload simply forwards whatever sourceChainId the composeMsg
        // carries; both directions need real routes wired in the registry.
        vm.prank(deployer);
        routeRegistry.setRoute(
            customSrc, RGB_CHAIN_ID,
            true, address(rgbVerifier), address(rgbModule)
        );

        // Drop the emitter filter so Forge's expectEmit scans past the token's
        // Transfer event (emitter = usdt0) and matches BridgeFundsIn by topic0.
        vm.expectEmit(true, false, false, true);
        emit BridgeFundsIn(mockAdapter, TX_ID, AMOUNT, AMOUNT, 0, 0, customSrc, RGB_CHAIN_ID, DST_ADDR);

        vm.prank(mockAdapter);
        bridge.fundsIn(AMOUNT, customSrc, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertEq(rgbModule.fundsInRecords(TX_ID), AMOUNT, 'record stored on module');
    }

    // ========================================================================
    // fundsIn — happy path (zero commission default)
    // ========================================================================

    function test_fundsIn_transfersTokens() public {
        uint256 userBefore = usdt0.balanceOf(user);

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
        assertEq(usdt0.balanceOf(user),            userBefore - AMOUNT);
    }

    function test_fundsIn_storesRecordOnModule() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertEq(rgbModule.fundsInRecords(TX_ID), AMOUNT);
    }

    function test_fundsIn_emitsBothEvents() public {
        vm.expectEmit(true, false, false, true);
        emit FundsIn(user, TX_ID, AMOUNT);
        vm.expectEmit(true, false, false, true);
        emit BridgeFundsIn(user, TX_ID, AMOUNT, AMOUNT, 0, 0, SOURCE_CHAIN_ID, RGB_CHAIN_ID, DST_ADDR);

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
    }

    function test_fundsIn_anyUserCanCall() public {
        address stranger = makeAddr('stranger');
        usdt0.mint(stranger, AMOUNT);
        vm.prank(stranger);
        usdt0.approve(address(bridge), AMOUNT);

        vm.prank(stranger);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
    }

    // ========================================================================
    // fundsIn — reverts
    // ========================================================================

    function test_fundsIn_revertsOnEmptyDestinationAddress() public {
        vm.expectRevert(IBridge.InvalidDestinationAddress.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, '', TX_ID, '');
    }

    function test_fundsIn_revertsOnEmptyDestinationChain() public {
        vm.expectRevert(IBridge.InvalidDestinationChainId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, 0, DST_ADDR, TX_ID, '');
    }

    function test_fundsIn_revertsWhenPaused() public {
        vm.prank(multisig);
        bridge.pauseInflow();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
    }

    function test_fundsIn_revertsOnDuplicateOperationId() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        // Duplicate-operationId guard moved into RgbSettlementModule. The
        // revert propagates up through routeRegistry → Bridge unchanged.
        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
    }

    // ========================================================================
    // fundsOut — happy path
    // ========================================================================

    function test_fundsOut_transfersAndEmits() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        vm.expectEmit(true, false, false, true);
        emit BridgeFundsOut(
            recipient, AMOUNT, AMOUNT, 0, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR
        );

        vm.prank(multisig);
        bridge.fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );

        assertEq(usdt0.balanceOf(recipient),       AMOUNT);
        assertEq(usdt0.balanceOf(address(bridge)), 0);
    }

    function test_fundsOut_consumesRecord() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        vm.prank(multisig);
        bridge.fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );

        assertEq(rgbModule.fundsInRecords(TX_ID), 0);
    }

    function test_fundsOut_multipleFundsInIds() public {
        uint256 txId1 = 100;
        uint256 txId2 = 101;
        uint256 amount1 = 60e18;
        uint256 amount2 = 40e18;

        vm.prank(user);
        bridge.fundsIn(amount1, RGB_CHAIN_ID, DST_ADDR, txId1, '');
        vm.prank(user);
        bridge.fundsIn(amount2, RGB_CHAIN_ID, DST_ADDR, txId2, '');

        uint256[] memory ids = new uint256[](2);
        ids[0] = txId1;
        ids[1] = txId2;

        vm.prank(multisig);
        bridge.fundsOut(
            recipient, amount1 + amount2, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(ids)
        );

        assertEq(usdt0.balanceOf(recipient), amount1 + amount2);
        assertEq(rgbModule.fundsInRecords(txId1), 0);
        assertEq(rgbModule.fundsInRecords(txId2), 0);
    }

    // ========================================================================
    // fundsOut — verifier reverts
    // ========================================================================

    function test_fundsOut_revertsOnUnverifiedBlock() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        bytes memory badProof = abi.encode(uint256(999_999), keccak256('unknown-block'));

        // RGBVerifier → BtcRelay reverts with the relay's string message.
        vm.expectRevert('verify: block commitment');
        vm.prank(multisig);
        bridge.fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            badProof, _settlement(_singleFundsInId())
        );
    }

    // ========================================================================
    // fundsOut — settlement-module reverts (delegated to RgbSettlementModule
    // but surfaced through Bridge)
    // ========================================================================

    function test_fundsOut_revertsOnUnknownFundsInId() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;

        vm.expectRevert(abi.encodeWithSelector(RgbSettlementModule.FundsInNotFound.selector, 999));
        vm.prank(multisig);
        bridge.fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(ids)
        );
    }

    function test_fundsOut_revertsOnAmountExceedsFundsIn() public {
        uint256 txId1 = 100;
        uint256 txId2 = 101;
        vm.prank(user);
        bridge.fundsIn(50e18, RGB_CHAIN_ID, DST_ADDR, txId1, '');
        vm.prank(user);
        bridge.fundsIn(50e18, RGB_CHAIN_ID, DST_ADDR, txId2, '');

        uint256[] memory ids = new uint256[](1);
        ids[0] = txId1;

        vm.expectRevert(RgbSettlementModule.FundsOutAmountExceedsFundsIn.selector);
        vm.prank(multisig);
        bridge.fundsOut(
            recipient, 60e18, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(ids)
        );
    }

    function test_fundsOut_revertsOnReplayedBurnId() public {
        uint256 txId1 = 200;
        uint256 txId2 = 201;
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, txId1, '');
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, txId2, '');

        uint256[] memory ids1 = new uint256[](1); ids1[0] = txId1;
        uint256[] memory ids2 = new uint256[](1); ids2[0] = txId2;

        vm.prank(multisig);
        bridge.fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(ids1)
        );
        assertTrue(bridge.consumedBurnIds(BURN_ID), 'burnId recorded');

        // Second fundsOut with the same burnId — must revert before any
        // module mutation, leaving the second record untouched.
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, BURN_ID));
        vm.prank(multisig);
        bridge.fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(ids2)
        );
        assertEq(rgbModule.fundsInRecords(txId2), AMOUNT, 'second fundsIn record preserved');
    }

    function test_fundsOut_revertsOnDoubleSpendsConsumedFundsIn() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        vm.prank(multisig);
        bridge.fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );

        // Top up the bridge directly (simulates a fresh pool) and try a second
        // release against the same — now consumed — fundsIn record.
        usdt0.mint(address(bridge), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(RgbSettlementModule.FundsInNotFound.selector, TX_ID));
        vm.prank(multisig);
        bridge.fundsOut(
            recipient, AMOUNT, BURN_ID + 1,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );
    }

    // ========================================================================
    // fundsOut — other reverts
    // ========================================================================

    function test_fundsOut_revertsIfNotOwner() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        bridge.fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );
    }

    function test_fundsOut_revertsOnZeroRecipient() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        vm.expectRevert(BridgeBase.InvalidRecipientAddress.selector);
        vm.prank(multisig);
        bridge.fundsOut(
            address(0), AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );
    }

    function test_fundsOut_revertsIfAmountExceedsPool() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        vm.expectRevert(BridgeBase.AmountExceedBridgePool.selector);
        vm.prank(multisig);
        bridge.fundsOut(
            recipient, AMOUNT + 1, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );
    }

    // ========================================================================
    // Commission — fundsIn TOKEN
    // ========================================================================

    function test_fundsIn_tokenCommission_routesToCM() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100;
        uint256 expectedNet        = AMOUNT - expectedCommission;

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertEq(usdt0.balanceOf(address(bridge)),         expectedNet,         'bridge net');
        assertEq(usdt0.balanceOf(address(cm)),             expectedCommission,  'cm pool');
        assertEq(cm.tokenCommissionPool(address(usdt0)),   expectedCommission,  'cm recorded');
        assertEq(rgbModule.fundsInRecords(TX_ID),          expectedNet,         'record = net');
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
        bridge.fundsIn{ value: nativeC }(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT);
        assertEq(address(cm).balance,              nativeC);
        assertEq(cm.nativeCommissionPool(),        nativeC);
        assertEq(rgbModule.fundsInRecords(TX_ID),  AMOUNT);
    }

    // ========================================================================
    // Commission — fundsOut TOKEN
    // ========================================================================

    function test_fundsOut_tokenCommission_routesToCM() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        uint256 percent = 500; // 5%
        _setFundsOutTokenRule(percent);

        uint256 expectedCommission = (AMOUNT * percent) / 100 / 100;
        uint256 expectedNet        = AMOUNT - expectedCommission;

        vm.prank(multisig);
        bridge.fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );

        assertEq(usdt0.balanceOf(recipient),              expectedNet,         'recipient net');
        assertEq(usdt0.balanceOf(address(cm)),            expectedCommission,  'cm pool');
        assertEq(cm.tokenCommissionPool(address(usdt0)),  expectedCommission,  'cm recorded');
    }

    // ========================================================================
    // Commission — NATIVE + FUNDS_OUT rejected at config time (R-W-04)
    // ========================================================================

    /// @dev Post R-W-04 the invalid (NATIVE, FUNDS_OUT) shape is rejected by the
    ///      CommissionManager setter, so it can never reach (and brick) fundsOut.
    function test_setCommissionRule_nativeFundsOut_reverts() public {
        vm.expectRevert(ICommissionManager.NativeCommissionNotAllowedOnFundsOut.selector);
        _setFundsOutNativeRule(100); // setCommissionRule(... NATIVE, FUNDS_OUT ...)
    }

    // ========================================================================
    // Commission — NativeValueMismatch
    // ========================================================================

    function test_fundsIn_revertsOnNativeValueMismatch_zeroRuleButValueSent() public {
        vm.deal(user, 1 ether);
        vm.expectRevert(IBridge.NativeValueMismatch.selector);
        vm.prank(user);
        bridge.fundsIn{ value: 1 ether }(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
    }

    function test_fundsIn_revertsOnNativeValueMismatch_nativeRuleButNoValue() public {
        _setFundsInNativeRule(100);

        vm.expectRevert(IBridge.NativeValueMismatch.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
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
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

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
        bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertEq(usdt0.balanceOf(address(bridge)), amount);
        assertEq(rgbModule.fundsInRecords(TX_ID),  amount);
    }
}
