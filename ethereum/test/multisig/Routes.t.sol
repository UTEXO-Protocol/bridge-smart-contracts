// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {RouteRegistry} from "../../src/RouteRegistry.sol";
import {IBridge} from "../../src/interfaces/IBridge.sol";
import {IMultisigProxy} from "../../src/interfaces/IMultisigProxy.sol";
import {IRouteRegistry} from "../../src/interfaces/IRouteRegistry.sol";
import {RouteConfig} from "../../src/interfaces/RouteTypes.sol";
import {RgbSettlementModule} from "../../src/settlement/RgbSettlementModule.sol";
import {MultisigHelper} from "../helpers/MultisigHelper.sol";
import {MultisigProxyTestBase} from "./MultisigProxyTestBase.sol";

/// @notice Route and registry proposals dispatch through the current Bridge.
contract MultisigRoutesTest is MultisigProxyTestBase {
    uint256 private constant NEW_SOURCE_CHAIN_ID = 1234;

    uint256 private constant NEW_DESTINATION_CHAIN_ID = 5678;

    uint256 private constant MISMATCHED_DESTINATION_CHAIN_ID = 9999;

    function _proposeSetRoute(uint256 srcId, uint256 dstId, bool enabled, address verifier, address module)
        private
        returns (bytes32 id)
    {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest = MultisigHelper.digestProposeSetRoute(
            domainSep, IBridge(proxy.bridge()).routeRegistry(), srcId, dstId, enabled, verifier, module, nonce, deadline
        );
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        id = proxy.proposeSetRoute(srcId, dstId, enabled, verifier, module, nonce, deadline, bitmap, sigs);
    }

    function _proposeUpdateRouteRegistry(address newRegistry) private returns (bytes32 id) {
        uint256 nonce = proxy.proposalNonce();
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes32 digest =
            MultisigHelper.digestProposeUpdateRouteRegistry(domainSep, proxy.bridge(), newRegistry, nonce, deadline);
        (uint256[] memory pks, uint256 bitmap) = _fedSigSet2of3();
        bytes[] memory sigs = MultisigHelper.signAll(vm, digest, pks);
        id = proxy.proposeUpdateRouteRegistry(newRegistry, nonce, deadline, bitmap, sigs);
    }

    function test_proposeSetRoute_addsBrandNewRoute() public {
        // Register a previously unconfigured route via governance.
        uint256 newSrc = NEW_SOURCE_CHAIN_ID;
        uint256 newDst = NEW_DESTINATION_CHAIN_ID;
        bytes32 id = _proposeSetRoute(newSrc, newDst, true, address(rgbVerifier), address(rgbModule));

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectEmit(true, true, false, true, address(routeRegistry));
        emit IRouteRegistry.RouteSet(newSrc, newDst, true, address(rgbVerifier), address(rgbModule));

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

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
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

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        proxy.executeProposal(
            id, abi.encode(RGB_CHAIN_ID, SOURCE_CHAIN_ID, false, address(rgbVerifier), address(rgbModule))
        );

        RouteConfig memory cfg = routeRegistry.getRoute(RGB_CHAIN_ID, SOURCE_CHAIN_ID);
        assertFalse(cfg.enabled, "route paused");
        assertEq(cfg.finalityVerifier, address(rgbVerifier), "verifier kept");
        assertEq(cfg.settlementModule, address(rgbModule), "module kept");
    }

    function test_proposeSetRoute_revertsOnZeroVerifier() public {
        bytes32 id =
            _proposeSetRoute(NEW_SOURCE_CHAIN_ID, NEW_DESTINATION_CHAIN_ID, true, address(0), address(rgbModule));

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        // Registry guard: ZeroFinalityVerifier propagates up through proxy.
        vm.expectRevert(IRouteRegistry.ZeroFinalityVerifier.selector);
        proxy.executeProposal(
            id, abi.encode(NEW_SOURCE_CHAIN_ID, NEW_DESTINATION_CHAIN_ID, true, address(0), address(rgbModule))
        );
    }

    function test_proposeSetRoute_revertsOnDataMismatch() public {
        bytes32 id = _proposeSetRoute(
            NEW_SOURCE_CHAIN_ID, NEW_DESTINATION_CHAIN_ID, true, address(rgbVerifier), address(rgbModule)
        );

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        // Wrong destChainId in opData.
        proxy.executeProposal(
            id,
            abi.encode(
                NEW_SOURCE_CHAIN_ID, MISMATCHED_DESTINATION_CHAIN_ID, true, address(rgbVerifier), address(rgbModule)
            )
        );
    }

    function test_proposeUpdateRouteRegistry_rotatesBridgePointer() public {
        // Deploy a NEW registry, owned by proxy, paired with the same Bridge.
        // In production the new registry's `bridge` immutable MUST match the
        // live Bridge — otherwise dispatcher calls revert NotBridge.
        RouteRegistry newRegistry = new RouteRegistry(address(bridge), address(proxy));

        bytes32 id = _proposeUpdateRouteRegistry(address(newRegistry));

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit IBridge.RouteRegistryUpdated(address(routeRegistry), address(newRegistry));

        proxy.executeProposal(id, abi.encode(address(newRegistry)));
        assertEq(bridge.routeRegistry(), address(newRegistry));
    }

    function test_proposeUpdateRouteRegistry_revertsOnZero() public {
        // Bridge.setRouteRegistry rejects zero; the error propagates through
        // the proposal's bound target.
        bytes32 id = _proposeUpdateRouteRegistry(address(0));

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(IBridge.InvalidRouteRegistryAddress.selector);
        proxy.executeProposal(id, abi.encode(address(0)));
    }

    function test_proposeUpdateRouteRegistry_revertsOnDataMismatch() public {
        address bogus = makeAddr("bogus");
        bytes32 id = _proposeUpdateRouteRegistry(bogus);

        vm.warp(vm.getBlockTimestamp() + TIMELOCK + 1);
        vm.expectRevert(IMultisigProxy.DataMismatch.selector);
        proxy.executeProposal(id, abi.encode(makeAddr("different")));
    }
}
