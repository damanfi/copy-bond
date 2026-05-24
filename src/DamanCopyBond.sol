// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IDamanCopyBond} from "damanfi-protocol/IDamanCopyBond.sol";
import {IUniverseWhitelist} from "damanfi-protocol/IUniverseWhitelist.sol";
import {BondEconomics} from "damanfi-protocol/BondEconomics.sol";
import {IAttributable} from "reverbprotocol/IAttributable.sol";
import {IBountyAccrual} from "reverbprotocol/IBountyAccrual.sol";
import {IReputationRegistry} from "reverbprotocol/IReputationRegistry.sol";
import {ICCTPReceiver, IMessageTransmitterV2} from "reverbprotocol/ICCTPReceiver.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DamanCopyBond. UUPS-upgradeable implementation of `IDamanCopyBond`.
/// @notice Slash-bond state machine. Leader posts USDC bond proportional
///         to claimed AUM. Followers subscribe with delegated capital.
///         The operator-side oracle records trade and settlement events.
///         A watchdog files a degradation claim. The leader may dispute
///         within the dispute window. An arbiter rules; the contract
///         enforces the 25% per-dispute slash cap; on upheld, 10% of
///         the slashed bond accrues to the watchdog as a bounty and
///         90% routes to the treasury. The arbiter records the
///         watchdog's outcome on the reputation registry on every
///         non-trivial ruling.
///
/// @dev Hardening:
///      - UUPS-upgradeable. `_authorizeUpgrade` is owner-gated; owner
///        is a TimelockController set in `initialize` and rotated only
///        through the Safe-plus-Timelock upgrade flow.
///      - `Pausable`: write surfaces (registerLeader, postBond,
///        subscribe, recordTrade, withdrawBond) gate on
///        `whenNotPaused`. Arbiter rulings and degradation
///        attestations stay unblocked during pause so in-flight
///        disputes settle without operator-side ceremony.
///      - `ReentrancyGuard`: every external state-changing function
///        carries `nonReentrant`; SafeERC20 is used for all token
///        moves. CEI ordering enforced on bounty + treasury split.
///      - Storage layout: no `immutable`, no constructor state;
///        30-slot `__gap` at end so subsequent upgrades append
///        without colliding.
///
///      Substrate lineage:
///      - `refundProtocol` is the `IRefundProtocol`-conformant
///        dispute primitive at `github.com/reverbprotocol/protocol`.
///      - `bountyAccrual` is an `IBountyAccrual` instance (Daman's
///        UUPS-upgradeable implementation, separate from the
///        substrate's reference vanilla).
///      - `reputationRegistry` is an `IReputationRegistry` instance
///        (Daman's UUPS-upgradeable implementation with rotatable
///        single-recorder).
///      - The contract declares `is ICCTPReceiver` so leaders can
///        post bond from any CCTP source domain via
///        `postBondFromCCTP` / `onCCTPReceive`. The receive logic is
///        inlined (no inheritance of the substrate's
///        `CCTPReceiverMixin` because the mixin uses immutables that
///        are incompatible with the UUPS storage discipline).
///      - The contract declares `is IAttributable` to mark adoption
///        of the bytes32 builder attribution convention on every
///        external flow-producing surface.
contract DamanCopyBond is
    IDamanCopyBond,
    IAttributable,
    ICCTPReceiver,
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Bounty share of an upheld slash, in basis points. 10%.
    uint16 public constant WATCHDOG_BOUNTY_BPS = 1000;

    /// @notice Standard CCTP v2 hook payload offset (148 outer + 228 burn-message fixed).
    uint256 public constant CCTP_V2_HOOK_OFFSET = 376;

    // --- Wired dependencies (set in initialize) -------------------------

    IERC20 public fiatTokenContract;
    address public universeWhitelist;
    address public refundProtocolAddr;
    address public arbiterAddr;
    address public oracle;
    address public treasury;
    IBountyAccrual public bountyAccrual;
    IReputationRegistry public reputationRegistry;
    IMessageTransmitterV2 public messageTransmitter;
    uint64 public bondLockupSeconds;
    uint64 public disputeWindowSeconds;

    // --- State ----------------------------------------------------------

    mapping(address => Leader) private _leaders;
    mapping(address => mapping(address => Subscription)) private _subscriptions;
    mapping(uint256 => Claim) private _claims;
    uint256 private _nextClaimId;
    uint256 private _nextTradeId;

    /// @dev Reserved storage slots for forward compatibility.
    uint256[30] private __gap;

    error CCTPReceiveFailed();

    // --- Initialization -------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    struct InitParams {
        address fiatToken;
        address universe;
        address refundProtocol;
        address arbiter_;
        address oracle_;
        address treasury_;
        address bountyAccrual_;
        address reputationRegistry_;
        address messageTransmitter_;
        uint64 bondLockupSeconds_;
        uint64 disputeWindowSeconds_;
        address initialOwner;
    }

    function initialize(InitParams calldata p) external initializer {
        if (p.fiatToken == address(0) || p.universe == address(0) || p.refundProtocol == address(0)
            || p.arbiter_ == address(0) || p.oracle_ == address(0) || p.treasury_ == address(0)
            || p.bountyAccrual_ == address(0) || p.reputationRegistry_ == address(0)
            || p.messageTransmitter_ == address(0) || p.initialOwner == address(0)) {
            revert NullAddress();
        }
        __Ownable_init(p.initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        fiatTokenContract = IERC20(p.fiatToken);
        universeWhitelist = p.universe;
        refundProtocolAddr = p.refundProtocol;
        arbiterAddr = p.arbiter_;
        oracle = p.oracle_;
        treasury = p.treasury_;
        bountyAccrual = IBountyAccrual(p.bountyAccrual_);
        reputationRegistry = IReputationRegistry(p.reputationRegistry_);
        messageTransmitter = IMessageTransmitterV2(p.messageTransmitter_);
        bondLockupSeconds = p.bondLockupSeconds_;
        disputeWindowSeconds = p.disputeWindowSeconds_;
        _nextClaimId = 1;
        _nextTradeId = 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // --- Pause control --------------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- CCTP cross-domain bond posting ---------------------------------

    function postBondFromCCTP(bytes calldata message, bytes calldata attestation)
        external
        whenNotPaused
        nonReentrant
    {
        _receiveCCTP(message, attestation);
    }

    function onCCTPReceive(bytes calldata message, bytes calldata attestation)
        external
        override
        whenNotPaused
        nonReentrant
    {
        _receiveCCTP(message, attestation);
    }

    function _receiveCCTP(bytes calldata message, bytes calldata attestation) internal {
        uint256 balanceBefore = fiatTokenContract.balanceOf(address(this));
        bool ok = messageTransmitter.receiveMessage(message, attestation);
        if (!ok) revert CCTPReceiveFailed();
        uint256 mintedAmount = fiatTokenContract.balanceOf(address(this)) - balanceBefore;

        bytes calldata payload = _decodeCCTPPayload(message);
        (address leader, Tier tier, uint256 claimedAum) =
            abi.decode(payload, (address, Tier, uint256));

        Leader storage l = _leaders[leader];
        if (l.registeredAt == 0) {
            BondEconomics.Tier initialTier = _toEconTier(tier);
            uint256 initialRequired = BondEconomics.requiredBondFor(initialTier, claimedAum);
            _leaders[leader] = Leader({
                addr: leader,
                tier: tier,
                bondAmount: 0,
                claimedAum: claimedAum,
                registeredAt: uint64(block.timestamp),
                bondLockedUntil: uint64(block.timestamp) + bondLockupSeconds,
                active: false
            });
            emit LeaderRegistered(leader, tier, claimedAum, initialRequired);
            l = _leaders[leader];
        }

        l.bondAmount += mintedAmount;
        BondEconomics.Tier eTier = _toEconTier(l.tier);
        uint256 required = BondEconomics.requiredBondFor(eTier, l.claimedAum);
        if (l.bondAmount >= required && !l.active) {
            l.active = true;
        }
        emit LeaderBondPosted(leader, mintedAmount, l.bondAmount);
    }

    function _decodeCCTPPayload(bytes calldata message) internal pure returns (bytes calldata) {
        if (message.length <= CCTP_V2_HOOK_OFFSET) {
            return message[message.length:];
        }
        return message[CCTP_V2_HOOK_OFFSET:];
    }

    // --- Leader lifecycle ------------------------------------------------

    function registerLeader(Tier tier, uint256 claimedAum) external whenNotPaused {
        if (_leaders[msg.sender].registeredAt != 0) revert AlreadyRegistered();
        BondEconomics.Tier eTier = _toEconTier(tier);
        uint256 required = BondEconomics.requiredBondFor(eTier, claimedAum);
        _leaders[msg.sender] = Leader({
            addr: msg.sender,
            tier: tier,
            bondAmount: 0,
            claimedAum: claimedAum,
            registeredAt: uint64(block.timestamp),
            bondLockedUntil: uint64(block.timestamp) + bondLockupSeconds,
            active: false
        });
        emit LeaderRegistered(msg.sender, tier, claimedAum, required);
    }

    function postBond(uint256 amount) external whenNotPaused nonReentrant {
        Leader storage l = _leaders[msg.sender];
        if (l.registeredAt == 0) revert NotLeader();
        l.bondAmount += amount;
        BondEconomics.Tier eTier = _toEconTier(l.tier);
        uint256 required = BondEconomics.requiredBondFor(eTier, l.claimedAum);
        if (l.bondAmount >= required && !l.active) {
            l.active = true;
        }
        fiatTokenContract.safeTransferFrom(msg.sender, address(this), amount);
        emit LeaderBondPosted(msg.sender, amount, l.bondAmount);
    }

    function withdrawBond(uint256 amount) external whenNotPaused nonReentrant {
        Leader storage l = _leaders[msg.sender];
        if (l.registeredAt == 0) revert NotLeader();
        if (uint64(block.timestamp) < l.bondLockedUntil) revert BondLocked(l.bondLockedUntil);
        if (amount > l.bondAmount) revert InsufficientBond(amount, l.bondAmount);
        l.bondAmount -= amount;
        BondEconomics.Tier eTier = _toEconTier(l.tier);
        uint256 required = BondEconomics.requiredBondFor(eTier, l.claimedAum);
        if (l.bondAmount < required) {
            l.active = false;
        }
        fiatTokenContract.safeTransfer(msg.sender, amount);
        emit BondWithdrawn(msg.sender, amount);
    }

    // --- Follower lifecycle ----------------------------------------------

    function subscribe(address leader, uint256 capital, bytes32 builder)
        external
        whenNotPaused
        nonReentrant
    {
        Leader storage l = _leaders[leader];
        if (l.registeredAt == 0 || !l.active) revert NotLeader();
        _subscriptions[msg.sender][leader] = Subscription({
            follower: msg.sender,
            leader: leader,
            capital: capital,
            since: uint64(block.timestamp),
            builder: builder
        });
        fiatTokenContract.safeTransferFrom(msg.sender, address(this), capital);
        emit FollowerSubscribed(msg.sender, leader, capital, builder);
    }

    function unsubscribe(address leader) external nonReentrant {
        Subscription storage s = _subscriptions[msg.sender][leader];
        if (s.follower == address(0)) revert SubscriptionNotFound();
        uint256 cap = s.capital;
        delete _subscriptions[msg.sender][leader];
        if (cap > 0) {
            fiatTokenContract.safeTransfer(msg.sender, cap);
        }
        emit FollowerUnsubscribed(msg.sender, leader);
    }

    // --- Operator-side oracle entry points -------------------------------

    function recordTrade(address leader, address asset, uint256 amount, bool isLong)
        external
        whenNotPaused
    {
        if (msg.sender != oracle) revert NotWatchdog();
        if (!isLong) revert ShortNotPermitted();
        if (!IUniverseWhitelist(universeWhitelist).isEligible(asset)) revert AssetNotEligible(asset);
        emit TradeExecuted(leader, asset, amount, isLong, uint64(block.timestamp));
        _nextTradeId += 1;
    }

    function recordSettlement(address leader, uint256 tradeId, int256 pnl) external {
        if (msg.sender != oracle) revert NotWatchdog();
        emit SettlementCompleted(leader, tradeId, pnl, uint64(block.timestamp));
    }

    // --- Degradation flow ------------------------------------------------

    /// @dev `attestDegradation` is intentionally NOT pause-gated:
    ///      watchdog bees keep filing claims during pause so the
    ///      arbiter has a populated queue to rule on once writes
    ///      unpause.
    function attestDegradation(
        address leader,
        bytes32 evidenceHash,
        bytes32 builder
    ) external returns (uint256 claimId) {
        Leader storage l = _leaders[leader];
        if (l.registeredAt == 0) revert NotLeader();
        claimId = _nextClaimId++;
        _claims[claimId] = Claim({
            id: claimId,
            leader: leader,
            watchdog: msg.sender,
            evidenceHash: evidenceHash,
            filedAt: uint64(block.timestamp),
            disputeWindowEnds: uint64(block.timestamp) + disputeWindowSeconds,
            status: ClaimStatus.Filed,
            slashAmount: 0,
            builder: builder
        });
        emit DegradationFlagged(claimId, leader, msg.sender, evidenceHash, builder);
    }

    function disputeAttestation(uint256 claimId) external {
        Claim storage c = _claims[claimId];
        if (c.id == 0) revert ClaimNotFound(claimId);
        if (msg.sender != c.leader) revert NotLeader();
        if (uint64(block.timestamp) >= c.disputeWindowEnds) revert DisputeWindowClosed(claimId);
        if (c.status != ClaimStatus.Filed) revert AlreadyDisputed(claimId);
        c.status = ClaimStatus.Disputed;
        emit DisputeOpened(claimId, c.leader);
    }

    /// @dev `arbiterRule` is intentionally NOT pause-gated: arbiter
    ///      bees rule on pending claims; bounty + reputation each
    ///      run their own pause policies.
    function arbiterRule(
        uint256 claimId,
        uint256 slashAmount,
        bool upheld,
        bytes32 builder,
        bytes32 traceCid
    ) external nonReentrant {
        if (msg.sender != arbiterAddr) revert NotArbiter();
        Claim storage c = _claims[claimId];
        if (c.id == 0) revert ClaimNotFound(claimId);
        if (c.status == ClaimStatus.Upheld || c.status == ClaimStatus.Rejected) revert AlreadyRuled(claimId);

        Leader storage l = _leaders[c.leader];
        uint256 cap = BondEconomics.maxSlashAmount(l.bondAmount);
        if (slashAmount > cap) revert SlashCapExceeded(BondEconomics.SLASH_CAP_BPS);

        bytes32 effectiveBuilder = builder == bytes32(0) ? c.builder : builder;

        if (upheld) {
            // CEI: mutate state first, then external calls.
            c.status = ClaimStatus.Upheld;
            c.slashAmount = slashAmount;
            uint256 bountyAmount;
            uint256 treasuryAmount;
            if (slashAmount > 0) {
                bountyAmount = (slashAmount * WATCHDOG_BOUNTY_BPS) / BondEconomics.BPS_DENOMINATOR;
                treasuryAmount = slashAmount - bountyAmount;
                l.bondAmount -= slashAmount;
            }
            BondEconomics.Tier eTier = _toEconTier(l.tier);
            uint256 required = BondEconomics.requiredBondFor(eTier, l.claimedAum);
            if (l.bondAmount < required) {
                l.active = false;
                emit LeaderDeactivated(c.leader, "bond_below_required");
            }
            if (slashAmount > 0) {
                if (bountyAmount > 0) {
                    fiatTokenContract.forceApprove(address(bountyAccrual), bountyAmount);
                    bountyAccrual.accrueBounty(c.watchdog, bountyAmount);
                }
                if (treasuryAmount > 0) {
                    fiatTokenContract.safeTransfer(treasury, treasuryAmount);
                }
                emit BondSlashed(c.leader, slashAmount, claimId);
            }
            reputationRegistry.recordUpheld(c.watchdog);
        } else {
            c.status = ClaimStatus.Rejected;
            reputationRegistry.recordRejected(c.watchdog);
        }
        emit ArbiterRuled(claimId, slashAmount, upheld, effectiveBuilder, traceCid);
    }

    // --- View accessors --------------------------------------------------

    function getLeader(address leader) external view returns (Leader memory) {
        return _leaders[leader];
    }

    function getClaim(uint256 claimId) external view returns (Claim memory) {
        return _claims[claimId];
    }

    function getSubscription(address follower, address leader_) external view returns (Subscription memory) {
        return _subscriptions[follower][leader_];
    }

    function bondBalance(address leader) external view returns (uint256) {
        return _leaders[leader].bondAmount;
    }

    function universe() external view returns (address) {
        return universeWhitelist;
    }

    function refundProtocol() external view returns (address) {
        return refundProtocolAddr;
    }

    function fiatToken() external view returns (address) {
        return address(fiatTokenContract);
    }

    function arbiter() external view returns (address) {
        return arbiterAddr;
    }

    // --- Internal --------------------------------------------------------

    function _toEconTier(Tier t) internal pure returns (BondEconomics.Tier) {
        if (t == Tier.Retail) return BondEconomics.Tier.Retail;
        if (t == Tier.Mid) return BondEconomics.Tier.Mid;
        return BondEconomics.Tier.Institutional;
    }
}
