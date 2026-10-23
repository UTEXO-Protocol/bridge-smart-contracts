// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

// Context and configuration types shared by Bridge and route plugins.

/// @notice Context for a deposit or rebalance credit, built by Bridge.
/// @dev EVM ids identify EVM networks; RGB uses the protocol-assigned id 827166.
/// @param token                  Bridged ERC-20 token.
/// @param sender                 EVM caller: depositor, adapter or rebalance owner.
/// @param sourceSender           Deposits use the source sender (EVM addresses padded to bytes32);
///                               rebalances use `keccak256(bytes(sourceAddress))`.
/// @param grossAmount            Requested amount before token commission.
/// @param netAmount              Token amount credited after commission; grossAmount for
///                               rebalances.
/// @param operationId            Bridge-derived record id, using RGB mint identity or non-RGB
///                               context.
/// @param senderNonce            Deposit nonce for (sourceChainId, sourceSender); zero for
///                               rebalances.
/// @param sourceChainId          Local chain for direct deposits; authenticated origin otherwise.
/// @param destChainId            Destination network id.
/// @param destAddress            Route-specific address; empty for RGB because it is in the
///                               consignment.
struct FundsInContext {
    address token;
    address sender;
    bytes32 sourceSender;
    uint256 grossAmount;
    uint256 netAmount;
    bytes32 operationId;
    uint256 senderNonce;
    uint256 sourceChainId;
    uint256 destChainId;
    string destAddress;
}

/// @notice Context for a physical release or rebalance debit, built by Bridge.
/// @param token                  Bridged ERC-20 token.
/// @param recipient              Payout recipient; Bridge itself for a rebalance.
/// @param amount                 Gross liquidity debit before commission.
/// @param burnId                 Shared source-burn replay key.
/// @param sourceChainId          Network whose liquidity is debited.
/// @param destChainId            Destination network; remote for a rebalance.
/// @param sourceAddress          Source identity; empty when the source network is RGB.
/// @param isRebalance            Whether this is a rebalance debit rather than a physical payout.
/// @param sourceBurnTxId         Enclave-attested source-burn id, hashed into `burnId`.
///                               Bridge checks non-zero; enclaves validate its source-chain
///                               meaning.
struct FundsOutContext {
    address token;
    address recipient;
    uint256 amount;
    uint256 burnId;
    uint256 sourceChainId;
    uint256 destChainId;
    string sourceAddress;
    bool isRebalance;
    bytes32 sourceBurnTxId;
}

/// @notice Plugin configuration for a directional route.
/// @dev Both plugins must contain code; use Null implementations to omit a layer.
/// @param enabled                Whether Bridge can dispatch this route.
/// @param finalityVerifier       Read-only finality verifier.
/// @param settlementModule       Route settlement hook implementation.
struct RouteConfig {
    bool enabled;
    address finalityVerifier;
    address settlementModule;
}
