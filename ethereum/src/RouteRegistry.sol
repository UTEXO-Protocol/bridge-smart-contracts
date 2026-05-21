// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';

import { IRouteRegistry }    from './interfaces/IRouteRegistry.sol';
import { IFinalityVerifier } from './interfaces/IFinalityVerifier.sol';
import { ISettlementModule } from './interfaces/ISettlementModule.sol';
import {
    FundsInContext,
    FundsOutContext,
    RouteConfig
} from './interfaces/RouteTypes.sol';

/// @title RouteRegistry
/// @notice Bridge directory of routes and their plugin implementations.
///         Bound to one Bridge at deploy time; owned by `MultisigProxy` in
///         production so all route changes are timelocked federation ops.
///
/// @dev Storage layout: `_routes[keccak256(abi.encode(sourceChainId, destChainId))]`
///      → `RouteConfig`. Unset routes default to the zero struct
///      (`enabled == false`), so any dispatcher call against a never-configured
///      route reverts cleanly with `RouteNotEnabled`.
///
///      Plugin call ordering inside `beforeFundsOut` is fixed:
///        1. `IFinalityVerifier.verify(ctx, proof)`    — view-only;
///        2. `ISettlementModule.beforeFundsOut(ctx, settlementData)` — mutates.
///
///      The registry rejects `address(0)` for either plugin slot in
///      `setRoute`. Routes that intentionally need no source-side proof or
///      no per-route state register an explicit `NullVerifier` /
///      `NullSettlementModule` deployment — the trust-model decision is then
///      auditable on-chain rather than hidden behind an empty slot.
///
///      `renounceOwnership` is permanently blocked.
contract RouteRegistry is IRouteRegistry, Ownable {
    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Constructor was called with `bridge == address(0)`.
    error InvalidBridge();

    /// @notice `renounceOwnership` is blocked to avoid orphaning the
    ///         registry from federation governance.
    error RenounceOwnershipBlocked();

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice The Bridge instance this registry serves. Authorised caller
    ///         of `onFundsIn` and `beforeFundsOut`.
    address public immutable bridge;

    /// @dev Route table keyed by `keccak256(abi.encode(sourceChainId, destChainId))`.
    ///      Accessed externally via `getRoute(...)` (see `IRouteRegistry`).
    mapping(bytes32 routeKey => RouteConfig) internal _routes;

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyBridge() {
        if (msg.sender != bridge) revert NotBridge();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param bridge_ Bridge deployment this registry serves. Must be non-zero.
    /// @param owner_  Initial owner of the registry.
    constructor(address bridge_, address owner_) Ownable(owner_) {
        if (bridge_ == address(0)) revert InvalidBridge();
        bridge = bridge_;
    }

    // =========================================================================
    // Owner-only: route administration
    // =========================================================================

    /// @notice Adds or updates a route. Plugin slots MUST be non-zero —
    ///         use explicit `NullVerifier` / `NullSettlementModule`
    ///         deployments when a route deliberately opts out of a layer.
    ///         Federation can pause a route in place by setting
    ///         `enabled = false`; the plugin references stay registered
    ///         and can be re-enabled with a follow-up call.
    /// @param sourceChainId    Source chain id of the route key.
    /// @param destChainId      Destination chain id of the route key.
    /// @param enabled          New `enabled` flag.
    /// @param finalityVerifier Verifier contract for this route.
    /// @param settlementModule Settlement module contract for this route.
    function setRoute(
        uint256 sourceChainId,
        uint256 destChainId,
        bool    enabled,
        address finalityVerifier,
        address settlementModule
    ) external override onlyOwner {
        if (finalityVerifier == address(0)) revert ZeroFinalityVerifier();
        if (settlementModule == address(0)) revert ZeroSettlementModule();

        _routes[_routeKey(sourceChainId, destChainId)] = RouteConfig({
            enabled:          enabled,
            finalityVerifier: finalityVerifier,
            settlementModule: settlementModule
        });

        emit RouteSet(sourceChainId, destChainId, enabled, finalityVerifier, settlementModule);
    }

    /// @inheritdoc Ownable
    /// @dev Permanently blocked — the registry would otherwise be orphaned
    ///      from any future federation governance action.
    function renounceOwnership() public view override(Ownable) onlyOwner {
        revert RenounceOwnershipBlocked();
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @inheritdoc IRouteRegistry
    function getRoute(uint256 sourceChainId, uint256 destChainId)
        external
        view
        override
        returns (RouteConfig memory)
    {
        return _routes[_routeKey(sourceChainId, destChainId)];
    }

    // =========================================================================
    // Bridge-facing dispatchers
    // =========================================================================

    /// @inheritdoc IRouteRegistry
    function onFundsIn(FundsInContext calldata ctx, bytes calldata settlementData)
        external
        override
        onlyBridge
    {
        RouteConfig memory route = _routes[_routeKey(ctx.sourceChainId, ctx.destChainId)];
        if (!route.enabled) revert RouteNotEnabled(ctx.sourceChainId, ctx.destChainId);

        ISettlementModule(route.settlementModule).onFundsIn(ctx, settlementData);
    }

    /// @inheritdoc IRouteRegistry
    /// @dev Verifier runs first (view-only finality check). A reverting
    ///      verifier short-circuits the settlement-module call so no state
    ///      mutation happens unless finality is proven.
    function beforeFundsOut(
        FundsOutContext calldata ctx,
        bytes            calldata proof,
        bytes            calldata settlementData
    ) external override onlyBridge {
        RouteConfig memory route = _routes[_routeKey(ctx.sourceChainId, ctx.destChainId)];
        if (!route.enabled) revert RouteNotEnabled(ctx.sourceChainId, ctx.destChainId);

        IFinalityVerifier(route.finalityVerifier).verify(ctx, proof);
        ISettlementModule(route.settlementModule).beforeFundsOut(ctx, settlementData);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Canonical route key derivation. Using `abi.encode` (not
    ///      `encodePacked`) keeps the hash collision-free for arbitrary
    ///      `uint256` inputs.
    function _routeKey(uint256 sourceChainId, uint256 destChainId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(sourceChainId, destChainId));
    }
}
