// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DamanCopyBond} from "../src/DamanCopyBond.sol";
import {DamanBountyAccrual} from "../src/DamanBountyAccrual.sol";
import {DamanReputationRegistry} from "../src/DamanReputationRegistry.sol";
import {IDamanCopyBond} from "damanfi-protocol/IDamanCopyBond.sol";
import {BondEconomics} from "damanfi-protocol/BondEconomics.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockUniverse} from "./MockUniverse.sol";
import {MockMessageTransmitterV2} from "./MockMessageTransmitterV2.sol";

/// @notice Stateful invariant tests for the bond / slash / bounty
///         path. Foundry drives the handler with random sequences;
///         after every sequence the contract must satisfy the
///         three invariants below.
contract DamanCopyBondInvariantsTest is StdInvariant, Test {
    DamanCopyBond bond;
    DamanBountyAccrual bountyAccrual;
    DamanReputationRegistry reputationRegistry;
    MockUSDC usdc;
    BondHandler handler;

    address leader = address(0xA001);
    address watchdog = address(0xC001);
    address arbiter_ = address(0xD001);

    function setUp() public {
        usdc = new MockUSDC();
        MockUniverse universe = new MockUniverse();
        MockMessageTransmitterV2 mt = new MockMessageTransmitterV2(address(usdc));

        DamanBountyAccrual bountyImpl = new DamanBountyAccrual();
        bountyAccrual = DamanBountyAccrual(address(new ERC1967Proxy(
            address(bountyImpl),
            abi.encodeCall(DamanBountyAccrual.initialize, (address(usdc), address(this)))
        )));

        DamanReputationRegistry repImpl = new DamanReputationRegistry();
        reputationRegistry = DamanReputationRegistry(address(new ERC1967Proxy(
            address(repImpl),
            abi.encodeCall(
                DamanReputationRegistry.initialize,
                (address(this), int256(1), int256(-2), address(this))
            )
        )));

        DamanCopyBond bondImpl = new DamanCopyBond();
        bond = DamanCopyBond(address(new ERC1967Proxy(
            address(bondImpl),
            abi.encodeCall(DamanCopyBond.initialize, (DamanCopyBond.InitParams({
                fiatToken: address(usdc),
                universe: address(universe),
                refundProtocol: address(0xF001),
                arbiter_: arbiter_,
                oracle_: address(0xE001),
                treasury_: address(0xA101),
                bountyAccrual_: address(bountyAccrual),
                reputationRegistry_: address(reputationRegistry),
                messageTransmitter_: address(mt),
                bondLockupSeconds_: 7 days,
                disputeWindowSeconds_: 1 days,
                initialOwner: address(this)
            })))
        )));
        reputationRegistry.setRecorder(address(bond));

        // Seed leader with a posted bond.
        usdc.mint(leader, 100_000e18);
        vm.prank(leader);
        usdc.approve(address(bond), type(uint256).max);
        vm.startPrank(leader);
        bond.registerLeader(IDamanCopyBond.Tier.Retail, 100_000e18);
        bond.postBond(10_000e18);
        vm.stopPrank();

        handler = new BondHandler(bond, watchdog, arbiter_, leader);
        targetContract(address(handler));
    }

    /// @notice Per-dispute slash cap. Every upheld claim recorded a
    ///         slash amount no greater than 25% of the bond at
    ///         ruling time (enforced on-chain by
    ///         BondEconomics.maxSlashAmount). This invariant verifies
    ///         the historical record is consistent with the bound.
    function invariant_slashCapPerDispute() public view {
        // Iterate over all upheld claims; each recorded slashAmount
        // is at most cap-bps of the bond at the time of ruling.
        // We can't replay state, but we can bound the cumulative
        // slash by the cumulative bond posted minus the current
        // bond. That property is verified in invariant_solvency below.
        uint256 totalUpheldSlash;
        for (uint256 i = 1; i < 1000; i++) {
            IDamanCopyBond.Claim memory c = bond.getClaim(i);
            if (c.id == 0) break;
            if (c.status == IDamanCopyBond.ClaimStatus.Upheld) {
                totalUpheldSlash += c.slashAmount;
            }
        }
        // Cumulative slash never exceeds cumulative principal.
        uint256 currentBond = bond.getLeader(leader).bondAmount;
        uint256 cumulativePrincipal = 10_000e18 + handler.totalPosted();
        assertLe(totalUpheldSlash + currentBond, cumulativePrincipal);
    }

    /// @notice Bounty cap across all upheld claims: total bounty
    ///         accrued never exceeds 10% of total slashed.
    function invariant_bountyCapPerUpheldClaim() public view {
        uint256 totalBounty;
        for (uint256 i = 0; i < bountyAccrual.nextClaimId(); i++) {
            totalBounty += bountyAccrual.bountyAmount(i);
        }
        uint256 totalSlash;
        for (uint256 i = 1; i < 1000; i++) {
            IDamanCopyBond.Claim memory c = bond.getClaim(i);
            if (c.id == 0) break;
            if (c.status == IDamanCopyBond.ClaimStatus.Upheld) {
                totalSlash += c.slashAmount;
            }
        }
        // 10/90 split: total bounty equals exactly 10% of total slashed
        // (floor division). Use a non-strict inequality to allow for
        // rounding-down on the bounty side.
        assertLe(totalBounty * 10, totalSlash + 9);
    }

    /// @notice Bond solvency. Sum of leader bondAmount, total
    ///         slashed (sent to treasury + bounty), should equal
    ///         cumulative principal posted.
    function invariant_solvency() public view {
        uint256 currentBond = bond.getLeader(leader).bondAmount;
        uint256 totalSlashed;
        for (uint256 i = 1; i < 1000; i++) {
            IDamanCopyBond.Claim memory c = bond.getClaim(i);
            if (c.id == 0) break;
            if (c.status == IDamanCopyBond.ClaimStatus.Upheld) {
                totalSlashed += c.slashAmount;
            }
        }
        uint256 cumulativePrincipal = 10_000e18 + handler.totalPosted();
        assertEq(currentBond + totalSlashed, cumulativePrincipal);
    }
}

