// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { AggregatorV3Interface } from '@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol';

/// @title MockAggregatorV3
/// @notice Minimal Chainlink-compatible price feed for tests. Lets each test
///         drive `answer` and `updatedAt` directly, including the failure
///         shapes (zero, negative, stale) that `CommissionManager` rejects.
contract MockAggregatorV3 is AggregatorV3Interface {
    uint8   private  _decimals;
    int256  public   answer;
    uint256 public   updatedAt;
    uint80  public   roundId;

    constructor(uint8 decimals_, int256 initialAnswer, uint256 initialUpdatedAt) {
        _decimals = decimals_;
        answer    = initialAnswer;
        updatedAt = initialUpdatedAt;
        roundId   = 1;
    }

    function setAnswer(int256 v) external { answer = v; }
    function setUpdatedAt(uint256 v) external { updatedAt = v; }

    // ---- AggregatorV3Interface --------------------------------------------

    function decimals() external view override returns (uint8) { return _decimals; }
    function description() external pure override returns (string memory) { return 'MockAggregatorV3'; }
    function version() external pure override returns (uint256) { return 1; }

    function getRoundData(uint80 r)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (r, answer, updatedAt, updatedAt, r);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
