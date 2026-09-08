// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IParamController
/// @notice Read-only access to each tunable parameter of the protocol.
interface IParamController {
    /// @notice Pricing settings common to all markets in a tier. Spreads are expressed as half-spreads in
    ///         basis points either side of the oracle mid, and no fill may ever cross the oracle band.
    struct TierConfig {
        uint16 baseHalfSpreadBps;
        uint16 maxSkewBps;
        /// @dev How far the token's share of vault value may drift from the 50% target, in bps of value.
        uint16 inventoryBandBps;
        /// @dev The absolute limit on how far any fill, vault or RFQ, may sit from the guarded mid.
        uint16 oracleBandBps;
        /// @dev The biggest single vault swap allowed in the regular session, as quote-token notional.
        uint128 maxClip;
        bool enabled;
    }

    struct MarketConfig {
        uint8 tier;
        /// @dev Volume ceiling for each UTC day while the guarded launch lasts, as quote-token notional.
        uint128 dailyVolumeCap;
        /// @dev Limit on total vault value while the guarded launch lasts, in quote-token units.
        uint128 tvlCap;
        bool enabled;
    }

    /// @notice Multipliers applied per session, in bps of the base value (10_000 = x1.0).
    struct RegimeParams {
        uint16 extendedSpreadMulBps;
        uint16 closedSpreadMulBps;
        uint16 extendedClipMulBps;
        uint16 closedClipMulBps;
    }

    struct RiskParams {
        /// @dev How long trading remains halted once the sequencer recovers from an outage.
        uint32 sequencerGrace;
    }

    struct FeeParams {
        /// @dev Applied to each vault fill and shown as its own line on the ticket.
        uint16 swapFeeBps;
        /// @dev Applied to each RFQ fill and taken out of the quote-token leg.
        uint16 rfqFeeBps;
        /// @dev Portion of the vault's realised spread that goes to the protocol.
        uint16 spreadShareBps;
    }

    function owner() external view returns (address);
    function guardian() external view returns (address);

    function tierConfig(uint8 tier) external view returns (TierConfig memory);
    function marketConfig(address token) external view returns (MarketConfig memory);
    function regimeParams() external view returns (RegimeParams memory);
    function riskParams() external view returns (RiskParams memory);
    function feeParams() external view returns (FeeParams memory);
    function attestationIssuer(address issuer) external view returns (bool);
    function eligibilityAdapter() external view returns (address);
    function swapsPaused() external view returns (bool);
}
