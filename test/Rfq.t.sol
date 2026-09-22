// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./Base.t.sol";
import {RfqSettlement} from "../src/RfqSettlement.sol";
import {SwapRouter} from "../src/SwapRouter.sol";
import {IParamController} from "../src/interfaces/IParamController.sol";
import {IEligibilityRegistry} from "../src/interfaces/IEligibilityRegistry.sol";
import {Types, Roles} from "../src/libraries/Types.sol";

/// @notice The RFQ lane: a maker wins only by outpricing the vault, settlement is atomic, and each guard
///         (expiry, nonce, signature, role, band) is applied at fill time.
contract RfqTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seed(nvdaVault, NVDA_MID);
    }

    function _swapWithQuote(Types.MakerQuote memory q, bytes memory sig, uint256 amountIn) internal returns (uint256) {
        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = sig;
        vm.prank(trader);
        return router.swapExactIn(p);
    }

    function test_makerWinsWhenBeatingTheVault() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        uint256 better = vaultOut + vaultOut / 1000; // an improvement of 10 bps

        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, better, 1);
        uint256 makerUsdgBefore = usdg.balanceOf(maker);

        uint256 out = _swapWithQuote(q, _sign(q), amountIn);

        assertEq(out, better);
        // The protocol fee is taken from the quote-token leg, so the maker gets the input minus the fee.
        uint256 fee = amountIn * 2 / 10_000;
        assertEq(usdg.balanceOf(maker), makerUsdgBefore + amountIn - fee);
        assertEq(usdg.balanceOf(address(fees)), fee);
    }

    function test_vaultWinsWhenMakerIsWorse() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut - 1, 1);

        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        uint256 out = _swapWithQuote(q, _sign(q), amountIn);

        assertEq(out, vaultOut);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore); // the maker's balance is untouched
    }

    function test_sellSideFeeDeductedFromOutput() public {
        uint256 amountIn = 50e18;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(false, amountIn);
        uint256 gross = vaultOut + vaultOut / 500; // comfortably beats the vault even after the fee
        Types.MakerQuote memory q = _makerQuote(address(nvda), address(usdg), amountIn, gross, 7);

        uint256 out = _swapWithQuote(q, _sign(q), amountIn);
        uint256 fee = gross * 2 / 10_000;
        assertEq(out, gross - fee);
        assertEq(usdg.balanceOf(address(fees)), fee);
    }

    function test_nonceCannotBeReplayed() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut + vaultOut / 1000, 42);
        bytes memory sig = _sign(q);

        _swapWithQuote(q, sig, amountIn);

        // A used nonce looks the same as a cancelled one: the replay is treated as absent and the vault
        // fills, and the maker's balance is not touched again.
        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        (uint256 vaultOut2,) = nvdaVault.quoteSwap(true, amountIn);
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut2);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore);

        // As defence in depth, settlement on its own still rejects the replay.
        vm.prank(address(router));
        vm.expectRevert(RfqSettlement.NonceAlreadyUsed.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_cancelledQuoteFallsBackToVault() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 9);
        bytes memory sig = _sign(q);

        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 9;
        vm.prank(maker);
        rfq.cancel(nonces);

        // A cancelled candidate is a race rather than an error, so the router treats it as absent.
        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore);

        // As defence in depth, settlement on its own still rejects the nonce.
        vm.prank(address(router));
        vm.expectRevert(RfqSettlement.NonceAlreadyUsed.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_expiredQuoteFallsBackToVault() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 3);
        q.expiry = uint40(block.timestamp - 1);
        bytes memory sig = _sign(q);

        // A quote that expired in transit is treated as absent, and the vault takes the fill.
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut);

        // As defence in depth, settlement on its own still rejects the expired quote.
        vm.prank(address(router));
        vm.expectRevert(RfqSettlement.QuoteExpired.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_badSignatureRejected() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 4);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderPk, rfq.quoteDigest(q)); // signed with the wrong key

        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = abi.encodePacked(r, s, v);
        vm.prank(trader);
        vm.expectRevert(RfqSettlement.BadSignature.selector);
        router.swapExactIn(p);
    }

    function test_reservedQuoteForAnotherTakerRejected() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 5);
        q.taker = outsider;

        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);
        vm.prank(trader);
        vm.expectRevert(RfqSettlement.WrongTaker.selector);
        router.swapExactIn(p);
    }

    function test_cancelRecordsOnlyRealStateChanges() public {
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = 77;
        nonces[1] = 77; // repeated within the same batch

        vm.recordLogs();
        vm.prank(maker);
        rfq.cancel(nonces);
        vm.prank(maker);
        rfq.cancel(nonces); // then the entire batch once more

        // Four requests but only one genuine change, so the audit trail gets exactly one NonceCancelled.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertTrue(rfq.nonceUsed(maker, 77));
    }

    function test_bandCutsBothWays() public {
        // With no liquidity in the SPY vault, RFQ is the sole venue. Even a quote 2% better than mid for
        // the trader fails, because nothing settles outside the band regardless of what a maker signs.
        spy.mint(maker, 1_000e18);
        vm.prank(maker);
        spy.approve(address(rfq), type(uint256).max);

        uint256 amountIn = 10_000e6;
        uint256 fair = amountIn * 1e18 / SPY_MID;
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(spy), amountIn, fair * 102 / 100, 6);

        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);
        vm.prank(trader);
        vm.expectRevert();
        router.swapExactIn(p);
    }

    function test_revokedMakerFallsBackToVault() public {
        uint256 amountIn = 10_000e6;
        (uint256 vaultOut,) = nvdaVault.quoteSwap(true, amountIn);
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, vaultOut * 2, 8);
        bytes memory sig = _sign(q);

        vm.prank(issuer);
        attestations.revoke(maker, Roles.MAKER);

        // The maker lost its attestation after quoting but before inclusion. As with a cancellation, this
        // is a race on the maker's side rather than a trader error, so the candidate is treated as absent
        // and the vault takes the fill.
        uint256 makerNvdaBefore = nvda.balanceOf(maker);
        uint256 out = _swapWithQuote(q, sig, amountIn);
        assertEq(out, vaultOut);
        assertEq(nvda.balanceOf(maker), makerNvdaBefore);

        // As defence in depth, settlement on its own still rejects the maker.
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(IEligibilityRegistry.NotEligible.selector, maker, Roles.MAKER));
        rfq.settle(q, sig, trader, trader);
    }

    function test_settleOnlyThroughRouter() public {
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), 1_000e6, 1e18, 11);
        bytes memory sig = _sign(q);
        vm.prank(trader);
        vm.expectRevert(RfqSettlement.NotRouter.selector);
        rfq.settle(q, sig, trader, trader);
    }

    function test_retiredTierClosesTheRfqLaneToo() public {
        IParamController.TierConfig memory tier = params.tierConfig(1);
        tier.enabled = false;
        vm.prank(gov);
        params.setTierConfig(1, tier);

        // Once the vault is unlisted the candidate is the sole venue, and a fair quote once went through:
        // the tier flag shut the vault path but not the maker path. Settlement now checks the flag as well.
        uint256 amountIn = 10_000e6;
        Types.MakerQuote memory q = _makerQuote(address(usdg), address(nvda), amountIn, amountIn * 1e18 / NVDA_MID, 12);
        SwapRouter.SwapParams memory p = _params(q.tokenIn, q.tokenOut, amountIn, 0);
        p.quote = q;
        p.quoteSig = _sign(q);
        vm.prank(trader);
        vm.expectRevert(RfqSettlement.MarketNotListed.selector);
        router.swapExactIn(p);

        // Cancellation is unaffected, so a maker can always withdraw its quotes on a retired market.
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 12;
        vm.prank(maker);
        rfq.cancel(nonces);
        assertTrue(rfq.nonceUsed(maker, 12));
    }
}
