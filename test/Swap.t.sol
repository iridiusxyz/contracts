// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AnchorVault} from "../src/AnchorVault.sol";
import {ParamController} from "../src/ParamController.sol";
import {SwapRouter} from "../src/SwapRouter.sol";
import {IParamController} from "../src/interfaces/IParamController.sol";
import {IEligibilityRegistry} from "../src/interfaces/IEligibilityRegistry.sol";
import {Types, Roles} from "../src/libraries/Types.sol";

/// @notice The full vault path: pricing checked against the published formula, itemised fees, skew,
///         caps, bands, two-leg composition and where eligibility draws the line.
contract SwapTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seed(nvdaVault, NVDA_MID);
        _seed(spyVault, SPY_MID);
    }

    function test_buyPricesOffTheFormula() public {
        uint256 amountIn = 10_000e6;
        uint256 out = _swap(address(usdg), address(nvda), amountIn);

        // A balanced vault in the regular session: zero skew, 10 bps half-spread, 2 bps fee taken from the input.
        uint256 expected = _expectedBuyOut(amountIn, NVDA_MID, 10);
        assertEq(out, expected);
        assertEq(nvda.balanceOf(trader), 1_000e18 + expected);

        // The collector receives the itemised fee and 10% of the realised spread, and LPs keep the remainder.
        uint256 fee = amountIn * 2 / 10_000;
        uint256 net = amountIn - fee;
        uint256 spread = net - expected * NVDA_MID / 1e18;
        assertEq(usdg.balanceOf(address(fees)), fee + spread * 1000 / 10_000);
    }

    function test_sellPricesOffTheFormula() public {
        uint256 amountIn = 50e18;
        uint256 out = _swap(address(nvda), address(usdg), amountIn);

        uint256 bid = NVDA_MID * (10_000 - 10) / 10_000;
        uint256 gross = amountIn * bid / 1e18;
        uint256 expected = gross - gross * 2 / 10_000;
        assertEq(out, expected);
    }

    function test_breakdownIsItemised() public view {
        (uint256 out, Types.Breakdown memory b) = nvdaVault.quoteSwap(true, 10_000e6);
        assertGt(out, 0);
        assertEq(b.mid, NVDA_MID);
        assertEq(b.halfSpreadBps, 10);
        assertEq(b.skewBps, 0);
        assertEq(b.feeBps, 2);
        assertEq(uint8(b.session), uint8(Types.Session.Regular));
    }

    function test_skewTightensTheRebalancingSide() public {
        // Deplete the token side so the vault falls below target: further buys must then cost more, and
        // sells to it must pay better, than the balanced spread.
        _swap(address(usdg), address(nvda), 40_000e6);
        _swap(address(usdg), address(nvda), 40_000e6);

        (, Types.Breakdown memory buySide) = nvdaVault.quoteSwap(true, 10_000e6);
        (, Types.Breakdown memory sellSide) = nvdaVault.quoteSwap(false, 50e18);
        assertLt(buySide.skewBps, 0);
        assertGt(buySide.halfSpreadBps, 10);
        assertLt(sellSide.halfSpreadBps, 10);
    }

    function test_inventoryBandMakesVaultOneSided() public {
        // Withdraw most of the seed so the vault is small enough to reach the band edge within the clip.
        vm.startPrank(lp1);
        nvdaVault.withdraw(nvdaVault.balanceOf(lp1) * 9 / 10, lp1);
        vm.stopPrank();

        // With 100k of value, 50k per side and a 20% band, 15k of buys stays inside and another 10k crosses.
        _swap(address(usdg), address(nvda), 15_000e6);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 10_000e6, 0));

        // Quotes continue on the rebalancing side.
        uint256 out = _swap(address(nvda), address(usdg), 10e18);
        assertGt(out, 0);
    }

    function test_sellSideBandSimulationMatchesTheFill() public {
        // Use a fee big enough to shift the inventory maths, a band wide enough to accommodate it, and a
        // clip that allows one sell to reach the edge of the inventory band.
        vm.startPrank(gov);
        params.setFeeParams(IParamController.FeeParams({swapFeeBps: 1000, rfqFeeBps: 2, spreadShareBps: 1000}));
        params.setTierConfig(
            1,
            IParamController.TierConfig({
                baseHalfSpreadBps: 10,
                maxSkewBps: 15,
                inventoryBandBps: 2000,
                oracleBandBps: 1100,
                maxClip: 1_000_000e6,
                enabled: true
            })
        );
        vm.stopPrank();
        nvda.mint(trader, 2_000e18);

        // For a sell, the fee comes out of the gross proceeds yet goes to the collector along with the
        // spread share, leaving the vault down by the full gross. By that accounting a 208k sell into a
        // 500k/500k vault ends just beyond the 20% band; if the fee were simulated as kept, the same sell
        // would have previewed inside the band and filled.
        uint256 pastTheEdge = 208_000e6 * 1e18 / NVDA_MID;
        vm.expectRevert(AnchorVault.InventoryBandExceeded.selector);
        nvdaVault.quoteSwap(false, pastTheEdge);

        // When a sell previews inside the band, the vault is still inside it once the actual transfers happen.
        uint256 insideTheEdge = 190_000e6 * 1e18 / NVDA_MID;
        _swap(address(nvda), address(usdg), insideTheEdge);
        assertLe(nvdaVault.inventoryRatioBps() - 5_000, 2_000);
    }

    function test_clipBoundsSingleSwap() public {
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 60_000e6, 0));
    }

    function test_dailyVolumeCap() public {
        vm.prank(gov);
        params.setMarketConfig(
            address(nvda),
            IParamController.MarketConfig({tier: 1, dailyVolumeCap: 30_000e6, tvlCap: 5_000_000e6, enabled: true})
        );
        assertEq(nvdaVault.remainingDailyCap(), 30_000e6);
        _swap(address(usdg), address(nvda), 20_000e6);
        assertEq(nvdaVault.remainingDailyCap(), 10_000e6);

        // Quoting enforces the cap, so previews and fills match and the router sees a vault at its cap as
        // "no vault quote" instead of reverting partway through a fill.
        vm.expectRevert(AnchorVault.DailyCapExceeded.selector);
        nvdaVault.quoteSwap(true, 20_000e6);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 20_000e6, 0));

        // Anything the headroom says will fit does fill.
        assertGt(_swap(address(usdg), address(nvda), 10_000e6), 0);
        assertEq(nvdaVault.remainingDailyCap(), 0);

        // Each new UTC day resets the cap. Update the feed so the price is not stale.
        vm.warp(block.timestamp + 1 days);
        nvdaFeed.set(int256(NVDA_PRICE_8));
        assertEq(nvdaVault.remainingDailyCap(), 30_000e6);
        assertGt(_swap(address(usdg), address(nvda), 20_000e6), 0);
    }

    function test_slippageBoundReverts() public {
        uint256 expected = _expectedBuyOut(10_000e6, NVDA_MID, 10);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(SwapRouter.Slippage.selector, expected, expected + 1));
        router.swapExactIn(_params(address(usdg), address(nvda), 10_000e6, expected + 1));
    }

    function test_twoLegSwapThroughTheQuoteAsset() public {
        uint256 amountIn = 20e18; // NVDA goes in, SPY comes out
        uint256 out = _swap(address(nvda), address(spy), amountIn);

        // The first leg sells NVDA at its bid less the fee; the second buys SPY at its ask with the fee taken from the input.
        uint256 bid = NVDA_MID * (10_000 - 10) / 10_000;
        uint256 leg1Gross = amountIn * bid / 1e18;
        uint256 leg1Out = leg1Gross - leg1Gross * 2 / 10_000;
        uint256 expected = _expectedBuyOut(leg1Out, SPY_MID, 10);
        assertEq(out, expected);
        assertEq(spy.balanceOf(trader), 100e18 + expected);
    }

    function test_previewMatchesTheFill() public {
        // One leg, routed through the vault.
        SwapRouter.SwapParams memory p = _params(address(usdg), address(nvda), 10_000e6, 0);
        (uint256 previewed, Types.Venue venue) = router.previewExactIn(p);
        assertEq(uint8(venue), uint8(Types.Venue.Vault));
        vm.prank(trader);
        assertEq(router.swapExactIn(p), previewed);

        // Two legs via the quote asset, with the second priced on the output of the first.
        p = _params(address(nvda), address(spy), 20e18, 0);
        (previewed, venue) = router.previewExactIn(p);
        assertEq(uint8(venue), uint8(Types.Venue.Vault));
        vm.prank(trader);
        assertEq(router.swapExactIn(p), previewed);

        // When a maker candidate beats the vault, the preview reports the RFQ venue at the trader's net output.
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut + vaultOut / 1000, 42);
        p = _params(address(usdg), address(nvda), amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);
        (previewed, venue) = router.previewExactIn(p);
        assertEq(uint8(venue), uint8(Types.Venue.Rfq));
        assertEq(previewed, q.amountOut);
        vm.prank(trader);
        assertEq(router.swapExactIn(p), previewed);
    }

    function test_previewRaisesTheFillsErrors() public {
        // For the preview, just as for the fill, a halted market means no liquidity.
        nvda.setOraclePaused(true);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.previewExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));
        nvda.setOraclePaused(false);

        // A two-leg swap surfaces the vault's own reason, in this case the clip on the selling leg.
        vm.expectRevert(abi.encodeWithSelector(AnchorVault.ClipExceeded.selector, 300e18 * NVDA_MID / 1e18, 50_000e6));
        router.previewExactIn(_params(address(nvda), address(spy), 300e18, 0));

        // Supplying a candidate on a two-leg swap is a client error in either place.
        SwapRouter.SwapParams memory p = _params(address(nvda), address(spy), 1e18, 0);
        p.quote = _makerQuote(address(nvda), address(spy), 1e18, 1e18, 43);
        vm.expectRevert(SwapRouter.QuoteNotApplicable.selector);
        router.previewExactIn(p);
    }

    function test_traderEligibilityEnforced() public {
        usdg.mint(outsider, 10_000e6);
        vm.startPrank(outsider);
        usdg.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, outsider, Roles.TRADER));
        router.swapExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));
        vm.stopPrank();
    }

    function test_recipientEligibilityEnforced() public {
        SwapRouter.SwapParams memory p = _params(address(usdg), address(nvda), 1_000e6, 0);
        p.to = outsider;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, outsider, Roles.TRADER));
        router.swapExactIn(p);
    }

    function test_guardianPauseStopsSwapsOnly() public {
        vm.prank(guardian);
        params.setPaused(true);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.SwapsPaused.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));

        // The pause shuts off pricing as well, so no preview ever shows an unreachable quote.
        vm.expectRevert(AnchorVault.SwapsPaused.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Lifting the pause is not the guardian's job, since a stolen guardian key must not be able to
        // end a pause during an incident. Only the owner can clear it.
        vm.prank(guardian);
        vm.expectRevert(ParamController.NotOwner.selector);
        params.setPaused(false);
        vm.prank(gov);
        params.setPaused(false);
        assertGt(_swap(address(usdg), address(nvda), 1_000e6), 0);
    }

    function test_swapOnlyThroughRouter() public {
        vm.prank(trader);
        vm.expectRevert(AnchorVault.NotRouter.selector);
        nvdaVault.swap(true, 1_000e6, trader);
    }

    function test_deadlineEnforced() public {
        SwapRouter.SwapParams memory p = _params(address(usdg), address(nvda), 1_000e6, 0);
        p.deadline = block.timestamp - 1;
        vm.prank(trader);
        vm.expectRevert(SwapRouter.Expired.selector);
        router.swapExactIn(p);
    }

    function test_oversizeOrdersFailForTheirOwnReason() public {
        // An order well beyond the clip is rejected as a clip breach. When the size checks ran after the
        // balance simulation, a buy this big underflowed the token side first and showed up as an
        // arithmetic panic, both on a direct preview and on the two-leg preview that relays the vault's reason.
        vm.expectRevert(abi.encodeWithSelector(AnchorVault.ClipExceeded.selector, 1_000_000e6, 50_000e6));
        nvdaVault.quoteSwap(true, 1_000_000e6);
        uint256 sellLeg = 6_000e18 * NVDA_MID / 1e18;
        vm.expectRevert(abi.encodeWithSelector(AnchorVault.ClipExceeded.selector, sellLeg, 50_000e6));
        router.previewExactIn(_params(address(nvda), address(spy), 6_000e18, 0));

        // Within the clip but more than a small vault holds: reduce the vault to 25k per side and request
        // 30k of either. The error identifies the real problem rather than failing within the token transfer.
        uint256 lpShares = nvdaVault.balanceOf(lp1);
        vm.prank(lp1);
        nvdaVault.withdraw(lpShares * 95 / 100, lp1);
        uint256 tokenBal = nvda.balanceOf(address(nvdaVault));
        uint256 quoteBal = usdg.balanceOf(address(nvdaVault));

        uint256 wanted = _expectedBuyOut(30_000e6, NVDA_MID, 10);
        vm.expectRevert(abi.encodeWithSelector(AnchorVault.InsufficientInventory.selector, wanted, tokenBal));
        nvdaVault.quoteSwap(true, 30_000e6);

        uint256 sellIn = 30_000e6 * 1e18 / NVDA_MID;
        uint256 gross = sellIn * (NVDA_MID * (10_000 - 10) / 10_000) / 1e18;
        uint256 owed = gross + (sellIn * NVDA_MID / 1e18 - gross) * 1000 / 10_000;
        vm.expectRevert(abi.encodeWithSelector(AnchorVault.InsufficientInventory.selector, owed, quoteBal));
        nvdaVault.quoteSwap(false, sellIn);

        // The router treats both as no vault quote, leaving a maker free to take the trade.
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 30_000e6, 0));
    }

    function test_rebalancingSideKeepsQuotingOutsideTheBand() public {
        // A fill can never push a vault beyond its band, but a price move can: NVDA triples, so the token
        // side makes up 75% of value against a 20% band. With no checkpoint written, the move cap does not apply.
        nvdaFeed.set(int256(NVDA_PRICE_8 * 3));
        uint256 driftBefore = nvdaVault.inventoryRatioBps() - 5_000;
        assertGt(driftBefore, 2_000);

        // The harmful side remains shut, since selling the vault more NVDA pushes it further out.
        vm.expectRevert(AnchorVault.InventoryBandExceeded.selector);
        nvdaVault.quoteSwap(false, 10e18);
        vm.prank(trader);
        vm.expectRevert(SwapRouter.NoLiquidity.selector);
        router.swapExactIn(_params(address(nvda), address(usdg), 10e18, 0));

        // The rebalancing side functions. It was once rejected as well, because the fill still finished
        // outside the band, leaving the market stuck in the only direction that could have repaired it.
        uint256 out = _swap(address(usdg), address(nvda), 10_000e6);
        assertGt(out, 0);
        uint256 driftAfter = nvdaVault.inventoryRatioBps() - 5_000;
        assertLt(driftAfter, driftBefore);
        assertGt(driftAfter, 2_000); // remains outside the band and still one-sided
        vm.expectRevert(AnchorVault.InventoryBandExceeded.selector);
        nvdaVault.quoteSwap(false, 10e18);
    }
}
