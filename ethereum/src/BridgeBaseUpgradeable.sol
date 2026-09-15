// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BridgeBaseUpgradeable
/// @notice Initializable Bridge base used by the production Bridge proxy.
/// @dev MinimalBridge deliberately continues to use the constructor-based
///      BridgeBase. The storage gap reserves base slots so future base fields
///      can be added without moving Bridge's child storage.
abstract contract BridgeBaseUpgradeable is Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    address public TOKEN;
    bool private _outflowPaused;

    /// @dev Reserved for future BridgeBaseUpgradeable state variables.
    uint256[49] private __gap;

    event OutflowPaused(address account);
    event OutflowUnpaused(address account);

    error InvalidTokenAddress();
    error InvalidRecipientAddress();
    error AmountExceedBridgePool();
    error AmountExceedsUint64(uint256 amount);
    error RenounceOwnershipBlocked();
    error OutflowEnforcedPause();

    modifier whenOutflowNotPaused() {
        if (_outflowPaused) revert OutflowEnforcedPause();
        _;
    }

    function __BridgeBaseUpgradeable_init(address token_, address initialOwner_) internal onlyInitializing {
        if (token_ == address(0)) revert InvalidTokenAddress();

        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        __Pausable_init();

        TOKEN = token_;
    }

    function pauseInflow() external onlyOwner {
        _pause();
    }

    function unpauseInflow() external onlyOwner {
        _unpause();
    }

    function emergencyPauseAll() external onlyOwner {
        if (!paused()) _pause();
        if (!_outflowPaused) {
            _outflowPaused = true;
            emit OutflowPaused(_msgSender());
        }
    }

    function emergencyUnpauseAll() external onlyOwner {
        if (paused()) _unpause();
        if (_outflowPaused) {
            _outflowPaused = false;
            emit OutflowUnpaused(_msgSender());
        }
    }

    function renounceOwnership() public view virtual override onlyOwner {
        revert RenounceOwnershipBlocked();
    }

    function getContractBalance() external view returns (uint256) {
        return IERC20(TOKEN).balanceOf(address(this));
    }

    function outflowPaused() external view returns (bool) {
        return _outflowPaused;
    }

    function getChainId() public view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }
        return id;
    }
}
