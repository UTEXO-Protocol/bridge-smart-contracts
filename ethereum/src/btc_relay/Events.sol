// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.35;

library Events {
    event StoreHeader(bytes32 indexed commitHash, bytes32 indexed blockHash);
    event StoreForkHeader(bytes32 indexed commitHash, bytes32 indexed blockHash, uint256 indexed forkId);
    event ChainReorg(bytes32 indexed commitHash, bytes32 indexed blockHash, uint256 indexed forkId, address submitter, uint256 startHeight);
}
