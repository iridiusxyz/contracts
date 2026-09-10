// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IEligibilityRegistry, IEligibilityAdapter} from "./interfaces/IEligibilityRegistry.sol";
import {IParamController} from "./interfaces/IParamController.sol";

/// @title EligibilityRegistry
/// @notice Decides who is allowed to trade, supply liquidity and make markets. Policy lives in an adapter
///         selected via the ParamController, which means it can be swapped (EAS, ONCHAINID, Chainlink ACE)
///         with no change to the core. Anyone may call the views.
contract EligibilityRegistry is IEligibilityRegistry {
    IParamController public immutable params;

    error AdapterNotSet();
    error ZeroAddress();

    constructor(IParamController params_) {
        if (address(params_) == address(0)) revert ZeroAddress();
        params = params_;
    }

    function adapter() public view returns (IEligibilityAdapter) {
        address a = params.eligibilityAdapter();
        if (a == address(0)) revert AdapterNotSet();
        return IEligibilityAdapter(a);
    }

    function isEligible(address account, bytes32 role) public view override returns (bool) {
        return adapter().isEligible(account, role);
    }

    function requireRole(address account, bytes32 role) external view override {
        if (!isEligible(account, role)) revert NotEligible(account, role);
    }

    function attestationOf(address account, bytes32 role) external view override returns (bytes32 uid, uint64 expiry) {
        return adapter().attestationOf(account, role);
    }
}
