// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IBtcRelayView } from '../../src/interfaces/IBtcRelayView.sol';

/// @title MockBtcRelay
/// @notice Minimal mock of the Atomiq BtcRelay for testing.
///         Stores (height, commitmentHash) => confirmations.
contract MockBtcRelay is IBtcRelayView {
    mapping(bytes32 => uint256) private _blocks;
    uint32  private _blockHeight;
    uint224 private _chainwork;

    /// @notice Register a block so verifyBlockheaderHash returns the given confirmations.
    function setBlock(uint256 height, bytes32 commitmentHash, uint256 confirmations) external {
        _blocks[_key(height, commitmentHash)] = confirmations;
        if (uint32(height) >= _blockHeight) {
            _blockHeight = uint32(height + confirmations - 1);
        }
    }

    /// @inheritdoc IBtcRelayView
    function getChainwork() external view override returns (uint224) {
        return _chainwork;
    }

    /// @inheritdoc IBtcRelayView
    function getBlockheight() external view override returns (uint32) {
        return _blockHeight;
    }

    /// @inheritdoc IBtcRelayView
    function verifyBlockheaderHash(
        uint256 height,
        bytes32 commitmentHash
    ) external view override returns (uint256 confirmations) {
        confirmations = _blocks[_key(height, commitmentHash)];
        require(confirmations > 0, 'verify: block commitment');
    }

    /// @inheritdoc IBtcRelayView
    function getCommitHash(uint256 height) external pure override returns (bytes32) {
        // Not implemented in mock — returns zero
        height;
        return bytes32(0);
    }

    /// @inheritdoc IBtcRelayView
    function getTipCommitHash() external pure override returns (bytes32) {
        // Not implemented in mock — returns zero
        return bytes32(0);
    }

    function _key(uint256 height, bytes32 commitmentHash) private pure returns (bytes32) {
        return keccak256(abi.encode(height, commitmentHash));
    }
}
