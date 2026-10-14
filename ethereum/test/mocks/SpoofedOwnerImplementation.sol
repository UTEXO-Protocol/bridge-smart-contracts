// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {BridgeV2Mock} from "./BridgeV2Mock.sol";

/// @notice A view owner getter can report another owner without changing storage.
contract SpoofedOwnerImplementation is BridgeV2Mock {
    address private immutable _reportedOwner;

    constructor(address reportedOwner_) {
        _reportedOwner = reportedOwner_;
    }

    function owner() public view override returns (address) {
        return _reportedOwner;
    }
}
