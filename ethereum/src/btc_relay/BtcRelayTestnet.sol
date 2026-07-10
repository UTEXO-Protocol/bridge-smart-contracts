// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.35;

import {ForkImpl, Fork} from "./state/Fork.sol";
import {
    StoredBlockHeaderImpl,
    StoredBlockHeader,
    StoredBlockHeaderByteLength
} from "./structs/StoredBlockHeaderTestnet.sol";
import {CompactBlockHeaderByteLength} from "./structs/CompactBlockHeader.sol";
import {BtcRelayState, BtcRelayStateImpl} from "./state/BtcRelayState.sol";
import {Events} from "./Events.sol";

interface IBtcRelay {
    function submitMainBlockheaders(bytes calldata data) external;
    function submitShortForkBlockheaders(bytes calldata data) external;
    function submitForkBlockheaders(uint256 forkId, bytes calldata data) external;
}

interface IBtcRelayView {
    function getChainwork() external view returns (uint224);
    function getBlockheight() external view returns (uint32);
    function verifyBlockheader(StoredBlockHeader memory storedHeader) external view returns (uint256 confirmations);
    function verifyBlockheaderHash(uint256 height, bytes32 commitmentHash) external view returns (uint256 confirmations);
    function getCommitHash(uint256 height) external view returns (bytes32);
    function getTipCommitHash() external view returns (bytes32);
}

