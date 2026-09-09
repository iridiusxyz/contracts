// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Types} from "../libraries/Types.sol";

/// @title IOracleRouter
/// @notice The one place the protocol obtains any price from.
interface IOracleRouter {
    struct Quote {
        /// @dev Base units of the quote token for each whole listed token.
        uint256 price;
        uint64 updatedAt;
        Types.Session session;
        /// @dev Set while the market is paused (by the move cap, manually, or via `oraclePaused()` on the source).
        bool paused;
        /// @dev Set when the price has aged past the staleness bound for the session.
        bool stale;
        /// @dev The token's ERC-8056 `uiMultiplier()` where available, otherwise 1e18.
        uint256 multiplier;
        /// @dev Set while the sequencer grace period after an outage is running.
        bool sequencerGrace;
    }

    error PriceInvalid(address token);
    error FeedNotConfigured(address token);

    function quote(address token) external view returns (Quote memory);
    /// @notice Updates the move-cap checkpoint, pausing the market when the price has moved beyond the cap.
    function refresh(address token) external returns (Quote memory);
    function verifyStreamReport(address token, bytes calldata report) external returns (uint256 price);
    function tokenDecimals(address token) external view returns (uint8);
    function hasStream(address token) external view returns (bool);
}
