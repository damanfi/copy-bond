// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
        messageTransmitter = new MockMessageTransmitterV2(address(usdc));

        // Deploy each UUPS implementation, then wrap each in an
        // ERC1967Proxy and call initialize. This mirrors the
        // production deploy script: each contract's owner is set at
        // initialization; in tests the test contract is the owner
        // (no Safe + Timelock for unit tests).

        DamanBountyAccrual bountyImpl = new DamanBountyAccrual();
        bytes memory bountyInit = abi.encodeCall(
            DamanBountyAccrual.initialize,
            (address(usdc), address(this))
        );
        bountyAccrual = DamanBountyAccrual(
            address(new ERC1967Proxy(address(bountyImpl), bountyInit))
        );

        DamanReputationRegistry repImpl = new DamanReputationRegistry();
        bytes memory repInit = abi.encodeCall(
            DamanReputationRegistry.initialize,
            (address(this), int256(1), int256(-2), address(this))
        );
        reputationRegistry = DamanReputationRegistry(
            address(new ERC1967Proxy(address(repImpl), repInit))
        );

        DamanCopyBond bondImpl = new DamanCopyBond();
        DamanCopyBond.InitParams memory p = DamanCopyBond.InitParams({
            fiatToken: address(usdc),
            universe: address(universe),
            refundProtocol: refundProtocol,
            arbiter_: arbiter_,
            oracle_: oracle,
            treasury_: treasury,
            bountyAccrual_: address(bountyAccrual),
            reputationRegistry_: address(reputationRegistry),
            messageTransmitter_: address(messageTransmitter),
            bondLockupSeconds_: BOND_LOCKUP,
            disputeWindowSeconds_: DISPUTE_WINDOW,
            initialOwner: address(this)
        });
        bytes memory bondInit = abi.encodeCall(DamanCopyBond.initialize, (p));
        bond = DamanCopyBond(
            address(new ERC1967Proxy(address(bondImpl), bondInit))
        );

        // Wire copy-bond as the sole reputation recorder post-deploy
        // to break the construction cycle.
        reputationRegistry.setRecorder(address(bond));

        usdc.mint(leader, 100_000e18);
        usdc.mint(follower, 50_000e18);
        vm.prank(leader);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(follower);
        usdc.approve(address(bond), type(uint256).max);
    }

    function test_registerAndPostBond_activatesAtRequired() public {
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

        uint256 expectedBounty = (cap * bond.WATCHDOG_BOUNTY_BPS()) / BondEconomics.BPS_DENOMINATOR;
        uint256 expectedTreasury = cap - expectedBounty;
        assertEq(bond.getLeader(leader).bondAmount, bondPosted - cap);
        assertEq(usdc.balanceOf(treasury), expectedTreasury);
        assertEq(usdc.balanceOf(address(bountyAccrual)), expectedBounty);
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

        vm.prank(follower);
        bond.subscribe(leader, 5_000e18, followerBuilder);
        assertEq(bond.getSubscription(follower, leader).builder, followerBuilder);

        vm.prank(watchdog);
        uint256 claimId = bond.attestDegradation(leader, bytes32("evidence"), watchdogBuilder);
        assertEq(bond.getClaim(claimId).builder, watchdogBuilder);

        uint256 cap = BondEconomics.maxSlashAmount(bond.getLeader(leader).bondAmount);
        vm.prank(arbiter_);
        bond.arbiterRule(claimId, cap, true, bytes32(0), bytes32(0));

        assertEq(bond.getClaim(claimId).builder, watchdogBuilder);
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

        // BountyAccrual's first claimId is 0 (substrate convention).
        uint256 watchdogBalanceBefore = usdc.balanceOf(watchdog);
        vm.prank(watchdog);
        bountyAccrual.claimBounty(0);
        assertEq(usdc.balanceOf(watchdog), watchdogBalanceBefore + expectedBounty);
    }

    function test_postBondFromCCTP_activatesLeader() public {
        uint256 aum = 10_000e18;
        uint256 required = BondEconomics.requiredBondFor(BondEconomics.Tier.Retail, aum);

        bytes memory hookPayload = abi.encode(leader, IDamanCopyBond.Tier.Retail, aum);
        bytes memory message = abi.encodePacked(new bytes(376), hookPayload);

        messageTransmitter.setNextMint(address(bond), required);

        bond.postBondFromCCTP(message, "");

        IDamanCopyBond.Leader memory l = bond.getLeader(leader);
        assertEq(l.bondAmount, required);
        assertEq(uint8(l.tier), uint8(IDamanCopyBond.Tier.Retail));
        assertEq(l.claimedAum, aum);
        assertTrue(l.active);
    }

    function test_pause_blocksHumanFacingWrites() public {
        _activateLeader();
        bond.pause();

        vm.prank(leader);
        vm.expectRevert();
        bond.postBond(100e18);

        vm.prank(follower);
        vm.expectRevert();
        bond.subscribe(leader, 5_000e18, bytes32(0));
    }

    function test_pause_keepsAgentPathsUnblocked() public {
        _activateLeader();
        bond.pause();

        // Watchdog can still file claims; arbiter can still rule.
        vm.prank(watchdog);
        uint256 claimId = bond.attestDegradation(leader, bytes32("evidence"), bytes32(0));

        vm.prank(arbiter_);
        bond.arbiterRule(claimId, 0, false, bytes32(0), bytes32(0));

        assertEq(uint8(bond.getClaim(claimId).status), uint8(IDamanCopyBond.ClaimStatus.Rejected));
    }

    function test_initialize_doubleCallReverts() public {
        DamanCopyBond.InitParams memory p = DamanCopyBond.InitParams({
            fiatToken: address(usdc),
            universe: address(universe),
            refundProtocol: refundProtocol,
            arbiter_: arbiter_,
            oracle_: oracle,
            treasury_: treasury,
            bountyAccrual_: address(bountyAccrual),
            reputationRegistry_: address(reputationRegistry),
            messageTransmitter_: address(messageTransmitter),
            bondLockupSeconds_: BOND_LOCKUP,
            disputeWindowSeconds_: DISPUTE_WINDOW,
            initialOwner: address(this)
        });
        vm.expectRevert();
        bond.initialize(p);
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
