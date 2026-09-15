// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IParamController} from "./interfaces/IParamController.sol";
import {IEligibilityRegistry} from "./interfaces/IEligibilityRegistry.sol";
import {IOracleRouter} from "./interfaces/IOracleRouter.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {Types, Roles} from "./libraries/Types.sol";

/// @title AnchorVault
/// @notice A single market pairing one listed token with the quote asset. LPs fund it, and it quotes both
///         sides around the guarded oracle mid. Price comes from the oracle and never from reserves, with
///         inventory affecting only the spread. LP shares use value-based accounting, and withdrawal is
///         pro-rata and in kind in every state, so neither a pause nor a halt can lock up LP funds.
/// @dev The SwapRouter is the sole path for swaps. Since shares are minted at the current mid, deposits
///      need a live oracle; withdrawals do not touch the oracle at all.
contract AnchorVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IParamController public immutable params;
    IEligibilityRegistry public immutable eligibility;
    IOracleRouter public immutable oracle;
    VaultFactory public immutable factory;
    address public immutable feeCollector;
    IERC20 public immutable quoteToken;
    IERC20 public immutable token;
    uint8 public immutable tokenDec;
    uint8 public immutable quoteDec;
    /// @dev Converts the quote-unit value of the first deposit into 18-decimal shares.
    uint256 internal immutable shareScale;

    /// @notice Quote-token notional executed in each UTC day, compared with the market's daily cap.
    mapping(uint256 => uint256) public dailyVolume;

    struct SwapQuote {
        uint256 amountOut;
        /// @dev Notional in the quote token at mid; clips and daily caps are measured in this unit.
        uint256 notional;
        uint256 feeAmount;
        uint256 protocolSpread;
        Types.Breakdown breakdown;
    }

    event Deposited(
        address indexed lp, address indexed receiver, uint256 quoteAmount, uint256 tokenAmount, uint256 shares
    );
    event Withdrawn(address indexed lp, address indexed receiver, uint256 shares, uint256 quoteOut, uint256 tokenOut);
    event VaultSwap(
        address indexed to,
        bool buyToken,
        uint256 amountIn,
        uint256 amountOut,
        uint256 mid,
        uint16 halfSpreadBps,
        int16 skewBps,
        uint16 feeBps,
        Types.Session session
    );

    error NotRouter();
    error MarketNotListed();
    error MarketHalted();
    error SwapsPaused();
    error NoLiquidity();
    error ZeroAmount();
    error ZeroShares();
    error Slippage(uint256 shares, uint256 minShares);
    error BandExceeded();
    error ClipExceeded(uint256 notional, uint256 clip);
    error InsufficientInventory(uint256 needed, uint256 available);
    error DailyCapExceeded();
    error TvlCapExceeded();
    error InventoryBandExceeded();

    modifier onlyRouter() {
        if (msg.sender != factory.router()) revert NotRouter();
        _;
    }

    constructor(
        IParamController params_,
        IEligibilityRegistry eligibility_,
        IOracleRouter oracle_,
        address feeCollector_,
        address quoteToken_,
        address token_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
        params = params_;
        eligibility = eligibility_;
        oracle = oracle_;
        factory = VaultFactory(msg.sender);
        feeCollector = feeCollector_;
        quoteToken = IERC20(quoteToken_);
        token = IERC20(token_);
        tokenDec = IERC20Metadata(token_).decimals();
        quoteDec = IERC20Metadata(quoteToken_).decimals();
        shareScale = 10 ** (18 - quoteDec);
    }

    // ---------------------------------------------------------------------
    // LP side
    // ---------------------------------------------------------------------

    /// @notice Adds the quote asset, the token or both. The deposit is valued at the guarded mid and shares
    ///         are minted at today's value per share. `minShares` limits the mint just as `minAmountOut`
    ///         limits a swap: should the mid shift between signing and inclusion, the deposit reverts
    ///         instead of minting too few shares.
    function deposit(uint256 quoteAmount, uint256 tokenAmount, uint256 minShares, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (quoteAmount == 0 && tokenAmount == 0) revert ZeroAmount();
        eligibility.requireRole(msg.sender, Roles.LP);
        if (receiver != msg.sender) eligibility.requireRole(receiver, Roles.LP);

        uint256 mid = _liveMid();
        uint256 value = quoteAmount + tokenAmount * mid / 10 ** tokenDec;
        uint256 total = _totalValue(mid);

        IParamController.MarketConfig memory mkt = params.marketConfig(address(token));
        if (!mkt.enabled || !params.tierConfig(mkt.tier).enabled) revert MarketNotListed();
        if (total + value > mkt.tvlCap) revert TvlCapExceeded();

        uint256 supply = totalSupply();
        shares = supply == 0 ? value * shareScale : value * supply / total;
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert Slippage(shares, minShares);

        if (quoteAmount != 0) quoteToken.safeTransferFrom(msg.sender, address(this), quoteAmount);
        if (tokenAmount != 0) token.safeTransferFrom(msg.sender, address(this), tokenAmount);
        _mint(receiver, shares);
        emit Deposited(msg.sender, receiver, quoteAmount, tokenAmount, shares);
    }

    /// @notice Redeems shares for a pro-rata, in-kind slice of the vault's present inventory. Nothing gates
    ///         it: there is no eligibility check, no pause check and no oracle read. Holding shares is what
    ///         entitles an LP to withdraw; no permission is involved.
    function withdraw(uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 quoteOut, uint256 tokenOut)
    {
        if (shares == 0) revert ZeroShares();
        (quoteOut, tokenOut) = previewWithdraw(shares);
        _burn(msg.sender, shares);
        if (quoteOut != 0) quoteToken.safeTransfer(receiver, quoteOut);
        if (tokenOut != 0) token.safeTransfer(receiver, tokenOut);
        emit Withdrawn(msg.sender, receiver, shares, quoteOut, tokenOut);
    }

    // ---------------------------------------------------------------------
    // Trading side (router only)
    // ---------------------------------------------------------------------

    /// @notice Simulates a swap on current state. It reverts if the market is halted or the fill would
    ///         break a cap; the router interprets that as "no vault quote" instead of a failure, leaving
    ///         RFQ free to take the trade.
    function quoteSwap(bool buyToken, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, Types.Breakdown memory breakdown)
    {
        SwapQuote memory s = _price(oracle.quote(address(token)), buyToken, amountIn);
        return (s.amountOut, s.breakdown);
    }

    /// @notice Executes a swap: takes `amountIn` of the input asset from the router, delivers the output to
    ///         `to`, and passes the itemised protocol fee and spread share on to the fee collector.
    function swap(bool buyToken, uint256 amountIn, address to) external onlyRouter nonReentrant returns (uint256) {
        // `refresh` records a move-cap checkpoint; a print beyond the cap pauses the market rather than filling.
        IOracleRouter.Quote memory q = oracle.refresh(address(token));
        SwapQuote memory s = _price(q, buyToken, amountIn);
        dailyVolume[block.timestamp / 1 days] += s.notional;

        if (buyToken) {
            quoteToken.safeTransferFrom(msg.sender, address(this), amountIn);
            quoteToken.safeTransfer(feeCollector, s.feeAmount + s.protocolSpread);
            token.safeTransfer(to, s.amountOut);
        } else {
            token.safeTransferFrom(msg.sender, address(this), amountIn);
            quoteToken.safeTransfer(to, s.amountOut);
            quoteToken.safeTransfer(feeCollector, s.feeAmount + s.protocolSpread);
        }

        emit VaultSwap(
            to,
            buyToken,
            amountIn,
            s.amountOut,
            s.breakdown.mid,
            s.breakdown.halfSpreadBps,
            s.breakdown.skewBps,
            s.breakdown.feeBps,
            s.breakdown.session
        );
        return s.amountOut;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice How many shares depositing this mix would mint at this moment. Like `deposit`, it reverts
    ///         when the oracle cannot be used; eligibility and cap checks happen only in the real call.
    function previewDeposit(uint256 quoteAmount, uint256 tokenAmount) external view returns (uint256) {
        uint256 mid = _liveMid();
        uint256 value = quoteAmount + tokenAmount * mid / 10 ** tokenDec;
        uint256 supply = totalSupply();
        return supply == 0 ? value * shareScale : value * supply / _totalValue(mid);
    }

    /// @notice The in-kind amounts that withdrawing `shares` would pay out at this moment. As in `withdraw`,
    ///         this is balance arithmetic alone, with no oracle read and no gate.
    function previewWithdraw(uint256 shares) public view returns (uint256 quoteOut, uint256 tokenOut) {
        uint256 supply = totalSupply();
        if (supply == 0) return (0, 0);
        quoteOut = quoteToken.balanceOf(address(this)) * shares / supply;
        tokenOut = token.balanceOf(address(this)) * shares / supply;
    }

    /// @notice The vault's value in quote units at the present guarded mid; reverts when the oracle cannot be used.
    function totalValue() external view returns (uint256) {
        return _totalValue(_liveMid());
    }

    /// @notice The quote-token notional that can still be filled today before the daily cap is reached.
    ///         Since pricing enforces the cap, size orders against this headroom instead of requesting
    ///         quotes until one reverts.
    function remainingDailyCap() external view returns (uint256) {
        uint256 cap = params.marketConfig(address(token)).dailyVolumeCap;
        uint256 used = dailyVolume[block.timestamp / 1 days];
        return used >= cap ? 0 : cap - used;
    }

    /// @notice Share of vault value held in the token, in bps; 5_000 means exactly on target.
    function inventoryRatioBps() external view returns (uint256) {
        uint256 mid = _liveMid();
        uint256 total = _totalValue(mid);
        if (total == 0) return Types.TARGET_RATIO_BPS;
        return token.balanceOf(address(this)) * mid / 10 ** tokenDec * Types.BPS / total;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev The complete pricing formula, kept together: base spread adjusted for regime, signed inventory
    ///      skew, itemised fee, and the clip, band and daily-cap checks. It only reads public state, so
    ///      anyone can reproduce a quote off-chain from identical inputs.
    function _price(IOracleRouter.Quote memory q, bool buyToken, uint256 amountIn)
        internal
        view
        returns (SwapQuote memory s)
    {
        if (amountIn == 0) revert ZeroAmount();
        // Pricing rejects fills during the emergency pause just as the router does, so previews never show
        // an unreachable quote and the vault stays shut even if a router neglected to check.
        if (params.swapsPaused()) revert SwapsPaused();
        if (q.paused || q.stale || q.sequencerGrace) revert MarketHalted();

        IParamController.MarketConfig memory mkt = params.marketConfig(address(token));
        if (!mkt.enabled) revert MarketNotListed();
        // A market counts as listed only while its tier is enabled. Because the controller will not list a
        // market on a disabled tier, switching a tier off retires all of its markets in one change.
        IParamController.TierConfig memory tier = params.tierConfig(mkt.tier);
        if (!tier.enabled) revert MarketNotListed();
        IParamController.FeeParams memory fee = params.feeParams();
        (uint256 spreadMul, uint256 clipMul) = _regimeMultipliers(q.session);

        uint256 quoteBal = quoteToken.balanceOf(address(this));
        uint256 tokenBal = token.balanceOf(address(this));
        uint256 tokenValue = tokenBal * q.price / 10 ** tokenDec;
        uint256 total = quoteBal + tokenValue;
        if (total == 0) revert NoLiquidity();

        // Skew is signed and positive when the vault is long the token. Trades that rebalance the vault get
        // a tighter quote and trades that unbalance it a wider one, capped at the edge of the band.
        int256 skew = int256(uint256(tier.maxSkewBps))
            * (int256(tokenValue * Types.BPS / total) - int256(Types.TARGET_RATIO_BPS))
            / int256(uint256(tier.inventoryBandBps));
        if (skew > int256(uint256(tier.maxSkewBps))) skew = int256(uint256(tier.maxSkewBps));
        if (skew < -int256(uint256(tier.maxSkewBps))) skew = -int256(uint256(tier.maxSkewBps));

        int256 half = int256(uint256(tier.baseHalfSpreadBps) * spreadMul / Types.BPS) + (buyToken ? -skew : skew);
        if (half < 0) half = 0;
        uint256 halfSpread = uint256(half);
        if (halfSpread + fee.swapFeeBps > tier.oracleBandBps) revert BandExceeded();

        // Size checks need only the order and the mid, so they run first: an order above the clip is
        // rejected for that reason before it can push any balance arithmetic out of range.
        s.notional = buyToken ? amountIn : amountIn * q.price / 10 ** tokenDec;
        uint256 clip = uint256(tier.maxClip) * clipMul / Types.BPS;
        if (s.notional > clip) revert ClipExceeded(s.notional, clip);
        if (dailyVolume[block.timestamp / 1 days] + s.notional > mkt.dailyVolumeCap) revert DailyCapExceeded();

        // Balances after the trade are simulated together with the price, so a preview and its fill match
        // exactly, inventory band and all: `swap` does precisely what `quoteSwap` reports. When inventory
        // cannot cover a fill, the error says so explicitly instead of leaving the transfer to fail.
        uint256 newQuoteBal;
        uint256 newTokenVal;
        if (buyToken) {
            s.feeAmount = amountIn * fee.swapFeeBps / Types.BPS;
            uint256 net = amountIn - s.feeAmount;
            uint256 askPrice = q.price * (Types.BPS + halfSpread) / Types.BPS;
            s.amountOut = net * 10 ** tokenDec / askPrice;
            if (s.amountOut > tokenBal) revert InsufficientInventory(s.amountOut, tokenBal);
            uint256 midValue = s.amountOut * q.price / 10 ** tokenDec;
            s.protocolSpread = (net - midValue) * fee.spreadShareBps / Types.BPS;
            newQuoteBal = quoteBal + amountIn - s.feeAmount - s.protocolSpread;
            newTokenVal = tokenValue - midValue;
        } else {
            uint256 midValue = s.notional;
            uint256 bidPrice = q.price * (Types.BPS - halfSpread) / Types.BPS;
            uint256 gross = amountIn * bidPrice / 10 ** tokenDec;
            s.feeAmount = gross * fee.swapFeeBps / Types.BPS;
            s.amountOut = gross - s.feeAmount;
            s.protocolSpread = (midValue - gross) * fee.spreadShareBps / Types.BPS;
            // The fee comes out of `gross` yet is paid out alongside the spread share, so the vault finishes
            // the fill down by all of `gross` plus the spread share, matching what `swap` transfers.
            if (gross + s.protocolSpread > quoteBal) revert InsufficientInventory(gross + s.protocolSpread, quoteBal);
            newQuoteBal = quoteBal - gross - s.protocolSpread;
            newTokenVal = tokenValue + midValue;
        }

        // No fill may leave the vault beyond its inventory band, or push it further out after a price
        // move has already done so. In both cases the vault becomes one-sided: the harmful direction
        // stops quoting and the rebalancing direction carries on, which returns a vault pushed out by a
        // price move to within the band without needing an LP deposit.
        uint256 newTotal = newQuoteBal + newTokenVal;
        if (newTotal == 0) revert NoLiquidity();
        uint256 drift = _drift(newTokenVal * Types.BPS / newTotal);
        if (drift > tier.inventoryBandBps && drift >= _drift(tokenValue * Types.BPS / total)) {
            revert InventoryBandExceeded();
        }

        s.breakdown = Types.Breakdown({
            mid: q.price,
            halfSpreadBps: uint16(halfSpread),
            skewBps: int16(skew),
            feeBps: fee.swapFeeBps,
            session: q.session
        });
    }

    /// @dev How far a token share of value sits from the 50% target, in bps.
    function _drift(uint256 ratioBps) internal pure returns (uint256) {
        return ratioBps > Types.TARGET_RATIO_BPS ? ratioBps - Types.TARGET_RATIO_BPS : Types.TARGET_RATIO_BPS - ratioBps;
    }

    function _regimeMultipliers(Types.Session session) internal view returns (uint256 spreadMul, uint256 clipMul) {
        IParamController.RegimeParams memory r = params.regimeParams();
        if (session == Types.Session.Regular) return (Types.BPS, Types.BPS);
        if (session == Types.Session.Extended) return (r.extendedSpreadMulBps, r.extendedClipMulBps);
        return (r.closedSpreadMulBps, r.closedClipMulBps);
    }

    function _liveMid() internal view returns (uint256) {
        IOracleRouter.Quote memory q = oracle.quote(address(token));
        if (q.paused || q.stale || q.sequencerGrace) revert MarketHalted();
        return q.price;
    }

    function _totalValue(uint256 mid) internal view returns (uint256) {
        return quoteToken.balanceOf(address(this)) + token.balanceOf(address(this)) * mid / 10 ** tokenDec;
    }

    /// @dev Shares can only be transferred between attested LPs. Minting and burning are excluded, so an
    ///      expired attestation can never stand in the way of a withdrawal.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) eligibility.requireRole(to, Roles.LP);
        super._update(from, to, value);
    }
}
