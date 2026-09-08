// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IEligibilityAdapter
/// @notice The policy engine the registry delegates to. It can be implemented by EAS, ONCHAINID or Chainlink ACE.
interface IEligibilityAdapter {
    function isEligible(address account, bytes32 role) external view returns (bool);
    function attestationOf(address account, bytes32 role) external view returns (bytes32 uid, uint64 expiry);
}

/// @title IEligibilityRegistry
/// @notice Consulted on each swap, deposit, RFQ settlement and transfer of vault shares. Withdrawals are
///         never gated, since leaving a vault comes with holding shares rather than being a permission.
interface IEligibilityRegistry {
    error NotEligible(address account, bytes32 role);

    function isEligible(address account, bytes32 role) external view returns (bool);
    function requireRole(address account, bytes32 role) external view;
    function attestationOf(address account, bytes32 role) external view returns (bytes32 uid, uint64 expiry);
}
