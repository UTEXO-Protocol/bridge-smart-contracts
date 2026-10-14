// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Compatible implementation with no owner getter.
contract MissingOwnerImplementation {
    function bridgeProxyCompatibilityUUID() external pure returns (bytes32) {
        return keccak256("utexo.bridge.proxy.compatibility.v1");
    }
}
