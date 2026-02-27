// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.28;

import {CappedOracle} from "sparklend-advanced/CappedOracle.sol";
import {AggregatorV3Interface} from "./lib/DeployHelpers.sol";

/**
 * @title CappedChainlinkFeed
 * @notice Extends Spark's audited CappedOracle with latestRoundData() for Morpho oracle compatibility
 * @dev CappedOracle (audited by ChainSecurity) provides latestAnswer() = min(maxPrice, source price).
 *      This contract adds latestRoundData() which Morpho's ChainlinkDataFeedLib requires.
 */
contract CappedChainlinkFeed is CappedOracle {
    constructor(address _source, int256 _maxPrice) CappedOracle(_source, _maxPrice) {}

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) =
            AggregatorV3Interface(address(source)).latestRoundData();
        if (answer > maxPrice) answer = maxPrice;
    }
}
