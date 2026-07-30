// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {RollingOutflowLimiter} from "../../src/libraries/RollingOutflowLimiter.sol";

/// @title RollingOutflowLimiterHarness
/// @notice External wrapper for isolated rolling-window unit tests.
contract RollingOutflowLimiterHarness {
    using RollingOutflowLimiter for RollingOutflowLimiter.Window;

    RollingOutflowLimiter.Window private _window;

    function consume(uint256 amount) external returns (uint256) {
        return _window.consume(amount);
    }

    function current() external view returns (uint256) {
        return _window.current();
    }
}
