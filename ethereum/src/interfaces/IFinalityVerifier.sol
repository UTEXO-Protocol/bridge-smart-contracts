// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { FundsOutContext } from './RouteTypes.sol';

/// @title IFinalityVerifier
/// @notice Pluggable, route-specific finality / proof verifier consumed by
///         `RouteRegistry.beforeFundsOut`. Each route registers its own
///         implementation so Bridge stays agnostic of any single source
///         chain's proof format (Bitcoin SPV header, Concordium light-client
///         proof, attested message, …).
///
/// @dev Verifiers MUST be read-only — they may not mutate Bridge state or
///      their own. Settlement / accounting belongs in `ISettlementModule`.
///
///      The `proof` parameter is opaque to Bridge and `RouteRegistry`; each
///      verifier owns its own encoding (typically `abi.encode(...)` of the
///      finality data it needs).
///
///      Routes that intentionally rely solely on TEE M-of-N signatures plus
///      the common replay guard SHOULD register a `NullVerifier` rather than
///      leaving the slot empty — the on-chain registry then makes that
///      trust-model decision explicit and auditable.
interface IFinalityVerifier {
    /// @notice Reverts iff `proof` does not establish finality for the
    ///         operation described by `ctx`. View-only.
    /// @param ctx   Canonical fundsOut context built by Bridge.
    /// @param proof Opaque payload; layout is defined by the verifier itself.
    function verify(FundsOutContext calldata ctx, bytes calldata proof) external view;
}
