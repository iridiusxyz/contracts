// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IParamController} from "./interfaces/IParamController.sol";

/// @title FeeCollector
/// @notice Collects the itemised swap fees, the RFQ fees and the protocol's share of the spread. Until the
///         governance module assumes responsibility for allocation, the ParamController owner controls withdrawals.
contract FeeCollector {
    using SafeERC20 for IERC20;

    IParamController public immutable params;

    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error NotGovernance();
    error ZeroAddress();

    constructor(IParamController params_) {
        if (address(params_) == address(0)) revert ZeroAddress();
        params = params_;
    }

    function withdraw(IERC20 token, address to, uint256 amount) external {
        if (msg.sender != params.owner()) revert NotGovernance();
        // Plenty of tokens accept a transfer to the zero address and simply burn it, so a blank recipient
        // in a governance proposal would destroy fees instead of failing.
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Withdrawn(address(token), to, amount);
    }

    /// @notice Sweeps the whole balance of `token`, sparing proposals from having to guess an exact amount
    ///         that fees accruing in the meantime would already have changed by execution time.
    function withdrawAll(IERC20 token, address to) external returns (uint256 amount) {
        if (msg.sender != params.owner()) revert NotGovernance();
        if (to == address(0)) revert ZeroAddress();
        amount = _sweep(token, to);
    }

    /// @notice Sweeps the full balance of each token in `tokens`, so a treasury proposal can collect
    ///         every fee asset in one call. Tokens with nothing to sweep are skipped.
    function withdrawAllMany(IERC20[] calldata tokens, address to) external returns (uint256[] memory amounts) {
        if (msg.sender != params.owner()) revert NotGovernance();
        if (to == address(0)) revert ZeroAddress();
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = _sweep(tokens[i], to);
        }
    }

    function _sweep(IERC20 token, address to) internal returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount == 0) return 0;
        token.safeTransfer(to, amount);
        emit Withdrawn(address(token), to, amount);
    }
}
