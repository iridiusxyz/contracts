// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IEligibilityAdapter} from "../interfaces/IEligibilityRegistry.sol";
import {IParamController} from "../interfaces/IParamController.sol";
import {Roles} from "../libraries/Types.sol";

/// @title NativeAttestationAdapter
/// @notice A standalone attestation store whose semantics match EAS, for use where no EAS deployment
///         exists yet (Robinhood Chain testnet). Each attestation records role, jurisdiction class,
///         investor class and expiry, and no personal data is kept. The ParamController whitelists
///         issuers, which can be KYC providers or the signing services they run.
contract NativeAttestationAdapter is IEligibilityAdapter {
    struct Attestation {
        bytes32 uid;
        address issuer;
        bytes2 jurisdictionClass;
        uint8 investorClass;
        uint64 issuedAt;
        uint64 expiry;
        bool revoked;
    }

    IParamController public immutable params;
    uint256 public nonce;

    mapping(address => mapping(bytes32 => Attestation)) internal _attestations;

    event Attested(
        address indexed account,
        bytes32 indexed role,
        bytes32 uid,
        address indexed issuer,
        bytes2 jurisdictionClass,
        uint8 investorClass,
        uint64 expiry
    );
    event Revoked(address indexed account, bytes32 indexed role, bytes32 uid, address indexed issuer);

    error NotIssuer();
    error BadExpiry();
    error NotAttested();
    error UnknownRole();
    error ZeroAddress();

    modifier onlyIssuer() {
        if (!params.attestationIssuer(msg.sender)) revert NotIssuer();
        _;
    }

    constructor(IParamController params_) {
        // Issuer checks all consult the controller; with no controller there can be no issuer and no attestation.
        if (address(params_) == address(0)) revert ZeroAddress();
        params = params_;
    }

    /// @notice Creates or renews an attestation; a renewal replaces the earlier record.
    function attest(address account, bytes32 role, bytes2 jurisdictionClass, uint8 investorClass, uint64 expiry)
        external
        onlyIssuer
        returns (bytes32 uid)
    {
        return _attest(account, role, jurisdictionClass, investorClass, expiry);
    }

    /// @notice Attests a list of accounts to one role with the same classes and expiry, which is how an
    ///         issuer onboards a cohort cleared by the same review. Any invalid entry reverts the whole batch.
    function attestBatch(
        address[] calldata accounts,
        bytes32 role,
        bytes2 jurisdictionClass,
        uint8 investorClass,
        uint64 expiry
    ) external onlyIssuer returns (bytes32[] memory uids) {
        uids = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            uids[i] = _attest(accounts[i], role, jurisdictionClass, investorClass, expiry);
        }
    }

    function _attest(address account, bytes32 role, bytes2 jurisdictionClass, uint8 investorClass, uint64 expiry)
        internal
        returns (bytes32 uid)
    {
        if (expiry <= block.timestamp) revert BadExpiry();
        // Roles are hashes, so a typo in one still produces a valid-looking value. The record would be
        // written and the account would still fail every check, so reject anything the protocol never asks about.
        if (role != Roles.TRADER && role != Roles.LP && role != Roles.MAKER && role != Roles.RELAYER) {
            revert UnknownRole();
        }
        // No wallet can ever act as the zero account, so a record for it would only clutter the audit trail.
        if (account == address(0)) revert ZeroAddress();
        uid = keccak256(abi.encodePacked(account, role, msg.sender, ++nonce, block.chainid));
        _attestations[account][role] = Attestation({
            uid: uid,
            issuer: msg.sender,
            jurisdictionClass: jurisdictionClass,
            investorClass: investorClass,
            issuedAt: uint64(block.timestamp),
            expiry: expiry,
            revoked: false
        });
        emit Attested(account, role, uid, msg.sender, jurisdictionClass, investorClass, expiry);
    }

    /// @notice Revokes with immediate effect. Revocation is open to any whitelisted issuer, letting others override a compromised one.
    function revoke(address account, bytes32 role) external onlyIssuer {
        _revoke(account, role);
    }

    /// @notice Revokes one role from a list of accounts, for when an issuer has to withdraw a whole cohort
    ///         at once, for example after a review is found to be flawed. One unknown account reverts the batch.
    function revokeBatch(address[] calldata accounts, bytes32 role) external onlyIssuer {
        for (uint256 i = 0; i < accounts.length; i++) {
            _revoke(accounts[i], role);
        }
    }

    function _revoke(address account, bytes32 role) internal {
        Attestation storage a = _attestations[account][role];
        // Revoking something never issued would create a phantom entry and emit a zero uid, cluttering
        // the audit trail; a mistyped account from an issuer ought to fail visibly instead.
        if (a.uid == bytes32(0)) revert NotAttested();
        a.revoked = true;
        emit Revoked(account, role, a.uid, msg.sender);
    }

    function isEligible(address account, bytes32 role) external view override returns (bool) {
        Attestation storage a = _attestations[account][role];
        return a.uid != bytes32(0) && !a.revoked && a.expiry > block.timestamp && params.attestationIssuer(a.issuer);
    }

    function attestationOf(address account, bytes32 role) external view override returns (bytes32 uid, uint64 expiry) {
        Attestation storage a = _attestations[account][role];
        return (a.uid, a.expiry);
    }

    function attestation(address account, bytes32 role) external view returns (Attestation memory) {
        return _attestations[account][role];
    }
}
