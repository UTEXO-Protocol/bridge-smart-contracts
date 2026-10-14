// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Commission quote fixture returning the entire amount as fee and zero net.
contract ZeroNetCommissionManager {
    address public immutable bridgeAddress;

    constructor(address bridge_) {
        bridgeAddress = bridge_;
    }

    function calculateFundsOutCommission(uint256, uint256, address, uint256 amount)
        external
        pure
        returns (uint256 tokenCommission, uint256 nativeCommission, uint256 netAmount)
    {
        return (amount, 0, 0);
    }
}