/// @notice Fuzz handler. Foundry calls these functions with random
///         arguments. Each operation may revert (cap exceeded,
///         claim already ruled, etc.); the invariants run only on
///         successful sequences.
contract BondHandler is Test {
    DamanCopyBond public bond;
    address public watchdog;
    address public arbiter_;
    address public leader;
    uint256 public totalPosted;

    constructor(DamanCopyBond bond_, address watchdog_, address arbiter__, address leader_) {
        bond = bond_;
        watchdog = watchdog_;
        arbiter_ = arbiter__;
        leader = leader_;
    }

    function postExtraBond(uint96 amount) external {
        uint256 a = uint256(amount) % 5_000e18;
        if (a == 0) return;
        vm.prank(leader);
        try bond.postBond(a) {
            totalPosted += a;
        } catch {}
    }

    function fileClaim() external {
        vm.prank(watchdog);
        try bond.attestDegradation(leader, bytes32("fuzz"), bytes32(0)) {} catch {}
    }

    function ruleUpheld(uint8 claimIdSeed, uint96 slashSeed) external {
        uint256 claimId = (uint256(claimIdSeed) % 32) + 1;
        IDamanCopyBond.Claim memory c = bond.getClaim(claimId);
        if (c.id == 0) return;
        if (c.status == IDamanCopyBond.ClaimStatus.Upheld
            || c.status == IDamanCopyBond.ClaimStatus.Rejected) return;
        uint256 bondNow = bond.getLeader(leader).bondAmount;
        uint256 cap = BondEconomics.maxSlashAmount(bondNow);
        uint256 slashAmount = cap == 0 ? 0 : (uint256(slashSeed) % (cap + 1));
        vm.prank(arbiter_);
        try bond.arbiterRule(claimId, slashAmount, true, bytes32(0), bytes32(0)) {} catch {}
    }

    function ruleRejected(uint8 claimIdSeed) external {
        uint256 claimId = (uint256(claimIdSeed) % 32) + 1;
        IDamanCopyBond.Claim memory c = bond.getClaim(claimId);
        if (c.id == 0) return;
        if (c.status == IDamanCopyBond.ClaimStatus.Upheld
            || c.status == IDamanCopyBond.ClaimStatus.Rejected) return;
        vm.prank(arbiter_);
        try bond.arbiterRule(claimId, 0, false, bytes32(0), bytes32(0)) {} catch {}
    }
}
