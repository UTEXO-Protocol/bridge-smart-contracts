// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.35;

//Interval (in blocks) of the difficulty adjustment
uint256 constant DIFFICULTY_ADJUSTMENT_INTERVAL = 2016;

//Maximum positive difference between bitcoin block's timestamp and EVM chain's on-chain clock
//Nodes in bitcoin network generally reject any block with timestamp more than 2 hours in the future
//As we are dealing with another blockchain here,
// with the possibility of the EVM chain's on-chain clock being skewed, we chose double the value -> 4 hours
uint256 constant MAX_FUTURE_BLOCKTIME = 4 * 60 * 60;

//Lowest possible mining difficulty - highest possible target
uint256 constant UNROUNDED_MAX_TARGET = 0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
uint256 constant ROUNDED_MAX_TARGET = 0x00000000FFFF0000000000000000000000000000000000000000000000000000;
uint32 constant ROUNDED_MAX_TARGET_NBITS = 0xFFFF001D;

//Bitcoin epoch timespan
uint256 constant TARGET_TIMESPAN = 14 * 24 * 60 * 60; //2 weeks
uint256 constant TARGET_TIMESPAN_DIV_4 = TARGET_TIMESPAN / 4;
uint256 constant TARGET_TIMESPAN_MUL_4 = TARGET_TIMESPAN * 4;
