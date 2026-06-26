// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { OutflowRateLimiter } from '../../src/libraries/OutflowRateLimiter.sol';

/// @title OutflowRateLimiterHarness
/// @notice Thin external wrapper around the `OutflowRateLimiter` library so its
///         `internal` functions can be unit-tested in isolation, without the
///         `Bridge` contract.
/// @dev    Holds a single `Bucket` in storage. Storage-mutating library calls
///         (`spend` / `configure` / `configurePrimed`) act on it; `read`
///         exposes the raw persisted state and `currentState` exposes the
///         refill-adjusted view. `setRaw` lets tests construct otherwise
///         unreachable states (e.g. a stored allowance above capacity) to drive
///         the library's defensive branches.
contract OutflowRateLimiterHarness {
    using OutflowRateLimiter for OutflowRateLimiter.Bucket;

    OutflowRateLimiter.Bucket internal bucket;

    // ----- storage-mutating wrappers -----

    function spend(uint256 amount, address token) external {
        bucket.spend(amount, token);
    }

    function configure(OutflowRateLimiter.Settings memory settings) external {
        bucket.configure(settings);
    }

    function configurePrimed(OutflowRateLimiter.Settings memory settings) external {
        bucket.configurePrimed(settings);
    }

    // ----- view wrappers -----

    function currentState() external view returns (OutflowRateLimiter.Bucket memory) {
        return bucket.currentState();
    }

    function read() external view returns (OutflowRateLimiter.Bucket memory) {
        return bucket;
    }

    // ----- pure wrappers -----

    function validate(OutflowRateLimiter.Settings memory settings, bool mustBeDisabled) external pure {
        OutflowRateLimiter.validate(settings, mustBeDisabled);
    }

    /// @dev Drives the `uint256 -> uint128` narrowing guard directly; this path
    ///      is unreachable through the public API because all inputs are bounded
    ///      by the `uint128` capacity/token fields.
    function asUint128(uint256 value) external pure returns (uint128) {
        return OutflowRateLimiter._asUint128(value);
    }

    // ----- test setup helper -----

    function setRaw(
        uint128 tokens,
        uint32 lastUpdated,
        bool isEnabled,
        uint128 capacity,
        uint128 rate
    ) external {
        bucket = OutflowRateLimiter.Bucket({
            tokens: tokens,
            lastUpdated: lastUpdated,
            isEnabled: isEnabled,
            capacity: capacity,
            rate: rate
        });
    }
}
