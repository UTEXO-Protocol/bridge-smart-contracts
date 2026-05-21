// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test }    from 'forge-std/Test.sol';
import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';

import { RouteRegistry } from '../src/RouteRegistry.sol';
import { IRouteRegistry } from '../src/interfaces/IRouteRegistry.sol';
import {
    FundsInContext,
    FundsOutContext,
    RouteConfig
} from '../src/interfaces/RouteTypes.sol';

import { MockFinalityVerifier } from './mocks/MockFinalityVerifier.sol';
import { MockSettlementModule } from './mocks/MockSettlementModule.sol';

/// @title RouteRegistryTest
/// @notice Unit tests for the route directory + dispatcher. The Bridge is
///         simulated via `vm.prank(bridge)`; verifier / module are real
///         test stubs (mocks) so the dispatch path is exercised end-to-end.
contract RouteRegistryTest is Test {
    // Events re-declared for vm.expectEmit
    event RouteSet(
        uint256 indexed sourceChainId,
        uint256 indexed destChainId,
        bool            enabled,
        address         finalityVerifier,
        address         settlementModule
    );

    RouteRegistry         registry;
    MockFinalityVerifier  verifier;
    MockSettlementModule  module;

    address owner    = makeAddr('owner');
    address bridge   = makeAddr('bridge');
    address attacker = makeAddr('attacker');
    address user     = makeAddr('user');
    address recipient = makeAddr('recipient');
    address token    = makeAddr('token');

    uint256 constant SOURCE_CHAIN_ID = 1_000_001;  // RGB
    uint256 constant DEST_CHAIN_ID   = 42161;      // arbitrum
    uint256 constant OTHER_CHAIN_ID  = 8453;       // polygon

    function setUp() public {
        registry = new RouteRegistry(bridge, owner);
        verifier = new MockFinalityVerifier();
        module   = new MockSettlementModule();
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    function _registerHappyRoute() internal {
        vm.prank(owner);
        registry.setRoute(
            SOURCE_CHAIN_ID,
            DEST_CHAIN_ID,
            true,
            address(verifier),
            address(module)
        );
    }

    function _fundsInCtx() internal view returns (FundsInContext memory) {
        return FundsInContext({
            token:         token,
            sender:        user,
            grossAmount:   100e18,
            netAmount:     95e18,
            operationId:   42,
            sourceChainId: SOURCE_CHAIN_ID,
            destChainId:   DEST_CHAIN_ID,
            destAddress:   'rgb:asset/utxo1abc'
        });
    }

    function _fundsOutCtx() internal view returns (FundsOutContext memory) {
        return FundsOutContext({
            token:         token,
            recipient:     recipient,
            amount:        95e18,
            burnId:        9_001,
            sourceChainId: SOURCE_CHAIN_ID,
            destChainId:   DEST_CHAIN_ID,
            sourceAddress: 'rgb:sender/utxo1src'
        });
    }

    // ========================================================================
    // Constructor
    // ========================================================================

    function test_constructor_storesBridge() public view {
        assertEq(registry.bridge(), bridge);
    }

    function test_constructor_setsOwner() public view {
        assertEq(registry.owner(), owner);
    }

    function test_constructor_revertsOnZeroBridge() public {
        vm.expectRevert(RouteRegistry.InvalidBridge.selector);
        new RouteRegistry(address(0), owner);
    }

    function test_constructor_revertsOnZeroOwner() public {
        // OZ Ownable v5 throws OwnableInvalidOwner(0) on a zero initial owner.
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0))
        );
        new RouteRegistry(bridge, address(0));
    }

    // ========================================================================
    // setRoute
    // ========================================================================

    function test_setRoute_addsRouteAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit RouteSet(SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(verifier), address(module));

        vm.prank(owner);
        registry.setRoute(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(verifier), address(module)
        );

        RouteConfig memory cfg = registry.getRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID);
        assertTrue(cfg.enabled);
        assertEq(cfg.finalityVerifier, address(verifier));
        assertEq(cfg.settlementModule, address(module));
    }

    function test_setRoute_updatesExistingRoute() public {
        _registerHappyRoute();

        MockFinalityVerifier newVerifier = new MockFinalityVerifier();
        MockSettlementModule newModule   = new MockSettlementModule();

        vm.prank(owner);
        registry.setRoute(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, false, address(newVerifier), address(newModule)
        );

        RouteConfig memory cfg = registry.getRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID);
        assertFalse(cfg.enabled, 'paused');
        assertEq(cfg.finalityVerifier, address(newVerifier), 'verifier rotated');
        assertEq(cfg.settlementModule, address(newModule),   'module rotated');
    }

    function test_setRoute_revertsOnZeroVerifier() public {
        vm.prank(owner);
        vm.expectRevert(IRouteRegistry.ZeroFinalityVerifier.selector);
        registry.setRoute(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(0), address(module)
        );
    }

    function test_setRoute_revertsOnZeroModule() public {
        vm.prank(owner);
        vm.expectRevert(IRouteRegistry.ZeroSettlementModule.selector);
        registry.setRoute(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(verifier), address(0)
        );
    }

    function test_setRoute_revertsIfNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        registry.setRoute(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(verifier), address(module)
        );
    }

    // ========================================================================
    // getRoute
    // ========================================================================

    function test_getRoute_unsetReturnsZeroStruct() public view {
        RouteConfig memory cfg = registry.getRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID);
        assertFalse(cfg.enabled);
        assertEq(cfg.finalityVerifier, address(0));
        assertEq(cfg.settlementModule, address(0));
    }

    function test_getRoute_setReturnsConfiguredValues() public {
        _registerHappyRoute();
        RouteConfig memory cfg = registry.getRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID);
        assertTrue(cfg.enabled);
        assertEq(cfg.finalityVerifier, address(verifier));
        assertEq(cfg.settlementModule, address(module));
    }

    // ========================================================================
    // onFundsIn
    // ========================================================================

    function test_onFundsIn_dispatchesToModule() public {
        _registerHappyRoute();

        vm.prank(bridge);
        registry.onFundsIn(_fundsInCtx(), abi.encode('hello'));

        assertEq(module.onFundsInCount(),     1, 'module called once');
        assertEq(module.lastSender(),         user);
        assertEq(module.lastOperationId(),    42);
        assertEq(module.lastNetAmount(),      95e18);
        assertEq(module.lastSettlementData(), abi.encode('hello'));
    }

    function test_onFundsIn_revertsIfNotBridge() public {
        _registerHappyRoute();

        vm.prank(attacker);
        vm.expectRevert(IRouteRegistry.NotBridge.selector);
        registry.onFundsIn(_fundsInCtx(), '');
    }

    function test_onFundsIn_revertsOnUnsetRoute() public {
        // Never called setRoute.
        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, DEST_CHAIN_ID
            )
        );
        registry.onFundsIn(_fundsInCtx(), '');
    }

    function test_onFundsIn_revertsOnDisabledRoute() public {
        // Register a disabled route (enabled = false).
        vm.prank(owner);
        registry.setRoute(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, false, address(verifier), address(module)
        );

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, DEST_CHAIN_ID
            )
        );
        registry.onFundsIn(_fundsInCtx(), '');
    }

    function test_onFundsIn_routeKeyIncludesBothChainIds() public {
        // Route registered ONLY for (SOURCE, DEST). A ctx with (SOURCE, OTHER)
        // must NOT match — otherwise the route key collapses to source-only,
        // which would be a critical correctness bug.
        _registerHappyRoute();

        FundsInContext memory ctx = _fundsInCtx();
        ctx.destChainId = OTHER_CHAIN_ID;

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, OTHER_CHAIN_ID
            )
        );
        registry.onFundsIn(ctx, '');
    }

    // ========================================================================
    // beforeFundsOut
    // ========================================================================

    function test_beforeFundsOut_dispatchesToVerifierAndModule() public {
        _registerHappyRoute();

        vm.prank(bridge);
        registry.beforeFundsOut(_fundsOutCtx(), abi.encode('proof'), abi.encode('settlement'));

        // Verifier is view → can't record counts. Module proves the dispatch
        // reached step 2, which by code path means step 1 (verify) also ran.
        assertEq(module.beforeFundsOutCount(),  1);
        assertEq(module.lastRecipient(),        recipient);
        assertEq(module.lastAmount(),           95e18);
        assertEq(module.lastBurnId(),           9_001);
        assertEq(module.lastSettlementData(),   abi.encode('settlement'));
    }

    function test_beforeFundsOut_verifierRevertShortCircuitsModule() public {
        _registerHappyRoute();
        verifier.setShouldRevert(true);

        vm.prank(bridge);
        vm.expectRevert(MockFinalityVerifier.MockVerifierForcedRevert.selector);
        registry.beforeFundsOut(_fundsOutCtx(), '', '');

        // Module must NOT have been called.
        assertEq(module.beforeFundsOutCount(), 0, 'module skipped on verifier revert');
    }

    function test_beforeFundsOut_propagatesModuleRevert() public {
        _registerHappyRoute();
        module.setShouldRevertOnBeforeFundsOut(true);

        vm.prank(bridge);
        vm.expectRevert(MockSettlementModule.MockModuleForcedRevert.selector);
        registry.beforeFundsOut(_fundsOutCtx(), '', '');
    }

    function test_beforeFundsOut_revertsIfNotBridge() public {
        _registerHappyRoute();

        vm.prank(attacker);
        vm.expectRevert(IRouteRegistry.NotBridge.selector);
        registry.beforeFundsOut(_fundsOutCtx(), '', '');
    }

    function test_beforeFundsOut_revertsOnUnsetRoute() public {
        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, DEST_CHAIN_ID
            )
        );
        registry.beforeFundsOut(_fundsOutCtx(), '', '');
    }

    function test_beforeFundsOut_revertsOnDisabledRoute() public {
        vm.prank(owner);
        registry.setRoute(
            SOURCE_CHAIN_ID, DEST_CHAIN_ID, false, address(verifier), address(module)
        );

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, DEST_CHAIN_ID
            )
        );
        registry.beforeFundsOut(_fundsOutCtx(), '', '');
    }

    // ========================================================================
    // renounceOwnership
    // ========================================================================

    function test_renounceOwnership_blocked() public {
        vm.prank(owner);
        vm.expectRevert(RouteRegistry.RenounceOwnershipBlocked.selector);
        registry.renounceOwnership();
    }

    function test_renounceOwnership_revertsIfNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        registry.renounceOwnership();
    }
}
