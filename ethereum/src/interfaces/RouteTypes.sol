// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// @title RouteTypes
/// @notice Shared data shapes used by `IRouteRegistry`, `ISettlementModule`
///         and `IFinalityVerifier`. Lives in one file so the three interfaces
///         can import the same canonical definitions without circular deps.
///
/// @dev The structs are passed by value through `calldata` between Bridge and
///      the route plugins. They carry every field a verifier or settlement
///      module needs to do its work, so adding a new plugin in the future
///      does not require touching Bridge's call sites.
///
///      Chain identifiers are `uint256` everywhere: real `block.chainid`.

/// @notice Canonical context for a `Bridge.fundsIn` call. Built by Bridge
///         after commission has been computed and tokens have been pulled,
///         then forwarded into `RouteRegistry.onFundsIn` → `ISettlementModule`.
/// @param token              ERC-20 the Bridge accepts (the bridged asset).
/// @param sender             Address that initiated the deposit — the EOA on
///                           the public overload, or the LZ adapter on the
///                           adapter-only overload.
/// @param grossAmount        Gross amount the user supplied (pre-commission).
/// @param netAmount          Amount actually bridged after token commission
///                           has been taken.
/// @param operationId        Backend-assigned operation identifier.
/// @param sourceChainId      `block.chainid` for direct EVM deposits, or the
///                           non-spoofable chain id forwarded by the adapter.
/// @param destChainId        Target chain id (backend-assigned for non-EVM
///                           destinations).
/// @param destAddress        Target address on the destination chain.
struct FundsInContext {
    address token;
    address sender;
    uint256 grossAmount;
    uint256 netAmount;
    uint256 operationId;
    uint256 sourceChainId;
    uint256 destChainId;
    string  destAddress;
}

/// @notice Canonical context for a `Bridge.fundsOut` call. Built by Bridge
///         after the common replay guard has been enforced, then forwarded
///         into `RouteRegistry.beforeFundsOut` → `IFinalityVerifier` and
///         `ISettlementModule`.
/// @param token              ERC-20 the Bridge releases.
/// @param recipient          Final recipient on this chain.
/// @param amount             Gross amount being released from the pool
///                           (pre-commission).
/// @param burnId             Source-side burn identifier — the common replay
///                           guard enforced by Bridge itself. Carried in the
///                           context so verifiers and settlement modules can
///                           reference it if they need to.
/// @param sourceChainId      Source chain id.
/// @param destChainId        Destination chain id (this chain, in practice).
/// @param sourceAddress      Sender address on the source chain.
struct FundsOutContext {
    address token;
    address recipient;
    uint256 amount;
    uint256 burnId;
    uint256 sourceChainId;
    uint256 destChainId;
    string  sourceAddress;
}

/// @notice Per-route configuration stored in `RouteRegistry`.
/// @dev    A route is keyed by the pair `(sourceChainId, destChainId)`. The
///         registry MUST reject `address(0)` for `finalityVerifier` or
///         `settlementModule` — routes that intentionally need no proof or no
///         per-route state register an explicit `NullVerifier` /
///         `NullSettlementModule` so the trust model is auditable on-chain.
/// @param enabled            Master switch. Disabled routes revert at the
///                           registry's dispatcher methods.
/// @param finalityVerifier   Contract that validates `bytes proof` for this
///                           route. View-only.
/// @param settlementModule   Contract that owns route-specific accounting
///                           (e.g. RGB `fundsInRecords`). State-mutating.
struct RouteConfig {
    bool    enabled;
    address finalityVerifier;
    address settlementModule;
}
