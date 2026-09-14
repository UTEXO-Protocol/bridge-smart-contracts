// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Bridge} from "../../src/Bridge.sol";

contract BridgeV2Mock is Bridge {
    uint256 public upgradeValue;

    error UpgradeInitializationFailed();

    function initializeV2(uint256 value) external reinitializer(2) {
        upgradeValue = value;
    }

    function initializeV2AndRevert(uint256 value) external reinitializer(2) {
        upgradeValue = value;
        revert UpgradeInitializationFailed();
    }

    function version() external pure returns (uint256) {
        return 2;
    }

    function initializeV2WithOwner(address newOwner) external reinitializer(2) {
        upgradeValue = 777;
        _transferOwnership(newOwner);
    }
}
