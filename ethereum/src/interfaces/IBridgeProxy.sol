// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

interface IBridgeProxy {
    function implementation() external view returns (address);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
