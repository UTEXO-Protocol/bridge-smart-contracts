// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { FundsInContext, FundsOutContext, RouteConfig } from './RouteTypes.sol';

/// @title IRouteRegistry
/// @notice Per-Bridge directory of routes and their plugin implementations.
///         Owns the `(sourceChainId, destChainId) → (verifier, settlementModule)`
///         mapping and is the only contract Bridge talks to when handling
///         route-specific verification or accounting.
///
/// @dev Lifecycle:
///        - Deployed once per Bridge instance and bound to it via an
///          immutable `bridge` address. The registry only accepts dispatcher
///          calls (`onFundsIn` / `beforeFundsOut`) from that address.
///        - Owned by `MultisigProxy`. Federation-governed setters add /
///          update / disable routes; there is no direct EOA admin path.
///        - Plugins (`IFinalityVerifier`, `ISettlementModule`) are external
///          contracts; the registry must reject `address(0)` for either slot
///          so that the trust-model decision is explicit on-chain (use the
///          `NullVerifier` / `NullSettlementModule` for routes that
///          deliberately omit a layer).
///
///      Plugin call ordering inside `beforeFundsOut` is fixed by this
///      interface: **verifier first** (view-only finality check), settlement
///      module **second** (state mutation). A reverting verifier shortcuts
///      the settlement-module call.
interface IRouteRegistry {
    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Caller is not the configured Bridge instance.
    error NotBridge();

    /// @notice The requested route is not present or has `enabled == false`.
    error RouteNotEnabled(uint256 sourceChainId, uint256 destChainId);

    /// @notice `finalityVerifier` was passed as `address(0)`. Use the
    ///         explicit `NullVerifier` deployment instead.
    error ZeroFinalityVerifier();

    /// @notice `settlementModule` was passed as `address(0)`. Use the
    ///         explicit `NullSettlementModule` deployment instead.
    error ZeroSettlementModule();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted whenever a route's `RouteConfig` is created or updated.
    /// @param sourceChainId    Source chain id of the route key.
    /// @param destChainId      Destination chain id of the route key.
    /// @param enabled          New `enabled` flag.
    /// @param finalityVerifier Verifier contract for this route.
    /// @param settlementModule Settlement module contract for this route.
    event RouteSet(
        uint256 indexed sourceChainId,
        uint256 indexed destChainId,
        bool            enabled,
        address         finalityVerifier,
        address         settlementModule
    );

    // =========================================================================
    // Owner-only: route administration
    // =========================================================================

    /// @notice Adds or updates a route. Owner-only. Both plugin slots MUST be
    ///         non-zero — explicit `NullVerifier` / `NullSettlementModule`
    ///         deployments cover routes that deliberately opt out of a layer.
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
    ) external;

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Returns the current `RouteConfig` for the route key
    ///         `(sourceChainId, destChainId)`. Unset routes return the zero
    ///         struct (`enabled == false`).
    function getRoute(uint256 sourceChainId, uint256 destChainId)
        external
        view
        returns (RouteConfig memory);

    // =========================================================================
    // Bridge-facing dispatchers
    // =========================================================================

    /// @notice Forwards the inbound context to the settlement module of the
    ///         route `(ctx.sourceChainId, ctx.destChainId)`. Reverts if the
    ///         route is not enabled. Callable only by `bridge`.
    function onFundsIn(FundsInContext calldata ctx, bytes calldata settlementData) external;

    /// @notice Runs the verifier (view-only proof check) and then the
    ///         settlement module's `beforeFundsOut` hook, in that order, for
    ///         the route `(ctx.sourceChainId, ctx.destChainId)`. Reverts if
    ///         the route is not enabled. Callable only by `bridge`.
    function beforeFundsOut(
        FundsOutContext calldata ctx,
        bytes            calldata proof,
        bytes            calldata settlementData
    ) external;
}
