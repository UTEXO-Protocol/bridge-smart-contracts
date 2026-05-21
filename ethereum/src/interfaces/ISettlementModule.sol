// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { FundsInContext, FundsOutContext } from './RouteTypes.sol';

/// @title ISettlementModule
/// @notice Pluggable, route-specific accounting / state module consumed by
///         `RouteRegistry.onFundsIn` and `RouteRegistry.beforeFundsOut`.
///         Owns any storage that varies per source chain.
///
/// @dev Modules MUST gate their write-paths to `onlyRouteRegistry`. The
///      module's deployment is paired with exactly one `RouteRegistry`
///      instance, and authorisation is enforced via an immutable in the
///      module's constructor. Bridge never calls the module directly.
///
///      Routes that need no per-route state SHOULD register a
///      `NullSettlementModule`. Leaving the slot empty (`address(0)`) is
///      forbidden by `RouteRegistry` — the trust-model decision must be
///      explicit and visible on-chain.
///
///      The `settlementData` blob is opaque to Bridge / `RouteRegistry`;
///      each module owns its own decoding rules. For the RGB-route module
///      this would typically be `abi.encode(uint256[] fundsInIds)`.
interface ISettlementModule {
    /// @notice Hook invoked by `RouteRegistry.onFundsIn` after Bridge has
    ///         pulled the tokens and forwarded commission. The module records
    ///         (or otherwise reacts to) the new inbound deposit.
    /// @param ctx            Canonical fundsIn context built by Bridge.
    /// @param settlementData Opaque per-route data supplied by the caller;
    ///                       layout defined by the module itself.
    function onFundsIn(FundsInContext calldata ctx, bytes calldata settlementData) external;

    /// @notice Hook invoked by `RouteRegistry.beforeFundsOut` *before* Bridge
    ///         releases funds. The module performs any route-specific state
    ///         updates needed to authorise the release (e.g. consumes the
    ///         referenced RGB `fundsInIds`). Reverts if the release is not
    ///         valid for this module's accounting view.
    /// @param ctx            Canonical fundsOut context built by Bridge.
    /// @param settlementData Opaque per-route data supplied by the caller;
    ///                       layout defined by the module itself.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata settlementData) external;
}
