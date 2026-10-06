// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {FundsInContext, FundsOutContext} from "./RouteTypes.sol";

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
///      Each module owns its settlementData layout. For RGB inbound routes
///      Bridge also decodes abi.encode(uint256 rgbOpId) to derive the backing
///      id; release data encodes parallel operationId and amount arrays.
interface ISettlementModule {
    /// @notice Whether inbound records use the consignment-derived RGB mint id.
    /// @dev Bridge queries the configured module before deriving the id. Only
    ///      modules that write RGB mint records return true; other routes keep
    ///      their existing deposit or rebalance identity.
    function usesRgbMintDepositId() external view returns (bool);

    /// @notice Hook invoked by `RouteRegistry.onFundsIn` after Bridge has
    ///         pulled the tokens and forwarded commission. The module records
    ///         (or otherwise reacts to) the new inbound deposit.
    /// @param ctx            Canonical fundsIn context built by Bridge.
    /// @param settlementData Opaque per-route data supplied by the caller;
    ///                       layout defined by the module itself.
    /// @return externalId    Optional route-specific correlation id for Bridge's
    ///                       `FundsIn` event (the RGB OpId for the RGB route; `0`
    ///                       for modules that need none, so Bridge emits no
    ///                       `FundsIn`). NOT an on-chain dedup key — the
    ///                       canonical key is `ctx.operationId`.
    function onFundsIn(FundsInContext calldata ctx, bytes calldata settlementData) external returns (uint256 externalId);

    /// @notice Hook invoked by `RouteRegistry.beforeFundsOut` before a physical
    ///         Bridge release or the debit leg of an accounting-only rebalance.
    ///         The module performs any route-specific validation or state
    ///         updates needed to authorise the operation. `ctx.isRebalance`
    ///         distinguishes the two authenticated Bridge call sites.
    /// @param ctx            Canonical fundsOut context built by Bridge.
    /// @param settlementData Opaque per-route data supplied by the caller;
    ///                       layout defined by the module itself.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata settlementData) external;
}
