// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.35;

import {Nbits} from "./Nbits.sol";
import {
    TARGET_TIMESPAN, TARGET_TIMESPAN_DIV_4, TARGET_TIMESPAN_MUL_4,
    ROUNDED_MAX_TARGET, ROUNDED_MAX_TARGET_NBITS
} from "../Constants.sol";

library Difficulty {

    //Old version of the target computation, operates on targets and uses uint256 arithmetics
    // function _computeNewTarget(uint32 prevTimestamp, uint32 startTimestamp, uint256 prevTarget) pure internal returns (uint256 newTarget) {
    //     uint256 timespan = uint256(prevTimestamp) - uint256(startTimestamp);
        
    //     //Difficulty increase/decrease multiples are clamped between 0.25 (-75%) and 4 (+300%)
    //     if(timespan < TARGET_TIMESPAN_DIV_4) timespan = TARGET_TIMESPAN_DIV_4;
    //     if(timespan > TARGET_TIMESPAN_MUL_4) timespan = TARGET_TIMESPAN_MUL_4;

    //     newTarget = prevTarget * timespan / TARGET_TIMESPAN;
    //     if(newTarget > UNROUNDED_MAX_TARGET) newTarget = UNROUNDED_MAX_TARGET;
    // }

    //New version of the target computation, works directly with nBits
    function computeNewTarget(uint32 prevTimestamp, uint32 startTimestamp, uint32 prevNbitsLE, bool clampTarget) pure internal returns (uint256 newTarget, uint32 newNbitsLE) {
        uint256 timespan = uint256(prevTimestamp) - uint256(startTimestamp);
        //Difficulty increase/decrease multiples are clamped between 0.25 (-75%) and 4 (+300%)
        if(timespan < TARGET_TIMESPAN_DIV_4) timespan = TARGET_TIMESPAN_DIV_4;
        if(timespan > TARGET_TIMESPAN_MUL_4) timespan = TARGET_TIMESPAN_MUL_4;

        uint256 targetTimespan = TARGET_TIMESPAN;
        assembly {
            let nSize := and(prevNbitsLE, 0xFF)
            let nWord := or(
                or(
                    and(shl(16, prevNbitsLE), 0x7f000000),
                    and(prevNbitsLE, 0xff0000)
                ),
                and(shr(16, prevNbitsLE), 0xff00)
            ) //Shift it 1 more byte to the left, so we have enough precision when we do multiplication and division
            //The maximum value of the nWord is 0x7fffff00 (due to the extra shift to the left)
            //The range of values for the newNWord is from nWord/4 to nWord*4
            let newNWord := div(mul(nWord, timespan), targetTimespan) //Adjust the nWord based on timestamp

            if gt(and(newNWord, 0xff00000000), 0) {
                //The result requires increasing the nSize
                nSize := add(nSize, 1)
                newNWord := shr(8, newNWord)
            }
            if iszero(and(newNWord, 0xff000000)) {
                //The result requires decreasing the nSize
                nSize := sub(nSize, 1)
                newNWord := shl(8, newNWord)
            }
            //Any other possibility cannot happen, because of the bounded div 4 and mul 4 adjustments
            
            //Check that nbits are not encoding negative number, in case yes, shift
            // the result one byte to the right and adjust nSize accordingly
            if eq(and(newNWord, 0x80000000), 0x80000000) {
                newNWord := shr(8, newNWord)
                nSize := add(nSize, 1)
            }

            newNbitsLE := or(
                or(
                    and(shl(16, newNWord), 0xff000000),
                    and(newNWord, 0xff0000)
                ),
                or(
                    and(shr(16, newNWord), 0xff00),
                    nSize
                )
            )
        }

        newTarget = Nbits.toTarget(newNbitsLE);

        if(clampTarget) {
            if(newTarget > ROUNDED_MAX_TARGET) {
                newNbitsLE = ROUNDED_MAX_TARGET_NBITS;
                newTarget = ROUNDED_MAX_TARGET;
            }
        }
    }

    //Compute chainwork according to bitcoin core implementation
    // https://github.com/bitcoin/bitcoin/blob/master/src/chain.cpp#L131
    function getChainWork(uint256 target) pure internal returns (uint256 chainwork) {
        assembly {
            chainwork := add(div(not(target), add(target, 1)), 1)
        }
    }
}
