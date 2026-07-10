// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.35;

library Nbits {
    //Calculates difficulty target from nBits
    //Description: https://btcinformation.org/en/developer-reference#target-nbits
    //This implementation panics on negative targets, accepts oveflown targets
    function toTarget(uint32 nBitsLE) internal pure returns (uint256 target) {
        uint256 nSize;
        assembly {
            nSize := and(nBitsLE, 0xFF)
            let nWord :=
                or(or(and(shl(8, nBitsLE), 0x7f0000), and(shr(8, nBitsLE), 0xff00)), and(shr(24, nBitsLE), 0xff))

            switch lt(nSize, 3)
            case 1 {
                target := shr(shl(3, sub(3, nSize)), nWord) //shl(3, sub(3, nSize)) == mul(sub(3, nSize), 8)
            }
            default {
                target := shl(shl(3, sub(nSize, 3)), nWord) //shl(3, sub(nSize, 3)) == mul(sub(nSize, 3), 8)
            }
        }
        require(target == 0 || nBitsLE & 0x8000 == 0, "Nbits: negative");
    }

    //Compresses difficulty target to nBits
    //Description: https://btcinformation.org/en/developer-reference#target-nbits
    function toReversedNbits(uint256 target) internal pure returns (uint32 nBitsLE) {
        assembly {
            switch target
            case 0 {
                nBitsLE := 0x00000000
            }
            default {
                //Find first non-zero byte
                let start := 0
                for {} iszero(byte(start, target)) { start := add(start, 1) } {}
                let nSize := sub(32, start)

                let result
                switch lt(nSize, 3)
                case 1 {
                    result := shl(shl(3, sub(3, nSize)), target) //shl(3, sub(3, nSize)) == mul(sub(3, nSize), 8)
                }
                default {
                    result := shr(shl(3, sub(nSize, 3)), target) //shl(3, sub(nSize, 3)) == mul(sub(nSize, 3), 8)
                }

                //Check that nbits are not encoding negative number, in case yes, shift
                // the result one byte to the right and adjust nSize accordingly
                if eq(and(result, 0x00800000), 0x00800000) {
                    result := shr(8, result)
                    nSize := add(nSize, 1)
                }

                nBitsLE := or(
                    or(and(shl(24, result), 0xff000000), and(shl(8, result), 0xff0000)),
                    or(and(shr(8, result), 0xff00), nSize)
                )
            }
        }
    }
}
