// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IDamanCopyBond} from "damanfi-protocol/IDamanCopyBond.sol";
import {IUniverseWhitelist} from "damanfi-protocol/IUniverseWhitelist.sol";
import {BondEconomics} from "damanfi-protocol/BondEconomics.sol";
import {IAttributable} from "reverbprotocol/IAttributable.sol";
import {IBountyAccrual} from "reverbprotocol/IBountyAccrual.sol";
import {IReputationRegistry} from "reverbprotocol/IReputationRegistry.sol";
import {CCTPReceiverMixin} from "reverbprotocol/CCTPReceiverMixin.sol";
import {IERC20} from "./IERC20.sol";

/// @title DamanCopyBond. Vanilla reference implementation of `IDamanCopyBond`.
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
/// @dev Substrate lineage and conformance:
///      - `refundProtocol` is the `IRefundProtocol`-conformant dispute
///        primitive at `github.com/reverbprotocol/protocol`.
///      - `bountyAccrual` is an `IBountyAccrual` instance (substrate
///        reference impl wrapped as `DamanBountyAccrual`).
///      - `reputationRegistry` is an `IReputationRegistry` instance
///        (Daman-specific `DamanReputationRegistry` with rotatable
///        recorder).
///      - The contract inherits `CCTPReceiverMixin` from the substrate
///        so leaders can post a bond from any CCTP source domain in
///        one transaction via `postBondFromCCTP` (which calls the
///        inherited `onCCTPReceive`). The decoded hook payload is
///        `(address leader, Tier tier, uint256 claimedAum)` and is
///        handled in `handlePayload`.
///      - The contract declares `is IAttributable` to mark adoption of
///        the bytes32 builder attribution convention on every external
///        flow-producing surface (subscribe, attestDegradation,
///        arbiterRule).
contract DamanCopyBond is IDamanCopyBond, IAttributable, CCTPReceiverMixin {
    IERC20 public immutable fiatTokenContract;
    address public immutable universeWhitelist;
    address public immutable refundProtocolAddr;
    address public immutable arbiterAddr;
    address public immutable oracle;
    address public immutable treasury;
    uint64 public immutable bondLockupSeconds;
    uint64 public immutable disputeWindowSeconds;
    IBountyAccrual public immutable bountyAccrual;
    IReputationRegistry public immutable reputationRegistry;

    /// @notice Bounty share of an upheld slash, in basis points. 10%.
    uint16 public constant WATCHDOG_BOUNTY_BPS = 1000;

    mapping(address => Leader) private _leaders;
    mapping(address => mapping(address => Subscription)) private _subscriptions;
    mapping(uint256 => Claim) private _claims;
    uint256 private _nextClaimId;
    uint256 private _nextTradeId;

    constructor(
        address _fiatToken,
        address _universe,
        address _refundProtocol,
        address _arbiter,
        address _oracle,
        address _treasury,
        address _bountyAccrual,
        address _reputationRegistry,
        address _messageTransmitter,
        uint64 _bondLockupSeconds,
        uint64 _disputeWindowSeconds
    ) CCTPReceiverMixin(_messageTransmitter, _fiatToken) {
        if (_fiatToken == address(0) || _universe == address(0) || _refundProtocol == address(0)
            || _arbiter == address(0) || _oracle == address(0) || _treasury == address(0)
            || _bountyAccrual == address(0) || _reputationRegistry == address(0)) {
            revert NullAddress();
        }
        fiatTokenContract = IERC20(_fiatToken);
        universeWhitelist = _universe;
        refundProtocolAddr = _refundProtocol;
        arbiterAddr = _arbiter;
        oracle = _oracle;
        treasury = _treasury;
        bountyAccrual = IBountyAccrual(_bountyAccrual);
        reputationRegistry = IReputationRegistry(_reputationRegistry);
        bondLockupSeconds = _bondLockupSeconds;
        disputeWindowSeconds = _disputeWindowSeconds;
        _nextClaimId = 1;
        _nextTradeId = 1;
    }

    // --- CCTP cross-domain bond posting ----------------------------------

    /// @notice Daman-named alias for the substrate's `onCCTPReceive`.
    ///         Submit an attested CCTP v2 message that mints USDC to
    ///         this contract and carries a hook payload of
    ///         `(address leader, Tier tier, uint256 claimedAum)`. The
    ///         minted USDC activates the leader's bond.
    function postBondFromCCTP(bytes calldata message, bytes calldata attestation) external {
        this.onCCTPReceive(message, attestation);
    }

    /// @notice Substrate hook called by `CCTPReceiverMixin.onCCTPReceive`
    ///         after USDC has been minted to this contract.
    /// @param  payload      ABI-encoded `(address, Tier, uint256)`.
    /// @param  mintedAmount USDC newly minted to this contract by CCTP.
    function handlePayload(bytes calldata payload, uint256 mintedAmount) internal override {
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

    // --- Leader lifecycle ------------------------------------------------

    function registerLeader(Tier tier, uint256 claimedAum) external {
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

    function postBond(uint256 amount) external {
        Leader storage l = _leaders[msg.sender];
        if (l.registeredAt == 0) revert NotLeader();
        bool ok = fiatTokenContract.transferFrom(msg.sender, address(this), amount);
        require(ok, "transferFrom failed");
        l.bondAmount += amount;
        BondEconomics.Tier eTier = _toEconTier(l.tier);
        uint256 required = BondEconomics.requiredBondFor(eTier, l.claimedAum);
        if (l.bondAmount >= required && !l.active) {
            l.active = true;
        }
        emit LeaderBondPosted(msg.sender, amount, l.bondAmount);
    }

    function withdrawBond(uint256 amount) external {
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
        bool ok = fiatTokenContract.transfer(msg.sender, amount);
        require(ok, "transfer failed");
        emit BondWithdrawn(msg.sender, amount);
    }

    // --- Follower lifecycle ----------------------------------------------

    function subscribe(address leader, uint256 capital, bytes32 builder) external {
        Leader storage l = _leaders[leader];
        if (l.registeredAt == 0 || !l.active) revert NotLeader();
        bool ok = fiatTokenContract.transferFrom(msg.sender, address(this), capital);
        require(ok, "transferFrom failed");
        _subscriptions[msg.sender][leader] = Subscription({
            follower: msg.sender,
            leader: leader,
            capital: capital,
            since: uint64(block.timestamp),
            builder: builder
        });
        emit FollowerSubscribed(msg.sender, leader, capital, builder);
    }

    function unsubscribe(address leader) external {
        Subscription storage s = _subscriptions[msg.sender][leader];
        if (s.follower == address(0)) revert SubscriptionNotFound();
        uint256 cap = s.capital;
        delete _subscriptions[msg.sender][leader];
        if (cap > 0) {
            bool ok = fiatTokenContract.transfer(msg.sender, cap);
            require(ok, "transfer failed");
        }
        emit FollowerUnsubscribed(msg.sender, leader);
    }

    // --- Operator-side oracle entry points -------------------------------

    function recordTrade(address leader, address asset, uint256 amount, bool isLong) external {
        if (msg.sender != oracle) revert NotWatchdog();
        // ADR-001: the oracle records only on-platform trades it executed
        // itself. The eligibility check below binds asset selection to
        // the universe whitelist.
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

    function arbiterRule(
        uint256 claimId,
        uint256 slashAmount,
        bool upheld,
        bytes32 builder,
        bytes32 traceCid
    ) external {
        if (msg.sender != arbiterAddr) revert NotArbiter();
        Claim storage c = _claims[claimId];
        if (c.id == 0) revert ClaimNotFound(claimId);
        if (c.status == ClaimStatus.Upheld || c.status == ClaimStatus.Rejected) revert AlreadyRuled(claimId);

        Leader storage l = _leaders[c.leader];
        uint256 cap = BondEconomics.maxSlashAmount(l.bondAmount);
        if (slashAmount > cap) revert SlashCapExceeded(BondEconomics.SLASH_CAP_BPS);

        // `builder` on the ruling overrides the claim-side tag when
        // non-zero; otherwise inherit from the claim so the
        // attribution chain stays consistent.
        bytes32 effectiveBuilder = builder == bytes32(0) ? c.builder : builder;

        if (upheld) {
            c.status = ClaimStatus.Upheld;
            c.slashAmount = slashAmount;
            if (slashAmount > 0) {
                // 10/90 split: bounty to the watchdog via the substrate
                // accrual, treasury keeps the remaining 90%.
                uint256 bountyAmount = (slashAmount * WATCHDOG_BOUNTY_BPS) / BondEconomics.BPS_DENOMINATOR;
                uint256 treasuryAmount = slashAmount - bountyAmount;
                l.bondAmount -= slashAmount;
                if (bountyAmount > 0) {
                    // Approve the bounty contract to pull the bounty
                    // notional, then accrue on behalf of the watchdog.
                    bool ok = fiatTokenContract.approve(address(bountyAccrual), bountyAmount);
                    require(ok, "approve failed");
                    bountyAccrual.accrueBounty(c.watchdog, bountyAmount);
                }
                if (treasuryAmount > 0) {
                    bool ok = fiatTokenContract.transfer(treasury, treasuryAmount);
                    require(ok, "treasury transfer failed");
                }
                emit BondSlashed(c.leader, slashAmount, claimId);
            }
            BondEconomics.Tier eTier = _toEconTier(l.tier);
            uint256 required = BondEconomics.requiredBondFor(eTier, l.claimedAum);
            if (l.bondAmount < required) {
                l.active = false;
                emit LeaderDeactivated(c.leader, "bond_below_required");
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
