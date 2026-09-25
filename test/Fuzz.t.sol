// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AnchorVault} from "../src/AnchorVault.sol";
import {RfqSettlement} from "../src/RfqSettlement.sol";
import {SwapRouter} from "../src/SwapRouter.sol";
import {IParamController} from "../src/interfaces/IParamController.sol";
import {Types, Roles} from "../src/libraries/Types.sol";

/// @notice The suite's invariants, exercised with fuzzed sizes and states instead of hand-picked cases:
///         previews match fills, no fill clears outside the oracle band or leaves the vault beyond its
///         inventory band, a swap or deposit never reduces value per share, and no exit is ever gated.
contract FuzzTest is BaseTest {
    uint256 internal seedShares;

    function setUp() public override {
        super.setUp();
        seedShares = _seed(nvdaVault, NVDA_MID);
        _seed(spyVault, SPY_MID);
        // A single trade moves value per share off 1:1 so that rounding actually matters.
        _swap(address(usdg), address(nvda), 10_000e6);
    }

    function testFuzz_vaultPreviewMatchesTheFill(bool buyToken, uint256 amountIn) public {
        // Anything from dust up to slightly beyond the regular clip, in either direction.
        amountIn = buyToken ? bound(amountIn, 1, 60_000e6) : bound(amountIn, 1, 340e18);
        SwapRouter.SwapParams memory p = buyToken
            ? _params(address(usdg), address(nvda), amountIn, 0)
            : _params(address(nvda), address(usdg), amountIn, 0);

        uint256 previewed;
        try nvdaVault.quoteSwap(buyToken, amountIn) returns (uint256 out, Types.Breakdown memory) {
            previewed = out;
        } catch {}

        if (previewed == 0) {
            // The preview reverted or returned zero, and the router treats both as no vault quote.
            vm.prank(trader);
            vm.expectRevert(SwapRouter.NoLiquidity.selector);
            router.swapExactIn(p);
            return;
        }

        uint256 valuePerShareBefore = nvdaVault.totalValue() * 1e18 / nvdaVault.totalSupply();
        vm.prank(trader);
        uint256 filled = router.swapExactIn(p);
        assertEq(filled, previewed, "fill differs from preview");

        // After the fill the vault is still inside its inventory band and the LPs are not worse off.
        uint256 ratio = nvdaVault.inventoryRatioBps();
        uint256 drift = ratio > 5_000 ? ratio - 5_000 : 5_000 - ratio;
        assertLe(drift, 2_000, "fill left the vault outside its inventory band");
        assertGe(nvdaVault.totalValue() * 1e18 / nvdaVault.totalSupply(), valuePerShareBefore, "value per share fell");

        // Also, once above dust where rounding no longer dominates, it cleared within the oracle band.
        uint256 notional = buyToken ? amountIn : amountIn * NVDA_MID / 1e18;
        if (notional >= 1e6) {
            uint256 implied = buyToken ? amountIn * 1e18 / filled : filled * 1e18 / amountIn;
            uint256 diff = implied > NVDA_MID ? implied - NVDA_MID : NVDA_MID - implied;
            assertLe(diff * 10_000 / NVDA_MID, 75, "fill outside the oracle band");
        }
    }

    function testFuzz_depositPreviewMatchesTheMint(uint256 quoteAmount, uint256 tokenAmount) public {
        quoteAmount = bound(quoteAmount, 0, 1_000_000e6);
        tokenAmount = bound(tokenAmount, 0, 5_000e18);

        if (quoteAmount == 0 && tokenAmount == 0) {
            vm.prank(lp2);
            vm.expectRevert(AnchorVault.ZeroAmount.selector);
            nvdaVault.deposit(0, 0, 0, lp2);
            return;
        }

        uint256 previewed = nvdaVault.previewDeposit(quoteAmount, tokenAmount);
        if (previewed == 0) {
            // A deposit too small for one share would mint nothing, so it is rejected instead of being absorbed.
            vm.prank(lp2);
            vm.expectRevert(AnchorVault.ZeroShares.selector);
            nvdaVault.deposit(quoteAmount, tokenAmount, 0, lp2);
            return;
        }

        uint256 valuePerShareBefore = nvdaVault.totalValue() * 1e18 / nvdaVault.totalSupply();
        vm.prank(lp2);
        uint256 minted = nvdaVault.deposit(quoteAmount, tokenAmount, previewed, lp2);
        assertEq(minted, previewed, "mint differs from preview");
        // Mint rounding favours the vault, so existing LPs are never diluted.
        assertGe(nvdaVault.totalValue() * 1e18 / nvdaVault.totalSupply(), valuePerShareBefore, "deposit diluted");
    }

    function testFuzz_withdrawalIsProRataInEveryState(uint256 shares, uint8 state) public {
        shares = bound(shares, 1, seedShares);
        state = uint8(bound(state, 0, 5));
        if (state == 1) nvda.setOraclePaused(true); // halt for a corporate action
        if (state == 2) {
            vm.prank(guardian);
            params.setPaused(true); // the emergency pause
        }
        if (state == 3) {
            IParamController.TierConfig memory tier = params.tierConfig(1);
            tier.enabled = false;
            vm.prank(gov);
            params.setTierConfig(1, tier); // the market is retired
        }
        if (state == 4) vm.warp(block.timestamp + 3 hours); // the feed goes stale
        if (state == 5) {
            vm.prank(issuer);
            attestations.revoke(lp1, Roles.LP); // the attestation is revoked
        }

        uint256 quoteBal = usdg.balanceOf(address(nvdaVault));
        uint256 tokenBal = nvda.balanceOf(address(nvdaVault));
        uint256 supply = nvdaVault.totalSupply();
        (uint256 previewedQuote, uint256 previewedToken) = nvdaVault.previewWithdraw(shares);

        vm.prank(lp1);
        (uint256 quoteOut, uint256 tokenOut) = nvdaVault.withdraw(shares, lp1);
        assertEq(quoteOut, previewedQuote);
        assertEq(tokenOut, previewedToken);
        assertEq(quoteOut, quoteBal * shares / supply);
        assertEq(tokenOut, tokenBal * shares / supply);
        assertEq(nvdaVault.balanceOf(lp1), seedShares - shares);
    }

    function testFuzz_makerFillsStayInsideTheBand(uint256 priceBps) public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        // Ranges from 10% worse than the vault to 10% better, crossing the band edge both ways.
        uint256 amountOut = vaultOut * bound(priceBps, 9_000, 11_000) / 10_000;

        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, amountOut, 1);
        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);

        vm.prank(trader);
        try router.swapExactIn(p) returns (uint256 out) {
            // Regardless of venue, the trader did at least as well as the vault and got a price within the band.
            assertGe(out, vaultOut, "trader did worse than the vault");
            if (out > vaultOut) assertEq(out, amountOut, "maker won on other than its own terms");
            uint256 implied = amountIn * 1e18 / out;
            uint256 diff = implied > NVDA_MID ? implied - NVDA_MID : NVDA_MID - implied;
            assertLe(diff * 10_000 / NVDA_MID, 75, "fill outside the oracle band");
        } catch (bytes memory reason) {
            // A candidate that beats the vault can be blocked by the band and nothing else.
            assertGt(amountOut, vaultOut, "vault fill failed");
            bytes4 selector;
            assembly {
                selector := mload(add(reason, 32))
            }
            assertEq(selector, RfqSettlement.BandExceeded.selector, "unexpected settlement failure");
        }
    }
}
