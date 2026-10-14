// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Deterministic amount-floor getters installed at the manager's Bridge address.
contract MockDepositFloor {
    uint256 public minFundsInAmount;
    uint256 public minFundsOutAmount;

    function setMinFundsInAmount(uint256 value) external {
        minFundsInAmount = value;
    }

    function setMinFundsOutAmount(uint256 value) external {
        minFundsOutAmount = value;
    }
}
