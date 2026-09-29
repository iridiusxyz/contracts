// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AnchorVault} from "../src/AnchorVault.sol";
import {SwapRouter} from "../src/SwapRouter.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {Types} from "../src/libraries/Types.sol";
import {MockERC20, MockStockToken, MockAggregatorV3} from "../src/mocks/Mocks.sol";

/// @title Seed
/// @notice Gives a new testnet deployment some activity: it mints mock balances, supplies the launch vault
///         with balanced liquidity, and routes one buy and one sell so the explorer has genuine fills to
///         display. The deployer acts as both LP and trader, roles the testnet deploy has attested it for.
/// @dev Loads deployments/<chainId>.json as produced by Deploy.s.sol. Run:
///        forge script script/Seed.s.sol --rpc-url robinhood_testnet --broadcast
contract Seed is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        MockERC20 usdg = MockERC20(vm.parseJsonAddress(json, ".USDG"));
        MockStockToken stock = MockStockToken(vm.parseJsonAddress(json, ".StockToken"));
        MockAggregatorV3 feed = MockAggregatorV3(vm.parseJsonAddress(json, ".StockFeed"));
        AnchorVault vault = AnchorVault(vm.parseJsonAddress(json, ".AnchorVault"));
        SwapRouter router = SwapRouter(vm.parseJsonAddress(json, ".SwapRouter"));

        vm.startBroadcast(pk);

        // Push a new oracle round so nothing reads as stale, then mint balances for the LP and trader roles.
        feed.set(feed.answer());
        uint256 mid = uint256(feed.answer()) / 100; // converts the 8-decimal feed into 6-decimal quote units
        usdg.mint(me, 1_500_000e6);
        stock.mint(me, 1_000_000e6 * 1e18 / mid);

        // Balanced liquidity of 500,000 USDG on each side.
        usdg.approve(address(vault), type(uint256).max);
        stock.approve(address(vault), type(uint256).max);
        vault.deposit(500_000e6, 500_000e6 * 1e18 / mid, 0, me);

        // A single buy and a single sell via the router, giving each side of the book a fill.
        usdg.approve(address(router), type(uint256).max);
        stock.approve(address(router), type(uint256).max);
        Types.MakerQuote memory none;
        router.swapExactIn(
            SwapRouter.SwapParams({
                tokenIn: address(usdg),
                tokenOut: address(stock),
                amountIn: 10_000e6,
                minAmountOut: 0,
                to: address(0),
                deadline: block.timestamp + 10 minutes,
                quote: none,
                quoteSig: ""
            })
        );
        router.swapExactIn(
            SwapRouter.SwapParams({
                tokenIn: address(stock),
                tokenOut: address(usdg),
                amountIn: 20e18,
                minAmountOut: 0,
                to: address(0),
                deadline: block.timestamp + 10 minutes,
                quote: none,
                quoteSig: ""
            })
        );

        vm.stopBroadcast();

        console2.log("Seeded vault", address(vault));
        console2.log("Vault value (quote units)", vault.totalValue());
    }
}