contract BtcRelayTestnet is IBtcRelay, IBtcRelayView {
    using StoredBlockHeaderImpl for StoredBlockHeader;
    using ForkImpl for Fork;
    using BtcRelayStateImpl for BtcRelayState;

    BtcRelayState _relayState;

    //Mapping of the blockHeight => main chain blockheader commitment
    mapping(uint256 => bytes32) _mainChain;
    //Mapping of the submitter address => fork id => Fork struct
    mapping(address => mapping(uint256 => Fork)) _forks;

    //Whether to clamp block target (enforce the maximum PoW block target of 0x00000000FFFF0000000000000000000000000000000000000000000000000000),
    // only used during testing
    bool immutable _clampBlockTarget;

    //Initialize the btc relay with the provided stored_header
    constructor(StoredBlockHeader memory storedHeader, bool clampBlockTarget) {
        _clampBlockTarget = clampBlockTarget;

        //Save the initial stored header
        bytes32 commitHash = storedHeader.hash();
        uint32 blockHeight = storedHeader.blockHeight();
        _mainChain[blockHeight] = commitHash;
        _relayState.write(
            blockHeight, uint224(storedHeader.chainWork() & 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
        );

        //Emit event
        emit Events.StoreHeader(commitHash, storedHeader.header_blockhash());
    }

    //Internal functions
    function _verifyBlockheaderHash(uint256 height, bytes32 commitmentHash)
        internal
        view
        returns (uint256 confirmations)
    {
        uint256 mainBlockheight = _relayState.blockHeight;
        //Check that the block height isn't past the tip, this can happen if there is a reorg, where a shorter
        // chain becomes the cannonical one, this can happen due to the heaviest work rule (and not lonest chain rule)
        require(height <= mainBlockheight, "verify: future block");

        require(_mainChain[height] == commitmentHash, "verify: block commitment");

        confirmations = mainBlockheight - height + 1;
    }

    //Mutating functions
    function submitMainBlockheaders(bytes calldata data) external {
        require(data.length >= StoredBlockHeaderByteLength + CompactBlockHeaderByteLength, "submitMain: no headers");

        StoredBlockHeader memory storedHeader = StoredBlockHeaderImpl.fromCalldata(data, 0); //160-byte previous blockheader

        //Verify stored header is latest committed
        uint32 blockHeight = _relayState.blockHeight;
        require(blockHeight == storedHeader.blockHeight(), "submitMain: block height");
        require(_mainChain[blockHeight] == storedHeader.hash(), "submitMain: block commitment");

        //Proccess new block headers, start at offset 160 and read 48-byte blockheaders
        for (uint256 i = StoredBlockHeaderByteLength; i < data.length; i += CompactBlockHeaderByteLength) {
            //Process the blockheader
            bytes32 blockHash = storedHeader.updateChain(data, i, block.timestamp);
            blockHeight = storedHeader.blockHeight();

            //Write header commitment
            bytes32 commitHash = storedHeader.hash();
            _mainChain[blockHeight] = commitHash;

            //Emit event
            emit Events.StoreHeader(commitHash, blockHash);
        }

        //Update globals
        _relayState.write(
            blockHeight, uint224(storedHeader.chainWork() & 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
        );
    }

    function submitShortForkBlockheaders(bytes calldata data) external {
        require(data.length >= StoredBlockHeaderByteLength + CompactBlockHeaderByteLength, "submitMain: no headers");

        StoredBlockHeader memory storedHeader = StoredBlockHeaderImpl.fromCalldata(data, 0);

        //Verify stored header is committed
        (uint32 tipBlockHeight, uint256 chainWork) = _relayState.read();
        uint32 blockHeight = storedHeader.blockHeight();
        require(blockHeight <= tipBlockHeight, "shortFork: future block");
        require(_mainChain[blockHeight] == storedHeader.hash(), "shortFork: block commitment");

        uint256 startHeight = uint256(blockHeight) + 1;

        //Proccess new block headers
        bytes32 commitHash;
        bytes32 blockHash;
        for (uint256 i = StoredBlockHeaderByteLength; i < data.length; i += CompactBlockHeaderByteLength) {
            //Process the blockheader
            blockHash = storedHeader.updateChain(data, i, block.timestamp);
            blockHeight = storedHeader.blockHeight();

            //Write header commitment
            commitHash = storedHeader.hash();
            _mainChain[blockHeight] = commitHash;

            //Emit event - here we can already emit main chain submission events
            emit Events.StoreHeader(commitHash, blockHash);
        }

        //Check if this fork's chainwork is higher than main chainwork
        uint256 newChainWork = storedHeader.chainWork();
        require(newChainWork > chainWork, "shortFork: not enough work");

        //Emit chain re-org event
        emit Events.ChainReorg(commitHash, blockHash, 0, msg.sender, startHeight);

        //Update globals
        _relayState.write(
            blockHeight, uint224(newChainWork & 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
        );
    }

    function submitForkBlockheaders(uint256 forkId, bytes calldata data) external {
        require(data.length >= StoredBlockHeaderByteLength + CompactBlockHeaderByteLength, "fork: no headers");
        require(forkId != 0, "fork: forkId 0 reserved");
        Fork storage fork = _forks[msg.sender][forkId];

        StoredBlockHeader memory storedHeader = StoredBlockHeaderImpl.fromCalldata(data, 0);

        (uint32 tipBlockHeight, uint256 chainWork) = _relayState.read();
        bytes32 commitHash = storedHeader.hash();
        uint256 forkStartBlockheight = fork.startHeight;
        if (forkStartBlockheight == 0) {
            //Verify stored header is committed in the main chain
            uint256 storedHeaderBlockHeight = storedHeader.blockHeight();
            require(storedHeaderBlockHeight <= tipBlockHeight, "fork: future block");
            require(_mainChain[storedHeaderBlockHeight] == commitHash, "fork: block commitment");
            forkStartBlockheight = storedHeaderBlockHeight + 1;
            //Save the block start height and also the commitment of the fork root block (latest
            // block that is still committed in the main chain)
            fork.startHeight = uint32(forkStartBlockheight);
            fork.chain[storedHeaderBlockHeight] = commitHash;
        } else {
            //Verify stored header is the tip of the fork chain
            uint256 forkTipHeight = fork.tipHeight;
            require(fork.chain[forkTipHeight] == commitHash, "fork: fork block commitment");
        }

        //Proccess new block headers
        bytes32 blockHash;
        uint32 forkTipBlockHeight;
        mapping(uint256 => bytes32) storage forkChain = fork.chain;
        for (uint256 i = StoredBlockHeaderByteLength; i < data.length; i += CompactBlockHeaderByteLength) {
            //Process the blockheader
            blockHash = storedHeader.updateChain(data, i, block.timestamp);
            forkTipBlockHeight = storedHeader.blockHeight();

            //Write header commitment
            commitHash = storedHeader.hash();
            forkChain[forkTipBlockHeight] = commitHash;

            //Emit event - here we can already emit main chain submission events
            emit Events.StoreForkHeader(commitHash, blockHash, forkId);
        }

        //Update tip height of the fork
        fork.tipHeight = forkTipBlockHeight;

        //Check if this fork's chainwork is higher than main chainwork
        uint256 newChainWork = storedHeader.chainWork();
        if (chainWork < newChainWork) {
            //This fork has just overtaken the main chain in chainwork
            //Make this fork main chain
            uint256 blockHeight = forkStartBlockheight - 1;

            //Make sure that the fork's root block is still committed
            require(_mainChain[blockHeight] == forkChain[blockHeight], "fork: reorg block commitment");
            delete forkChain[blockHeight];

            blockHeight++;

            for (; blockHeight <= forkTipBlockHeight; blockHeight++) {
                _mainChain[blockHeight] = forkChain[blockHeight];
                delete forkChain[blockHeight];
            }
            fork.remove();

            //Emit chain re-org event
            emit Events.ChainReorg(commitHash, blockHash, forkId, msg.sender, forkStartBlockheight);

            //Update globals
            _relayState.write(
                forkTipBlockHeight, uint224(newChainWork & 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
            );
        }
    }

    //Read-only functions
    function getChainwork() external view returns (uint224 chainWork) {
        return _relayState.chainWork;
    }

    function getBlockheight() external view returns (uint32 blockheight) {
        return _relayState.blockHeight;
    }

    function verifyBlockheader(StoredBlockHeader memory storedHeader) external view returns (uint256 confirmations) {
        return _verifyBlockheaderHash(storedHeader.blockHeight(), storedHeader.hash());
    }

    function verifyBlockheaderHash(uint256 height, bytes32 commitmentHash)
        external
        view
        returns (uint256 confirmations)
    {
        return _verifyBlockheaderHash(height, commitmentHash);
    }

    function getCommitHash(uint256 height) external view returns (bytes32) {
        return _mainChain[height];
    }

    function getTipCommitHash() external view returns (bytes32) {
        return _mainChain[_relayState.blockHeight];
    }
}
