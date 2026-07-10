// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.35;

struct BtcRelayState {
    uint32 blockHeight;
    uint224 chainWork;
}

library BtcRelayStateImpl {
    //Optimized read function, that reads all the values at once
    function read(BtcRelayState storage self) internal view returns (uint32 blockHeight, uint224 chainWork) {
        //The following assembly is equivalent to:
        // blockHeight = self.blockHeight;
        // chainWork = self.chainWork;
        assembly {
            let value := sload(self.slot) //All the data is stored at slot 0
            blockHeight := and(value, 0xffffffff)
            chainWork := shr(32, value)
        }
    }

    //Optimized write function that writes all the values at once
    function write(BtcRelayState storage self, uint32 blockHeight, uint224 chainWork) internal {
        //The following assembly is equivalent to:
        // self.blockHeight = blockHeight;
        // self.chainWork = chainWork;
        assembly {
            let value := or(blockHeight, shl(32, chainWork))
            sstore(self.slot, value)
        }
    }
}
