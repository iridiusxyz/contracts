// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {NativeAttestationAdapter} from "../src/adapters/NativeAttestationAdapter.sol";
import {IParamController} from "../src/interfaces/IParamController.sol";
import {Roles} from "../src/libraries/Types.sol";

/// @notice The native attestation store tested in isolation: who can issue, what a record means across its
///         lifetime, how the issuer whitelist affects every existing record, and which inputs are rejected.
contract AttestationsTest is BaseTest {
    function test_deploymentRefusesAZeroController() public {
        // Issuer checks all consult the controller; without one there can never be an issuer or an attestation.
        vm.expectRevert(NativeAttestationAdapter.ZeroAddress.selector);
        new NativeAttestationAdapter(IParamController(address(0)));
    }

    function test_attestRefusesTheZeroAccount() public {
        // No wallet can act as the zero account, so a record for it would only clutter the audit trail.
        vm.prank(issuer);
        vm.expectRevert(NativeAttestationAdapter.ZeroAddress.selector);
        attestations.attest(address(0), Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));
    }

    function test_onlyWhitelistedIssuersMayAttest() public {
        vm.prank(outsider);
        vm.expectRevert(NativeAttestationAdapter.NotIssuer.selector);
        attestations.attest(outsider, Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));
    }

    function test_expiryMustBeInTheFuture() public {
        vm.prank(issuer);
        vm.expectRevert(NativeAttestationAdapter.BadExpiry.selector);
        attestations.attest(outsider, Roles.TRADER, "LT", 2, uint64(block.timestamp));
    }

    function test_renewalOverwritesThePreviousRecord() public {
        (bytes32 uidBefore, uint64 expiryBefore) = attestations.attestationOf(trader, Roles.TRADER);
        vm.prank(issuer);
        bytes32 uid = attestations.attest(trader, Roles.TRADER, "LT", 2, expiryBefore + 30 days);

        (bytes32 uidAfter, uint64 expiryAfter) = attestations.attestationOf(trader, Roles.TRADER);
        assertEq(uidAfter, uid);
        assertTrue(uid != uidBefore);
        assertEq(expiryAfter, expiryBefore + 30 days);
        assertTrue(eligibility.isEligible(trader, Roles.TRADER));
    }

    function test_eligibilityEndsAtExpiry() public {
        (, uint64 expiry) = attestations.attestationOf(trader, Roles.TRADER);
        vm.warp(expiry - 1);
        assertTrue(eligibility.isEligible(trader, Roles.TRADER));
        vm.warp(expiry);
        assertFalse(eligibility.isEligible(trader, Roles.TRADER));

        // Eligibility lapses, but the record itself can still be read.
        (bytes32 uid,) = attestations.attestationOf(trader, Roles.TRADER);
        assertTrue(uid != bytes32(0));
    }

    function test_delistingAnIssuerVoidsEverythingItIssued() public {
        vm.prank(gov);
        params.setAttestationIssuer(issuer, false);
        assertFalse(eligibility.isEligible(trader, Roles.TRADER));
        assertFalse(eligibility.isEligible(lp1, Roles.LP));
        assertFalse(eligibility.isEligible(maker, Roles.MAKER));

        // Whitelisting the issuer again brings them back, since the records were disowned rather than deleted.
        vm.prank(gov);
        params.setAttestationIssuer(issuer, true);
        assertTrue(eligibility.isEligible(trader, Roles.TRADER));
    }

    function test_anyIssuerMayRevokeAnotherIssuersRecord() public {
        address second = makeAddr("secondIssuer");
        vm.prank(gov);
        params.setAttestationIssuer(second, true);

        // Any other issuer can withdraw a compromised issuer's records with no need to wait for governance.
        vm.prank(second);
        attestations.revoke(trader, Roles.TRADER);
        assertFalse(eligibility.isEligible(trader, Roles.TRADER));

        // Issuing a new attestation restores the account.
        vm.prank(issuer);
        attestations.attest(trader, Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));
        assertTrue(eligibility.isEligible(trader, Roles.TRADER));
    }

    function test_batchAttestsEveryAccount() public {
        address[] memory accounts = new address[](3);
        accounts[0] = makeAddr("a");
        accounts[1] = makeAddr("b");
        accounts[2] = makeAddr("c");

        vm.prank(issuer);
        bytes32[] memory uids =
            attestations.attestBatch(accounts, Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));

        assertEq(uids.length, 3);
        for (uint256 i = 0; i < accounts.length; i++) {
            (bytes32 uid,) = attestations.attestationOf(accounts[i], Roles.TRADER);
            assertEq(uid, uids[i]);
            assertTrue(eligibility.isEligible(accounts[i], Roles.TRADER));
        }
        assertTrue(uids[0] != uids[1] && uids[1] != uids[2]);
    }

    function test_batchIsAllOrNothing() public {
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("a");
        accounts[1] = address(0);

        vm.prank(issuer);
        vm.expectRevert(NativeAttestationAdapter.ZeroAddress.selector);
        attestations.attestBatch(accounts, Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));
        assertFalse(eligibility.isEligible(accounts[0], Roles.TRADER));

        vm.prank(outsider);
        vm.expectRevert(NativeAttestationAdapter.NotIssuer.selector);
        attestations.attestBatch(accounts, Roles.TRADER, "LT", 2, uint64(block.timestamp + 1 days));
    }

    function test_revokeBatchEndsEveryAttestation() public {
        address[] memory accounts = new address[](2);
        accounts[0] = lp1;
        accounts[1] = lp2;

        vm.prank(issuer);
        attestations.revokeBatch(accounts, Roles.LP);
        assertFalse(eligibility.isEligible(lp1, Roles.LP));
        assertFalse(eligibility.isEligible(lp2, Roles.LP));
    }

    function test_revokeBatchIsAllOrNothing() public {
        address[] memory accounts = new address[](2);
        accounts[0] = lp1;
        accounts[1] = outsider; // never attested

        vm.prank(issuer);
        vm.expectRevert(NativeAttestationAdapter.NotAttested.selector);
        attestations.revokeBatch(accounts, Roles.LP);
        assertTrue(eligibility.isEligible(lp1, Roles.LP));

        vm.prank(outsider);
        vm.expectRevert(NativeAttestationAdapter.NotIssuer.selector);
        attestations.revokeBatch(accounts, Roles.LP);
    }
}
