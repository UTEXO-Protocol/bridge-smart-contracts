// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IFinalityVerifier} from "../interfaces/IFinalityVerifier.sol";
import {FundsOutContext} from "../interfaces/RouteTypes.sol";

/// @title NullVerifier
/// @notice No-op implementation for routes that omit finality checks.
/// @dev Stateless and callable by anyone. Register explicitly instead of a zero plugin address.
contract NullVerifier is IFinalityVerifier {
    /// @inheritdoc IFinalityVerifier
    function verify(FundsOutContext calldata, bytes calldata) external pure override {
        // Intentionally empty. Route validity rests on TEE M-of-N + burnId.
    }
}
