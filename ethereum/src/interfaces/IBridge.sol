// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IBridge {
    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidDestinationAddress();
    error InvalidDestinationChainId();
    error InvalidSourceChainId();
    error InvalidBtcRelayAddress();
    error InvalidCommissionManagerAddress();
    error NotLZAdapter();
    error DuplicateOperationId();
    error BurnIdAlreadyConsumed(uint256 burnId);
    error FundsInNotFound(uint256 operationId);
    error FundsOutAmountExceedsFundsIn();
    error NativeCommissionNotAllowedOnFundsOut();
    error NativeValueMismatch();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted on every successful `setLZAdapter`.
    /// @param oldAdapter Previous trusted adapter (zero before first set).
    /// @param newAdapter New trusted adapter (zero disables the adapter overload).
    event LZAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    /// @param sender             Address that deposited the tokens (the EOA on the
    ///                           public overload, or the LZ adapter on the
    ///                           adapter-only overload).
    /// @param operationId        Backend-assigned operation identifier.
    /// @param amount             Gross amount the user supplied (pre-commission).
    /// @param netAmount          Amount actually bridged after token commission is taken.
    /// @param tokenCommission    Fee charged in the bridged token (deducted from `amount`).
    /// @param nativeCommission   Fee charged in native wei (paid via `msg.value`).
    /// @param sourceChainId      EVM `block.chainid` for direct deposits, or the
    ///                           non-spoofable chain id forwarded by the adapter.
    /// @param destinationChainId Target chain id (backend-assigned for non-EVM
    ///                           destinations like RGB / Bitcoin).
    /// @param destinationAddress Target address on the destination chain.
    event BridgeFundsIn(
        address indexed sender,
        uint256 operationId,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 nativeCommission,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  destinationAddress
    );

    /// @param recipient          Recipient on this chain.
    /// @param amount             Gross amount released from the bridge pool (pre-commission).
    /// @param netAmount          Amount actually delivered to `recipient`.
    /// @param tokenCommission    Fee taken in the bridged token (sent to the CommissionManager).
    /// @param operationId        Backend-assigned operation identifier.
    /// @param burnId             Identifier extracted from the burn consignment on the
    ///                           source side. Stored on-chain to block fundsOut replays.
    /// @param sourceChainId      Source chain id (non-EVM side for RGB→EVM releases).
    /// @param destinationChainId Destination chain id (EVM target receiving the release).
    /// @param sourceAddress      Sender address on the source chain.
    /// @param blockHeight        Bitcoin block height verified via BtcRelay.
    /// @param commitmentHash     Bitcoin block commitment hash verified via BtcRelay.
    event BridgeFundsOut(
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 tokenCommission,
        uint256 operationId,
        uint256 burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  sourceAddress,
        uint256 blockHeight,
        bytes32 commitmentHash
    );

    // =========================================================================
    // External — user-facing
    // =========================================================================

    /// @notice Direct deposit overload for EVM users on this chain. The
    ///         `sourceChainId` half of the commission route key is filled with
    ///         `block.chainid` — non-spoofable by the caller.
    /// @dev Payable: if the active route uses NATIVE commission currency, `msg.value`
    ///      must equal the quoted native commission; otherwise `msg.value` must be 0.
    /// @dev Permissionless. Replay protection is enforced via `operationId`
    ///      (rejected if it already exists in `fundsInRecords`).
    function fundsIn(
        uint256 amount,
        uint256 destinationChainId,
        string  calldata destinationAddress,
        uint256 operationId
    ) external payable;

    /// @notice Adapter-only overload. Used by `UtexoLZAdapter.lzCompose` to
    ///         forward a cross-chain deposit while preserving the original
    ///         source-chain id (carried in `composeMsg` and validated against
    ///         the adapter's trusted-entrypoint registry on the source side).
    /// @dev Reverts `NotLZAdapter` if `msg.sender` is not the configured
    ///      `lzAdapter`. Until federation sets a non-zero adapter, the
    ///      overload is effectively closed.
    function fundsIn(
        uint256 amount,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  calldata destinationAddress,
        uint256 operationId
    ) external payable;

    // =========================================================================
    // External — owner-only (called via MultisigProxy.execute)
    // =========================================================================

    /// @notice Release tokens to a recipient. Verifies the Bitcoin block header
    ///         is known to BtcRelay and that the referenced fundsIn operations
    ///         exist on-chain before releasing.
    ///         Only callable by owner (MultisigProxy via execute()).
    /// @dev `destinationChainId` is part of the CommissionManager route key and
    ///      lets the same Bridge serve multi-hop routes.
    /// @dev `burnId` is the identifier the backend extracts from the burn
    ///      consignment on the source side. The contract records it on success
    ///      and rejects any future call referencing the same `burnId`.
    /// @dev `fundsInIds` are processed sequentially: each referenced record is
    ///      either fully consumed (deleted) or partially consumed (decremented)
    ///      until `amount` is fully covered.
    function fundsOut(
        address recipient,
        uint256 amount,
        uint256 operationId,
        uint256 burnId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        string  calldata sourceAddress,
        uint256 blockHeight,
        bytes32 commitmentHash,
        uint256[] calldata fundsInIds
    ) external;

    // =========================================================================
    // External — admin (called via MultisigProxy)
    // =========================================================================

    /// @notice Updates the trusted LayerZero adapter address. Owner-only
    ///         (MultisigProxy in production). Passing `address(0)` disables the
    ///         adapter overload until a non-zero address is set again.
    function setLZAdapter(address newAdapter) external;

    /// @notice Current trusted adapter; `address(0)` means the adapter overload
    ///         is closed.
    function lzAdapter() external view returns (address);

    /// @notice Permanently blocked — ownership cannot be renounced.
    function renounceOwnership() external view;
}
