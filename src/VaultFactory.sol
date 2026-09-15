// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IParamController} from "./interfaces/IParamController.sol";
import {IEligibilityRegistry} from "./interfaces/IEligibilityRegistry.sol";
import {IOracleRouter} from "./interfaces/IOracleRouter.sol";
import {AnchorVault} from "./AnchorVault.sol";

/// @title VaultFactory
/// @notice Creates a single AnchorVault for each listed token and acts as the registry where the router finds
///         vaults. Only governance can open a market; its parameters are held in the ParamController, and
///         the first fill cannot be priced until its oracle feed has been configured.
contract VaultFactory {
    IParamController public immutable params;
    IEligibilityRegistry public immutable eligibility;
    IOracleRouter public immutable oracle;
    address public immutable feeCollector;
    address public immutable quoteToken;

    /// @notice The SwapRouter, assigned a single time. Vaults look it up here, which lets the router be deployed after the factory.
    address public router;

    mapping(address => address) public vaultOf;
    address[] public allMarkets;

    event RouterSet(address router);
    event MarketOpened(address indexed token, address vault);

    error NotGovernance();
    error RouterAlreadySet();
    error RouterNotSet();
    error MarketExists();
    error MarketNotConfigured();
    error QuoteAssetNotListable();
    error ZeroAddress();

    modifier onlyGovernance() {
        if (msg.sender != params.owner()) revert NotGovernance();
        _;
    }

    constructor(
        IParamController params_,
        IEligibilityRegistry eligibility_,
        IOracleRouter oracle_,
        address feeCollector_,
        address quoteToken_
    ) {
        if (
            address(params_) == address(0) || address(eligibility_) == address(0) || address(oracle_) == address(0)
                || feeCollector_ == address(0) || quoteToken_ == address(0)
        ) revert ZeroAddress();
        params = params_;
        eligibility = eligibility_;
        oracle = oracle_;
        feeCollector = feeCollector_;
        quoteToken = quoteToken_;
    }

    /// @notice Connects the router exactly once. This cannot be undone; a different router requires a fresh deployment.
    function setRouter(address router_) external onlyGovernance {
        // The router can only be set once, so a zero address here would leave the factory permanently unusable.
        if (router_ == address(0)) revert ZeroAddress();
        if (router != address(0)) revert RouterAlreadySet();
        router = router_;
        emit RouterSet(router_);
    }

    function createMarket(address token) external onlyGovernance returns (address vault) {
        if (router == address(0)) revert RouterNotSet();
        // Routing depends on which leg of a swap is the quote asset, so a vault pricing the quote asset
        // against itself would describe a market the router has no way to reach.
        if (token == quoteToken) revert QuoteAssetNotListable();
        if (vaultOf[token] != address(0)) revert MarketExists();
        // Lacking market parameters or an oracle feed, a vault still deploys but then rejects every
        // deposit and fill; insisting on the wiring first rules out a partly opened market.
        if (!params.marketConfig(token).enabled) revert MarketNotConfigured();
        oracle.tokenDecimals(token); // throws FeedNotConfigured until governance has set up the feed
        string memory sym = IERC20Metadata(token).symbol();
        vault = address(
            new AnchorVault(
                params,
                eligibility,
                oracle,
                feeCollector,
                quoteToken,
                token,
                string.concat("Iridius ", sym, " Vault"),
                string.concat("zv", sym)
            )
        );
        vaultOf[token] = vault;
        allMarkets.push(token);
        emit MarketOpened(token, vault);
    }

    function marketsLength() external view returns (uint256) {
        return allMarkets.length;
    }
}
