// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {FundsInContext, FundsOutContext} from "../interfaces/RouteTypes.sol";

/// @title NullSettlementModule
/// @notice No-op implementation for routes that omit settlement accounting.
/// @dev Stateless and callable by anyone. Register explicitly instead of a zero plugin address.
contract NullSettlementModule is ISettlementModule {
    /// @inheritdoc ISettlementModule
    function usesRgbMintDepositId() external pure override returns (bool) {
        return false;
    }

    /// @inheritdoc ISettlementModule
    /// @dev Returns `0`: no external correlation id, so Bridge emits no
    ///      `FundsIn` event for routes using this module.
    function onFundsIn(FundsInContext calldata, bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc ISettlementModule
    function beforeFundsOut(FundsOutContext calldata, bytes calldata) external pure override {
        // Intentionally empty.
    }
}
