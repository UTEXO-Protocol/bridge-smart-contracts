// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { ISettlementModule } from '../interfaces/ISettlementModule.sol';
import { FundsInContext, FundsOutContext } from '../interfaces/RouteTypes.sol';

/// @title RgbSettlementModule
/// @notice `ISettlementModule` for the RGB → Arbitrum route. Owns the
///         per-route accounting that lets Bridge release funds against
///         previously recorded RGB deposits without ever discarding
///         residual liquidity.
///
/// @dev Storage layout:
///        `fundsInRecords[operationId] = netAmount` — the post-commission
///        amount that the user actually bridged for that deposit. The
///        backend keys outbound RGB → Arbitrum redemptions to one or more
///        of these `operationId`s, supplying them as `bytes settlementData`
///        on the fundsOut path.
///
///      Sequential, partial consumption: a fundsOut request consumes the
///      referenced records in supplied order. Each record is either:
///        - fully consumed and `delete`d, if its remaining balance is
///          smaller than the amount left to release, or
///        - partially consumed (decremented), leaving the residual under
///          the same `operationId` available for future redemptions.
///      A reverting record (`FundsInNotFound`) shortcuts the loop. A
///      shortfall after every record has been visited reverts
///      `FundsOutAmountExceedsFundsIn`.
///
///      Auth: `onFundsIn` / `beforeFundsOut` are gated on the immutable
///      `routeRegistry` address. Re-pointing at a different registry =
///      redeploy the module + rotate the route under federation governance.
///
///      `settlementData` layout:
///        - `onFundsIn`:  ignored (Bridge already supplies the canonical
///                        `operationId` / `netAmount` inside `ctx`).
///        - `beforeFundsOut`: `abi.encode(uint256[] fundsInIds)`.
///
///      This contract owns no tokens. Bridge keeps custody; the module
///      only mutates its own bookkeeping. Reverts here roll back the
///      surrounding `Bridge.fundsOut` call atomically.
contract RgbSettlementModule is ISettlementModule {
    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Constructor was called with `address(0)`.
    error InvalidRouteRegistry();

    /// @notice Caller is not the configured `RouteRegistry`.
    error NotRouteRegistry();

    /// @notice An `onFundsIn` call referenced an `operationId` that already
    ///         has a non-zero record. Re-using an `operationId` would
    ///         silently overwrite the previous net amount and is rejected.
    error DuplicateOperationId();

    /// @notice A `beforeFundsOut` call referenced an `operationId` whose
    ///         `fundsInRecords` slot is zero (either never recorded or
    ///         already fully consumed by a previous release).
    error FundsInNotFound(uint256 operationId);

    /// @notice The supplied `fundsInIds` did not cover the requested
    ///         release amount (sum of remaining records < amount).
    error FundsOutAmountExceedsFundsIn();

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice The `RouteRegistry` instance authorised to drive this module.
    ///         The pairing is fixed at deploy time.
    address public immutable routeRegistry;

    /// @notice `operationId → netAmount` ledger of RGB deposits available
    ///         for release. A zero value means "no liquidity under this
    ///         id" — either never recorded or already consumed in full.
    mapping(uint256 operationId => uint256 netAmount) public fundsInRecords;

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyRouteRegistry() {
        if (msg.sender != routeRegistry) revert NotRouteRegistry();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param routeRegistry_ The `RouteRegistry` deployment that will drive
    ///                       this module. Must be non-zero.
    constructor(address routeRegistry_) {
        if (routeRegistry_ == address(0)) revert InvalidRouteRegistry();
        routeRegistry = routeRegistry_;
    }

    // =========================================================================
    // ISettlementModule
    // =========================================================================

    /// @inheritdoc ISettlementModule
    /// @dev Records the post-commission `netAmount` for `ctx.operationId`.
    ///      Reverts `DuplicateOperationId` if a non-zero record already
    ///      exists under the same id. `settlementData` is ignored for this
    ///      module — the canonical fundsIn data is taken from `ctx`.
    function onFundsIn(FundsInContext calldata ctx, bytes calldata /* settlementData */)
        external
        override
        onlyRouteRegistry
    {
        if (fundsInRecords[ctx.operationId] != 0) revert DuplicateOperationId();
        fundsInRecords[ctx.operationId] = ctx.netAmount;
    }

    /// @inheritdoc ISettlementModule
    /// @dev Decodes `settlementData` as `(uint256[] fundsInIds)` and
    ///      consumes the referenced records sequentially.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata settlementData)
        external
        override
        onlyRouteRegistry
    {
        uint256[] memory fundsInIds = abi.decode(settlementData, (uint256[]));

        uint256 remaining = ctx.amount;
        for (uint256 i = 0; i < fundsInIds.length; i++) {
            uint256 recorded = fundsInRecords[fundsInIds[i]];
            if (recorded == 0) revert FundsInNotFound(fundsInIds[i]);

            if (recorded > remaining) {
                // Partial consumption — preserve the residual on the same
                // operationId for future redemptions.
                fundsInRecords[fundsInIds[i]] = recorded - remaining;
                remaining = 0;
                break;
            }

            // recorded <= remaining — consume the record fully.
            delete fundsInRecords[fundsInIds[i]];
            remaining -= recorded;

            if (remaining == 0) break;
        }
        if (remaining != 0) revert FundsOutAmountExceedsFundsIn();
    }
}
