// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @dev Records calls so stale dispatch cannot hide behind a target-side revert.
contract GovernanceTargetMock {
    address public routeRegistry;
    address public commissionManager;
    uint256 public calls;

    function setRouteRegistry(address registry) external {
        routeRegistry = registry;
        calls++;
    }

    function setCommissionManager(address manager) external {
        commissionManager = manager;
        calls++;
    }

    function commissionRecipient() external pure returns (address) {
        return address(0xBEEF);
    }

    fallback() external {
        calls++;
    }
}
