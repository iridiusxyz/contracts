// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AnchorVault} from "../src/AnchorVault.sol";
import {OracleRouter} from "../src/OracleRouter.sol";
import {SwapRouter} from "../src/SwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/IExternal.sol";
import {IOracleRouter} from "../src/interfaces/IOracleRouter.sol";
import {Types} from "../src/libraries/Types.sol";
import {MockStreamAdapter} from "../src/mocks/Mocks.sol";

/// @notice Sessions and halts: with the underlying market closed, spreads widen and clips shrink, and any
///         oracle failure halts trading rather than producing a wrong price.
contract RegimesTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seed(nvdaVault, NVDA_MID);
    }

    function test_closedSessionWidensSpreadAndShrinksClip() public {
        (uint256 regularOut,) = nvdaVault.quoteSwap(true, 10_000e6);

        nvda.setMarketStatus(5); // by Chainlink convention, 5 = closed
        (uint256 closedOut, Types.Breakdown memory b) = nvdaVault.quoteSwap(true, 10_000e6);

        assertEq(uint8(b.session), uint8(Types.Session.Closed));
        assertEq(b.halfSpreadBps, 30); // a 10 bps base under the x3 closed multiplier
        assertLt(closedOut, regularOut);

        // The clip is halved, so 26,000 fits within the 50,000 regular clip but exceeds the 25,000 closed one.
        vm.expectRevert(abi.encodeWithSelector(AnchorVault.ClipExceeded.selector, 26_000e6, 25_000e6));
        nvdaVault.quoteSwap(true, 26_000e6);
    }

    function test_extendedSessionMultiplier() public {
        nvda.setMarketStatus(2);
        (, Types.Breakdown memory b) = nvdaVault.quoteSwap(true, 10_000e6);
        assertEq(uint8(b.session), uint8(Types.Session.Extended));
        assertEq(b.halfSpreadBps, 15); // a 10 bps base under the x1.5 extended multiplier
    }

    function test_staleFeedHaltsTrading() public {
        vm.warp(block.timestamp + 2 hours); // the staleness bound for the regular session is 1 hour
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // A new round lifts the halt by itself, with no privileged action required.
        nvdaFeed.set(int256(NVDA_PRICE_8));
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_corporateActionPausesAndResumes() public {
        nvda.setOraclePaused(true);
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        nvda.setOraclePaused(false);
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_moveCapPausesMarketPendingReview() public {
        _swap(address(usdg), address(nvda), 1_000e6); // records the first checkpoint

        // A 30% print against a 25% cap shows as halted as soon as it arrives: the preview rejects it,
        // the router therefore sees no vault quote, and no maker can settle against it either.
        nvdaFeed.set(int256(NVDA_PRICE_8 * 130 / 100));
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));
        assertFalse(oracle.checkpoint(address(nvda)).paused);

        // Nothing survives a reverted fill, so whoever calls refresh is the one who records the pause.
        vm.expectEmit(true, false, false, true);
        emit OracleRouter.MarketPausedEvent(address(nvda), NVDA_MID, NVDA_MID * 130 / 100);
        vm.prank(outsider);
        oracle.refresh(address(nvda));
        assertTrue(oracle.checkpoint(address(nvda)).paused);

        // After being recorded, the halt lasts beyond the move-cap window. Otherwise the doubtful print
        // would just become the new baseline an hour later and fill with nobody having reviewed it.
        vm.warp(block.timestamp + 2 hours);
        nvdaFeed.set(int256(NVDA_PRICE_8 * 130 / 100));
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Only governance can clear the pause, with a published rationale. Resume resets the checkpoint
        // baseline, so trading picks up at the reviewed price without tripping the cap again.
        vm.prank(gov);
        oracle.resume(address(nvda));
        assertGt(_swap(address(usdg), address(nvda), 1_000e6), 0);
    }

    function test_moveCapRebaselinesAfterTheWindow() public {
        _swap(address(usdg), address(nvda), 1_000e6);

        // The cap only measures against a recent checkpoint. A print arriving after the window, no matter
        // how far it is from the previous one, counts as normal drift in a quiet market and sets a new baseline.
        vm.warp(block.timestamp + 2 hours);
        nvdaFeed.set(int256(NVDA_PRICE_8 * 130 / 100));
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
        assertGt(_swap(address(usdg), address(nvda), 1_000e6), 0);
        assertEq(oracle.checkpoint(address(nvda)).lastPrice, NVDA_MID * 130 / 100);
    }

    function test_sequencerOutageAndGrace() public {
        sequencer.setWithTimestamps(1, block.timestamp, block.timestamp); // the sequencer is down
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Running again but within the one-hour grace period, so trading stays halted.
        sequencer.setWithTimestamps(0, block.timestamp, block.timestamp);
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        vm.warp(block.timestamp + 61 minutes);
        nvdaFeed.set(int256(NVDA_PRICE_8));
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_uninitializedSequencerRoundHaltsTrading() public {
        // Chainlink gives startedAt = 0 until the uptime round is initialised. That has to count as an
        // outage rather than "up since the epoch", or the grace arithmetic would let trading straight through.
        sequencer.setWithTimestamps(0, 0, block.timestamp);
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);
    }

    function test_scheduleRefusesImpossibleSessions() public {
        // Regular hours closing before they open would make every minute extended or closed.
        OracleRouter.Schedule memory s = OracleRouter.Schedule({
            regularOpen: 21 hours, regularClose: 14 hours + 30 minutes, extendedOpen: 9 hours, extendedClose: 25 hours
        });
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidSchedule.selector);
        oracle.setSchedule(s);

        // Regular hours have to fall within extended hours.
        s = OracleRouter.Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 15 hours, extendedClose: 25 hours
        });
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidSchedule.selector);
        oracle.setSchedule(s);

        // An extended session running into its own next open would leave the market without any closed period.
        s = OracleRouter.Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 9 hours, extendedClose: 33 hours
        });
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidSchedule.selector);
        oracle.setSchedule(s);

        // The launch layout, with extended hours running past midnight, is still accepted as before.
        s = OracleRouter.Schedule({
            regularOpen: 14 hours + 30 minutes, regularClose: 21 hours, extendedOpen: 9 hours, extendedClose: 25 hours
        });
        vm.prank(gov);
        oracle.setSchedule(s);
        (,,, uint32 extendedClose) = oracle.schedule();
        assertEq(extendedClose, 25 hours);
    }

    function test_feedConfigRefusesSelfDisablingGuards() public {
        // With a zero staleness bound every round would be stale and the market would halt for good.
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidFeedConfig.selector);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            0,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0)
        );

        // A zero-window move cap would only ever compare prints within one block.
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidFeedConfig.selector);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            0,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0)
        );

        // With zero divergence tolerance, a stream adapter would turn down every report it checks.
        vm.prank(gov);
        vm.expectRevert(OracleRouter.InvalidFeedConfig.selector);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            0,
            address(nvda),
            address(nvda),
            address(nvda),
            address(0xDEAD)
        );
    }

    function test_streamReportVerifiesOnlyAgainstALiveMid() public {
        MockStreamAdapter stream = new MockStreamAdapter();
        vm.prank(gov);
        oracle.configureFeed(
            address(nvda),
            address(usdg),
            AggregatorV3Interface(address(nvdaFeed)),
            1 hours,
            2 hours,
            4 days,
            2500,
            1 hours,
            200,
            address(nvda),
            address(nvda),
            address(nvda),
            address(stream)
        );

        // Within tolerance, the report verifies and is scaled to quote-token units.
        stream.set(NVDA_PRICE_8);
        assertEq(oracle.verifyStreamReport(address(nvda), ""), NVDA_MID);

        // A divergence of 3% against a 2% tolerance is rejected.
        stream.set(NVDA_PRICE_8 * 103 / 100);
        vm.expectRevert(abi.encodeWithSelector(OracleRouter.StreamDivergence.selector, NVDA_MID, NVDA_MID * 103 / 100));
        oracle.verifyStreamReport(address(nvda), "");

        // Divergence is measured against the feed mid, which is precisely the value not to trust while
        // the market is halted, so no report verifies until the halt is lifted.
        stream.set(NVDA_PRICE_8);
        vm.prank(gov);
        oracle.pause(address(nvda));
        vm.expectRevert(abi.encodeWithSelector(OracleRouter.MarketHalted.selector, address(nvda)));
        oracle.verifyStreamReport(address(nvda), "");
    }

    function test_multiplierReportedNotDoubleApplied() public view {
        // The ERC-8056 multiplier is already built into Chainlink equity feeds, so the router exposes it
        // for display only and never applies it to the price.
        assertEq(oracle.quote(address(nvda)).multiplier, 1e18);
        assertEq(oracle.quote(address(nvda)).price, NVDA_MID);
    }

    function test_refreshOnlyCheckpointsPrintsTheMarketCouldTradeOn() public {
        _swap(address(usdg), address(nvda), 1_000e6);
        uint256 baselineAt = oracle.checkpoint(address(nvda)).lastAt;

        // The router will not fill on a stale round, so such a round cannot become the baseline for
        // judging the next print either.
        vm.warp(block.timestamp + 2 hours);
        vm.prank(outsider);
        oracle.refresh(address(nvda));
        assertEq(oracle.checkpoint(address(nvda)).lastAt, baselineAt);

        // The same goes for a fresh round arriving while the source is paused. What matters here is a
        // corporate action: when the pause starts the feed still carries the pre-split price, someone
        // calls refresh, and the split-adjusted print then lands within the move-cap window. Measured
        // from the paused refresh, that print would trip the cap and hold the market until governance
        // resumes it; measured from the last real fill, it falls outside the window and just sets a new baseline.
        nvdaFeed.set(int256(NVDA_PRICE_8));
        nvda.setOraclePaused(true);
        vm.prank(outsider);
        oracle.refresh(address(nvda));
        assertEq(oracle.checkpoint(address(nvda)).lastAt, baselineAt);

        vm.warp(block.timestamp + 10 minutes);
        nvdaFeed.set(int256(NVDA_PRICE_8 / 10)); // a 10-for-1 split
        nvda.setOraclePaused(false);
        assertFalse(oracle.quote(address(nvda)).paused);
        vm.prank(outsider);
        oracle.refresh(address(nvda));
        assertEq(oracle.checkpoint(address(nvda)).lastPrice, NVDA_MID / 10);
        assertFalse(oracle.checkpoint(address(nvda)).paused);
    }

    function test_priceThatScalesToZeroIsInvalid() public {
        // An 8-decimal answer smaller than one quote unit scales down to a zero mid. Since the vault's
        // ask, the RFQ band and the stream divergence check all divide by the mid, it must be stopped at
        // the entrance rather than causing a panic in each of them.
        nvdaFeed.set(99); // 0.00000099 USD, under the 6-decimal quote unit
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.PriceInvalid.selector, address(nvda)));
        oracle.quote(address(nvda));
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.PriceInvalid.selector, address(nvda)));
        nvdaVault.quoteSwap(true, 1_000e6);

        // Pricing resumes with the first answer that rounds to a whole quote unit.
        nvdaFeed.set(100);
        assertEq(oracle.quote(address(nvda)).price, 1);
    }
}
