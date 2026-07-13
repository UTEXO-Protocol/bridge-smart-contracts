// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FeeOnTransferERC20
/// @notice Mintable ERC-20 that charges a fee (in basis points) on every
///         movement between two non-zero addresses — i.e. both `transfer` and
///         `transferFrom`. The recipient receives `amount - fee`; the `fee`
///         is burned (total supply drops), so the recipient's balance delta is
///         `amount - fee`.
/// @dev    Mint (`from == address(0)`) and burn (`to == address(0)`) are NOT
///         taxed, so `mint(addr, x)` credits exactly `x`. OZ v5 routes every
///         balance change through `_update`, so overriding it taxes transfer and
///         transferFrom uniformly.
contract FeeOnTransferERC20 is ERC20 {
    /// @notice Fee charged on transfers, in basis points (1% == 100 bps).
    uint256 public feeBps;

    uint256 private constant _BPS_DENOMINATOR = 10_000;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_) ERC20(name_, symbol_) {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Fee that would be charged on a movement of `amount`.
    function feeOn(uint256 amount) public view returns (uint256) {
        return (amount * feeBps) / _BPS_DENOMINATOR;
    }

    /// @dev Tax only movements between two non-zero addresses (transfer /
    ///      transferFrom). The fee is burned: credit the recipient
    ///      `amount - fee` and remove `fee` from total supply.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = feeOn(value);
            if (fee != 0) {
                // Debit `from` fully, credit `to` net, burn the fee.
                super._update(from, to, value - fee);
                super._update(from, address(0), fee);
                return;
            }
        }
        super._update(from, to, value);
    }
}
