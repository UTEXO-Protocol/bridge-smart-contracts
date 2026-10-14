// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IFinalityVerifier} from "../../src/interfaces/IFinalityVerifier.sol";
import {FundsOutContext} from "../../src/interfaces/RouteTypes.sol";

/// @notice Configurable view verifier that accepts proofs or raises a distinct error.
contract MockFinalityVerifier is IFinalityVerifier {
    error MockVerifierForcedRevert();

    bool public shouldRevert;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    /// @inheritdoc IFinalityVerifier
    function verify(FundsOutContext calldata, bytes calldata) external view override {
        if (shouldRevert) revert MockVerifierForcedRevert();
    }
}
