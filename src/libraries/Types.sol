// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Types
/// @notice Structs, enums and constants used across the Iridius protocol.
library Types {
    // ---------------------------------------------------------------------
    // Enums
    // ---------------------------------------------------------------------

    /// @notice How the oracle router classifies the underlying market. The vault bases its trading regime
    ///         on it, widening spreads and shrinking clips whenever the regular session is not open.
    enum Session {
        Regular,
        Extended,
        Closed
    }

    /// @notice The venue that executed a swap.
    enum Venue {
        Vault,
        Rfq
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    /// @dev Each vault aims to hold value split 50/50 between the listed token and the quote asset.
    uint256 internal constant TARGET_RATIO_BPS = 5_000;

    // ---------------------------------------------------------------------
    // Signed messages
    // ---------------------------------------------------------------------

    /// @notice A maker quote for the RFQ lane, signed under EIP-712. Signing and cancelling cost nothing, and
    ///         settlement uses it up. One, and only one, of `tokenIn` and `tokenOut` must be the quote asset.
    struct MakerQuote {
        address maker;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        /// @dev Zero for an open quote, otherwise the only trader allowed to take it.
        address taker;
        uint40 expiry;
        uint256 nonce;
    }

    // ---------------------------------------------------------------------
    // Pricing
    // ---------------------------------------------------------------------

    /// @notice A vault quote split into its itemised parts. Each fill emits it, so the record on-chain
    ///         holds exactly the breakdown that appeared on the ticket.
    struct Breakdown {
        /// @dev Base units of the quote token for each whole listed token, taken from the guarded oracle.
        uint256 mid;
        /// @dev Half-spread for this side after regime adjustment and after the skew term.
        uint16 halfSpreadBps;
        /// @dev The signed inventory skew; a positive value means the vault is long the token.
        int16 skewBps;
        /// @dev The protocol fee charged on this fill.
        uint16 feeBps;
        Session session;
    }
}

/// @title Roles
/// @notice The eligibility roles the registry checks.
library Roles {
    bytes32 internal constant TRADER = keccak256("iridius.role.TRADER");
    bytes32 internal constant LP = keccak256("iridius.role.LP");
    bytes32 internal constant MAKER = keccak256("iridius.role.MAKER");
    bytes32 internal constant RELAYER = keccak256("iridius.role.RELAYER");
}
