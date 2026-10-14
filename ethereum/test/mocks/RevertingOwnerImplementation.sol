// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {MissingOwnerImplementation} from "./MissingOwnerImplementation.sol";

/// @notice Bridge implementation whose owner getter always reverts.
contract RevertingOwnerImplementation is MissingOwnerImplementation {
    function owner() external pure returns (address) {
        revert("broken owner");
    }
}
