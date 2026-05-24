// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DamanCopyBond} from "../src/DamanCopyBond.sol";
import {DamanBountyAccrual} from "../src/DamanBountyAccrual.sol";
import {DamanReputationRegistry} from "../src/DamanReputationRegistry.sol";
import {IDamanCopyBond} from "damanfi-protocol/IDamanCopyBond.sol";
import {IUniverseWhitelist} from "damanfi-protocol/IUniverseWhitelist.sol";
import {BondEconomics} from "damanfi-protocol/BondEconomics.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockUniverse} from "./MockUniverse.sol";
import {MockMessageTransmitterV2} from "./MockMessageTransmitterV2.sol";

contract DamanCopyBondTest is Test {
    DamanCopyBond bond;
    DamanBountyAccrual bountyAccrual;
    DamanReputationRegistry reputationRegistry;
    MockUSDC usdc;
    MockUniverse universe;
    MockMessageTransmitterV2 messageTransmitter;

    address leader = address(0xA001);
    address follower = address(0xB001);
    address watchdog = address(0xC001);
    address arbiter_ = address(0xD001);
    address oracle = address(0xE001);
    address refundProtocol = address(0xF001);
    address treasury = address(0xA101);
    address eligibleAsset = address(0xA201);
    address ineligibleAsset = address(0xA202);

    uint64 constant BOND_LOCKUP = 7 days;
    uint64 constant DISPUTE_WINDOW = 1 days;

    function setUp() public {
        usdc = new MockUSDC();
        universe = new MockUniverse();
        universe.setEligible(eligibleAsset, true);

        bountyAccrual = new DamanBountyAccrual(address(usdc));
        reputationRegistry = new DamanReputationRegistry(address(this), 1, -2);
        messageTransmitter = new MockMessageTransmitterV2(address(usdc));

        bond = new DamanCopyBond(
            address(usdc), address(universe), refundProtocol,
            arbiter_, oracle, treasury,
            address(bountyAccrual), address(reputationRegistry),
            address(messageTransmitter),
            BOND_LOCKUP, DISPUTE_WINDOW
        );

        // The copy-bond is the sole recorder against the reputation
        // registry; wire it up post-deploy to break the construction
        // cycle (registry needs copy-bond address; copy-bond needs
        // registry address).
        reputationRegistry.setRecorder(address(bond));

        usdc.mint(leader, 100_000e18);
        usdc.mint(follower, 50_000e18);
        vm.prank(leader);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(follower);
        usdc.approve(address(bond), type(uint256).max);
    }

    function test_registerAndPostBond_activatesAtRequired() public {
        // Retail tier, $10k claimed AUM → 10% = $1k required.
        uint256 aum = 10_000e18;
        uint256 required = BondEconomics.requiredBondFor(BondEconomics.Tier.Retail, aum);
        assertEq(required, 1_000e18);

        vm.prank(leader);
        bond.registerLeader(IDamanCopyBond.Tier.Retail, aum);
        assertFalse(bond.getLeader(leader).active);

        vm.prank(leader);
        bond.postBond(required);
        IDamanCopyBond.Leader memory l = bond.getLeader(leader);
        assertEq(l.bondAmount, required);
        assertTrue(l.active);
    }

    function test_registerLeader_revertsOnSecondCall() public {
        vm.startPrank(leader);
        bond.registerLeader(IDamanCopyBond.Tier.Retail, 10_000e18);
        vm.expectRevert(IDamanCopyBond.AlreadyRegistered.selector);
        bond.registerLeader(IDamanCopyBond.Tier.Mid, 5_000_000e18);
        vm.stopPrank();
    }

    function test_postBond_revertsForUnregistered() public {
        vm.prank(leader);
        vm.expectRevert(IDamanCopyBond.NotLeader.selector);
        bond.postBond(1_000e18);
    }

    function test_subscribe_transfersCapital() public {
        _activateLeader();
        vm.prank(follower);
        bond.subscribe(leader, 5_000e18, bytes32(0));
        IDamanCopyBond.Subscription memory s = bond.getSubscription(follower, leader);
        assertEq(s.capital, 5_000e18);
        assertEq(s.leader, leader);
    }

    function test_subscribe_revertsOnInactiveLeader() public {
        vm.prank(follower);
        vm.expectRevert(IDamanCopyBond.NotLeader.selector);
        bond.subscribe(leader, 5_000e18, bytes32(0));
    }

    function test_recordTrade_oracleOnly() public {
        _activateLeader();
        vm.prank(address(0xBEEF));
        vm.expectRevert(IDamanCopyBond.NotWatchdog.selector);
        bond.recordTrade(leader, eligibleAsset, 100e18, true);

        vm.prank(oracle);
        bond.recordTrade(leader, eligibleAsset, 100e18, true);
    }

    function test_recordTrade_revertsOnShort() public {
        _activateLeader();
        vm.prank(oracle);
        vm.expectRevert(IDamanCopyBond.ShortNotPermitted.selector);
        bond.recordTrade(leader, eligibleAsset, 100e18, false);
    }

    function test_recordTrade_revertsOnIneligibleAsset() public {
        _activateLeader();
        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(IDamanCopyBond.AssetNotEligible.selector, ineligibleAsset));
        bond.recordTrade(leader, ineligibleAsset, 100e18, true);
    }

    function test_attestDegradation_filesClaim() public {
        _activateLeader();
        vm.prank(watchdog);
        uint256 claimId = bond.attestDegradation(leader, bytes32("evidence"), bytes32(0));
        IDamanCopyBond.Claim memory c = bond.getClaim(claimId);
        assertEq(uint8(c.status), uint8(IDamanCopyBond.ClaimStatus.Filed));
        assertEq(c.watchdog, watchdog);
    }

    function test_disputeAttestation_movesToDisputed() public {
        _activateLeader();
        vm.prank(watchdog);
        uint256 claimId = bond.attestDegradation(leader, bytes32("evidence"), bytes32(0));

        vm.prank(leader);
        bond.disputeAttestation(claimId);
        assertEq(uint8(bond.getClaim(claimId).status), uint8(IDamanCopyBond.ClaimStatus.Disputed));
    }

    function test_disputeAttestation_revertsAfterWindow() public {
        _activateLeader();
        vm.prank(watchdog);
        uint256 claimId = bond.attestDegradation(leader, bytes32("evidence"), bytes32(0));
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.prank(leader);
        vm.expectRevert(abi.encodeWithSelector(IDamanCopyBond.DisputeWindowClosed.selector, claimId));
        bond.disputeAttestation(claimId);
    }

    function test_arbiterRule_slashesUpToCap() public {
        _activateLeader();
        uint256 bondPosted = bond.getLeader(leader).bondAmount;
        uint256 cap = BondEconomics.maxSlashAmount(bondPosted);

        vm.prank(watchdog);
        uint256 claimId = bond.attestDegradation(leader, bytes32("evidence"), bytes32(0));

        vm.prank(arbiter_);
        bond.arbiterRule(claimId, cap, true, bytes32(0), bytes32(0));

        // 10/90 split: bountyAccrual receives 10%, treasury receives 90%.
        uint256 expectedBounty = (cap * bond.WATCHDOG_BOUNTY_BPS()) / BondEconomics.BPS_DENOMINATOR;
        uint256 expectedTreasury = cap - expectedBounty;
        assertEq(bond.getLeader(leader).bondAmount, bondPosted - cap);
        assertEq(usdc.balanceOf(treasury), expectedTreasury);
        assertEq(usdc.balanceOf(address(bountyAccrual)), expectedBounty);
        // Reputation registry recorded the upheld outcome.
        assertEq(reputationRegistry.reputationScore(watchdog), 1);
        assertEq(reputationRegistry.cumulativeUpheld(watchdog), 1);
    }

    function test_arbiterRule_revertsOnCapBreach() public {
        _activateLeader();
        uint256 bondPosted = bond.getLeader(leader).bondAmount;
        uint256 cap = BondEconomics.maxSlashAmount(bondPosted);

        vm.prank(watchdog);
        uint256 claimId = bond.attestDegradation(leader, bytes32("evidence"), bytes32(0));

        vm.prank(arbiter_);
        vm.expectRevert(abi.encodeWithSelector(IDamanCopyBond.SlashCapExceeded.selector, BondEconomics.SLASH_CAP_BPS));
        bond.arbiterRule(claimId, cap + 1, true, bytes32(0), bytes32(0));
    }

    function test_arbiterRule_rejectedClaimDoesNotSlash() public {
        _activateLeader();
        uint256 bondPosted = bond.getLeader(leader).bondAmount;

        vm.prank(watchdog);
        uint256 claimId = bond.attestDegradation(leader, bytes32("evidence"), bytes32(0));

        vm.prank(arbiter_);
        bond.arbiterRule(claimId, 0, false, bytes32(0), bytes32(0));

        assertEq(bond.getLeader(leader).bondAmount, bondPosted);
        assertEq(uint8(bond.getClaim(claimId).status), uint8(IDamanCopyBond.ClaimStatus.Rejected));
        // Reputation registry recorded the rejection.
        assertEq(reputationRegistry.reputationScore(watchdog), -2);
        assertEq(reputationRegistry.cumulativeRejected(watchdog), 1);
    }

    function test_withdrawBond_blockedUntilLockup() public {
        _activateLeader();
        uint64 unlocksAt = bond.getLeader(leader).bondLockedUntil;
        vm.prank(leader);
        vm.expectRevert(abi.encodeWithSelector(IDamanCopyBond.BondLocked.selector, unlocksAt));
        bond.withdrawBond(100e18);
    }

    function test_withdrawBond_succeedsAfterLockup() public {
        _activateLeader();
        uint256 posted = bond.getLeader(leader).bondAmount;
        vm.warp(block.timestamp + BOND_LOCKUP + 1);

        vm.prank(leader);
        bond.withdrawBond(posted);
        assertEq(bond.getLeader(leader).bondAmount, 0);
        assertFalse(bond.getLeader(leader).active);
    }

    function test_views_exposeWiring() public view {
        assertEq(bond.universe(), address(universe));
        assertEq(bond.refundProtocol(), refundProtocol);
        assertEq(bond.fiatToken(), address(usdc));
        assertEq(bond.arbiter(), arbiter_);
    }

    function test_builderAttribution_travelsEndToEnd() public {
        _activateLeader();
        bytes32 followerBuilder = bytes32("follower-ui-tag");
        bytes32 watchdogBuilder = bytes32("watchdog-policy-tag");

        // subscribe writes builder onto the Subscription record.
        vm.prank(follower);
        bond.subscribe(leader, 5_000e18, followerBuilder);
        assertEq(bond.getSubscription(follower, leader).builder, followerBuilder);

        // attestDegradation writes builder onto the Claim record.
        vm.prank(watchdog);
        uint256 claimId = bond.attestDegradation(leader, bytes32("evidence"), watchdogBuilder);
        assertEq(bond.getClaim(claimId).builder, watchdogBuilder);

        // arbiterRule with bytes32(0) inherits the claim's builder.
        uint256 cap = BondEconomics.maxSlashAmount(bond.getLeader(leader).bondAmount);
        vm.prank(arbiter_);
        bond.arbiterRule(claimId, cap, true, bytes32(0), bytes32(0));

        // The claim's stored builder is unchanged after the ruling
        // (the inheritance happens on the emitted event, not the
        // stored record).
        assertEq(bond.getClaim(claimId).builder, watchdogBuilder);
    }

    function test_constructor_revertsOnZeroAddress() public {
        // Pass valid _fiatToken + _messageTransmitter so the substrate
        // mixin's own check passes; then pass address(0) for a
        // Daman-side param so NullAddress fires inside the Daman body.
        vm.expectRevert(IDamanCopyBond.NullAddress.selector);
        new DamanCopyBond(
            address(usdc), address(universe), refundProtocol, arbiter_, oracle, treasury,
            address(0), address(reputationRegistry),
            address(messageTransmitter),
            BOND_LOCKUP, DISPUTE_WINDOW
        );
    }

    function test_postBondFromCCTP_activatesLeader() public {
        uint256 aum = 10_000e18;
        uint256 required = BondEconomics.requiredBondFor(BondEconomics.Tier.Retail, aum);

        // Construct a CCTP message: 376 bytes of CCTP-shaped prefix,
        // then ABI-encoded (address leader, Tier tier, uint256 aum)
        // as the hook payload that CCTPReceiverMixin slices off.
        bytes memory hookPayload = abi.encode(leader, IDamanCopyBond.Tier.Retail, aum);
        bytes memory message = abi.encodePacked(new bytes(376), hookPayload);

        // Prime the mock to mint `required` USDC into the bond on
        // receive. Real CCTP burns on the source domain and the
        // attestation services credit the destination; the mock skips
        // both and mints directly.
        messageTransmitter.setNextMint(address(bond), required);

        bond.postBondFromCCTP(message, "");

        IDamanCopyBond.Leader memory l = bond.getLeader(leader);
        assertEq(l.bondAmount, required);
        assertEq(uint8(l.tier), uint8(IDamanCopyBond.Tier.Retail));
        assertEq(l.claimedAum, aum);
        assertTrue(l.active);
    }

    function test_bountyAccrual_routes10PercentToWatchdog() public {
        _activateLeader();
        uint256 bondPosted = bond.getLeader(leader).bondAmount;
        uint256 cap = BondEconomics.maxSlashAmount(bondPosted);

        vm.prank(watchdog);
        uint256 claimId = bond.attestDegradation(leader, bytes32("evidence"), bytes32(0));

        vm.prank(arbiter_);
        bond.arbiterRule(claimId, cap, true, bytes32(0), bytes32("ipfs-cid-hex"));

        uint256 expectedBounty = (cap * bond.WATCHDOG_BOUNTY_BPS()) / BondEconomics.BPS_DENOMINATOR;

        // Watchdog can claim the accrued bounty from BountyAccrual.
        // Substrate's BountyAccrualVanilla numbers claims from 0.
        uint256 watchdogBalanceBefore = usdc.balanceOf(watchdog);
        vm.prank(watchdog);
        bountyAccrual.claimBounty(0);
        assertEq(usdc.balanceOf(watchdog), watchdogBalanceBefore + expectedBounty);
    }

    // --- helpers ---------------------------------------------------------

    function _activateLeader() internal {
        uint256 aum = 10_000e18;
        vm.startPrank(leader);
        bond.registerLeader(IDamanCopyBond.Tier.Retail, aum);
        bond.postBond(BondEconomics.requiredBondFor(BondEconomics.Tier.Retail, aum));
        vm.stopPrank();
    }
}
