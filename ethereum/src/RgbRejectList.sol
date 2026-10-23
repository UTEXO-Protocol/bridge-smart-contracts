// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IRgbRejectList} from "./interfaces/IRgbRejectList.sol";

/// @title RgbRejectList
/// @notice Append-only reject list consumed by RGB clients.
/// @dev Standalone and non-upgradeable. Only the appender adds entries; the owner
///      rotates the appender. Corrective entries supersede earlier decisions.
///      Use a cold owner and a hot appender. If the appender is compromised, the owner
///      rotates it and the new appender publishes corrective entries. Ownership is
///      two-step; renunciation is blocked to preserve administration of the fixed list.
contract RgbRejectList is IRgbRejectList, Ownable2Step {
    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Ownership cannot be renounced, preserving the ability to rotate the appender.
    error RenounceOwnershipBlocked();

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev Entries in append order. Index i is stable forever once written.
    Entry[] private _entries;

    /// @inheritdoc IRgbRejectList
    address public override appender;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param owner_                 Initial owner, who appoints and rotates the appender.
    ///                               Must be non-zero (enforced by `Ownable`).
    /// @param appender_              Initial appender, allowed to append entries. Must be
    ///                               non-zero.
    constructor(address owner_, address appender_) Ownable(owner_) {
        _setAppender(appender_);
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyAppender() {
        if (msg.sender != appender) revert NotAppender(msg.sender);
        _;
    }

    // =========================================================================
    // Appender-only
    // =========================================================================

    /// @inheritdoc IRgbRejectList
    function append(Entry[] calldata batch) external override onlyAppender {
        if (batch.length == 0) revert EmptyBatch();

        uint256 index = _entries.length;
        for (uint256 i = 0; i < batch.length; i++) {
            Entry calldata entry = batch[i];
            if (entry.opId == bytes32(0)) revert InvalidOpId();

            _entries.push(entry);
            emit EntryAdded(index + i, entry.opId, entry.assignmentType, entry.no, entry.reject);
        }
    }

    // =========================================================================
    // Owner-only
    // =========================================================================

    /// @inheritdoc IRgbRejectList
    function setAppender(address newAppender) external override onlyOwner {
        _setAppender(newAppender);
    }

    /// @notice Always reverts; ownership cannot be renounced.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipBlocked();
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @inheritdoc IRgbRejectList
    function length() external view override returns (uint256) {
        return _entries.length;
    }

    /// @inheritdoc IRgbRejectList
    function entries(uint256 start, uint256 end) external view override returns (Entry[] memory page) {
        uint256 len = _entries.length;
        if (end > len) end = len;
        if (start >= end) return new Entry[](0);

        page = new Entry[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = _entries[i];
        }
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _setAppender(address newAppender) private {
        if (newAppender == address(0)) revert InvalidAppender();
        emit AppenderUpdated(appender, newAppender);
        appender = newAppender;
    }
}
