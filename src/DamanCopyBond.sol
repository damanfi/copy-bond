// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IDamanCopyBond} from "damanfi-protocol/IDamanCopyBond.sol";
import {IUniverseWhitelist} from "damanfi-protocol/IUniverseWhitelist.sol";
import {BondEconomics} from "damanfi-protocol/BondEconomics.sol";
import {IERC20} from "./IERC20.sol";

/// @title DamanCopyBond. Vanilla reference implementation of `IDamanCopyBond`.
/// @notice Slash-bond state machine. Leader posts USDC bond proportional
///         to claimed AUM. Followers subscribe with delegated capital.
///         The operator-side oracle records trade and settlement events.
///         A watchdog files a degradation claim. The leader may dispute
///         within the dispute window. An arbiter rules; the contract
///         enforces the 25% per-dispute slash cap; slashed funds route
///         to the configured treasury.
///
/// @dev Substrate lineage: `refundProtocol` is the `IRefundProtocol`
///      conformant dispute primitive deployed at
///      `github.com/reverbprotocol/protocol`. The address is recorded
///      at construction so that downstream consumers can observe the
///      substrate relationship on chain. Follower-side capital flows
///      can optionally route through the refund protocol in richer
///      deployments; the vanilla impl keeps follower capital tracking
///      in this contract for clarity.
contract DamanCopyBond is IDamanCopyBond {
    IERC20 public immutable fiatTokenContract;
    address public immutable universeWhitelist;
    address public immutable refundProtocolAddr;
    address public immutable arbiterAddr;
    address public immutable oracle;
    address public immutable treasury;
    uint64 public immutable bondLockupSeconds;
    uint64 public immutable disputeWindowSeconds;

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
        uint64 _bondLockupSeconds,
        uint64 _disputeWindowSeconds
    ) {
        if (_fiatToken == address(0) || _universe == address(0) || _refundProtocol == address(0)
            || _arbiter == address(0) || _oracle == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        fiatTokenContract = IERC20(_fiatToken);
        universeWhitelist = _universe;
        refundProtocolAddr = _refundProtocol;
        arbiterAddr = _arbiter;
        oracle = _oracle;
        treasury = _treasury;
        bondLockupSeconds = _bondLockupSeconds;
        disputeWindowSeconds = _disputeWindowSeconds;
        _nextClaimId = 1;
        _nextTradeId = 1;
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

    function subscribe(address leader, uint256 capital) external {
        Leader storage l = _leaders[leader];
        if (l.registeredAt == 0 || !l.active) revert NotLeader();
        bool ok = fiatTokenContract.transferFrom(msg.sender, address(this), capital);
        require(ok, "transferFrom failed");
        _subscriptions[msg.sender][leader] = Subscription({
            follower: msg.sender,
            leader: leader,
            capital: capital,
            since: uint64(block.timestamp)
        });
        emit FollowerSubscribed(msg.sender, leader, capital);
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

    function attestDegradation(address leader, bytes32 evidenceHash) external returns (uint256 claimId) {
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
            slashAmount: 0
        });
        emit DegradationFlagged(claimId, leader, msg.sender, evidenceHash);
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

    function arbiterRule(uint256 claimId, uint256 slashAmount, bool upheld) external {
        if (msg.sender != arbiterAddr) revert NotArbiter();
        Claim storage c = _claims[claimId];
        if (c.id == 0) revert ClaimNotFound(claimId);
        if (c.status == ClaimStatus.Upheld || c.status == ClaimStatus.Rejected) revert AlreadyRuled(claimId);

        Leader storage l = _leaders[c.leader];
        uint256 cap = BondEconomics.maxSlashAmount(l.bondAmount);
        if (slashAmount > cap) revert SlashCapExceeded(BondEconomics.SLASH_CAP_BPS);

        if (upheld) {
            c.status = ClaimStatus.Upheld;
            c.slashAmount = slashAmount;
            if (slashAmount > 0) {
                l.bondAmount -= slashAmount;
                bool ok = fiatTokenContract.transfer(treasury, slashAmount);
                require(ok, "treasury transfer failed");
                emit BondSlashed(c.leader, slashAmount, claimId);
            }
            BondEconomics.Tier eTier = _toEconTier(l.tier);
            uint256 required = BondEconomics.requiredBondFor(eTier, l.claimedAum);
            if (l.bondAmount < required) {
                l.active = false;
                emit LeaderDeactivated(c.leader, "bond_below_required");
            }
        } else {
            c.status = ClaimStatus.Rejected;
        }
        emit ArbiterRuled(claimId, slashAmount, upheld);
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
