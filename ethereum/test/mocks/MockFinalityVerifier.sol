// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IFinalityVerifier } from '../../src/interfaces/IFinalityVerifier.sol';
import { FundsOutContext }   from '../../src/interfaces/RouteTypes.sol';

/// @title MockFinalityVerifier
/// @notice Test stub for `IFinalityVerifier`. The `verify` function is
///         declared `view` by the interface, so this mock cannot record
///         call counts on its own — but the test harness uses combined
///         observations on the paired `MockSettlementModule` to prove
///         that `verify` ran before (and authorised) the module call.
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
