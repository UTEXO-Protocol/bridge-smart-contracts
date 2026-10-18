// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title BridgeBase
/// @notice Token custody, ownership and pause primitives for MinimalBridge.
abstract contract BridgeBase is Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice The only accepted ERC-20 token. Immutable after deploy.
    address public immutable TOKEN;

    /// @notice Withdrawal pause, independent of the Pausable inflow flag.
    bool private _outflowPaused;

    // =========================================================================
    // Events
    // =========================================================================

    // Each concrete bridge declares its own deposit event.

    /// @notice Emitted when withdrawals are paused.
    event OutflowPaused(address account);

    /// @notice Emitted when withdrawals resume.
    event OutflowUnpaused(address account);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice The configured token address is zero.
    error InvalidTokenAddress();
    /// @notice The release recipient is zero.
    error InvalidRecipientAddress();
    /// @notice The release exceeds the token balance held by the bridge.
    error AmountExceedBridgePool();
    /// @notice The event amount does not fit uint64.
    error AmountExceedsUint64(uint256 amount);
    /// @notice Ownership cannot be renounced.
    error RenounceOwnershipBlocked();

    /// @notice Withdrawals are paused.
    error OutflowEnforcedPause();

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev Reverts while withdrawals are paused.
    modifier whenOutflowNotPaused() {
        if (_outflowPaused) revert OutflowEnforcedPause();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address token_) Ownable(msg.sender) {
        if (token_ == address(0)) revert InvalidTokenAddress();
        TOKEN = token_;
    }

    // =========================================================================
    // Owner-only
    // =========================================================================

    /// @notice Pauses deposits without pausing withdrawals.
    function pauseInflow() external onlyOwner {
        _pause();
    }

    /// @notice Resumes deposits.
    function unpauseInflow() external onlyOwner {
        _unpause();
    }

    /// @notice Pauses deposits and withdrawals; safe to call when already paused.
    function emergencyPauseAll() external onlyOwner {
        if (!paused()) _pause(); // inflow (OpenZeppelin flag), guarded against double-pause
        if (!_outflowPaused) {
            _outflowPaused = true;
            emit OutflowPaused(_msgSender());
        }
    }

    /// @notice Resumes deposits and withdrawals, including a planned inflow pause.
    function emergencyUnpauseAll() external onlyOwner {
        if (paused()) _unpause();
        if (_outflowPaused) {
            _outflowPaused = false;
            emit OutflowUnpaused(_msgSender());
        }
    }

    /// @notice Always reverts; ownership must remain transferable.
    function renounceOwnership() public view virtual override onlyOwner {
        revert RenounceOwnershipBlocked();
    }

    // =========================================================================
    // View
    // =========================================================================

    /// @notice Returns the token balance held by this contract, including direct transfers.
    function getContractBalance() external view returns (uint256) {
        return IERC20(TOKEN).balanceOf(address(this));
    }

    /// @notice Returns whether withdrawals are paused.
    /// @dev The inflow freeze is exposed by OpenZeppelin's `paused()`.
    function outflowPaused() external view returns (bool) {
        return _outflowPaused;
    }

    /// @notice Returns the current EVM chain id.
    function getChainId() public view returns (uint256) {
        uint256 id;
        assembly { id := chainid() }
        return id;
    }
}
