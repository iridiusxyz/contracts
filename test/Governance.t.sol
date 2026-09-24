// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Roles} from "../src/libraries/Types.sol";
import {ParamController} from "../src/ParamController.sol";
import {IParamController} from "../src/interfaces/IParamController.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {IOracleRouter} from "../src/interfaces/IOracleRouter.sol";
import {NativeAttestationAdapter} from "../src/adapters/NativeAttestationAdapter.sol";
import {MockStockToken} from "../src/mocks/Mocks.sol";

/// @notice Change control: ending bootstrap binds the controller to the timelock, the guardian's only power
///         is pausing, and validation rejects any configuration the pricing formula could not honour.
contract GovernanceTest is BaseTest {
    function _feeCall(uint16 swapFee) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            ParamController.setFeeParams,
            (IParamController.FeeParams({swapFeeBps: swapFee, rfqFeeBps: 2, spreadShareBps: 1000}))
        );
    }

    function test_bootstrapLocksSettersToTheTimelock() public {
        vm.prank(gov);
        params.finishBootstrap();

        // Nobody, not even the owner, may call a setter directly.
        vm.prank(gov);
        vm.expectRevert(ParamController.NotSelf.selector);
        params.setFeeParams(IParamController.FeeParams({swapFeeBps: 5, rfqFeeBps: 2, spreadShareBps: 1000}));

        // The sole route is to schedule, sit out the delay, then execute.
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        params.schedule(calls, bytes32("salt"), keccak256("rationale: fee retune per Q3 execution data"));

        vm.prank(gov);
        vm.expectRevert(ParamController.OperationNotReady.selector);
        params.execute(calls, bytes32("salt"));

        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        params.execute(calls, bytes32("salt"));
        assertEq(params.feeParams().swapFeeBps, 5);
    }

    function test_scheduledOperationCanBeCancelled() public {
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        bytes32 id = params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.prank(gov);
        params.cancel(id);
        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        vm.expectRevert(ParamController.OperationNotFound.selector);
        params.execute(calls, bytes32("salt"));

        // A second cancel is rejected, because a cancelled operation is effectively gone.
        vm.prank(gov);
        vm.expectRevert(ParamController.OperationNotFound.selector);
        params.cancel(id);
    }

    function test_cancelledOperationCanBeRescheduled() public {
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        bytes32 id = params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.prank(gov);
        params.cancel(id);

        // Rescheduling the same batch with the same salt starts a new timelock instead of hitting a spent id.
        vm.prank(gov);
        params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        params.execute(calls, bytes32("salt"));
        assertEq(params.feeParams().swapFeeBps, 5);
    }

    function test_guardianCanPauseAndNothingElse() public {
        vm.prank(guardian);
        params.setPaused(true);
        assertTrue(params.swapsPaused());

        vm.prank(guardian);
        vm.expectRevert(ParamController.NotOwner.selector);
        params.setFeeParams(IParamController.FeeParams({swapFeeBps: 0, rfqFeeBps: 0, spreadShareBps: 0}));

        vm.prank(outsider);
        vm.expectRevert(ParamController.NotGuardian.selector);
        params.setPaused(true);
    }

    function test_tierValidationRefusesUnpriceableConfigs() public {
        // If the base spread plus full skew cannot fit within the oracle band, the config is rejected at once.
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidBps.selector);
        params.setTierConfig(
            4,
            IParamController.TierConfig({
                baseHalfSpreadBps: 60,
                maxSkewBps: 30,
                inventoryBandBps: 2000,
                oracleBandBps: 75,
                maxClip: 1_000e6,
                enabled: true
            })
        );

        // With a zero inventory band, an enabled tier would divide skew by zero on its first fill.
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidBps.selector);
        params.setTierConfig(
            4,
            IParamController.TierConfig({
                baseHalfSpreadBps: 10,
                maxSkewBps: 15,
                inventoryBandBps: 0,
                oracleBandBps: 75,
                maxClip: 1_000e6,
                enabled: true
            })
        );
    }

    function test_capsRefuseSelfDisablingConfigs() public {
        // A tier allowing no clip, or a market without daily or TVL headroom, is enabled only on paper,
        // since every fill or deposit would hit the cap and revert. Reject it early instead of launching a dead market.
        IParamController.TierConfig memory tier = params.tierConfig(1);
        tier.maxClip = 0;
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidCap.selector);
        params.setTierConfig(1, tier);

        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidCap.selector);
        params.setMarketConfig(
            address(nvda), IParamController.MarketConfig({tier: 1, dailyVolumeCap: 0, tvlCap: 1e6, enabled: true})
        );
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidCap.selector);
        params.setMarketConfig(
            address(nvda), IParamController.MarketConfig({tier: 1, dailyVolumeCap: 1e6, tvlCap: 0, enabled: true})
        );

        // Retirement uses a flag rather than a zero cap, so a disabled market can hold any caps whatsoever.
        vm.prank(gov);
        params.setMarketConfig(
            address(nvda), IParamController.MarketConfig({tier: 1, dailyVolumeCap: 0, tvlCap: 0, enabled: false})
        );
        assertFalse(params.marketConfig(address(nvda)).enabled);
    }

    function test_bootstrapRequiresTheMinimumDelay() public {
        // During bootstrap the owner can use a short delay for iteration but cannot bind the controller to it.
        vm.prank(gov);
        params.setDelay(30 minutes);
        vm.prank(gov);
        vm.expectRevert(ParamController.DelayTooShort.selector);
        params.finishBootstrap();

        uint256 floor = params.MIN_DELAY();
        vm.prank(gov);
        params.setDelay(floor);
        vm.prank(gov);
        params.finishBootstrap();
        assertTrue(params.bootstrapped());

        // After locking, that floor also applies to every delay change made through the timelock.
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(ParamController.setDelay, (30 minutes));
        vm.prank(gov);
        params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.warp(block.timestamp + 1 hours);
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(
                ParamController.CallFailed.selector, 0, abi.encodeWithSelector(ParamController.DelayTooShort.selector)
            )
        );
        params.execute(calls, bytes32("salt"));
    }

    function test_regimeValidationKeepsMultipliersHonest() public {
        // Session multipliers can only widen spreads and shrink clips.
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidBps.selector);
        params.setRegimeParams(
            IParamController.RegimeParams({
                extendedSpreadMulBps: 9_000,
                closedSpreadMulBps: 30_000,
                extendedClipMulBps: 7_500,
                closedClipMulBps: 5_000
            })
        );
    }

    function test_marketRequiresEnabledTier() public {
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidTier.selector);
        params.setMarketConfig(
            address(0xBEEF), IParamController.MarketConfig({tier: 9, dailyVolumeCap: 1e6, tvlCap: 1e6, enabled: true})
        );
    }

    function test_deploymentRefusesZeroAddresses() public {
        // With a zero owner, the controller could never be governed by anyone.
        vm.expectRevert(ParamController.ZeroAddress.selector);
        new ParamController(address(0), guardian, 1 days);

        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        new VaultFactory(params, eligibility, oracle, address(0), address(usdg));

        // The router can only be wired once, so a zero router would leave the factory permanently unusable.
        vm.prank(gov);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setRouter(address(0));
    }

    function test_marketOpensOnlyOnceFullyWired() public {
        MockStockToken fresh = new MockStockToken("Tesla Stock Token", "TSLAx");

        // Rejected while market parameters are missing.
        vm.prank(gov);
        vm.expectRevert(VaultFactory.MarketNotConfigured.selector);
        factory.createMarket(address(fresh));

        // Still rejected with parameters in place but no oracle feed.
        vm.prank(gov);
        params.setMarketConfig(
            address(fresh),
            IParamController.MarketConfig({tier: 1, dailyVolumeCap: 1_000e6, tvlCap: 1_000e6, enabled: true})
        );
        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(IOracleRouter.FeedNotConfigured.selector, address(fresh)));
        factory.createMarket(address(fresh));
    }

    function test_revokeRequiresAnAttestation() public {
        // A mistyped account from an issuer has to fail visibly instead of emitting a zero-uid revocation of nothing.
        vm.prank(issuer);
        vm.expectRevert(NativeAttestationAdapter.NotAttested.selector);
        attestations.revoke(outsider, Roles.TRADER);

        // Revoking a genuine record still works.
        vm.prank(issuer);
        attestations.revoke(trader, Roles.TRADER);
        assertFalse(eligibility.isEligible(trader, Roles.TRADER));
    }

    function test_ownershipHandoverIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(gov);
        params.transferOwnership(next);
        assertEq(params.owner(), gov); // ownership stays put until the new owner accepts
        vm.prank(next);
        params.acceptOwnership();
        assertEq(params.owner(), next);
    }

    function test_delayIsCappedSoATypoCannotLockGovernanceOut() public {
        // Exceeding the ceiling adds no safety, only a controller that nobody can alter for years.
        vm.expectRevert(ParamController.DelayTooLong.selector);
        new ParamController(gov, guardian, 31 days);

        uint256 ceiling = params.MAX_DELAY();
        vm.prank(gov);
        vm.expectRevert(ParamController.DelayTooLong.selector);
        params.setDelay(ceiling + 1);
        vm.prank(gov);
        params.setDelay(ceiling);
        assertEq(params.delay(), ceiling);

        // The ceiling also applies via the timelock, where a mistyped value would otherwise be permanent:
        // undoing it would need an operation that first sat out the mistyped delay.
        vm.prank(gov);
        params.setDelay(1 days);
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(ParamController.setDelay, (ceiling + 1));
        vm.prank(gov);
        params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(
                ParamController.CallFailed.selector, 0, abi.encodeWithSelector(ParamController.DelayTooLong.selector)
            )
        );
        params.execute(calls, bytes32("salt"));
    }
}
