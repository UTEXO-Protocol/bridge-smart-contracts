// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {BridgeV2Mock} from "./BridgeV2Mock.sol";

/// @notice Bridge implementation that answers unknown selectors with one ABI word.
contract WordFallbackImplementation is BridgeV2Mock {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 42)
            return(0, 32)
        }
    }
}
