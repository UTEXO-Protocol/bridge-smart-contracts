// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {FundsOutContext} from "./RouteTypes.sol";

/// @title IFinalityVerifier
/// @notice Route-specific finality checks called by RouteRegistry before settlement.
/// @dev Verifiers are read-only and define their proof encoding. NullVerifier
///      explicitly represents routes that rely on upstream validation.
interface IFinalityVerifier {
    /// @notice Reverts iff `proof` does not establish finality for the
    ///         operation described by `ctx`. View-only.
    /// @param ctx                    Canonical fundsOut context built by Bridge.
    /// @param proof                  Opaque payload; layout is defined by the verifier itself.
    function verify(FundsOutContext calldata ctx, bytes calldata proof) external view;
}
