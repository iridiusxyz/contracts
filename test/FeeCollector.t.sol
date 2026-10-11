// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "./Base.t.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

/// @notice The fee sink: only governance can move what it holds, and never to the zero address.
contract FeeCollectorTest is BaseTest {
    address internal treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();
        usdg.mint(address(fees), 1_234e6);
    }

    function test_onlyGovernanceMayWithdraw() public {
        vm.prank(outsider);
        vm.expectRevert(FeeCollector.NotGovernance.selector);
        fees.withdraw(IERC20(address(usdg)), outsider, 1e6);

        vm.prank(outsider);
        vm.expectRevert(FeeCollector.NotGovernance.selector);
        fees.withdrawAll(IERC20(address(usdg)), outsider);
    }

    function test_withdrawRefusesTheZeroRecipient() public {
        vm.startPrank(gov);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        fees.withdraw(IERC20(address(usdg)), address(0), 1e6);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        fees.withdrawAll(IERC20(address(usdg)), address(0));
        vm.stopPrank();
    }

    function test_withdrawAllSweepsTheFullBalance() public {
        vm.prank(gov);
        uint256 amount = fees.withdrawAll(IERC20(address(usdg)), treasury);

        assertEq(amount, 1_234e6);
        assertEq(usdg.balanceOf(treasury), 1_234e6);
        assertEq(usdg.balanceOf(address(fees)), 0);
    }

    function test_partialWithdrawLeavesTheRest() public {
        vm.prank(gov);
        fees.withdraw(IERC20(address(usdg)), treasury, 234e6);

        assertEq(usdg.balanceOf(treasury), 234e6);
        assertEq(usdg.balanceOf(address(fees)), 1_000e6);
    }
}
