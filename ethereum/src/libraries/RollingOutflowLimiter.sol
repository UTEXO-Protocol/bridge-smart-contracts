// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title RollingOutflowLimiter
/// @notice Bounded-storage accounting for aggregate outflow over a rolling
///         time window.
/// @dev Usage is grouped into one-hour slots. Twenty-five slots are retained:
///      an amount recorded at any point in hour H is removed no earlier than
///      the beginning of hour H+25, so it remains counted for at least 24
///      complete hours. This deliberately errs on the conservative side by up
///      to one hour and avoids the boundary double-spend of fixed daily epochs.
library RollingOutflowLimiter {
    uint256 internal constant SLOT_DURATION = 1 hours;
    uint256 internal constant SLOT_COUNT = 25;

    struct Window {
        uint256 spent;
        uint256 lastEpoch;
        bool initialized;
        uint256[SLOT_COUNT] slots;
    }

    /// @notice Record `amount` in the current rolling window.
    /// @return updatedSpent Total non-expired usage after recording `amount`.
    function consume(Window storage window, uint256 amount) internal returns (uint256 updatedSpent) {
        _roll(window);

        uint256 index = _currentEpoch() % SLOT_COUNT;
        window.slots[index] += amount;
        updatedSpent = window.spent + amount;
        window.spent = updatedSpent;
    }

    /// @notice Return the currently counted usage without modifying storage.
    function current(Window storage window) internal view returns (uint256 currentSpent) {
        if (!window.initialized) return 0;

        uint256 epoch = _currentEpoch();
        uint256 lastEpoch = window.lastEpoch;
        currentSpent = window.spent;

        // Timestamps cannot move backwards on-chain. If a test environment does,
        // retain all usage rather than accidentally weakening the limit.
        if (epoch <= lastEpoch) return currentSpent;

        uint256 elapsed = epoch - lastEpoch;
        if (elapsed >= SLOT_COUNT) return 0;

        for (uint256 i = 1; i <= elapsed; i++) {
            currentSpent -= window.slots[(lastEpoch + i) % SLOT_COUNT];
        }
    }

    /// @dev Expire slots that are at least 25 epochs old and advance the ring.
    function _roll(Window storage window) private {
        uint256 epoch = _currentEpoch();

        if (!window.initialized) {
            window.initialized = true;
            window.lastEpoch = epoch;
            return;
        }

        uint256 lastEpoch = window.lastEpoch;
        if (epoch <= lastEpoch) return;

        uint256 elapsed = epoch - lastEpoch;
        if (elapsed >= SLOT_COUNT) {
            for (uint256 i = 0; i < SLOT_COUNT; i++) {
                delete window.slots[i];
            }
            window.spent = 0;
        } else {
            uint256 spent = window.spent;
            for (uint256 i = 1; i <= elapsed; i++) {
                uint256 index = (lastEpoch + i) % SLOT_COUNT;
                spent -= window.slots[index];
                delete window.slots[index];
            }
            window.spent = spent;
        }

        window.lastEpoch = epoch;
    }

    function _currentEpoch() private view returns (uint256) {
        return block.timestamp / SLOT_DURATION;
    }
}
