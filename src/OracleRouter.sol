// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IOracleRouter} from "./interfaces/IOracleRouter.sol";
import {IParamController} from "./interfaces/IParamController.sol";
import {
    AggregatorV3Interface,
    IERC8056,
    IOraclePauseSource,
    IMarketStatusSource,
    IStreamAdapter
} from "./interfaces/IExternal.sol";
import {Types} from "./libraries/Types.sol";

/// @title OracleRouter
/// @notice Puts the protocol's guards around Chainlink Data Feeds (and, optionally, Data Streams): session
///         classification, staleness bounds, move caps, corporate-action pauses and the sequencer-uptime
///         grace period. All quotes on the venue start from the mid reported here, and no other contract reads a feed.
/// @dev Prices come back as base units of the quote token per whole listed token. Because Chainlink equity
///      feeds already fold in the ERC-8056 multiplier, the multiplier is reported but not applied a second time.
contract OracleRouter is IOracleRouter {
    using SafeCast for uint256;

    struct FeedConfig {
        AggregatorV3Interface feed;
        uint8 feedDecimals;
        uint8 quoteDecimals;
        uint8 tokenDecimals;
        uint32 stalenessRegular;
        uint32 stalenessExtended;
        uint32 stalenessClosed;
        uint16 moveCapBps;
        /// @dev The maximum age of the previous checkpoint for the move cap to remain meaningful.
        uint32 moveCapWindow;
        uint16 streamDivergenceBps;
        address marketStatusSource;
        address pauseSource;
        address multiplierSource;
        address streamAdapter;
        bool configured;
    }

    struct Checkpoint {
        uint128 lastPrice;
        uint40 lastAt;
        bool paused;
    }

    /// @notice Weekly schedule (UTC seconds of day) used as a fallback if no market-status source is configured.
    struct Schedule {
        uint32 regularOpen;
        uint32 regularClose;
        uint32 extendedOpen;
        uint32 extendedClose;
    }

    uint8 internal constant CL_STATUS_CLOSED = 5;
    uint8 internal constant CL_STATUS_EXTENDED = 2;

    IParamController public immutable params;
    AggregatorV3Interface public sequencerFeed;
    Schedule public schedule;

    mapping(address => FeedConfig) internal _feeds;
    mapping(address => Checkpoint) internal _checkpoints;

    event FeedConfigured(address indexed token, address feed, uint8 feedDecimals, uint8 quoteDecimals);
    event SequencerFeedSet(address feed);
    event ScheduleSet(uint32 regularOpen, uint32 regularClose, uint32 extendedOpen, uint32 extendedClose);
    event MarketPausedEvent(address indexed token, uint256 lastPrice, uint256 newPrice);
    event MarketResumed(address indexed token);
    event Checkpointed(address indexed token, uint256 price);

    error NotGovernance();
    error InvalidFeedConfig();
    error InvalidSchedule();
    error MarketHalted(address token);
    error StreamNotConfigured(address token);
    error StreamDivergence(uint256 feedPrice, uint256 streamPrice);

    modifier onlyGovernance() {
        if (msg.sender != params.owner()) revert NotGovernance();
        _;
    }

    constructor(IParamController params_) {
        params = params_;
        // US equities in UTC, standard time: regular 14:30 to 21:00, extended 09:00 to 01:00 the following day.
        Schedule memory s = Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 9 hours, extendedClose: 25 hours
        });
        _validateSchedule(s);
        schedule = s;
    }

    // ---------------------------------------------------------------------
    // Configuration (governance)
    // ---------------------------------------------------------------------

    function configureFeed(
        address token,
        address quoteToken,
        AggregatorV3Interface feed,
        uint32 stalenessRegular,
        uint32 stalenessExtended,
        uint32 stalenessClosed,
        uint16 moveCapBps,
        uint32 moveCapWindow,
        uint16 streamDivergenceBps,
        address marketStatusSource,
        address pauseSource,
        address multiplierSource,
        address streamAdapter
    ) external onlyGovernance {
        // Reject settings that quietly switch off their own guard: with a zero staleness bound every round
        // is stale and the market halts permanently, a move cap with a zero window only ever compares
        // prints within a single block, and a zero divergence tolerance turns away every stream report.
        if (stalenessRegular == 0 || stalenessExtended == 0 || stalenessClosed == 0) revert InvalidFeedConfig();
        if (moveCapBps != 0 && moveCapWindow == 0) revert InvalidFeedConfig();
        if (streamAdapter != address(0) && streamDivergenceBps == 0) revert InvalidFeedConfig();
        uint8 fd = feed.decimals();
        uint8 qd = IERC20Metadata(quoteToken).decimals();
        uint8 td = IERC20Metadata(token).decimals();
        _feeds[token] = FeedConfig({
            feed: feed,
            feedDecimals: fd,
            quoteDecimals: qd,
            tokenDecimals: td,
            stalenessRegular: stalenessRegular,
            stalenessExtended: stalenessExtended,
            stalenessClosed: stalenessClosed,
            moveCapBps: moveCapBps,
            moveCapWindow: moveCapWindow,
            streamDivergenceBps: streamDivergenceBps,
            marketStatusSource: marketStatusSource,
            pauseSource: pauseSource,
            multiplierSource: multiplierSource,
            streamAdapter: streamAdapter,
            configured: true
        });
        emit FeedConfigured(token, address(feed), fd, qd);
    }

    function setSequencerFeed(AggregatorV3Interface feed) external onlyGovernance {
        sequencerFeed = feed;
        emit SequencerFeedSet(address(feed));
    }

    function setSchedule(Schedule calldata s) external onlyGovernance {
        _validateSchedule(s);
        schedule = s;
        emit ScheduleSet(s.regularOpen, s.regularClose, s.extendedOpen, s.extendedClose);
    }

    /// @notice Reopens a market paused manually or by the move cap, and wipes the checkpoint as well:
    ///         governance has already reviewed the print it resumes into, and measuring the next fill against
    ///         the price from before the pause would trip the cap again on the same gap it just approved.
    function resume(address token) external onlyGovernance {
        delete _checkpoints[token];
        emit MarketResumed(token);
    }

    function pause(address token) external onlyGovernance {
        _checkpoints[token].paused = true;
        emit MarketPausedEvent(token, _checkpoints[token].lastPrice, 0);
    }

    // ---------------------------------------------------------------------
    // Quotes
    // ---------------------------------------------------------------------

    function quote(address token) public view override returns (Quote memory q) {
        FeedConfig storage c = _feeds[token];
        if (!c.configured) revert FeedNotConfigured(token);

        (, int256 answer,, uint256 updatedAt,) = c.feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) revert PriceInvalid(token);

        q.price = _scale(uint256(answer), c.feedDecimals, c.quoteDecimals);
        // When the feed has more decimals than the quote token, even a positive answer can scale down to
        // zero. Every later price calculation divides by the mid, so such a print is treated as invalid.
        if (q.price == 0) revert PriceInvalid(token);
        q.updatedAt = uint64(updatedAt);
        q.session = _session(c);
        q.stale = block.timestamp - updatedAt > _stalenessBound(c, q.session);
        // A print beyond the move cap shows as paused even before anything records it, so previews, fills
        // and RFQ settlement all reject the doubtful round in the very block it arrives.
        q.paused = _checkpoints[token].paused || _sourcePaused(c) || _beyondMoveCap(c, _checkpoints[token], q.price);
        q.multiplier = _multiplier(c);
        q.sequencerGrace = _sequencerGrace();
    }

    /// @inheritdoc IOracleRouter
    /// @dev Open to anyone. A fill that trips the cap reverts, undoing all of its writes, so the vault path
    ///      on its own can never make the pause stick; anyone monitoring the feed can call this directly so
    ///      the halt lasts beyond the move-cap window until governance resumes the market.
    ///      Checkpoints are written only for prints the market could actually trade on. Each checkpoint is
    ///      the reference for judging the next print, and a stale round, a paused source or a sequencer
    ///      still in its grace period is precisely what should not serve as that reference: anchored to
    ///      one of them, the first sound print after a corporate action or an outage would trip the cap on
    ///      the very gap it ought to close, leaving the market waiting for an unnecessary governance resume.
    function refresh(address token) external override returns (Quote memory q) {
        q = quote(token);
        FeedConfig storage c = _feeds[token];
        Checkpoint storage cp = _checkpoints[token];
        if (_beyondMoveCap(c, cp, q.price)) {
            if (!cp.paused) {
                cp.paused = true;
                emit MarketPausedEvent(token, cp.lastPrice, q.price);
            }
            return q;
        }
        if (q.paused || q.stale || q.sequencerGrace) return q;
        cp.lastPrice = q.price.toUint128();
        cp.lastAt = uint40(block.timestamp);
        emit Checkpointed(token, q.price);
    }

    /// @inheritdoc IOracleRouter
    function verifyStreamReport(address token, bytes calldata report) external override returns (uint256 price) {
        FeedConfig storage c = _feeds[token];
        if (!c.configured) revert FeedNotConfigured(token);
        if (c.streamAdapter == address(0)) revert StreamNotConfigured(token);
        // Divergence is measured against the feed price, which is precisely what cannot be trusted while
        // the market is halted, so no report verifies until the halt is lifted.
        Quote memory q = quote(token);
        if (q.paused || q.stale || q.sequencerGrace) revert MarketHalted(token);
        (uint256 raw,) = IStreamAdapter(c.streamAdapter).verify(token, report);
        price = _scale(raw, c.feedDecimals, c.quoteDecimals);
        uint256 diff = price > q.price ? price - q.price : q.price - price;
        if (diff * Types.BPS / q.price > c.streamDivergenceBps) revert StreamDivergence(q.price, price);
    }

    function tokenDecimals(address token) external view override returns (uint8) {
        FeedConfig storage c = _feeds[token];
        if (!c.configured) revert FeedNotConfigured(token);
        return c.tokenDecimals;
    }

    function feedConfig(address token) external view returns (FeedConfig memory) {
        return _feeds[token];
    }

    function checkpoint(address token) external view returns (Checkpoint memory) {
        return _checkpoints[token];
    }

    function hasStream(address token) external view override returns (bool) {
        return _feeds[token].streamAdapter != address(0);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Values are seconds of a UTC day. The regular session must fall within the extended one, and the
    ///      extended session may cross midnight but has to close before it next opens. Any other shape means
    ///      either no regular session or a day without a closed period, and the session classifier can
    ///      honour neither.
    function _validateSchedule(Schedule memory s) internal pure {
        if (s.regularOpen >= s.regularClose || s.regularClose > 1 days) revert InvalidSchedule();
        if (s.extendedOpen > s.regularOpen || s.extendedClose < s.regularClose) revert InvalidSchedule();
        if (s.extendedClose >= 1 days + s.extendedOpen) revert InvalidSchedule();
    }

    function _scale(uint256 answer, uint8 fromDec, uint8 toDec) internal pure returns (uint256) {
        if (toDec >= fromDec) return answer * (10 ** (toDec - fromDec));
        return answer / (10 ** (fromDec - toDec));
    }

    function _session(FeedConfig storage c) internal view returns (Types.Session) {
        if (c.marketStatusSource != address(0)) {
            uint8 s = IMarketStatusSource(c.marketStatusSource).marketStatus();
            if (s == CL_STATUS_CLOSED) return Types.Session.Closed;
            if (s == CL_STATUS_EXTENDED) return Types.Session.Extended;
            return Types.Session.Regular;
        }
        return _scheduledSession();
    }

    /// @dev Fallback based on weekday and time of day, with Saturday and Sunday closed. Holidays are not
    ///      modelled, so production deployments should configure a market-status source.
    function _scheduledSession() internal view returns (Types.Session) {
        uint256 dayOfWeek = (block.timestamp / 1 days + 4) % 7; // 0 = Sunday
        uint256 secondOfDay = block.timestamp % 1 days;
        Schedule memory s = schedule;
        // The extended session can run past midnight (extendedClose > 24h), so cover the early-morning tail.
        bool inWrappedTail = s.extendedClose > 1 days && secondOfDay < s.extendedClose - 1 days;
        if (inWrappedTail) {
            uint256 prevDay = (dayOfWeek + 6) % 7;
            return (prevDay == 0 || prevDay == 6) ? Types.Session.Closed : Types.Session.Extended;
        }
        if (dayOfWeek == 0 || dayOfWeek == 6) return Types.Session.Closed;
        if (secondOfDay >= s.regularOpen && secondOfDay < s.regularClose) return Types.Session.Regular;
        if (secondOfDay >= s.extendedOpen && secondOfDay < (s.extendedClose > 1 days ? 1 days : s.extendedClose)) {
            return Types.Session.Extended;
        }
        return Types.Session.Closed;
    }

    /// @dev The cap exists to catch one bad print, which makes it meaningful only against a recent
    ///      checkpoint. Only `refresh` writes checkpoints, and in a quiet market the last one may be days
    ///      old, by which point normal drift is indistinguishable from a gap. Beyond the window, the next
    ///      refresh simply sets a new baseline.
    function _beyondMoveCap(FeedConfig storage c, Checkpoint storage cp, uint256 price) internal view returns (bool) {
        if (cp.lastPrice == 0 || c.moveCapBps == 0 || block.timestamp - cp.lastAt > c.moveCapWindow) return false;
        uint256 last = cp.lastPrice;
        uint256 diff = price > last ? price - last : last - price;
        return diff * Types.BPS / last > c.moveCapBps;
    }

    function _stalenessBound(FeedConfig storage c, Types.Session s) internal view returns (uint256) {
        if (s == Types.Session.Regular) return c.stalenessRegular;
        if (s == Types.Session.Extended) return c.stalenessExtended;
        return c.stalenessClosed;
    }

    function _sourcePaused(FeedConfig storage c) internal view returns (bool) {
        if (c.pauseSource == address(0)) return false;
        try IOraclePauseSource(c.pauseSource).oraclePaused() returns (bool p) {
            return p;
        } catch {
            return false;
        }
    }

    function _multiplier(FeedConfig storage c) internal view returns (uint256) {
        if (c.multiplierSource == address(0)) return Types.WAD;
        try IERC8056(c.multiplierSource).uiMultiplier() returns (uint256 m) {
            return m == 0 ? Types.WAD : m;
        } catch {
            return Types.WAD;
        }
    }

    /// @dev Chainlink L2 Sequencer Uptime Feed: answer 0 = up, 1 = down; startedAt = when the status last changed.
    ///      The underlying market keeps moving through an outage even though nobody can transact, so trading
    ///      remains halted for the grace period after recovery instead of restarting on a frozen mid.
    function _sequencerGrace() internal view returns (bool) {
        if (address(sequencerFeed) == address(0)) return false;
        (, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();
        if (answer != 0) return true; // sequencer is down: count it as grace so no trading happens
        // A zero startedAt means the round has not been initialised; without this check the grace-period
        // arithmetic would read "no data" as "up since the epoch" and allow trading to restart.
        if (startedAt == 0) return true;
        uint256 grace = params.riskParams().sequencerGrace;
        return block.timestamp - startedAt < grace;
    }
}
