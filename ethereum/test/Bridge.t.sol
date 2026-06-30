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
import { OutflowRateLimiter }         from '../src/libraries/OutflowRateLimiter.sol';
import {
    CommissionConfig,
    CommissionSide,
    CommissionCurrency,
    ICommissionManager
} from '../src/interfaces/ICommissionManager.sol';

import { MockERC20 }        from './mocks/MockERC20.sol';
import { MockBtcRelay }     from './mocks/MockBtcRelay.sol';
import { MockAggregatorV3 } from './mocks/MockAggregatorV3.sol';
import { MockSettlementModule } from './mocks/MockSettlementModule.sol';

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
    event OutflowLimitUpdated(uint256 indexed chainId, uint256 capacity, uint256 refillRate, uint256 available);
    event GlobalOutflowLimitUpdated(uint256 capacity, uint256 refillRate, uint256 available);

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

        // Outflow rate limits: configure generous buckets so the
        // release path is enabled (fundsOut fails closed on an unconfigured
        // bucket). Buckets start full, so releases pass immediately.
        bridge.setOutflowLimit(RGB_CHAIN_ID, 1_000_000 ether, uint256(1_000_000 ether) / 1 days);
        bridge.setGlobalOutflowLimit(1_000_000 ether, uint256(1_000_000 ether) / 1 days);

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

    /// @dev Wrap the former 8 positional `fundsOut` args into the typed struct
    ///      and make the external Bridge call. Keeps `vm.prank` / `vm.expectRevert`
    ///      working: the inner `bridge.fundsOut` is the next external call.
    function _fundsOut(
        address recipient_,
        uint256 amount,
        uint256 burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string memory sourceAddress,
        bytes memory proof,
        bytes memory settlementData
    ) internal {
        bridge.fundsOut(IBridge.FundsOutParams(
            recipient_, amount, burnId, sourceChainId, destinationChainId,
            sourceAddress, proof, settlementData
        ));
    }

    /// @dev Build an ASCII string of exactly `len` bytes (for address-length caps).
    function _str(uint256 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = 'a';
        }
        return string(b);
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
        _fundsOut(
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

    function test_fundsIn_revertsOnDestinationAddressTooLong() public {
        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        string memory tooLong = _str(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AddressTooLong.selector, max + 1, max));
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, tooLong, TX_ID, '');
    }

    function test_fundsIn_acceptsDestinationAddressAtMaxLength() public {
        uint256 max = bridge.MAX_ADDRESS_LENGTH();

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, _str(max), TX_ID, '');
        assertEq(rgbModule.fundsInRecords(TX_ID), AMOUNT, 'deposit at the address-length cap is accepted');
    }

    function test_fundsOut_revertsOnSourceAddressTooLong() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        uint256 max = bridge.MAX_ADDRESS_LENGTH();
        string memory tooLong = _str(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.AddressTooLong.selector, max + 1, max));
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, tooLong,
            _proof(), _settlement(_singleFundsInId())
        );
    }

    function test_fundsOut_acceptsSourceAddressAtMaxLength() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        uint256 max = bridge.MAX_ADDRESS_LENGTH();

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, _str(max),
            _proof(), _settlement(_singleFundsInId())
        );
        assertEq(usdt0.balanceOf(recipient), AMOUNT, 'release with sourceAddress at the cap succeeds');
    }

    // ========================================================================
    // Proof length cap (R-I-12)
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
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        uint256 max = bridge.MAX_PROOF_LENGTH();
        bytes memory tooLong = _bytesOfLength(max + 1);

        vm.expectRevert(abi.encodeWithSelector(IBridge.ProofTooLong.selector, max + 1, max));
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            tooLong, _settlement(_singleFundsInId())
        );
    }

    function test_fundsOut_acceptsProofAtMaxLength() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        // A proof at the exact cap passes the length guard. It then reverts in
        // the verifier (the blob is not a valid (height, commitment) pair), so
        // the cap check is isolated by asserting it is NOT ProofTooLong: the
        // call reaches the verifier instead.
        uint256 max = bridge.MAX_PROOF_LENGTH();
        bytes memory atMax = _bytesOfLength(max);

        vm.prank(multisig);
        try bridge.fundsOut(IBridge.FundsOutParams(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            atMax, _settlement(_singleFundsInId())
        )) {
            // a decodable proof would succeed; this blob won't, so we don't
            // expect to land here — but if a future verifier accepts it, the
            // length guard still passed, which is what this test asserts.
        } catch (bytes memory reason) {
            // Must NOT be the length guard — proving max-length passes it.
            bytes4 sel = bytes4(reason);
            assertTrue(sel != IBridge.ProofTooLong.selector, 'max-length proof must clear the length guard');
        }
    }

    function test_fundsOut_acceptsRealProofUnderCap() public {
        // The production-shaped 64-byte RGB proof is well under the cap and the
        // happy path still succeeds.
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertLt(_proof().length, bridge.MAX_PROOF_LENGTH(), 'sanity: real proof under cap');

        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );
        assertEq(usdt0.balanceOf(recipient), AMOUNT, 'release with a normal proof succeeds');
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
        _fundsOut(
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
        _fundsOut(
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
        _fundsOut(
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
        _fundsOut(
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
        _fundsOut(
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
        _fundsOut(
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
        _fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(ids1)
        );
        assertTrue(bridge.consumedBurnIds(BURN_ID), 'burnId recorded');

        // Second fundsOut with the same burnId — must revert before any
        // module mutation, leaving the second record untouched.
        vm.expectRevert(abi.encodeWithSelector(IBridge.BurnIdAlreadyConsumed.selector, BURN_ID));
        vm.prank(multisig);
        _fundsOut(
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
        _fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );

        // Top up the bridge directly (simulates a fresh pool) and try a second
        // release against the same — now consumed — fundsIn record.
        usdt0.mint(address(bridge), AMOUNT);

        // Isolated liquidity (R-C-01 level 1): the first release drained the RGB
        // bucket to zero, and a direct mint does not credit it (only fundsIn
        // does). So the liquidity guard rejects the double-spend before the
        // settlement module's FundsInNotFound — an earlier, stronger backstop.
        vm.expectRevert(abi.encodeWithSelector(
            IBridge.InsufficientChainLiquidity.selector, RGB_CHAIN_ID, AMOUNT, uint256(0)
        ));
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID + 1,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );
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
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT, 'bucket credited net amount');
    }

    function test_isolatedLiquidity_tokenCommissionCreditsNetNotGross() public {
        _setFundsInTokenRule(400); // 4%
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        uint256 fee = cm.calculateStableFee(AMOUNT, 400, 100);
        assertGt(fee, 0, 'sanity: positive fee');
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT - fee, 'bucket credits net, not gross');
    }

    function test_isolatedLiquidity_fundsOutDebitsGrossAmount() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        uint256 release = 40e18;
        vm.prank(multisig);
        _fundsOut(
            recipient, release, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT - release, 'bucket debited by gross release');
    }

    function test_isolatedLiquidity_chainCannotConsumeAnotherChainsLiquidity() public {
        // Fund only the RGB bucket.
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        // A different source chain with an enabled route and a (full) outflow
        // bucket, so the rate limiter is NOT what blocks — only isolated
        // liquidity is. Its lockedLiquidity is zero.
        uint256 otherChain = 777;
        vm.prank(deployer);
        routeRegistry.setRoute(otherChain, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        vm.prank(multisig);
        bridge.setOutflowLimit(otherChain, 1_000_000 ether, uint256(1_000_000 ether) / 1 days);

        // Bridge holds AMOUNT (from the RGB deposit), but it is locked for RGB,
        // not for `otherChain`. The release must fail on isolated liquidity.
        assertEq(usdt0.balanceOf(address(bridge)), AMOUNT, 'pool has balance');
        vm.expectRevert(abi.encodeWithSelector(
            IBridge.InsufficientChainLiquidity.selector, otherChain, AMOUNT, uint256(0)
        ));
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID,
            otherChain, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );
    }

    function test_isolatedLiquidity_revertRollsBackDebit() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        // Bad proof → verifier reverts downstream of the liquidity debit.
        bytes memory badProof = abi.encode(uint256(999_999), keccak256('unknown'));
        vm.expectRevert();
        vm.prank(multisig);
        _fundsOut(
            recipient, AMOUNT, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            badProof, _settlement(_singleFundsInId())
        );
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), AMOUNT, 'debit rolled back on revert');
    }

    /// @dev Fuzz the deposit/release round trip: a release of exactly the locked
    ///      net amount succeeds and zeroes the bucket; one unit more reverts.
    function testFuzz_isolatedLiquidity_roundTrip(uint256 amount) public {
        // Bound to the user's funded balance and above the dust floor; no
        // commission in setUp so net == gross.
        amount = bound(amount, bridge.minFundsInAmount(), AMOUNT * 10);

        vm.prank(user);
        bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), amount, 'credited');

        // Mint an unlocked buffer so the pool balance exceeds the locked amount;
        // this isolates the per-chain liquidity guard from the raw balance guard
        // (a direct mint does not credit lockedLiquidity).
        usdt0.mint(address(bridge), amount + 1);

        // One unit over the locked amount reverts on the per-chain liquidity guard.
        vm.expectRevert(abi.encodeWithSelector(
            IBridge.InsufficientChainLiquidity.selector, RGB_CHAIN_ID, amount + 1, amount
        ));
        vm.prank(multisig);
        _fundsOut(
            recipient, amount + 1, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );

        // Exactly the locked amount succeeds and zeroes the bucket.
        vm.prank(multisig);
        _fundsOut(
            recipient, amount, BURN_ID,
            RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR,
            _proof(), _settlement(_singleFundsInId())
        );
        assertEq(bridge.lockedLiquidity(RGB_CHAIN_ID), 0, 'fully debited');
    }

    // ========================================================================
    // Outflow rate limit — OutflowRateLimiter token bucket
    //
    // fundsOut consumes the per-chain bucket (token-scoped errors) then the
    // global bucket (aggregate-scoped errors). setUp configures both RGB and
    // global to 1_000_000 ether and primes them full; tests reconfigure RGB down
    // (clamp makes available == new capacity) to exercise tight limits. SEED_TX
    // seeds ample isolated liquidity + a consumable settlement record, so the
    // token bucket is the only limiter. Rate-limit reverts are matched by
    // selector (the library's minWait is an implementation detail).
    // ========================================================================

    uint256 constant SEED_TX = 5_000;

    function _seedRGB(uint256 amount) internal {
        vm.prank(user);
        bridge.fundsIn(amount, RGB_CHAIN_ID, DST_ADDR, SEED_TX, '');
    }

    function _releaseRGB(uint256 amount, uint256 burnId) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = SEED_TX;
        vm.prank(multisig);
        _fundsOut(recipient, amount, burnId, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), abi.encode(ids));
    }

    function _setRGBBucket(uint256 cap, uint256 rate) internal {
        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, cap, rate);
    }

    function test_outflow_fullBucketAllowsCapacityRejectsOverByOne() public {
        _seedRGB(1000 ether);
        uint256 cap = 100 ether;
        _setRGBBucket(cap, cap / 1 days); // reconfig down → available == cap

        _releaseRGB(cap, BURN_ID);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, 'capacity fully spent');

        // One unit over the (now empty) bucket but still within capacity → rate-limited.
        vm.expectPartialRevert(OutflowRateLimiter.TokenOutflowThrottled.selector);
        _releaseRGB(1, BURN_ID + 1);
    }

    function test_outflow_releaseAboveCapacityReverts() public {
        _seedRGB(1000 ether);
        uint256 cap = 100 ether;
        _setRGBBucket(cap, cap / 1 days);

        // Full bucket, but the request exceeds capacity entirely → a different,
        // more-specific error than the rate-limit one.
        vm.expectPartialRevert(OutflowRateLimiter.TokenRequestAboveCapacity.selector);
        _releaseRGB(cap + 1, BURN_ID);
    }

    function test_outflow_refillAccruesOverTime() public {
        _seedRGB(1000 ether);
        uint256 cap = 100 ether;
        uint256 rate = cap / 1 days;
        _setRGBBucket(cap, rate);

        _releaseRGB(cap, BURN_ID);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, 'drained');

        vm.warp(block.timestamp + 12 hours);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), rate * 12 hours, 'partial linear refill');

        _releaseRGB(rate * 12 hours, BURN_ID + 1); // the refilled allowance is spendable
    }

    function test_outflow_noDoubleCapBurstOverShortGap() public {
        _seedRGB(1000 ether);
        uint256 cap = 100 ether;
        uint256 rate = cap / 1 days;
        _setRGBBucket(cap, rate);

        _releaseRGB(cap, BURN_ID);
        vm.warp(block.timestamp + 1); // one second later

        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), rate, 'only refillRate accrued, not a fresh cap');
        vm.expectPartialRevert(OutflowRateLimiter.TokenOutflowThrottled.selector);
        _releaseRGB(cap, BURN_ID + 1);
    }

    function test_outflow_perChainIsolation() public {
        uint256 other = 888;
        vm.prank(deployer);
        routeRegistry.setRoute(other, SOURCE_CHAIN_ID, true, address(rgbVerifier), address(rgbModule));
        vm.prank(multisig);
        bridge.setOutflowLimit(other, 50 ether, uint256(50 ether) / 1 days);

        _seedRGB(1000 ether);
        _setRGBBucket(100 ether, uint256(100 ether) / 1 days);
        _releaseRGB(100 ether, BURN_ID); // drain RGB bucket to 0

        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 0, 'RGB drained');
        assertEq(bridge.availableOutflow(other), 50 ether, 'other chain bucket untouched');
    }

    function test_outflow_globalBucketBoundsAggregate() public {
        // Per-chain RGB stays large (1M from setUp); tighten only the global bucket.
        vm.prank(multisig);
        bridge.setGlobalOutflowLimit(100 ether, uint256(100 ether) / 1 days);

        _seedRGB(1000 ether);
        _releaseRGB(100 ether, BURN_ID); // consumes the whole global allowance
        assertEq(bridge.availableGlobalOutflow(), 0, 'global drained');

        // The per-chain bucket still has room, but the global aggregate trips.
        vm.expectPartialRevert(OutflowRateLimiter.AggregateOutflowThrottled.selector);
        _releaseRGB(1, BURN_ID + 1);
    }

    function test_outflow_reconfigPreservesAvailableNoGift() public {
        _seedRGB(1000 ether);
        _setRGBBucket(100 ether, uint256(100 ether) / 1 days);
        _releaseRGB(60 ether, BURN_ID); // available 40 ether
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 40 ether, 'pre');

        // Raising capacity must NOT gift a fresh full bucket.
        _setRGBBucket(200 ether, uint256(200 ether) / 1 days);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 40 ether, 'available preserved, not gifted');
    }

    function test_outflow_reconfigClampsOnDecrease() public {
        _setRGBBucket(100 ether, uint256(100 ether) / 1 days); // available 100 ether
        _setRGBBucket(30 ether,  uint256(30 ether) / 1 days);  // clamp down
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 30 ether, 'clamped to new capacity');
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
        bridge.fundsIn(100 ether, unconfigured, DST_ADDR, SEED_TX, '');

        uint256[] memory ids = new uint256[](1);
        ids[0] = SEED_TX;
        vm.expectRevert(OutflowRateLimiter.LimitNotConfigured.selector);
        vm.prank(multisig);
        _fundsOut(recipient, 100 ether, BURN_ID, unconfigured, SOURCE_CHAIN_ID, SRC_ADDR, _proof(), abi.encode(ids));
    }

    function test_outflow_downstreamRevertRestoresBuckets() public {
        _seedRGB(1000 ether);
        _setRGBBucket(100 ether, uint256(100 ether) / 1 days);

        uint256 globalBefore = bridge.availableGlobalOutflow();
        bytes memory badProof = abi.encode(uint256(999_999), keccak256('unknown'));
        uint256[] memory ids = new uint256[](1);
        ids[0] = SEED_TX;

        vm.expectRevert();
        vm.prank(multisig);
        _fundsOut(recipient, 50 ether, BURN_ID, RGB_CHAIN_ID, SOURCE_CHAIN_ID, SRC_ADDR, badProof, abi.encode(ids));

        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), 100 ether, 'per-chain restored');
        assertEq(bridge.availableGlobalOutflow(), globalBefore, 'global restored');
    }

    function test_setOutflowLimit_revertsOnZeroChainId() public {
        vm.prank(multisig);
        vm.expectRevert(IBridge.InvalidOutflowLimit.selector);
        bridge.setOutflowLimit(0, 100 ether, uint256(100 ether) / 1 days);
    }

    function test_setOutflowLimit_revertsOnInvalidRate() public {
        // Library validation requires 0 < rate < capacity.
        vm.startPrank(multisig);
        vm.expectRevert(abi.encodeWithSelector(OutflowRateLimiter.InvalidLimitConfig.selector,
            OutflowRateLimiter.Settings({ isEnabled: true, capacity: uint128(100 ether), rate: uint128(100 ether) })));
        bridge.setOutflowLimit(RGB_CHAIN_ID, 100 ether, 100 ether); // rate == capacity
        vm.stopPrank();
    }

    function test_setOutflowLimit_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setOutflowLimit(RGB_CHAIN_ID, 100 ether, 1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        bridge.setGlobalOutflowLimit(100 ether, 1);
    }

    function test_setOutflowLimit_emitsEvent() public {
        uint256 cap = 100 ether;
        uint256 rate = cap / 1 days;
        // RGB already configured in setUp (full at 1M); reconfig down clamps
        // available to the new capacity.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit OutflowLimitUpdated(RGB_CHAIN_ID, cap, rate, cap);
        vm.prank(multisig);
        bridge.setOutflowLimit(RGB_CHAIN_ID, cap, rate);
    }

    /// @dev Fuzz the refill formula end-to-end through the live preview: reconfig
    ///      RGB to a fuzzed (capacity, rate), drain a fuzzed amount, warp a fuzzed
    ///      time, and assert availableOutflow matches an independent recomputation
    ///      of the library's min(capacity, tokens + elapsed*rate).
    function testFuzz_outflow_previewMatchesRefillFormula(
        uint256 capacity,
        uint256 rate,
        uint256 drain,
        uint256 elapsed
    ) public {
        capacity = bound(capacity, 2, 1_000_000 ether);     // <= setUp's 1M so reconfig-down clamps to full
        rate     = bound(rate, 1, capacity - 1);            // library requires 0 < rate < capacity
        drain    = bound(drain, 1, capacity < 1000 ether ? capacity : 1000 ether);
        elapsed  = bound(elapsed, 0, 4_000 days);

        _seedRGB(drain);
        _setRGBBucket(capacity, rate); // available == capacity (clamp down from 1M)
        _releaseRGB(drain, BURN_ID);   // available == capacity - drain

        vm.warp(block.timestamp + elapsed);

        uint256 tokensAfter = capacity - drain;
        uint256 expected = tokensAfter + elapsed * rate;
        if (expected > capacity) expected = capacity;
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), expected, 'preview matches library refill');
        assertLe(bridge.availableOutflow(RGB_CHAIN_ID), capacity, 'never exceeds capacity');
    }

    /// @dev A release within the live allowance debits exactly that amount.
    function testFuzz_outflow_releaseDebitsAvailable(uint256 capacity, uint256 amount) public {
        capacity = bound(capacity, 1 ether, 1_000_000 ether); // >= 1e18 so capacity/1day >= 1 (valid rate)
        amount   = bound(amount, 1, capacity < 1000 ether ? capacity : 1000 ether);

        _seedRGB(1000 ether);
        _setRGBBucket(capacity, capacity / 1 days);

        uint256 available = bridge.availableOutflow(RGB_CHAIN_ID); // == capacity
        _releaseRGB(amount, BURN_ID);
        assertEq(bridge.availableOutflow(RGB_CHAIN_ID), available - amount, 'debited exactly');
    }

    // ========================================================================
    // fundsOut — other reverts
    // ========================================================================

    function test_fundsOut_revertsIfNotOwner() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        _fundsOut(
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
        _fundsOut(
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
        _fundsOut(
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
        _fundsOut(
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

    // ========================================================================
    // fundsIn — full-flow state snapshots
    // ========================================================================

    function test_fundsIn_tokenCommission_fullFlowStateSnapshot() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);

        // Snapshot every balance/pool/record this TOKEN-commission flow should touch.
        uint256 userBefore       = usdt0.balanceOf(user);
        uint256 bridgeBefore     = usdt0.balanceOf(address(bridge));
        uint256 cmBefore         = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore     = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 userEthBefore    = user.balance;
        uint256 bridgeEthBefore  = address(bridge).balance;
        uint256 cmEthBefore      = address(cm).balance;
        uint256 recordBefore     = rgbModule.fundsInRecords(TX_ID);

        assertEq(bridgeBefore,     0, 'pre bridge token');
        assertEq(cmBefore,         0, 'pre cm token');
        assertEq(cmPoolBefore,     0, 'pre cm pool');
        assertEq(nativePoolBefore, 0, 'pre native pool');
        assertEq(recordBefore,     0, 'pre record');

        vm.expectEmit(true, false, false, true);
        emit FundsIn(user, TX_ID, netAmount);
        vm.expectEmit(true, false, false, true);
        emit BridgeFundsIn(
            user,
            TX_ID,
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
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertEq(usdt0.balanceOf(user),            userBefore - AMOUNT,      'user gross spent');
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + netAmount, 'bridge net delta');
        assertEq(usdt0.balanceOf(address(cm)),     cmBefore + tokenCommission, 'cm fee delta');
        assertEq(
            cm.tokenCommissionPool(address(usdt0)),
            cmPoolBefore + tokenCommission,
            'cm pool delta'
        );
        assertEq(cm.nativeCommissionPool(),       nativePoolBefore, 'native pool unchanged');
        assertEq(user.balance,                    userEthBefore,    'user native unchanged');
        assertEq(address(bridge).balance,         bridgeEthBefore,  'bridge native unchanged');
        assertEq(address(cm).balance,             cmEthBefore,      'cm native unchanged');
        assertEq(rgbModule.fundsInRecords(TX_ID), recordBefore + netAmount, 'record delta = net');

        // Gross USDT0 is conserved between Bridge liquidity and CM commission custody.
        assertEq(
            (usdt0.balanceOf(address(bridge)) - bridgeBefore) +
            (usdt0.balanceOf(address(cm)) - cmBefore),
            AMOUNT,
            'gross token conserved'
        );
    }

    function test_fundsIn_nativeCommission_fullFlowStateSnapshot() public {
        uint256 percent = 100; // 1%
        _setFundsInNativeRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertEq(tokenCommission, 0, 'token fee is zero');
        assertGt(nativeCommission, 0, 'native fee quoted');
        assertEq(netAmount, AMOUNT, 'net token amount');

        vm.deal(user, nativeCommission);

        // Snapshot token/native balances, pools, and RGB record touched by native-fee fundsIn.
        uint256 userTokenBefore   = usdt0.balanceOf(user);
        uint256 bridgeTokenBefore = usdt0.balanceOf(address(bridge));
        uint256 cmTokenBefore     = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore      = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore  = cm.nativeCommissionPool();
        uint256 userEthBefore     = user.balance;
        uint256 bridgeEthBefore   = address(bridge).balance;
        uint256 cmEthBefore       = address(cm).balance;
        uint256 recordBefore      = rgbModule.fundsInRecords(TX_ID);

        assertEq(bridgeTokenBefore, 0, 'pre bridge token');
        assertEq(cmTokenBefore,     0, 'pre cm token');
        assertEq(cmPoolBefore,      0, 'pre token pool');
        assertEq(nativePoolBefore,  0, 'pre native pool');
        assertEq(recordBefore,      0, 'pre record');

        vm.expectEmit(true, false, false, true);
        emit FundsIn(user, TX_ID, netAmount);
        vm.expectEmit(true, false, false, true);
        emit BridgeFundsIn(
            user,
            TX_ID,
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
        bridge.fundsIn{ value: nativeCommission }(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertEq(usdt0.balanceOf(user),            userTokenBefore - AMOUNT,       'user token gross spent');
        assertEq(usdt0.balanceOf(address(bridge)), bridgeTokenBefore + netAmount,  'bridge token delta');
        assertEq(usdt0.balanceOf(address(cm)),     cmTokenBefore,                  'cm token unchanged');
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore,             'token pool unchanged');
        assertEq(cm.nativeCommissionPool(),        nativePoolBefore + nativeCommission, 'native pool delta');
        assertEq(user.balance,                     userEthBefore - nativeCommission,    'user native paid');
        assertEq(address(bridge).balance,          bridgeEthBefore,                      'bridge native unchanged');
        assertEq(address(cm).balance,              cmEthBefore + nativeCommission,       'cm native delta');
        assertEq(rgbModule.fundsInRecords(TX_ID),  recordBefore + netAmount,             'record delta = net');

        // Native fee is conserved in CM custody while the full USDT0 principal stays in Bridge.
        assertEq(usdt0.balanceOf(address(bridge)) - bridgeTokenBefore, AMOUNT,           'gross token in bridge');
        assertEq(address(cm).balance - cmEthBefore, nativeCommission,                    'native fee conserved');
    }

    // ========================================================================
    // fundsOut — full-flow state snapshots
    // ========================================================================

    function test_fundsOut_snapshot_tokenCommission_partialConsume() public {
        uint256 releaseAmount = 60e18;
        uint256 percent = 500; // 5%

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');
        _setFundsOutTokenRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsOutCommission(RGB_CHAIN_ID, SOURCE_CHAIN_ID, address(usdt0), releaseAmount);
        assertGt(tokenCommission, 0, 'token fee quoted');
        assertEq(nativeCommission, 0, 'native fee is zero');
        assertEq(netAmount, releaseAmount - tokenCommission, 'net recipient amount');

        uint256[] memory ids = new uint256[](1);
        ids[0] = TX_ID;

        // Snapshot the Bridge fundsOut state after a larger RGB record exists.
        uint256 bridgeBefore    = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore = usdt0.balanceOf(recipient);
        uint256 cmBefore        = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore    = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore    = rgbModule.fundsInRecords(TX_ID);

        assertEq(bridgeBefore,     AMOUNT, 'pre bridge pool');
        assertEq(recipientBefore,  0,      'pre recipient token');
        assertEq(cmBefore,         0,      'pre cm token');
        assertEq(cmPoolBefore,     0,      'pre cm pool');
        assertEq(nativePoolBefore, 0,      'pre native pool');
        assertEq(recordBefore,     AMOUNT, 'pre record');
        assertFalse(bridge.consumedBurnIds(BURN_ID), 'pre burn id');

        vm.expectEmit(true, false, false, true);
        emit BridgeFundsOut(
            recipient,
            releaseAmount,
            netAmount,
            tokenCommission,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR
        );

        // Release only part of the RGB record; the module should preserve the residual.
        vm.prank(multisig);
        _fundsOut(
            recipient,
            releaseAmount,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(ids)
        );

        assertTrue(bridge.consumedBurnIds(BURN_ID), 'burn id consumed');
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore - releaseAmount, 'bridge gross debit');
        assertEq(usdt0.balanceOf(recipient),       recipientBefore + netAmount,  'recipient net delta');
        assertEq(usdt0.balanceOf(address(cm)),     cmBefore + tokenCommission,   'cm fee delta');
        assertEq(
            cm.tokenCommissionPool(address(usdt0)),
            cmPoolBefore + tokenCommission,
            'cm pool delta'
        );
        assertEq(cm.nativeCommissionPool(),        nativePoolBefore,             'native pool unchanged');
        assertEq(rgbModule.fundsInRecords(TX_ID),  recordBefore - releaseAmount, 'record residual');

        // The gross Bridge debit splits into recipient net payout and CM token commission.
        assertEq(
            (usdt0.balanceOf(recipient) - recipientBefore) +
            (usdt0.balanceOf(address(cm)) - cmBefore),
            releaseAmount,
            'gross fundsOut conserved'
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
        routeRegistry.setRoute(
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            true,
            address(rgbVerifier),
            address(revertingModule)
        );

        uint256 userBefore       = usdt0.balanceOf(user);
        uint256 bridgeBefore     = usdt0.balanceOf(address(bridge));
        uint256 cmBefore         = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore     = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore     = rgbModule.fundsInRecords(TX_ID);

        assertEq(bridgeBefore, 0, 'pre bridge token');
        assertEq(cmBefore,     0, 'pre cm token');
        assertEq(cmPoolBefore, 0, 'pre cm pool');
        assertEq(recordBefore, 0, 'pre rgb record');
        assertEq(revertingModule.onFundsInCount(), 0, 'pre module calls');

        // Bridge emits FundsIn/BridgeFundsIn only after route dispatch, so this
        // module revert prevents successful Bridge events from persisting.
        vm.expectRevert(MockSettlementModule.MockModuleForcedRevert.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertEq(usdt0.balanceOf(user),            userBefore,       'user token unchanged');
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore,     'bridge token unchanged');
        assertEq(usdt0.balanceOf(address(cm)),     cmBefore,         'cm token unchanged');
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, 'cm pool unchanged');
        assertEq(cm.nativeCommissionPool(),        nativePoolBefore, 'native pool unchanged');
        assertEq(rgbModule.fundsInRecords(TX_ID),  recordBefore,     'rgb record unchanged');
        assertEq(revertingModule.onFundsInCount(), 0,                'module state unchanged');
    }

    function test_fundsIn_commissionForwardingRevertRollsBackSettlementRecord() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission,, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertGt(tokenCommission, 0, 'token fee quoted');
        assertLt(netAmount, AMOUNT, 'net below gross');

        // Misconfigure only the CM bridge guard so the route/RGB write happens
        // before commission forwarding fails in receiveTokenCommission().
        vm.prank(deployer);
        cm.setBridgeAddress(makeAddr('wrong-bridge'));

        uint256 userBefore       = usdt0.balanceOf(user);
        uint256 bridgeBefore     = usdt0.balanceOf(address(bridge));
        uint256 cmBefore         = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore     = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore     = rgbModule.fundsInRecords(TX_ID);

        assertEq(bridgeBefore, 0, 'pre bridge token');
        assertEq(cmBefore,     0, 'pre cm token');
        assertEq(cmPoolBefore, 0, 'pre cm pool');
        assertEq(recordBefore, 0, 'pre rgb record');

        // FundsIn/BridgeFundsIn emit after commission forwarding, so this
        // late revert prevents successful Bridge events from persisting.
        vm.expectRevert(ICommissionManager.OnlyBridge.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        assertEq(usdt0.balanceOf(user),            userBefore,       'user token unchanged');
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore,     'bridge token unchanged');
        assertEq(usdt0.balanceOf(address(cm)),     cmBefore,         'cm token unchanged');
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, 'cm pool unchanged');
        assertEq(cm.nativeCommissionPool(),        nativePoolBefore, 'native pool unchanged');
        assertEq(rgbModule.fundsInRecords(TX_ID),  recordBefore,     'rgb record unchanged');
    }

    // ========================================================================
    // fundsOut — rollback snapshots
    // ========================================================================

    function test_fundsOut_verifierRevertRollsBackBurnIdAndRecords() public {
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        bytes memory badProof = abi.encode(uint256(999_999), keccak256('unknown-block'));

        uint256 bridgeBefore     = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore  = usdt0.balanceOf(recipient);
        uint256 cmBefore         = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore     = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 recordBefore     = rgbModule.fundsInRecords(TX_ID);

        assertFalse(bridge.consumedBurnIds(BURN_ID), 'pre burn id');
        assertEq(bridgeBefore, AMOUNT, 'pre bridge pool');
        assertEq(recipientBefore, 0, 'pre recipient token');
        assertEq(cmBefore, 0, 'pre cm token');
        assertEq(cmPoolBefore, 0, 'pre cm pool');
        assertEq(nativePoolBefore, 0, 'pre native pool');
        assertEq(recordBefore, AMOUNT, 'pre rgb record');

        // fundsOut marks the burn id before verifier dispatch. This verifier
        // failure rolls that mark back and short-circuits before RGB records
        // can be consumed.
        vm.expectRevert('verify: block commitment');
        vm.prank(multisig);
        _fundsOut(
            recipient,
            AMOUNT,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            badProof,
            _settlement(_singleFundsInId())
        );

        assertFalse(bridge.consumedBurnIds(BURN_ID), 'burn id unchanged');
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore, 'bridge token unchanged');
        assertEq(usdt0.balanceOf(recipient),       recipientBefore, 'recipient token unchanged');
        assertEq(usdt0.balanceOf(address(cm)),     cmBefore, 'cm token unchanged');
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, 'cm pool unchanged');
        assertEq(cm.nativeCommissionPool(),        nativePoolBefore, 'native pool unchanged');
        assertEq(rgbModule.fundsInRecords(TX_ID),  recordBefore, 'rgb record unchanged');
    }

    function test_fundsOut_settlementRevertRollsBackBurnIdAndRecords() public {
        uint256 txId1 = 100;
        uint256 txId2 = 101;
        uint256 amount1 = 50e18;
        uint256 amount2 = 50e18;
        uint256 releaseAmount = 60e18;

        vm.prank(user);
        bridge.fundsIn(amount1, RGB_CHAIN_ID, DST_ADDR, txId1, '');
        vm.prank(user);
        bridge.fundsIn(amount2, RGB_CHAIN_ID, DST_ADDR, txId2, '');

        uint256[] memory ids = new uint256[](1);
        ids[0] = txId1;

        uint256 bridgeBefore     = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore  = usdt0.balanceOf(recipient);
        uint256 cmBefore         = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore     = cm.tokenCommissionPool(address(usdt0));
        uint256 nativePoolBefore = cm.nativeCommissionPool();
        uint256 record1Before    = rgbModule.fundsInRecords(txId1);
        uint256 record2Before    = rgbModule.fundsInRecords(txId2);

        assertFalse(bridge.consumedBurnIds(BURN_ID), 'pre burn id');
        assertEq(bridgeBefore, amount1 + amount2, 'pre bridge pool');
        assertEq(recipientBefore, 0, 'pre recipient token');
        assertEq(cmBefore, 0, 'pre cm token');
        assertEq(cmPoolBefore, 0, 'pre cm pool');
        assertEq(nativePoolBefore, 0, 'pre native pool');
        assertEq(record1Before, amount1, 'pre record 1');
        assertEq(record2Before, amount2, 'pre record 2');

        // The first record is deleted before the module discovers the release
        // is underfunded; the revert must restore that consumed record too.
        vm.expectRevert(RgbSettlementModule.FundsOutAmountExceedsFundsIn.selector);
        vm.prank(multisig);
        _fundsOut(
            recipient,
            releaseAmount,
            BURN_ID,
            RGB_CHAIN_ID,
            SOURCE_CHAIN_ID,
            SRC_ADDR,
            _proof(),
            _settlement(ids)
        );

        assertFalse(bridge.consumedBurnIds(BURN_ID), 'burn id unchanged');
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore, 'bridge token unchanged');
        assertEq(usdt0.balanceOf(recipient),       recipientBefore, 'recipient token unchanged');
        assertEq(usdt0.balanceOf(address(cm)),     cmBefore, 'cm token unchanged');
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore, 'cm pool unchanged');
        assertEq(cm.nativeCommissionPool(),        nativePoolBefore, 'native pool unchanged');
        assertEq(rgbModule.fundsInRecords(txId1),  record1Before, 'record 1 rolled back');
        assertEq(rgbModule.fundsInRecords(txId2),  record2Before, 'record 2 unchanged');
    }

    // Current behavior reproduction
    // ========================================================================

    function test_fundsOutAcceptsProofNotBoundToReleaseContext_currentBehavior() public {
        address alternateRecipient = makeAddr('alternateRecipient');
        uint256 releaseAmount = 37e18;
        uint256 alternateBurnId = BURN_ID + 777;
        // R-C-01 (isolated liquidity + outflow limit) gates the `sourceChainId`
        // dimension: a release can only draw from a funded + rate-limited source
        // chain. So this reproduction keeps the source on the funded RGB chain
        // and shows the *remaining* unbound dimensions — recipient, amount,
        // burnId and destinationChainId are still not bound to the verifier proof.
        uint256 alternateSourceChainId = RGB_CHAIN_ID;
        uint256 alternateDestinationChainId = SOURCE_CHAIN_ID + 77;
        string memory alternateSourceAddress = 'rgb:unbound/source/utxo999';

        vm.prank(deployer);
        routeRegistry.setRoute(
            alternateSourceChainId,
            alternateDestinationChainId,
            true,
            address(rgbVerifier),
            address(rgbModule)
        );

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID, '');

        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recipientBefore = usdt0.balanceOf(alternateRecipient);
        uint256 recordBefore = rgbModule.fundsInRecords(TX_ID);

        assertEq(bridgeBefore, AMOUNT, 'pre bridge pool');
        assertEq(recipientBefore, 0, 'pre recipient token');
        assertEq(recordBefore, AMOUNT, 'pre record');
        assertFalse(bridge.consumedBurnIds(alternateBurnId), 'pre burn id');

        // Current behavior: this is still an authorized fundsOut call, but the
        // RGBVerifier checks only the encoded BTC block commitment proof. The
        // record was created on the default route and is consumed on this
        // alternate enabled route because the proof is not bound to release
        // context on-chain. If that binding is enforced later, invert this to
        // expect a revert.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeFundsOut(
            alternateRecipient,
            releaseAmount,
            releaseAmount,
            0,
            alternateBurnId,
            alternateSourceChainId,
            alternateDestinationChainId,
            alternateSourceAddress
        );

        vm.prank(multisig);
        _fundsOut(
            alternateRecipient,
            releaseAmount,
            alternateBurnId,
            alternateSourceChainId,
            alternateDestinationChainId,
            alternateSourceAddress,
            _proof(),
            _settlement(_singleFundsInId())
        );

        assertTrue(bridge.consumedBurnIds(alternateBurnId), 'burn id consumed');
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore - releaseAmount, 'bridge debit');
        assertEq(usdt0.balanceOf(alternateRecipient), recipientBefore + releaseAmount, 'recipient credited');
        assertEq(rgbModule.fundsInRecords(TX_ID), recordBefore - releaseAmount, 'record residual');
    }

    function test_operationIdPreemptionBlocksVictimRgbDeposit_currentBehavior() public {
        address preemptor = makeAddr('operationIdPreemptor');
        uint256 predictedOperationId = TX_ID + 9_000;
        uint256 preemptAmount = 25e18;

        usdt0.mint(preemptor, preemptAmount);
        vm.prank(preemptor);
        usdt0.approve(address(bridge), preemptAmount);

        uint256 preemptorBefore = usdt0.balanceOf(preemptor);
        uint256 victimBefore = usdt0.balanceOf(user);
        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 recordBefore = rgbModule.fundsInRecords(predictedOperationId);

        assertEq(preemptorBefore, preemptAmount, 'pre preemptor token');
        assertEq(recordBefore, 0, 'pre predicted record');

        // Current behavior: operationId uniqueness is enforced only by the
        // settlement record. A different address can occupy a predicted id
        // first, but doing so locks that address's own USDT0 in the Bridge.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit FundsIn(preemptor, predictedOperationId, preemptAmount);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeFundsIn(
            preemptor,
            predictedOperationId,
            preemptAmount,
            preemptAmount,
            0,
            0,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        vm.prank(preemptor);
        bridge.fundsIn(preemptAmount, RGB_CHAIN_ID, DST_ADDR, predictedOperationId, '');

        uint256 bridgeAfterPreempt = usdt0.balanceOf(address(bridge));
        uint256 recordAfterPreempt = rgbModule.fundsInRecords(predictedOperationId);

        assertEq(usdt0.balanceOf(preemptor), preemptorBefore - preemptAmount, 'preemptor funds locked');
        assertEq(bridgeAfterPreempt, bridgeBefore + preemptAmount, 'bridge credited by preemptor');
        assertEq(recordAfterPreempt, recordBefore + preemptAmount, 'record occupied');

        vm.expectRevert(RgbSettlementModule.DuplicateOperationId.selector);
        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, predictedOperationId, '');

        assertEq(usdt0.balanceOf(user), victimBefore, 'victim token unchanged');
        assertEq(usdt0.balanceOf(address(bridge)), bridgeAfterPreempt, 'bridge unchanged after victim revert');
        assertEq(rgbModule.fundsInRecords(predictedOperationId), recordAfterPreempt, 'preempted record unchanged');
    }

    // Bridge calls the settlement hook after pulling gross funds but before
    // forwarding token commission, so a hook that reads Bridge's raw balance
    // sees funds that will not remain as Bridge liquidity after the call.
    function test_onFundsInHookSeesBalanceIncludingFutureCommission_currentBehavior() public {
        uint256 percent = 400; // 4%
        _setFundsInTokenRule(percent);

        (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount) =
            cm.calculateFundsInCommission(SOURCE_CHAIN_ID, RGB_CHAIN_ID, address(usdt0), AMOUNT);
        assertGt(tokenCommission, 0, 'token fee quoted');
        assertEq(nativeCommission, 0, 'native fee is zero');

        MockSettlementModule observingModule = new MockSettlementModule();
        observingModule.setFundsInBalanceProbe(address(usdt0), address(bridge));

        vm.prank(deployer);
        routeRegistry.setRoute(
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            true,
            address(rgbVerifier),
            address(observingModule)
        );

        uint256 bridgeBefore = usdt0.balanceOf(address(bridge));
        uint256 cmBefore = usdt0.balanceOf(address(cm));
        uint256 cmPoolBefore = cm.tokenCommissionPool(address(usdt0));

        assertEq(bridgeBefore, 0, 'pre bridge token');
        assertEq(cmBefore, 0, 'pre cm token');
        assertEq(cmPoolBefore, 0, 'pre cm pool');

        vm.expectEmit(true, false, false, true, address(bridge));
        emit FundsIn(user, TX_ID + 10_000, netAmount);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeFundsIn(
            user,
            TX_ID + 10_000,
            AMOUNT,
            netAmount,
            tokenCommission,
            nativeCommission,
            SOURCE_CHAIN_ID,
            RGB_CHAIN_ID,
            DST_ADDR
        );

        vm.prank(user);
        bridge.fundsIn(AMOUNT, RGB_CHAIN_ID, DST_ADDR, TX_ID + 10_000, '');

        assertEq(observingModule.onFundsInCount(), 1, 'module called once');
        assertEq(observingModule.lastNetAmount(), netAmount, 'module got net amount');
        assertEq(
            observingModule.lastObservedBalanceOnFundsIn(),
            bridgeBefore + AMOUNT,
            'hook saw gross bridge balance'
        );
        assertEq(usdt0.balanceOf(address(bridge)), bridgeBefore + netAmount, 'final bridge net');
        assertEq(usdt0.balanceOf(address(cm)), cmBefore + tokenCommission, 'cm token delta');
        assertEq(cm.tokenCommissionPool(address(usdt0)), cmPoolBefore + tokenCommission, 'cm pool delta');
    }
}
