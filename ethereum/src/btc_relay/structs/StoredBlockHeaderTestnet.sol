// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.35;

import {CompactBlockHeaderImpl} from "./CompactBlockHeader.sol";
import {Nbits} from "../utils/Nbits.sol";
import {Difficulty} from "../utils/Difficulty.sol";
import {Endianness} from "../btc_utils/Endianness.sol";
import {DIFFICULTY_ADJUSTMENT_INTERVAL, MAX_FUTURE_BLOCKTIME} from "../Constants.sol";

/**
 * Bitcoin stored blockheader defined as a fixed-length bytes32 array
 * Structure (total 160 bytes):
 * - bytes blockheader (80 bytes)
 * - uint256 chainWork
 * - uint32 blockHeight
 * - uint32 lastDiffAdjustment
 * - uint32[10] prevBlockTimestamps
 */
struct StoredBlockHeader {
    bytes32[5] data;
}
uint256 constant StoredBlockHeaderByteLength = 160;
uint256 constant BitcoinBlockHeaderByteLength = 80;

library StoredBlockHeaderImpl {
    using CompactBlockHeaderImpl for bytes;

    function fromCalldata(bytes calldata data, uint256 offset)
        internal
        pure
        returns (StoredBlockHeader memory storedHeader)
    {
        require(data.length >= StoredBlockHeaderByteLength + offset, "StoredBlockHeader: out of bounds");
        assembly ("memory-safe") {
            calldatacopy(mload(storedHeader), add(data.offset, offset), StoredBlockHeaderByteLength) //Store stored header data
        }
    }

    //Getters
    function header_version(StoredBlockHeader memory self) internal pure returns (uint32 result) {
        assembly ("memory-safe") {
            result := shr(224, mload(mload(self)))
        }
        result = Endianness.reverseUint32(result);
    }

    function header_previousBlockhash(StoredBlockHeader memory self) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            result := mload(add(mload(self), 4))
        }
    }

    function header_merkleRoot(StoredBlockHeader memory self) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            result := mload(add(mload(self), 36))
        }
    }

    function header_timestamp(StoredBlockHeader memory self) internal pure returns (uint32 result) {
        assembly ("memory-safe") {
            result := shr(224, mload(add(mload(self), 68)))
        }
        result = Endianness.reverseUint32(result);
    }

    function header_nBitsLE(StoredBlockHeader memory self) internal pure returns (uint32 result) {
        assembly ("memory-safe") {
            result := shr(224, mload(add(mload(self), 72)))
        }
    }

    function header_nonce(StoredBlockHeader memory self) internal pure returns (uint32 result) {
        assembly ("memory-safe") {
            result := shr(224, mload(add(mload(self), 76)))
        }
        result = Endianness.reverseUint32(result);
    }

    function chainWork(StoredBlockHeader memory self) internal pure returns (uint256 result) {
        assembly ("memory-safe") {
            result := mload(add(mload(self), 80))
        }
    }

    function blockHeight(StoredBlockHeader memory self) internal pure returns (uint32 result) {
        assembly ("memory-safe") {
            result := shr(224, mload(add(mload(self), 112)))
        }
    }

    function lastDiffAdjustment(StoredBlockHeader memory self) internal pure returns (uint32 result) {
        assembly ("memory-safe") {
            result := shr(224, mload(add(mload(self), 116)))
        }
    }

    function previousBlockTimestamps(StoredBlockHeader memory self) internal pure returns (uint32[10] memory result) {
        assembly ("memory-safe") {
            let ptr := mload(self)
            let prevBlockTimestampsArray1 := mload(add(ptr, 120)) //offset(120) Stores first 8 last block timestamps
            let prevBlockTimestampsArray2 := mload(add(ptr, 128)) //offset(120 + 8) Stores last 2 last block timestamps in least significant bits
            mstore(result, shr(224, prevBlockTimestampsArray1))
            mstore(add(result, 32), and(shr(192, prevBlockTimestampsArray1), 0xffffffff))
            mstore(add(result, 64), and(shr(160, prevBlockTimestampsArray1), 0xffffffff))
            mstore(add(result, 96), and(shr(128, prevBlockTimestampsArray1), 0xffffffff))
            mstore(add(result, 128), and(shr(96, prevBlockTimestampsArray1), 0xffffffff))
            mstore(add(result, 160), and(shr(64, prevBlockTimestampsArray1), 0xffffffff))
            mstore(add(result, 192), and(shr(32, prevBlockTimestampsArray1), 0xffffffff))
            mstore(add(result, 224), and(prevBlockTimestampsArray1, 0xffffffff))
            mstore(add(result, 256), and(shr(32, prevBlockTimestampsArray2), 0xffffffff))
            mstore(add(result, 288), and(prevBlockTimestampsArray2, 0xffffffff))
        }
    }

    //Functions
    function header_blockhash(StoredBlockHeader memory self) internal view returns (bytes32 result) {
        assembly ("memory-safe") {
            //Invoke first sha256 hash on the memory region now storing the current blockheader, destination is scratch space at 0x00
            pop(staticcall(gas(), 0x02, mload(self), BitcoinBlockHeaderByteLength, 0x00, 32))
            //Invoke second sha256 on the scratch space at 0x00
            pop(staticcall(gas(), 0x02, 0x00, 32, 0x00, 32))

            //Load and return the result
            result := mload(0x00)
        }
    }

    function hash(StoredBlockHeader memory self) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            result := keccak256(mload(self), StoredBlockHeaderByteLength)
        }
    }

    //Writes new blockheader to the stored header memory and computes the double sha256 hash of this new blockheader
    function writeHeaderAndGetDblSha256Hash(StoredBlockHeader memory self, bytes calldata headers, uint256 offset)
        private
        view
        returns (bytes32 result)
    {
        assembly ("memory-safe") {
            let ptr := mload(self)

            //Invoke first sha256 hash on the memory region storing the previous blockheader, destination is scratch space at 0x00
            pop(staticcall(gas(), 0x02, ptr, BitcoinBlockHeaderByteLength, 0x00, 32))
            //Invoke second sha256 on the scratch space at 0x00, copy directly to where the previous blockhash should be stored for next stored blockheader
            pop(staticcall(gas(), 0x02, 0x00, 32, add(ptr, 4), 32))

            //Copy other data to the stored blockheader from calldata
            calldatacopy(ptr, add(headers.offset, offset), 4)
            calldatacopy(add(ptr, 36), add(headers.offset, add(offset, 4)), 44)

            //Invoke first sha256 hash on the memory region now storing the current blockheader, destination is scratch space at 0x00
            pop(staticcall(gas(), 0x02, ptr, BitcoinBlockHeaderByteLength, 0x00, 32))
            //Invoke second sha256 on the scratch space at 0x00
            pop(staticcall(gas(), 0x02, 0x00, 32, 0x00, 32))

            //Load and return the result
            result := mload(0x00)
        }
    }

    function updateChain(StoredBlockHeader memory self, bytes calldata headers, uint256 offset, uint256 timestamp)
        internal
        view
        returns (bytes32 blockHash)
    {
        //We don't check whether pevious header matches since submitted headers are submitted
        // without previousBlockHash fields, which is instead taken automatically from the
        // current StoredBlockHeader, this allows us to save at least 512 gas on calldata

        uint32 prevBlockTimestamp = header_timestamp(self);
        uint32 currBlockTimestamp = headers.timestamp(offset);

        //Check correct nbits
        uint256 currBlockHeight = blockHeight(self) + 1;
        uint32 _lastDiffAdjustment = lastDiffAdjustment(self);
        uint32 newNbits = headers.nBitsLE(offset);
        uint256 newTarget = Nbits.toTarget(newNbits);

        //Skip difficulty adjustment enforcement on testnet!
        if (currBlockHeight % DIFFICULTY_ADJUSTMENT_INTERVAL == 0) {
            //     //Compute new nbits, bitcoin uses the timestamp of the last block in the epoch to re-target PoW difficulty
            //     // https://github.com/bitcoin/bitcoin/blob/78dae8caccd82cfbfd76557f1fb7d7557c7b5edb/src/pow.cpp#L49
            //     uint256 computedNbits;
            //     (newTarget, computedNbits) = Difficulty.computeNewTarget(
            //         prevBlockTimestamp,
            //         _lastDiffAdjustment,
            //         header_nBitsLE(self),
            //         clampTarget
            //     );
            //     require(newNbits == computedNbits, "updateChain: new nbits");
            //     //Even though timestamp of the last block in epoch is used to re-target PoW difficulty, the first
            //     // block in a new epoch is used as last_diff_adjustment, the time it takes to mine the first block
            //     // in every epoch is therefore not taken into consideration when retargetting PoW - one of many
            //     // bitcoin's quirks
            _lastDiffAdjustment = currBlockTimestamp;
        }
        // } else {
        //     //nbits must be same as last block
        //     require(newNbits == header_nBitsLE(self), "updateChain: nbits");
        //     newTarget = Nbits.toTarget(newNbits);
        // }

        //Check PoW
        blockHash = writeHeaderAndGetDblSha256Hash(self, headers, offset);
        require(uint256(Endianness.reverseBytes32(blockHash)) < Nbits.toTarget(newNbits), "updateChain: invalid PoW");

        //Verify timestamp is larger than median of last 11 block timestamps
        uint256 count = 0;
        uint256 prevBlockTimestampsArray1;
        uint256 prevBlockTimestampsArray2;
        assembly ("memory-safe") {
            let ptr := mload(self)
            prevBlockTimestampsArray1 := mload(add(ptr, 120)) //offset(120) Stores first 8 last block timestamps
            prevBlockTimestampsArray2 := mload(add(ptr, 128)) //offset(120 + 8) Stores last 2 last block timestamps in least significant bits
            count := gt(currBlockTimestamp, prevBlockTimestamp)
            count := add(count, gt(currBlockTimestamp, shr(224, prevBlockTimestampsArray1)))
            count := add(count, gt(currBlockTimestamp, and(shr(192, prevBlockTimestampsArray1), 0xffffffff)))
            count := add(count, gt(currBlockTimestamp, and(shr(160, prevBlockTimestampsArray1), 0xffffffff)))
            count := add(count, gt(currBlockTimestamp, and(shr(128, prevBlockTimestampsArray1), 0xffffffff)))
            count := add(count, gt(currBlockTimestamp, and(shr(96, prevBlockTimestampsArray1), 0xffffffff)))
            count := add(count, gt(currBlockTimestamp, and(shr(64, prevBlockTimestampsArray1), 0xffffffff)))
            count := add(count, gt(currBlockTimestamp, and(shr(32, prevBlockTimestampsArray1), 0xffffffff)))
            count := add(count, gt(currBlockTimestamp, and(prevBlockTimestampsArray1, 0xffffffff)))
            count := add(count, gt(currBlockTimestamp, and(shr(32, prevBlockTimestampsArray2), 0xffffffff)))
            count := add(count, gt(currBlockTimestamp, and(prevBlockTimestampsArray2, 0xffffffff)))
        }
        require(count > 5, "updateChain: timestamp median");
        require(currBlockTimestamp < timestamp + MAX_FUTURE_BLOCKTIME, "updateChain: timestamp future");

        //Update prev block timestamps
        assembly {
            prevBlockTimestampsArray1 := shl(32, prevBlockTimestampsArray1) //Shift to the left, to remove oldest timestamp
            prevBlockTimestampsArray1 := or(
                prevBlockTimestampsArray1,
                and(shr(32, prevBlockTimestampsArray2), 0xffffffff)
            ) //Push timestamp from arr2 to arr1
            prevBlockTimestampsArray2 := shl(32, prevBlockTimestampsArray2) //Shift to the left
            prevBlockTimestampsArray2 := or(prevBlockTimestampsArray2, prevBlockTimestamp) //Add previous block timestamp
        }

        uint256 _chainWork = chainWork(self) + Difficulty.getChainWork(newTarget);

        //Save the stored blockheader to memory
        assembly ("memory-safe") {
            //Blockheader is already written to memory with prior writeHeaderAndGetDblSha256Hash() call
            let ptr := mload(self)

            //Write chainwork at offset 80..112
            mstore(add(ptr, 80), _chainWork)
            mstore(
                add(ptr, 112),
                or(
                    or(
                        shl(224, currBlockHeight), //Current block height at offset 112..116
                        shl(192, and(_lastDiffAdjustment, 0xffffffff)) //Last difficulty adjustment at offset 116..120
                    ),
                    shr(64, prevBlockTimestampsArray1) //First 6 values of previous block timestamps at offset 120..144
                )
            )
            //Ensure we don't write outside the region of the stored blockheader byte array, so we
            // have a little bit of an overlap here
            mstore(
                add(ptr, 128),
                or(shl(64, prevBlockTimestampsArray1), and(prevBlockTimestampsArray2, 0xffffffffffffffff))
            )
        }
    }
}
