// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {FundsInContext, FundsOutContext, RouteConfig} from "./RouteTypes.sol";

/// @title IRouteRegistry
/// @notice Route configuration and Bridge-only plugin dispatch.
/// @dev Each route requires deployed verifier and settlement contracts. Use explicit
///      Null plugins when omitting checks. Release verification precedes settlement.
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

    /// @notice `finalityVerifier` does not contain deployed contract code.
    error InvalidFinalityVerifier(address finalityVerifier);

    /// @notice `settlementModule` does not contain deployed contract code.
    error InvalidSettlementModule(address settlementModule);

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted whenever a route's `RouteConfig` is created or updated.
    /// @param sourceChainId          Source chain id of the route key.
    /// @param destChainId            Destination chain id of the route key.
    /// @param enabled                New `enabled` flag.
    /// @param finalityVerifier       Verifier contract for this route.
    /// @param settlementModule       Settlement module contract for this route.
    event RouteSet(
        uint256 indexed sourceChainId,
        uint256 indexed destChainId,
        bool enabled,
        address finalityVerifier,
        address settlementModule
    );

    // =========================================================================
    // Owner-only: route administration
    // =========================================================================

    /// @notice Adds or updates a route. Owner-only. Both plugin slots MUST point
    ///         to deployed contracts — explicit `NullVerifier` /
    ///         `NullSettlementModule` deployments cover routes that deliberately
    ///         opt out of a layer.
    /// @dev Plugin code checks also apply when disabling a route.
    /// @param sourceChainId          Source chain id of the route key.
    /// @param destChainId            Destination chain id of the route key.
    /// @param enabled                New `enabled` flag.
    /// @param finalityVerifier       Verifier contract for this route.
    /// @param settlementModule       Settlement module contract for this route.
    function setRoute(
        uint256 sourceChainId,
        uint256 destChainId,
        bool enabled,
        address finalityVerifier,
        address settlementModule
    ) external;

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Bridge deployment permanently paired with this registry.
    function bridge() external view returns (address);

    /// @notice Returns the current `RouteConfig` for the route key
    ///         `(sourceChainId, destChainId)`. Unset routes return the zero
    ///         struct (`enabled == false`).
    function getRoute(uint256 sourceChainId, uint256 destChainId) external view returns (RouteConfig memory);

    // =========================================================================
    // Bridge-facing dispatchers
    // =========================================================================

    /// @notice Returns the inbound identity mode of the configured route module.
    /// @dev Local EVM destinations always retain legacy identity, including
    ///      reverse routes that use an RGB ledger for withdrawal validation.
    ///      Callable only by Bridge. Unset or disabled routes revert, just as
    ///      they do at onFundsIn; no route-kind state is stored separately.
    function usesRgbMintDepositId(uint256 sourceChainId, uint256 destChainId) external view returns (bool);

    /// @notice Forwards the inbound context to the settlement module of the
    ///         route `(ctx.sourceChainId, ctx.destChainId)`. Reverts if the
    ///         route is not enabled. Callable only by `bridge`.
    /// @return externalId The settlement module's optional correlation id (see
    ///                    `ISettlementModule.onFundsIn`); forwarded to Bridge.
    function onFundsIn(FundsInContext calldata ctx, bytes calldata settlementData) external returns (uint256 externalId);

    /// @notice Runs the verifier (view-only proof check) and then the
    ///         settlement module's `beforeFundsOut` hook, in that order, for
    ///         the route `(ctx.sourceChainId, ctx.destChainId)`. Reverts if
    ///         the route is not enabled. Callable only by `bridge`.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata proof, bytes calldata settlementData) external;
}
