// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {MissingOwnerImplementation} from "./MissingOwnerImplementation.sol";

/// @notice Bridge implementation whose owner getter returns a truncated ABI word.
contract MalformedOwnerImplementation is MissingOwnerImplementation {
    fallback() external {
        assembly { return(0, 1) }
    }
}
