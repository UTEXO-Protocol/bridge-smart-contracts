// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Nonzero payloads for address, proof and settlement-data length tests.
library PayloadHelper {
    /// @dev Repeated ASCII 'a' bytes keep any complete ABI word nonzero.
    function filledBytes(uint256 length) internal pure returns (bytes memory payload) {
        payload = new bytes(length);
        for (uint256 i; i < length; ++i) {
            payload[i] = 0x61;
        }
    }
}
