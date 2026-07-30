// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {RollingOutflowLimiterHarness} from "./mocks/RollingOutflowLimiterHarness.sol";

contract RollingOutflowLimiterTest is Test {
    RollingOutflowLimiterHarness harness;

    function setUp() public {
        harness = new RollingOutflowLimiterHarness();
        vm.warp(1_000_000);
    }

    function test_current_startsAtZero() public view {
        assertEq(harness.current(), 0);
    }

    function test_consume_accumulatesWithinOneSlot() public {
        assertEq(harness.consume(10), 10);
        assertEq(harness.consume(15), 25);
        assertEq(harness.current(), 25);
    }

    function test_usageDoesNotExpireBeforeFull24Hours() public {
        uint256 start = block.timestamp;
        harness.consume(100);

        vm.warp(start + 24 hours);
        assertEq(harness.current(), 100, "hour-slot rounding must never expire usage early");
    }

    function test_usageExpiresAfterConservative25HourBound() public {
        harness.consume(100);

        vm.warp(block.timestamp + 25 hours);
        assertEq(harness.current(), 0);
        assertEq(harness.consume(7), 7, "stale ring state cleared before new usage");
    }

    function test_rollingExpiryRemovesOnlyExpiredSlots() public {
        harness.consume(10);
        vm.warp(block.timestamp + 10 hours);
        harness.consume(20);
        vm.warp(block.timestamp + 15 hours);

        assertEq(harness.current(), 20, "old slot expired while newer slot remains");
        assertEq(harness.consume(5), 25);
    }

    function testFuzz_currentEqualsSumOfNonExpiredSlots(uint128 a, uint128 b, uint128 c) public {
        a = uint128(bound(a, 0, type(uint96).max));
        b = uint128(bound(b, 0, type(uint96).max));
        c = uint128(bound(c, 0, type(uint96).max));

        harness.consume(a);
        vm.warp(block.timestamp + 5 hours);
        harness.consume(b);
        vm.warp(block.timestamp + 20 hours);

        assertEq(harness.current(), b, "first slot expired at 25 epochs");

        harness.consume(c);
        assertEq(harness.current(), uint256(b) + uint256(c));
    }
}
