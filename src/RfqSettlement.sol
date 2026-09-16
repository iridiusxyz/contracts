// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IParamController} from "./interfaces/IParamController.sol";
import {IEligibilityRegistry} from "./interfaces/IEligibilityRegistry.sol";
import {IOracleRouter} from "./interfaces/IOracleRouter.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {Types, Roles} from "./libraries/Types.sol";

/// @title RfqSettlement
/// @notice Settles maker quotes atomically. Makers sign EIP-712 quotes off-chain at no cost, and the winning
///         quote settles here in a single transaction: the input goes to the maker, the output to the trader
///         and the fee to the collector. Assets travel straight between maker and taker wallets and never sit here.
/// @dev The market's oracle band limits every fill, so the worst a compromised maker key can do is fill
///      within the band, no worse than an aggressive yet honest maker. Cancelling quotes can never be
///      paused. Makers using smart accounts are supported via EIP-1271.
contract RfqSettlement is EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "MakerQuote(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOut,"
        "address taker,uint40 expiry,uint256 nonce)"
    );

    IParamController public immutable params;
    IEligibilityRegistry public immutable eligibility;
    IOracleRouter public immutable oracle;
    VaultFactory public immutable factory;
    address public immutable feeCollector;
    address public immutable quoteToken;

    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    event RfqFilled(
        address indexed maker,
        address indexed taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 netOut,
        uint256 fee,
        uint256 mid
    );
    event NonceCancelled(address indexed maker, uint256 nonce);

    error NotRouter();
    error QuoteExpired();
    error WrongTaker();
    error NonceAlreadyUsed();
    error BadSignature();
    error QuoteAssetRequired();
    error MarketNotListed();
    error MarketHalted();
    error BandExceeded(uint256 implied, uint256 mid);
    error ZeroAmount();
    error ZeroAddress();

    modifier onlyRouter() {
        if (msg.sender != factory.router()) revert NotRouter();
        _;
    }

    constructor(
        IParamController params_,
        IEligibilityRegistry eligibility_,
        IOracleRouter oracle_,
        VaultFactory factory_,
        address feeCollector_
    ) EIP712("Iridius", "1") {
        if (
            address(params_) == address(0) || address(eligibility_) == address(0) || address(oracle_) == address(0)
                || feeCollector_ == address(0)
        ) revert ZeroAddress();
        params = params_;
        eligibility = eligibility_;
        oracle = oracle_;
        factory = factory_;
        feeCollector = feeCollector_;
        quoteToken = factory_.quoteToken();
    }

    function quoteDigest(Types.MakerQuote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH, q.maker, q.tokenIn, q.tokenOut, q.amountIn, q.amountOut, q.taker, q.expiry, q.nonce
                )
            )
        );
    }

    /// @notice Settles a maker quote on behalf of `taker` and sends the output to `to`. Only the router may
    ///         call it, having already confirmed the taker's eligibility and taken custody of the input asset.
    function settle(Types.MakerQuote calldata q, bytes calldata signature, address taker, address to)
        external
        onlyRouter
        returns (uint256 netOut)
    {
        if (q.amountIn == 0 || q.amountOut == 0) revert ZeroAmount();
        if (block.timestamp > q.expiry) revert QuoteExpired();
        if (q.taker != address(0) && q.taker != taker) revert WrongTaker();
        if (nonceUsed[q.maker][q.nonce]) revert NonceAlreadyUsed();
        nonceUsed[q.maker][q.nonce] = true;

        if (!SignatureChecker.isValidSignatureNow(q.maker, quoteDigest(q), signature)) revert BadSignature();
        eligibility.requireRole(q.maker, Roles.MAKER);

        // One leg, and only one, is the quote asset; the other identifies the market whose guards are applied.
        bool buyBase = q.tokenIn == quoteToken;
        if (buyBase == (q.tokenOut == quoteToken)) revert QuoteAssetRequired();
        address base = buyBase ? q.tokenOut : q.tokenIn;

        uint256 mid = _bandCheckedMid(base, buyBase ? q.amountIn : q.amountOut, buyBase ? q.amountOut : q.amountIn);

        uint256 fee;
        if (buyBase) {
            // The fee is taken from the quote-token leg; makers quote gross and build it into their price.
            fee = q.amountIn * params.feeParams().rfqFeeBps / Types.BPS;
            IERC20(q.tokenIn).safeTransferFrom(msg.sender, q.maker, q.amountIn - fee);
            IERC20(q.tokenIn).safeTransferFrom(msg.sender, feeCollector, fee);
            IERC20(q.tokenOut).safeTransferFrom(q.maker, to, q.amountOut);
            netOut = q.amountOut;
        } else {
            fee = q.amountOut * params.feeParams().rfqFeeBps / Types.BPS;
            IERC20(q.tokenIn).safeTransferFrom(msg.sender, q.maker, q.amountIn);
            IERC20(q.tokenOut).safeTransferFrom(q.maker, to, q.amountOut - fee);
            IERC20(q.tokenOut).safeTransferFrom(q.maker, feeCollector, fee);
            netOut = q.amountOut - fee;
        }

        emit RfqFilled(q.maker, taker, q.tokenIn, q.tokenOut, q.amountIn, netOut, fee, mid);
    }

    /// @notice Cancels quotes by nonce. The maker can call it whenever they like, paused or not, and can reach
    ///         it through the L1 delayed inbox if the sequencer is censoring.
    function cancel(uint256[] calldata nonces) external {
        for (uint256 i = 0; i < nonces.length; i++) {
            // Nonces that were already used or cancelled are skipped, so events reflect only genuine state
            // changes and never report "cancelling" a quote that has already settled.
            if (nonceUsed[msg.sender][nonces[i]]) continue;
            nonceUsed[msg.sender][nonces[i]] = true;
            emit NonceCancelled(msg.sender, nonces[i]);
        }
    }

    /// @dev Applies the vault path's listing and halt conditions together with the hard band: regardless
    ///      of what a maker signed, no fill further than the band from the guarded mid will settle.
    function _bandCheckedMid(address base, uint256 quoteAmount, uint256 baseAmount) internal view returns (uint256) {
        IParamController.MarketConfig memory mkt = params.marketConfig(base);
        if (!mkt.enabled) revert MarketNotListed();
        // A market counts as listed only while its tier is enabled. Switching a tier off retires all of its
        // markets, and that must shut the maker lane along with the vault; otherwise a retired market
        // would carry on trading through any maker still prepared to quote it.
        IParamController.TierConfig memory tier = params.tierConfig(mkt.tier);
        if (!tier.enabled) revert MarketNotListed();
        IOracleRouter.Quote memory oq = oracle.quote(base);
        if (oq.paused || oq.stale || oq.sequencerGrace) revert MarketHalted();

        uint256 implied = quoteAmount * 10 ** oracle.tokenDecimals(base) / baseAmount;
        uint256 diff = implied > oq.price ? implied - oq.price : oq.price - implied;
        if (diff * Types.BPS / oq.price > tier.oracleBandBps) revert BandExceeded(implied, oq.price);
        return oq.price;
    }
}
