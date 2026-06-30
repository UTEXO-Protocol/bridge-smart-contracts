// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title OutflowRateLimiter
/// @dev Amounts are stored as uint128 to keep bucket state compact; Bridge
///      rejects larger admin inputs before constructing a limit config.
library OutflowRateLimiter {
    error LimitNotConfigured();
    error StoredAllowanceAboveCapacity(uint256 available, uint256 capacity);
    error TokenRequestAboveCapacity(uint256 capacity, uint256 requested, address token);
    error AggregateRequestAboveCapacity(uint256 capacity, uint256 requested);
    error TokenOutflowThrottled(uint256 retryAfter, uint256 available, address token);
    error AggregateOutflowThrottled(uint256 retryAfter, uint256 available);
    error InvalidLimitConfig(Settings settings);
    error DisabledLimitHasValues(Settings settings);
    error LimitMustStayDisabled();
    error AmountExceedsUint128(uint256 value);

    event AllowanceSpent(uint256 amount);
    event LimitSettingsChanged(Settings settings);

    struct Bucket {
        uint128 tokens;
        uint32 lastUpdated;
        bool isEnabled;
        uint128 capacity;
        uint128 rate;
    }

    struct Settings {
        bool isEnabled;
        uint128 capacity;
        uint128 rate;
    }

    /// @notice Debit `amount` from an enabled bucket.
    /// @dev `token == address(0)` selects aggregate-scope revert reasons.
    function spend(Bucket storage bucket, uint256 amount, address token) internal {
        if (!bucket.isEnabled) revert LimitNotConfigured();
        if (amount == 0) return;

        uint256 capacity = bucket.capacity;
        uint256 available = _preview(bucket);

        if (amount > capacity) {
            if (token == address(0)) revert AggregateRequestAboveCapacity(capacity, amount);
            revert TokenRequestAboveCapacity(capacity, amount, token);
        }

        if (amount > available) {
            uint256 retryAfter = _ceilDiv(amount - available, bucket.rate);
            if (token == address(0)) revert AggregateOutflowThrottled(retryAfter, available);
            revert TokenOutflowThrottled(retryAfter, available, token);
        }

        // Persist the post-spend state in one write each (no separate refill write).
        bucket.tokens = _asUint128(available - amount);
        bucket.lastUpdated = uint32(block.timestamp);
        emit AllowanceSpent(amount);
    }

    /// @notice Apply settings and fill the bucket on the first enable only.
    /// @dev Later changes preserve accrued allowance, clamped to new capacity.
    function configurePrimed(Bucket storage bucket, Settings memory settings) internal {
        bool firstEnable = !bucket.isEnabled && settings.isEnabled;
        configure(bucket, settings);
        if (firstEnable) bucket.tokens = settings.capacity;
    }

    /// @notice Return bucket state including refill accrued up to this block.
    function currentState(Bucket memory bucket) internal view returns (Bucket memory) {
        bucket.tokens = _asUint128(_preview(bucket));
        bucket.lastUpdated = uint32(block.timestamp);
        return bucket;
    }

    /// @notice Apply new settings while carrying over accrued allowance.
    function configure(Bucket storage bucket, Settings memory settings) internal {
        uint256 carried = _preview(bucket);

        bucket.tokens = _asUint128(_min(carried, settings.capacity));
        bucket.lastUpdated = uint32(block.timestamp);
        bucket.isEnabled = settings.isEnabled;
        bucket.capacity = settings.capacity;
        bucket.rate = settings.rate;

        emit LimitSettingsChanged(settings);
    }

    /// @notice Validate settings before they are written to a bucket.
    function validate(Settings memory settings, bool mustBeDisabled) internal pure {
        if (mustBeDisabled && settings.isEnabled) revert LimitMustStayDisabled();

        if (settings.isEnabled) {
            if (settings.capacity == 0 || settings.rate == 0 || settings.rate >= settings.capacity) {
                revert InvalidLimitConfig(settings);
            }
            return;
        }

        if (settings.capacity != 0 || settings.rate != 0) revert DisabledLimitHasValues(settings);
    }

    function _preview(Bucket memory bucket) private view returns (uint256) {
        uint256 available = bucket.tokens;
        uint256 capacity = bucket.capacity;
        if (available > capacity) revert StoredAllowanceAboveCapacity(available, capacity);

        uint256 elapsed = block.timestamp - bucket.lastUpdated;
        if (elapsed == 0 || bucket.rate == 0 || available == capacity) return available;

        uint256 room = capacity - available;
        uint256 refillRate = bucket.rate;
        if (elapsed >= _ceilDiv(room, refillRate)) return capacity;

        return available + elapsed * refillRate;
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator == 0 ? 0 : ((numerator - 1) / denominator) + 1;
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }

    function _asUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert AmountExceedsUint128(value);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }
}
