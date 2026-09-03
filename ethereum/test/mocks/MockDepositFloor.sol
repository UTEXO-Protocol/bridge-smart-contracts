// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Minimal stand-in for the Bridge's `minFundsInAmount` /
///         `minFundsOutAmount` getters, which `CommissionManager` reads to bound
///         a route's flat `baseFee` on its respective side. Used by the
///         CommissionManager unit tests, which exercise the manager in isolation
///         and have no real Bridge deployment.
/// @dev Intended to be installed with `vm.etch` at the address the manager was
///      constructed with, so the existing `vm.prank(BRIDGE)` call sites keep
///      working unchanged.
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
