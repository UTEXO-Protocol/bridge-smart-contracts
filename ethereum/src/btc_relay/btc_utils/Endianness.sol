// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.35;

library Endianness {
    function reverseUint32(uint32 input) internal pure returns (uint32) {
        assembly {
            input := or(shr(8, and(input, 0xFF00FF00)), shl(8, and(input, 0x00FF00FF)))
            input := or(shr(16, and(input, 0xFFFF0000)), shl(16, and(input, 0x0000FFFF)))
        }
        return input;
    }

    function reverseUint64(uint64 input) internal pure returns (uint64) {
        assembly {
            input := or(shr(8, and(input, 0xFF00FF00FF00FF00)), shl(8, and(input, 0x00FF00FF00FF00FF)))
            input := or(shr(16, and(input, 0xFFFF0000FFFF0000)), shl(16, and(input, 0x0000FFFF0000FFFF)))
            input := or(shr(32, and(input, 0xFFFFFFFF00000000)), shl(32, and(input, 0x00000000FFFFFFFF)))
        }
        return input;
    }
    
    function reverseBytes32(bytes32 input) internal pure returns (bytes32) {
        assembly {
            // swap bytes
            input := or(shr(8, and(input, 0xFF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00)), shl(8, and(input, 0x00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF)))
            input := or(shr(16, and(input, 0xFFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000)), shl(16, and(input, 0x0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF)))
            input := or(shr(32, and(input, 0xFFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000)), shl(32, and(input, 0x00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF)))
            input := or(shr(64, and(input, 0xFFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF0000000000000000)), shl(64, and(input, 0x0000000000000000FFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF)))
            input := or(shr(128, input), shl(128, input))
        }
        return input;
    }
}
