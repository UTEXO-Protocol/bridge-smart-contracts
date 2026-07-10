// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.35;

import {Endianness} from "../btc_utils/Endianness.sol";

uint256 constant CompactBlockHeaderByteLength = 48;

/**
 * Bitcoin blockheader decoding from bytes (previous block hash is not included and is instead
 *  fetched from latest stored blockheader)
 * Structure (total 48 bytes):
 * - uint32 versionLE
 * - bytes32 merkleRoot
 * - uint32 timestampLE
 * - uint32 nBitsLE
 * - uint32 nonce
 */
library CompactBlockHeaderImpl {
    function verifyOutOfBounds(bytes calldata self, uint256 offset) internal pure {
        require(self.length >= offset + CompactBlockHeaderByteLength, "BlockHeader: out of bounds");
    }

    //Getters

    //Gets the timestamp of the blockheader, NOTE: This doesn't check whether the offset is out of bounds!
    function timestamp(bytes calldata self, uint256 offset) internal pure returns (uint32 result) {
        assembly ("memory-safe") {
            result := shr(224, calldataload(add(add(self.offset, offset), 36)))
        }
        result = Endianness.reverseUint32(result);
    }

    //Gets the nBits of the blockheader in little-endian format, NOTE: This doesn't check whether the offset is out of bounds!
    function nBitsLE(bytes calldata self, uint256 offset) internal pure returns (uint32 result) {
        assembly ("memory-safe") {
            result := shr(224, calldataload(add(add(self.offset, offset), 40)))
        }
    }
}
