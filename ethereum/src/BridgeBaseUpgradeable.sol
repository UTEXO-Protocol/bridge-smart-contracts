// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BridgeBaseUpgradeable
/// @notice Initializable token, ownership and pause primitives for Bridge.
/// @dev Storage changes must preserve the deployed layout, including the reserved gap.
abstract contract BridgeBaseUpgradeable is Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice The accepted ERC-20 token, set during initialization.
    address public TOKEN;
    /// @dev Withdrawal pause, independent of the Pausable inflow flag.
    bool private _outflowPaused;

    /// @dev Reserved for future BridgeBaseUpgradeable state variables.
    uint256[49] private __gap;

    /// @notice Emitted when withdrawals are paused.
    event OutflowPaused(address account);
    /// @notice Emitted when withdrawals resume.
    event OutflowUnpaused(address account);

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

    /// @dev Reverts while withdrawals are paused.
    modifier whenOutflowNotPaused() {
        if (_outflowPaused) revert OutflowEnforcedPause();
        _;
    }

    /// @dev Initializes token custody, ownership and the unpaused state once.
    function __BridgeBaseUpgradeable_init(address token_, address initialOwner_) internal onlyInitializing {
        if (token_ == address(0)) revert InvalidTokenAddress();

        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        __Pausable_init();

        TOKEN = token_;
    }

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
        if (!paused()) _pause();
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

    /// @notice Always reverts; ownership cannot be renounced.
    function renounceOwnership() public view virtual override onlyOwner {
        revert RenounceOwnershipBlocked();
    }

    /// @notice Returns the token balance held by this contract, including direct transfers.
    function getContractBalance() external view returns (uint256) {
        return IERC20(TOKEN).balanceOf(address(this));
    }

    /// @notice Returns whether withdrawals are paused.
    function outflowPaused() external view returns (bool) {
        return _outflowPaused;
    }

    /// @notice Returns the current EVM chain id.
    function getChainId() public view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }
        return id;
    }
}
