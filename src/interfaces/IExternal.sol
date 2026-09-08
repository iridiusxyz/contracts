// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A minimal interface to Chainlink aggregators (price feeds plus the L2 Sequencer Uptime Feed).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice The ERC-8056 corporate-action interface that Robinhood Stock Tokens expose.
interface IERC8056 {
    /// @return Shares per token at 18 decimals, accounting for splits and reinvested dividends.
    function uiMultiplier() external view returns (uint256);
}

/// @notice An optional source of pauses (a corporate action is under way). Either the token or a feed wrapper can serve.
interface IOraclePauseSource {
    function oraclePaused() external view returns (bool);
}

/// @notice An optional source of market status that mirrors the `marketStatus` field of Chainlink Data Streams v11 RWA.
interface IMarketStatusSource {
    /// @return status Follows the Chainlink convention: 1 = regular session, 2 = extended hours, 5 = closed.
    function marketStatus() external view returns (uint8 status);
}

/// @notice Checks a Chainlink Data Streams report on-chain and hands back a price.
interface IStreamAdapter {
    /// @param report The signed report payload for the stream that is configured.
    /// @return price Expressed in the feed answer's units (feed decimals).
    /// @return observedAt Timestamp carried by the report.
    function verify(address collateralToken, bytes calldata report) external returns (uint256 price, uint256 observedAt);
}
