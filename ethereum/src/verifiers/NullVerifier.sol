// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IFinalityVerifier }  from '../interfaces/IFinalityVerifier.sol';
import { FundsOutContext }    from '../interfaces/RouteTypes.sol';

/// @title NullVerifier
/// @notice Explicit "no source-side proof required" `IFinalityVerifier`.
///         Routes register this when they intentionally rely solely on
///         M-of-N TEE signatures and Bridge's common replay guard
///         (`burnId`) — for example, when an attested-message scheme on the
///         source chain already provides equivalent guarantees off-chain.
///
/// @dev Stateless and immutable. There is no admin, no pause, no upgrade.
///      One deployment is enough for Bridge — federation passes the same
///      address into every route that opts out of a source-side proof.
///
///      Federation MUST NOT leave a route's `finalityVerifier` set to
///      `address(0)`. The registry rejects that on `setRoute`, forcing the
///      operator to register *this* contract — making the trust-model
///      decision visible on-chain.
contract NullVerifier is IFinalityVerifier {
    /// @inheritdoc IFinalityVerifier
    function verify(FundsOutContext calldata, bytes calldata) external pure override {
        // Intentionally empty. Route validity rests on TEE M-of-N + burnId.
    }
}
