// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IRouteRegistry} from "./interfaces/IRouteRegistry.sol";
import {IFinalityVerifier} from "./interfaces/IFinalityVerifier.sol";
import {ISettlementModule} from "./interfaces/ISettlementModule.sol";
import {FundsInContext, FundsOutContext, RouteConfig} from "./interfaces/RouteTypes.sol";

/// @title RouteRegistry
/// @notice Stores route configuration and dispatches Bridge calls to plugins.
/// @dev Paired with one immutable Bridge. The owner manages routes; dispatch to disabled
///      or unset routes reverts. `getRoute` returns stored configuration without this check.
///      Release verification runs before the settlement hook.
contract RouteRegistry is IRouteRegistry, Ownable2Step {
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

    /// @notice Bridge authorized to call this registry's dispatchers.
    address public immutable override bridge;

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

    /// @param bridge_                Bridge deployment this registry serves. Must be non-zero.
    /// @param owner_                 Initial owner of the registry.
    constructor(address bridge_, address owner_) Ownable(owner_) {
        if (bridge_ == address(0)) revert InvalidBridge();
        bridge = bridge_;
    }

    // =========================================================================
    // Owner-only: route administration
    // =========================================================================

    /// @inheritdoc IRouteRegistry
    function setRoute(
        uint256 sourceChainId,
        uint256 destChainId,
        bool enabled,
        address finalityVerifier,
        address settlementModule
    ) external override onlyOwner {
        if (finalityVerifier == address(0)) revert ZeroFinalityVerifier();
        if (settlementModule == address(0)) revert ZeroSettlementModule();
        if (finalityVerifier.code.length == 0) revert InvalidFinalityVerifier(finalityVerifier);
        if (settlementModule.code.length == 0) revert InvalidSettlementModule(settlementModule);

        _routes[_routeKey(sourceChainId, destChainId)] =
            RouteConfig({enabled: enabled, finalityVerifier: finalityVerifier, settlementModule: settlementModule});

        emit RouteSet(sourceChainId, destChainId, enabled, finalityVerifier, settlementModule);
    }

    /// @notice Always reverts; ownership cannot be renounced.
    function renounceOwnership() public view override(Ownable) onlyOwner {
        revert RenounceOwnershipBlocked();
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @inheritdoc IRouteRegistry
    function getRoute(uint256 sourceChainId, uint256 destChainId) external view override returns (RouteConfig memory) {
        return _routes[_routeKey(sourceChainId, destChainId)];
    }

    // =========================================================================
    // Bridge-facing dispatchers
    // =========================================================================

    /// @inheritdoc IRouteRegistry
    function usesRgbMintDepositId(uint256 sourceChainId, uint256 destChainId)
        external
        view
        override
        onlyBridge
        returns (bool)
    {
        RouteConfig memory route = _routes[_routeKey(sourceChainId, destChainId)];
        if (!route.enabled) revert RouteNotEnabled(sourceChainId, destChainId);
        if (destChainId == block.chainid) return false;
        return ISettlementModule(route.settlementModule).usesRgbMintDepositId();
    }

    /// @inheritdoc IRouteRegistry
    function onFundsIn(FundsInContext calldata ctx, bytes calldata settlementData)
        external
        override
        onlyBridge
        returns (uint256 externalId)
    {
        RouteConfig memory route = _routes[_routeKey(ctx.sourceChainId, ctx.destChainId)];
        if (!route.enabled) revert RouteNotEnabled(ctx.sourceChainId, ctx.destChainId);

        return ISettlementModule(route.settlementModule).onFundsIn(ctx, settlementData);
    }

    /// @inheritdoc IRouteRegistry
    /// @dev Verifier runs first (view-only finality check). A reverting
    ///      verifier short-circuits the settlement-module call so no state
    ///      mutation happens unless finality is proven.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata proof, bytes calldata settlementData)
        external
        override
        onlyBridge
    {
        RouteConfig memory route = _routes[_routeKey(ctx.sourceChainId, ctx.destChainId)];
        if (!route.enabled) revert RouteNotEnabled(ctx.sourceChainId, ctx.destChainId);

        IFinalityVerifier(route.finalityVerifier).verify(ctx, proof);
        ISettlementModule(route.settlementModule).beforeFundsOut(ctx, settlementData);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Hashes the ABI-encoded source and destination chain ids.
    function _routeKey(uint256 sourceChainId, uint256 destChainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(sourceChainId, destChainId));
    }
}
