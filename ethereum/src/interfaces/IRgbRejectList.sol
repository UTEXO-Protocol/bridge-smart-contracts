// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IRgbRejectList
/// @notice On-chain source of the RGB reject list consumed by RGB client-side
///         validation.
///
/// @dev    Granularity. An entry targets one operation output (opout): an
///         operation id plus the assignment type and output index within it,
///         so one output of an operation can be rejected without the others.
///
///         Read model. Validators do NOT query this contract once per
///         opout. Validation walks the contract history and needs a lookup for
///         every opout in it, with early exits (stop on a reject, skip the rest
///         of a branch on an allow) that make each lookup depend on the
///         previous one.
///
///         Latest entry wins. The list is a log of decisions: an opout may
///         appear any number of times, and its current decision is the one in
///         its LAST entry — e.g. a rejected opout is allowed again by
///         appending an allow entry for it. Entries for different opouts of
///         the same operation are independent. Clients apply entries in index
///         order, so later entries override earlier ones. The log is the only
///         state: there is no on-chain per-opout lookup.
///
///         Append-only. Entries can be added and never changed or removed, so a
///         client caches entries up to the last index it has seen and on the
///         next sync fetches only `[cachedLength, length())`. Reading `length()`
///         and the pages at one fixed block keeps a sync consistent even if
///         entries are appended while it runs.
///
///         Page size. `entries` is bounded by the `eth_call` gas cap and
///         timeout of the RPC node serving it, not by this contract, so the
///         page size is a client-side choice.
///
///         Roles. The owner is the cold administrative key: it only appoints
///         and rotates the appender. The appender is the hot key of the tool
///         that publishes entries, and the only account that can append.
///         Compromising the appender therefore cannot take over the registry:
///         the owner revokes it, and the new appender reverses its decisions by
///         appending corrective entries. The rogue entries stay in the log.
interface IRgbRejectList {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice One reject-list entry, targeting one operation output (opout).
    /// @param opId           RGB operation id of the output.
    /// @param assignmentType RGB assignment type of the output.
    /// @param no             Output index within that assignment type.
    /// @param reject         `true` rejects the opout — any allocation whose
    ///                       history passes through it is invalid. `false`
    ///                       allows it — the validator may skip the rest of
    ///                       that history branch.
    struct Entry {
        bytes32 opId;
        uint16 assignmentType;
        uint16 no;
        bool reject;
    }

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice `append` was called with no entries.
    error EmptyBatch();

    /// @notice An entry carried the zero operation id, which no RGB operation
    ///         has; rejected to catch uninitialised input.
    error InvalidOpId();

    /// @notice The caller of `append` is not the appender.
    error NotAppender(address caller);

    /// @notice The appender was set to the zero address.
    error InvalidAppender();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted for every appended entry. For indexing and monitoring;
    /// @param index          Position of the entry in the list.
    /// @param opId           RGB operation id of the output.
    /// @param assignmentType RGB assignment type of the output.
    /// @param no             Output index within that assignment type.
    /// @param reject         `true` = reject, `false` = allow.
    event EntryAdded(uint256 indexed index, bytes32 indexed opId, uint16 assignmentType, uint16 no, bool reject);

    /// @notice Emitted when the owner appoints a new appender.
    /// @param previousAppender Appender being replaced.
    /// @param newAppender      Appender from now on.
    event AppenderUpdated(address indexed previousAppender, address indexed newAppender);

    // =========================================================================
    // Appender-only
    // =========================================================================

    /// @notice Append a batch of entries, in order. Appender-only. An entry for
    ///         an opout that is already listed supersedes its earlier
    ///         decision, including within the same batch. Reverts as a whole if
    ///         any entry is invalid, so a batch is either recorded entirely or
    ///         not at all.
    function append(Entry[] calldata batch) external;

    // =========================================================================
    // Owner-only
    // =========================================================================

    /// @notice Appoint `newAppender` as the only account allowed to append,
    ///         replacing the current one. Owner-only. Must be non-zero.
    function setAppender(address newAppender) external;

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Number of entries. A client compares it with its cached count to
    ///         decide whether there is anything new to download.
    function length() external view returns (uint256);

    /// @notice Entries in `[start, end)`, clamped to the list length. A range
    ///         that is empty after clamping returns an empty array instead of
    ///         reverting, so a client can request fixed-size pages without
    ///         knowing the exact length.
    function entries(uint256 start, uint256 end) external view returns (Entry[] memory page);

    /// @notice The account currently allowed to append entries.
    function appender() external view returns (address);
}
