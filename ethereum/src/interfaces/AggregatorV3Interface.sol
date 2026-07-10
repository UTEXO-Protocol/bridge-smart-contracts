// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

// Vendored from @chainlink/contracts (chainlink-brownie-contracts v1.3.0),
// src/v0.8/shared/interfaces/AggregatorV3Interface.sol. Inlined here to drop the
// dependency on the deprecated/archived chainlink-brownie-contracts repository.
// The interface is self-contained (no imports) and matches Chainlink upstream.

// solhint-disable-next-line interface-starts-with-i
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
