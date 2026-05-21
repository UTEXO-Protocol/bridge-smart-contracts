// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { ISettlementModule } from '../interfaces/ISettlementModule.sol';
import { FundsInContext, FundsOutContext } from '../interfaces/RouteTypes.sol';

/// @title NullSettlementModule
/// @notice Explicit "no per-route settlement state" `ISettlementModule`.
///         Routes register this when they need no module-owned accounting
///         on top of Bridge's common bookkeeping — for example, a simple
///         attested release where the verifier already covers everything.
///
/// @dev Stateless and immutable. Both hooks are no-ops; no access control is
///      needed because there is nothing to mutate or grief. One deployment
///      is enough for Bridge — federation passes the same address into
///      every route that opts out of per-route state.
///
///      Federation MUST NOT leave a route's `settlementModule` set to
///      `address(0)`. The registry rejects that on `setRoute`, forcing the
///      operator to register *this* contract — making the trust-model
///      decision visible on-chain.
contract NullSettlementModule is ISettlementModule {
    /// @inheritdoc ISettlementModule
    function onFundsIn(FundsInContext calldata, bytes calldata) external pure override {
        // Intentionally empty.
    }

    /// @inheritdoc ISettlementModule
    function beforeFundsOut(FundsOutContext calldata, bytes calldata) external pure override {
        // Intentionally empty.
    }
}
