// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Adversarial compatibility getter returning a wrong word, 31 bytes or a revert.
contract InvalidCompatibilityMarkerImplementation {
    uint8 private immutable _mode;

    constructor(uint8 mode_) {
        _mode = mode_;
    }

    function initializeStub() external pure {}

    fallback() external {
        if (_mode == 2) revert("marker reverted");
        bytes32 response = _mode == 0 ? bytes32(0) : keccak256("utexo.bridge.proxy.compatibility.v1");
        uint256 length = _mode == 1 ? 31 : 32;
        assembly ("memory-safe") {
            mstore(0, response)
            return(0, length)
        }
    }
}
