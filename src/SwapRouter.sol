// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IParamController} from "./interfaces/IParamController.sol";
import {IEligibilityRegistry} from "./interfaces/IEligibilityRegistry.sol";
import {AnchorVault} from "./AnchorVault.sol";
import {RfqSettlement} from "./RfqSettlement.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {Types, Roles} from "./libraries/Types.sol";

/// @title SwapRouter
/// @notice The only way in for traders. It verifies eligibility, weighs the anchor vault against an optional
///         maker quote, settles on whichever gives the trader the better price, and builds token-to-token
///         swaps from two atomic legs via the quote asset. The comparison happens on-chain and is exact: the
///         vault quote is recomputed from oracle and vault state inside the same transaction and the maker
///         quote's signature is checked, so no front-end can send a trade to a price worse than the vault's.
contract SwapRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IParamController public immutable params;
    IEligibilityRegistry public immutable eligibility;
    VaultFactory public immutable factory;
    RfqSettlement public immutable rfq;
    address public immutable quoteToken;

    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        /// @dev Who receives the output; zero stands for the trader.
        address to;
        uint256 deadline;
        /// @dev An optional RFQ candidate for single-leg swaps; `quote.maker == address(0)` indicates there is none.
        Types.MakerQuote quote;
        bytes quoteSig;
    }

    event Swapped(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Types.Venue venue
    );

    error Expired();
    error SwapsPaused();
    error SameToken();
    error ZeroAmount();
    error NoLiquidity();
    error Slippage(uint256 amountOut, uint256 minAmountOut);
    error QuoteMismatch();
    error QuoteNotApplicable();
    error ZeroAddress();

    constructor(
        IParamController params_,
        IEligibilityRegistry eligibility_,
        VaultFactory factory_,
        RfqSettlement rfq_
    ) {
        // quoteToken() just below already exercises the factory; the others would otherwise fail only when first used.
        if (address(params_) == address(0) || address(eligibility_) == address(0) || address(rfq_) == address(0)) {
            revert ZeroAddress();
        }
        params = params_;
        eligibility = eligibility_;
        factory = factory_;
        rfq = rfq_;
        quoteToken = factory_.quoteToken();
    }

    /// @notice Swaps a precise input amount, with the signed `minAmountOut` and `deadline` limiting the fill.
    ///         Should state shift so that the fill would fall short of those limits, the swap reverts instead.
    function swapExactIn(SwapParams calldata p) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > p.deadline) revert Expired();
        if (params.swapsPaused()) revert SwapsPaused();
        if (p.tokenIn == p.tokenOut) revert SameToken();
        if (p.amountIn == 0) revert ZeroAmount();
        eligibility.requireRole(msg.sender, Roles.TRADER);
        address to = p.to == address(0) ? msg.sender : p.to;
        if (to != msg.sender) eligibility.requireRole(to, Roles.TRADER);

        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);

        Types.Venue venue;
        if (p.tokenIn == quoteToken || p.tokenOut == quoteToken) {
            (amountOut, venue) = _bestLeg(p, p.tokenIn == quoteToken, to);
        } else {
            // Two legs via the quote asset, atomic from start to finish. RFQ candidates are only valid for
            // single-leg swaps, so one supplied here is a client mistake and is reported, not quietly dropped.
            if (p.quote.maker != address(0)) revert QuoteNotApplicable();
            uint256 quoteOut = _vaultSwap(p.tokenIn, false, p.amountIn, address(this));
            amountOut = _vaultSwap(p.tokenOut, true, quoteOut, to);
            venue = Types.Venue.Vault;
        }

        if (amountOut < p.minAmountOut) revert Slippage(amountOut, p.minAmountOut);
        emit Swapped(msg.sender, p.tokenIn, p.tokenOut, p.amountIn, amountOut, venue);
    }

    /// @notice What `swapExactIn` would do with these params at this moment: the trader's output and the
    ///         winning venue, accounting for the RFQ candidate and two-leg composition. It throws the errors
    ///         the fill would throw, letting a client size and route from a single answer without rebuilding
    ///         the comparison; only the deadline, eligibility and the candidate's signature are checked
    ///         solely by the call itself.
    function previewExactIn(SwapParams calldata p) external view returns (uint256 amountOut, Types.Venue venue) {
        if (params.swapsPaused()) revert SwapsPaused();
        if (p.tokenIn == p.tokenOut) revert SameToken();
        if (p.amountIn == 0) revert ZeroAmount();

        if (p.tokenIn == quoteToken || p.tokenOut == quoteToken) {
            (, uint256 vaultOut, uint256 rfqNet) = _priceLeg(p, p.tokenIn == quoteToken);
            if (rfqNet > vaultOut) return (rfqNet, Types.Venue.Rfq);
            if (vaultOut == 0) revert NoLiquidity();
            return (vaultOut, Types.Venue.Vault);
        }

        if (p.quote.maker != address(0)) revert QuoteNotApplicable();
        uint256 quoteOut = _vaultQuote(p.tokenIn, false, p.amountIn);
        return (_vaultQuote(p.tokenOut, true, quoteOut), Types.Venue.Vault);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Settles on the vault or the optional maker candidate, whichever gives the trader the better price.
    function _bestLeg(SwapParams calldata p, bool buyToken, address to)
        internal
        returns (uint256 amountOut, Types.Venue venue)
    {
        (address vault, uint256 vaultOut, uint256 rfqNet) = _priceLeg(p, buyToken);

        if (rfqNet > vaultOut) {
            IERC20(p.tokenIn).forceApprove(address(rfq), p.amountIn);
            amountOut = rfq.settle(p.quote, p.quoteSig, msg.sender, to);
            venue = Types.Venue.Rfq;
        } else if (vaultOut > 0) {
            amountOut = _vaultSwapAt(vault, buyToken, p.amountIn, to);
            venue = Types.Venue.Vault;
        } else {
            revert NoLiquidity();
        }
    }

    /// @dev Prices the vault and the optional maker candidate exactly as the fill compares them. A vault that
    ///      is halted or missing prices at zero instead of reverting, letting RFQ serve a market the vault cannot.
    function _priceLeg(SwapParams calldata p, bool buyToken)
        internal
        view
        returns (address vault, uint256 vaultOut, uint256 rfqNet)
    {
        vault = factory.vaultOf(buyToken ? p.tokenOut : p.tokenIn);
        if (vault != address(0)) {
            try AnchorVault(vault).quoteSwap(buyToken, p.amountIn) returns (uint256 out, Types.Breakdown memory) {
                vaultOut = out;
            } catch {}
        }

        if (p.quote.maker != address(0)) {
            if (p.quote.tokenIn != p.tokenIn || p.quote.tokenOut != p.tokenOut || p.quote.amountIn != p.amountIn) {
                revert QuoteMismatch();
            }
            // If a candidate expired in transit, was cancelled by its maker, or its maker lost the
            // attestation after quoting, that is an ordinary race rather than a client mistake: treat it as
            // absent so the vault can still take the fill. A malformed or wrongly signed candidate still
            // reverts loudly in settlement.
            bool usable = block.timestamp <= p.quote.expiry && !rfq.nonceUsed(p.quote.maker, p.quote.nonce)
                && eligibility.isEligible(p.quote.maker, Roles.MAKER);
            if (usable) {
                // The RFQ fee is taken from the quote-token leg: on a buy it comes out of the input before
                // the maker is paid, and on a sell it is subtracted from the trader's output. The
                // comparison uses what reaches the trader.
                rfqNet = buyToken
                    ? p.quote.amountOut
                    : p.quote.amountOut - p.quote.amountOut * params.feeParams().rfqFeeBps / Types.BPS;
            }
        }
    }

    /// @dev One leg of a two-leg preview, passing the vault's own errors through just as the fill does.
    function _vaultQuote(address base, bool buyToken, uint256 amountIn) internal view returns (uint256 out) {
        address vault = factory.vaultOf(base);
        if (vault == address(0)) revert NoLiquidity();
        (out,) = AnchorVault(vault).quoteSwap(buyToken, amountIn);
    }

    function _vaultSwap(address base, bool buyToken, uint256 amountIn, address to) internal returns (uint256) {
        address vault = factory.vaultOf(base);
        if (vault == address(0)) revert NoLiquidity();
        return _vaultSwapAt(vault, buyToken, amountIn, to);
    }

    function _vaultSwapAt(address vault, bool buyToken, uint256 amountIn, address to) internal returns (uint256) {
        IERC20(buyToken ? quoteToken : address(AnchorVault(vault).token())).forceApprove(vault, amountIn);
        return AnchorVault(vault).swap(buyToken, amountIn, to);
    }
}
