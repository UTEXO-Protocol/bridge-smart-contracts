// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {MultisigProxy} from "../../src/MultisigProxy.sol";
import {EmergencyUnpause} from "../../script/interact/EmergencyUnpause.s.sol";

/// @notice Exposes inherited production nonce and digest preparation directly.
/// @dev Tests exercise the actual interaction script rather than a duplicate.
contract EmergencyUnpauseHarness is EmergencyUnpause {
    function prepare(MultisigProxy proxy, uint256 deadline) external view returns (uint256 nonce, bytes32 digest) {
        return _prepareEmergencyUnpause(proxy, deadline);
    }
}
