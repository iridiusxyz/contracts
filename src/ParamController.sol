// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IParamController} from "./interfaces/IParamController.sol";
import {Types} from "./libraries/Types.sol";

/// @title ParamController
/// @notice Keeps all of the protocol's tunable parameters behind a timelock, emitting an event for each change.
/// @dev Governance sequence: `schedule(calls, rationale)` -> wait `delay` -> `execute(calls, salt)`.
///      As the setters are `onlySelf`, `execute` is the only path to them. While bootstrapping, the owner
///      may call setters directly; `finishBootstrap()` cannot be reversed and binds the controller to the
///      timelock. Pausing swaps is all the guardian can do. No function here moves funds or gates a vault withdrawal.
contract ParamController is IParamController {
    // ---------------------------------------------------------------------
    // Governance state
    // ---------------------------------------------------------------------

    /// @notice The minimum timelock the controller will bind itself to. After bootstrap ends the delay can
    ///         never drop below it, and bootstrap cannot end while the delay is still under it.
    uint256 public constant MIN_DELAY = 1 hours;
    /// @notice The maximum timelock the controller accepts, during bootstrap and after it. Going beyond this
    ///         adds no safety, only a controller that nobody can alter for years, and once the delay itself
    ///         is only changeable via the timelock, a mistyped value would be permanent.
    uint256 public constant MAX_DELAY = 30 days;

    address public override owner;
    address public override guardian;
    address public pendingOwner;
    uint256 public delay;
    bool public bootstrapped;

    struct Operation {
        uint64 eta;
        bool executed;
        bool cancelled;
        bytes32 rationale;
    }

    mapping(bytes32 => Operation) public operations;

    // ---------------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------------

    mapping(uint8 => TierConfig) internal _tiers;
    mapping(address => MarketConfig) internal _markets;
    mapping(address => bool) public override attestationIssuer;
    address public override eligibilityAdapter;
    bool public override swapsPaused;

    RegimeParams internal _regimeParams;
    RiskParams internal _riskParams;
    FeeParams internal _feeParams;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event OperationScheduled(bytes32 indexed id, uint64 eta, bytes32 rationale, bytes[] calls);
    event OperationExecuted(bytes32 indexed id);
    event OperationCancelled(bytes32 indexed id);
    event ParamChanged(bytes32 indexed key, bytes32 indexed subject, bytes value);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);
    event GuardianChanged(address indexed guardian);
    event DelayChanged(uint256 delay);
    event BootstrapFinished();
    event EmergencyPause(bool swapsPaused, address indexed by);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error NotGuardian();
    error NotSelf();
    error NotPendingOwner();
    error AlreadyBootstrapped();
    error OperationExists();
    error OperationNotReady();
    error OperationNotFound();
    error CallFailed(uint256 index, bytes reason);
    error InvalidBps();
    error InvalidTier();
    error InvalidCap();
    error DelayTooShort();
    error DelayTooLong();
    error ZeroAddress();

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev After bootstrap, setters go through `execute`; until then the owner can call them directly.
    modifier onlySelf() {
        if (bootstrapped) {
            if (msg.sender != address(this)) revert NotSelf();
        } else {
            if (msg.sender != owner && msg.sender != address(this)) revert NotOwner();
        }
        _;
    }

    constructor(address owner_, address guardian_, uint256 delay_) {
        // A zero guardian simply means there is none, but a zero owner leaves a controller no one could ever govern.
        if (owner_ == address(0)) revert ZeroAddress();
        if (delay_ > MAX_DELAY) revert DelayTooLong();
        owner = owner_;
        guardian = guardian_;
        delay = delay_;
        emit OwnershipTransferred(address(0), owner_);
        emit GuardianChanged(guardian_);
        emit DelayChanged(delay_);
    }

    // ---------------------------------------------------------------------
    // Timelock
    // ---------------------------------------------------------------------

    function operationId(bytes[] calldata calls, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(calls, salt));
    }

    /// @notice Queues a batch of setter calls, with `rationale` holding the hash of the rationale that was published.
    function schedule(bytes[] calldata calls, bytes32 salt, bytes32 rationale) external onlyOwner returns (bytes32 id) {
        id = operationId(calls, salt);
        // The same salt may be reused to reschedule a cancelled batch; an id stays taken only while its
        // operation is pending or has been executed.
        if (operations[id].eta != 0 && !operations[id].cancelled) revert OperationExists();
        uint64 eta = uint64(block.timestamp + delay);
        operations[id] = Operation({eta: eta, executed: false, cancelled: false, rationale: rationale});
        emit OperationScheduled(id, eta, rationale, calls);
    }

    /// @notice Runs a queued batch after its timelock has passed.
    function execute(bytes[] calldata calls, bytes32 salt) external onlyOwner {
        bytes32 id = operationId(calls, salt);
        Operation storage op = operations[id];
        if (op.eta == 0 || op.cancelled || op.executed) revert OperationNotFound();
        if (block.timestamp < op.eta) revert OperationNotReady();
        op.executed = true;
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory reason) = address(this).call(calls[i]);
            if (!ok) revert CallFailed(i, reason);
        }
        emit OperationExecuted(id);
    }

    function cancel(bytes32 id) external onlyOwner {
        Operation storage op = operations[id];
        if (op.eta == 0 || op.executed || op.cancelled) revert OperationNotFound();
        op.cancelled = true;
        emit OperationCancelled(id);
    }

    /// @notice Binds the controller to the timelock for good; this cannot be undone.
    function finishBootstrap() external onlyOwner {
        if (bootstrapped) revert AlreadyBootstrapped();
        // `setDelay` only enforces its floor after bootstrap, so the check is repeated here: fixing a shorter
        // delay would produce a timelock able to change its own delay quicker than anyone could respond.
        if (delay < MIN_DELAY) revert DelayTooShort();
        bootstrapped = true;
        emit BootstrapFinished();
    }

    // ---------------------------------------------------------------------
    // Ownership and guardian
    // ---------------------------------------------------------------------

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function setGuardian(address guardian_) external onlySelf {
        guardian = guardian_;
        emit GuardianChanged(guardian_);
    }

    function setDelay(uint256 delay_) external onlySelf {
        if (bootstrapped && delay_ < MIN_DELAY) revert DelayTooShort();
        if (delay_ > MAX_DELAY) revert DelayTooLong();
        delay = delay_;
        emit DelayChanged(delay_);
    }

    // ---------------------------------------------------------------------
    // Emergency pause, covering swaps alone. Deposits, withdrawals and RFQ cancellation can never be paused.
    // The guardian may switch the pause on, but only the owner may switch it off.
    // ---------------------------------------------------------------------

    function setPaused(bool swaps) external {
        if (msg.sender != guardian && msg.sender != owner && msg.sender != address(this)) revert NotGuardian();
        // The guardian's authority runs in one direction only: it can halt trading at once but cannot
        // resume it, so a stolen guardian key cannot lift a pause while an incident is under way.
        if (!swaps && msg.sender == guardian) revert NotOwner();
        swapsPaused = swaps;
        emit EmergencyPause(swaps, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Setters (timelocked)
    // ---------------------------------------------------------------------

    function setTierConfig(uint8 tier, TierConfig calldata cfg) external onlySelf {
        if (tier == 0) revert InvalidTier();
        // The oracle band is the outermost limit: the base spread plus the full skew has to fit within it,
        // the inventory band must leave room either side of the target, and no value may go above 100%.
        if (
            cfg.oracleBandBps > Types.BPS || cfg.inventoryBandBps > Types.TARGET_RATIO_BPS
                || (cfg.enabled && cfg.inventoryBandBps == 0)
                || uint256(cfg.baseHalfSpreadBps) + cfg.maxSkewBps > cfg.oracleBandBps
        ) revert InvalidBps();
        // With a zero clip an enabled tier rejects every fill, which amounts to disabling the market by mistake.
        if (cfg.enabled && cfg.maxClip == 0) revert InvalidCap();
        _tiers[tier] = cfg;
        emit ParamChanged("tier", bytes32(uint256(tier)), abi.encode(cfg));
    }

    function setMarketConfig(address token, MarketConfig calldata cfg) external onlySelf {
        if (cfg.enabled && !_tiers[cfg.tier].enabled) revert InvalidTier();
        // In the same way, a zero daily cap rejects all fills and a zero TVL cap all deposits. To retire
        // a market, set `enabled = false` rather than zeroing a cap.
        if (cfg.enabled && (cfg.dailyVolumeCap == 0 || cfg.tvlCap == 0)) revert InvalidCap();
        _markets[token] = cfg;
        emit ParamChanged("market", bytes32(uint256(uint160(token))), abi.encode(cfg));
    }

    function setRegimeParams(RegimeParams calldata p) external onlySelf {
        // Session multipliers may only widen spreads and shrink clips, never the opposite.
        if (
            p.extendedSpreadMulBps < Types.BPS || p.closedSpreadMulBps < p.extendedSpreadMulBps
                || p.extendedClipMulBps > Types.BPS || p.closedClipMulBps > p.extendedClipMulBps
        ) revert InvalidBps();
        _regimeParams = p;
        emit ParamChanged("regimeParams", bytes32(0), abi.encode(p));
    }

    function setRiskParams(RiskParams calldata p) external onlySelf {
        _riskParams = p;
        emit ParamChanged("riskParams", bytes32(0), abi.encode(p));
    }

    function setFeeParams(FeeParams calldata p) external onlySelf {
        if (p.swapFeeBps > Types.BPS || p.rfqFeeBps > Types.BPS || p.spreadShareBps > Types.BPS) revert InvalidBps();
        _feeParams = p;
        emit ParamChanged("feeParams", bytes32(0), abi.encode(p));
    }

    function setAttestationIssuer(address issuer, bool ok) external onlySelf {
        attestationIssuer[issuer] = ok;
        emit ParamChanged("attestationIssuer", bytes32(uint256(uint160(issuer))), abi.encode(ok));
    }

    function setEligibilityAdapter(address adapter) external onlySelf {
        eligibilityAdapter = adapter;
        emit ParamChanged("eligibilityAdapter", bytes32(uint256(uint160(adapter))), "");
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function tierConfig(uint8 tier) external view override returns (TierConfig memory) {
        return _tiers[tier];
    }

    function marketConfig(address token) external view override returns (MarketConfig memory) {
        return _markets[token];
    }

    function regimeParams() external view override returns (RegimeParams memory) {
        return _regimeParams;
    }

    function riskParams() external view override returns (RiskParams memory) {
        return _riskParams;
    }

    function feeParams() external view override returns (FeeParams memory) {
        return _feeParams;
    }
}
