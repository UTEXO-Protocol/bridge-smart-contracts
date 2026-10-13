// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";
import {RouteRegistry} from "../../src/RouteRegistry.sol";
import {IRouteRegistry} from "../../src/interfaces/IRouteRegistry.sol";
import {FundsInContext, FundsOutContext, RouteConfig} from "../../src/interfaces/RouteTypes.sol";
import {MockFinalityVerifier} from "../mocks/MockFinalityVerifier.sol";
import {MockSettlementModule} from "../mocks/MockSettlementModule.sol";

/// @notice Route configuration and authenticated dispatch from the configured Bridge.
/// @dev Paired verifier and module errors distinguish verification from dispatch.
contract RouteRegistryTest is Test {
    bytes32 internal constant SRC_BURN_TX_ID = keccak256("unit-burn-tx");

    // Events re-declared for vm.expectEmit

    RouteRegistry internal registry;

    MockFinalityVerifier internal verifier;

    MockSettlementModule internal module;

    address internal owner = makeAddr("owner");

    address internal bridge = makeAddr("bridge");

    address internal attacker = makeAddr("attacker");

    address internal user = makeAddr("user");

    address internal recipient = makeAddr("recipient");

    address internal token = makeAddr("token");

    uint256 internal constant SOURCE_CHAIN_ID = 1_000_001;

    // RGB

    uint256 internal constant DEST_CHAIN_ID = 42161;

    // arbitrum

    uint256 internal constant OTHER_CHAIN_ID = 8453;

    // Base

    function setUp() public {
        registry = new RouteRegistry(bridge, owner);
        verifier = new MockFinalityVerifier();
        module = new MockSettlementModule();
    }

    function _registerHappyRoute() private {
        vm.prank(owner);
        registry.setRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(verifier), address(module));
    }

    function _fundsInCtx() private view returns (FundsInContext memory) {
        return FundsInContext({
            token: token,
            sender: user,
            sourceSender: bytes32(uint256(uint160(user))),
            grossAmount: 100e18,
            netAmount: 95e18,
            operationId: bytes32(uint256(42)),
            senderNonce: 0,
            sourceChainId: SOURCE_CHAIN_ID,
            destChainId: DEST_CHAIN_ID,
            destAddress: "rgb:asset/utxo1abc"
        });
    }

    function _fundsOutCtx() private view returns (FundsOutContext memory) {
        return FundsOutContext({
            token: token,
            recipient: recipient,
            amount: 95e18,
            burnId: 9_001,
            sourceChainId: SOURCE_CHAIN_ID,
            destChainId: DEST_CHAIN_ID,
            sourceAddress: "rgb:sender/utxo1src",
            isRebalance: false,
            sourceBurnTxId: SRC_BURN_TX_ID
        });
    }

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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new RouteRegistry(bridge, address(0));
    }

    function test_setRoute_addsRouteAndEmits() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit IRouteRegistry.RouteSet(SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(verifier), address(module));

        vm.prank(owner);
        registry.setRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(verifier), address(module));

        RouteConfig memory cfg = registry.getRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID);
        assertTrue(cfg.enabled);
        assertEq(cfg.finalityVerifier, address(verifier));
        assertEq(cfg.settlementModule, address(module));
    }

    function test_setRoute_updatesExistingRoute() public {
        _registerHappyRoute();

        MockFinalityVerifier newVerifier = new MockFinalityVerifier();
        MockSettlementModule newModule = new MockSettlementModule();

        vm.prank(owner);
        registry.setRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID, false, address(newVerifier), address(newModule));

        RouteConfig memory cfg = registry.getRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID);
        assertFalse(cfg.enabled, "paused");
        assertEq(cfg.finalityVerifier, address(newVerifier), "verifier rotated");
        assertEq(cfg.settlementModule, address(newModule), "module rotated");
    }

    function test_setRoute_revertsOnZeroVerifier() public {
        vm.prank(owner);
        vm.expectRevert(IRouteRegistry.ZeroFinalityVerifier.selector);
        registry.setRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(0), address(module));
    }

    function test_setRoute_revertsOnZeroModule() public {
        vm.prank(owner);
        vm.expectRevert(IRouteRegistry.ZeroSettlementModule.selector);
        registry.setRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(verifier), address(0));
    }

    function test_setRoute_revertsOnCodelessVerifier() public {
        address codelessVerifier = makeAddr("codelessVerifier");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IRouteRegistry.InvalidFinalityVerifier.selector, codelessVerifier));
        registry.setRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, codelessVerifier, address(module));
    }

    function test_setRoute_revertsOnCodelessModule() public {
        address codelessModule = makeAddr("codelessModule");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IRouteRegistry.InvalidSettlementModule.selector, codelessModule));
        registry.setRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(verifier), codelessModule);
    }

    function test_setRoute_revertsForNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        registry.setRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID, true, address(verifier), address(module));
    }

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

    function test_usesRgbMintDepositId_readsConfiguredModule() public {
        _registerHappyRoute();
        vm.prank(bridge);
        assertFalse(registry.usesRgbMintDepositId(SOURCE_CHAIN_ID, DEST_CHAIN_ID));
        module.setUsesRgbMintDepositId(true);
        vm.prank(bridge);
        assertTrue(registry.usesRgbMintDepositId(SOURCE_CHAIN_ID, DEST_CHAIN_ID));
    }

    function test_usesRgbMintDepositId_localEvmDestinationKeepsLegacyMode() public {
        module.setUsesRgbMintDepositId(true);
        vm.prank(owner);
        registry.setRoute(SOURCE_CHAIN_ID, block.chainid, true, address(verifier), address(module));
        vm.prank(bridge);
        assertFalse(registry.usesRgbMintDepositId(SOURCE_CHAIN_ID, block.chainid));
    }

    function test_usesRgbMintDepositId_revertsIfNotBridge() public {
        _registerHappyRoute();
        vm.expectRevert(IRouteRegistry.NotBridge.selector);
        vm.prank(attacker);
        registry.usesRgbMintDepositId(SOURCE_CHAIN_ID, DEST_CHAIN_ID);
    }

    function test_usesRgbMintDepositId_revertsOnUnsetAndDisabledRoutes() public {
        vm.expectRevert(abi.encodeWithSelector(IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, DEST_CHAIN_ID));
        vm.prank(bridge);
        registry.usesRgbMintDepositId(SOURCE_CHAIN_ID, DEST_CHAIN_ID);
        vm.prank(owner);
        registry.setRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID, false, address(verifier), address(module));
        vm.expectRevert(abi.encodeWithSelector(IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, DEST_CHAIN_ID));
        vm.prank(bridge);
        registry.usesRgbMintDepositId(SOURCE_CHAIN_ID, DEST_CHAIN_ID);
    }

    function test_onFundsIn_dispatchesToModule() public {
        _registerHappyRoute();

        vm.prank(bridge);
        registry.onFundsIn(_fundsInCtx(), abi.encode("hello"));

        assertEq(module.onFundsInCount(), 1, "module called once");
        assertEq(module.lastSender(), user);
        assertEq(module.lastOperationId(), bytes32(uint256(42)));
        assertEq(module.lastNetAmount(), 95e18);
        assertEq(module.lastSettlementData(), abi.encode("hello"));
    }

    function test_onFundsIn_revertsIfNotBridge() public {
        _registerHappyRoute();

        vm.prank(attacker);
        vm.expectRevert(IRouteRegistry.NotBridge.selector);
        registry.onFundsIn(_fundsInCtx(), "");
    }

    function test_onFundsIn_revertsOnUnsetRoute() public {
        // Never called setRoute.
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, DEST_CHAIN_ID));
        registry.onFundsIn(_fundsInCtx(), "");
    }

    function test_onFundsIn_revertsOnDisabledRoute() public {
        // Register a disabled route (enabled = false).
        vm.prank(owner);
        registry.setRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID, false, address(verifier), address(module));

        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, DEST_CHAIN_ID));
        registry.onFundsIn(_fundsInCtx(), "");
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
            abi.encodeWithSelector(IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, OTHER_CHAIN_ID)
        );
        registry.onFundsIn(ctx, "");
    }

    function test_beforeFundsOut_dispatchesToVerifierAndModule() public {
        _registerHappyRoute();

        vm.expectCall(
            address(verifier), abi.encodeCall(MockFinalityVerifier.verify, (_fundsOutCtx(), abi.encode("proof")))
        );
        vm.prank(bridge);
        registry.beforeFundsOut(_fundsOutCtx(), abi.encode("proof"), abi.encode("settlement"));

        assertEq(module.beforeFundsOutCount(), 1);
        assertEq(module.lastRecipient(), recipient);
        assertEq(module.lastAmount(), 95e18);
        assertEq(module.lastBurnId(), 9_001);
        assertEq(module.lastSettlementData(), abi.encode("settlement"));
    }

    function test_beforeFundsOut_verifierRevertShortCircuitsModule() public {
        _registerHappyRoute();
        verifier.setShouldRevert(true);
        // Different forced errors prove that the verifier is dispatched first.
        module.setShouldRevertOnBeforeFundsOut(true);

        vm.prank(bridge);
        vm.expectRevert(MockFinalityVerifier.MockVerifierForcedRevert.selector);
        registry.beforeFundsOut(_fundsOutCtx(), "", "");

        // No module writes persist after the verifier failure.
        assertEq(module.beforeFundsOutCount(), 0, "no module writes persist after revert");
    }

    function test_beforeFundsOut_propagatesModuleRevert() public {
        _registerHappyRoute();
        module.setShouldRevertOnBeforeFundsOut(true);

        vm.prank(bridge);
        vm.expectRevert(MockSettlementModule.MockModuleForcedRevert.selector);
        registry.beforeFundsOut(_fundsOutCtx(), "", "");
    }

    function test_beforeFundsOut_revertsIfNotBridge() public {
        _registerHappyRoute();

        vm.prank(attacker);
        vm.expectRevert(IRouteRegistry.NotBridge.selector);
        registry.beforeFundsOut(_fundsOutCtx(), "", "");
    }

    function test_beforeFundsOut_revertsOnUnsetRoute() public {
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, DEST_CHAIN_ID));
        registry.beforeFundsOut(_fundsOutCtx(), "", "");
    }

    function test_beforeFundsOut_revertsOnDisabledRoute() public {
        vm.prank(owner);
        registry.setRoute(SOURCE_CHAIN_ID, DEST_CHAIN_ID, false, address(verifier), address(module));

        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(IRouteRegistry.RouteNotEnabled.selector, SOURCE_CHAIN_ID, DEST_CHAIN_ID));
        registry.beforeFundsOut(_fundsOutCtx(), "", "");
    }

    function test_renounceOwnership_blocked() public {
        vm.prank(owner);
        vm.expectRevert(RouteRegistry.RenounceOwnershipBlocked.selector);
        registry.renounceOwnership();
    }

    function test_renounceOwnership_revertsForNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        registry.renounceOwnership();
    }
}
