// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Ownable } from '@openzeppelin/contracts/access/Ownable.sol';
import { SafeERC20, IERC20 } from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import { Pausable } from '@openzeppelin/contracts/utils/Pausable.sol';

/// @title BridgeBase
/// @notice Abstract base contract shared by BaseBridge and Bridge.
///
/// @dev Provides:
///      - Single accepted token (immutable, set at deploy).
///      - pause / unpause (owner-only).
///      - Permanently blocked renounceOwnership.
///      - Utility views: getChainId, getContractBalance.
abstract contract BridgeBase is Ownable, Pausable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice The only accepted ERC-20 token. Immutable after deploy.
    address public immutable TOKEN;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted on every fundsIn.
    /// @param sender      Address that deposited the tokens.
    /// @param operationId Backend-assigned operation identifier.
    /// @param amount      Amount of tokens locked.
    event FundsIn(
        address indexed sender,
        uint256 operationId,
        uint256 amount
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidTokenAddress();
    error InvalidRecipientAddress();
    error AmountExceedBridgePool();
    error RenounceOwnershipBlocked();

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

    /// @notice Pause all user-facing operations.
    function pause() external onlyOwner { _pause(); }

    /// @notice Resume all user-facing operations.
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Permanently blocks renouncing ownership.
    function renounceOwnership() public view virtual override onlyOwner {
        revert RenounceOwnershipBlocked();
    }

    // =========================================================================
    // View
    // =========================================================================

    /// @notice Returns the token balance held by the contract (bridgeable liquidity).
    function getContractBalance() external view returns (uint256) {
        return IERC20(TOKEN).balanceOf(address(this));
    }

    /// @notice Returns the current chain ID.
    function getChainId() public view returns (uint256) {
        uint256 id;
        assembly { id := chainid() }
        return id;
    }
}
