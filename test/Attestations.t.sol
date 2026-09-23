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
}
