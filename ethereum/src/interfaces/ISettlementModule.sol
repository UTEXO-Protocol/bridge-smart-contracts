// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {FundsInContext, FundsOutContext} from "./RouteTypes.sol";

/// @title ISettlementModule
/// @notice Route-specific settlement hooks called through RouteRegistry.
/// @dev Stateful hooks must authenticate their registry. NullSettlementModule is
///      the explicit no-state implementation. Modules define payload encoding, except
///      RGB identity mode: Bridge also decodes
///      `abi.encode(uint256 rgbOpId, uint64 beforeBlock)` on credit.
///      Hooks receive intermediate Bridge accounting; use ctx for the current operation,
///      not balance or liquidity getters as a completed-operation snapshot.
///      Bridge transfer entrypoints are `nonReentrant`; view getters remain callable.
interface ISettlementModule {
    /// @notice Whether inbound records use the consignment-derived RGB mint id.
    /// @dev Bridge queries the configured module before deriving the id. Only
    ///      modules that write RGB mint records return true; other routes keep
    ///      their existing deposit or rebalance identity.
    function usesRgbMintDepositId() external view returns (bool);

    /// @notice Processes a deposit or the credit leg of a rebalance.
    /// @dev Deposit hooks run after token receipt and token commission forwarding.
    ///      A rebalance has no token transfer. Bridge builds `ctx`; the registry forwards it.
    /// @param ctx                    Bridge-derived credit context.
    /// @param settlementData         Route-specific payload.
    /// @return externalId Optional RGB event id; zero suppresses `FundsIn`.
    ///                    Record identity is `ctx.operationId`.
    function onFundsIn(FundsInContext calldata ctx, bytes calldata settlementData) external returns (uint256 externalId);

    /// @notice Validates settlement before a physical release or rebalance debit.
    /// @dev The interface permits stateful hooks; the current RGB implementations only
    ///      read backing records. `ctx.isRebalance` distinguishes the Bridge call sites.
    /// @param ctx                    Bridge-derived debit context, forwarded by RouteRegistry.
    /// @param settlementData         Route-specific settlement payload.
    function beforeFundsOut(FundsOutContext calldata ctx, bytes calldata settlementData) external;
}
