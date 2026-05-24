// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DamanBenevolence} from "../src/DamanBenevolence.sol";
import {DamanReputationRegistry} from "../src/DamanReputationRegistry.sol";
import {IDamanCredit} from "damanfi-protocol/IDamanCredit.sol";
import {IDamanReputationRegistry} from "damanfi-protocol/IDamanReputationRegistry.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract DamanBenevolenceTest is Test {
    DamanBenevolence internal credit;
    DamanReputationRegistry internal registry;
    MockUSDC internal usdc;

    address internal owner = address(0xA110);
    address internal pauser = address(0xB110);
    address internal admin = address(0xCAFE);
    address internal recorder = address(0xDEAD); // not used in these tests
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xC0FFEE);
    address internal relayer = address(0xBEEF);

    bytes32 internal constant ROLE_WATCHDOG = keccak256("watchdog");

    function setUp() public {
        usdc = new MockUSDC();

        // Deploy registry behind a UUPS proxy.
        DamanReputationRegistry registryImpl = new DamanReputationRegistry();
        bytes memory registryInit = abi.encodeCall(
            DamanReputationRegistry.initialize, (admin, int256(1), int256(-1), owner)
        );
        registry = DamanReputationRegistry(
            address(new ERC1967Proxy(address(registryImpl), registryInit))
        );

        // Deploy credit behind a UUPS proxy.
        DamanBenevolence creditImpl = new DamanBenevolence();
        bytes memory creditInit = abi.encodeCall(
            DamanBenevolence.initialize, (address(usdc), address(registry), owner, pauser)
        );
        credit =
            DamanBenevolence(address(new ERC1967Proxy(address(creditImpl), creditInit)));

        // Fund treasury.
        usdc.mint(address(credit), 100e6);
    }

    // ---------------------------------------------------------------
    // Direct loan path
    // ---------------------------------------------------------------

    function test_freshEntrant_borrowsToCap_repaysFully() public {
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);

        assertTrue(credit.isEligible(alice));
        assertEq(credit.lifetimeBorrowCount(alice), 0);

        vm.prank(alice);
        credit.requestLoan(5e6);

        assertEq(credit.debtOf(alice), 5e6);
        assertEq(credit.lifetimeBorrowCount(alice), 1);
        assertEq(usdc.balanceOf(alice), 5e6);
        assertEq(usdc.balanceOf(address(credit)), 95e6);

        // Repay.
        vm.prank(alice);
        usdc.approve(address(credit), 5e6);
        vm.prank(alice);
        credit.repay(5e6);

        assertEq(credit.debtOf(alice), 0);
        assertEq(usdc.balanceOf(address(credit)), 100e6);
    }

    function test_activeButBust_borrows() public {
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);
        vm.prank(alice);
        credit.requestLoan(5e6);
        vm.prank(alice);
        usdc.approve(address(credit), 5e6);
        vm.prank(alice);
        credit.repay(5e6);
        // alice now has lifetimeBorrowCount=1, debt=0, balance=0.
        // lastActivity == register timestamp; within 24h, balance < 1e6 → eligible.
        assertTrue(credit.isEligible(alice));

        vm.prank(alice);
        credit.requestLoan(3e6);
        assertEq(credit.debtOf(alice), 3e6);
        assertEq(credit.lifetimeBorrowCount(alice), 2);
    }

    function test_revert_notRegistered() public {
        vm.expectRevert(IDamanCredit.NotRegistered.selector);
        vm.prank(alice);
        credit.requestLoan(1e6);
    }

    function test_revert_notFreshAndStale() public {
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);
        vm.prank(alice);
        credit.requestLoan(2e6);
        // Repay so balance > threshold? No: balance after borrow is 2e6 > 1e6 threshold.
        // Even though within window, balance > bust threshold → ineligible.
        vm.expectRevert(IDamanCredit.NotEligible.selector);
        vm.prank(alice);
        credit.requestLoan(1e6);
    }

    function test_revert_staleActivity() public {
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);
        vm.prank(alice);
        credit.requestLoan(5e6);
        vm.prank(alice);
        usdc.approve(address(credit), 5e6);
        vm.prank(alice);
        credit.repay(5e6);
        // Advance time beyond the window.
        vm.warp(block.timestamp + 25 hours);
        assertFalse(credit.isEligible(alice));
        vm.expectRevert(IDamanCredit.NotEligible.selector);
        vm.prank(alice);
        credit.requestLoan(1e6);
    }

    function test_revert_exceedsBorrowerCap() public {
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);
        vm.expectRevert(IDamanCredit.ExceedsBorrowerCap.selector);
        vm.prank(alice);
        credit.requestLoan(6e6);
    }

    function test_revert_exceedsTreasury() public {
        // Drain treasury to 1 USDC by lending to 19 distinct addrs.
        for (uint256 i = 1; i <= 19; i++) {
            address agent = address(uint160(0x10000 + i));
            vm.prank(agent);
            registry.register(ROLE_WATCHDOG);
            vm.prank(agent);
            credit.requestLoan(5e6);
        }
        assertEq(usdc.balanceOf(address(credit)), 5e6);

        // Twentieth agent wants 6 USDC but only 5 available.
        address last = address(uint160(0x10000 + 20));
        vm.prank(last);
        registry.register(ROLE_WATCHDOG);
        vm.expectRevert(IDamanCredit.ExceedsBorrowerCap.selector);
        vm.prank(last);
        credit.requestLoan(6e6);

        // 21st agent: cap-trip would happen first since 6 > 5e6 cap. Try 5+1 split.
        // Treasury available is 5e6 but cap is also 5e6. Push by borrowing 4 then 2.
        // Will exceed treasury on second.
        // simpler: bring treasury to 3 by one more borrow
        vm.prank(last);
        credit.requestLoan(2e6);
        assertEq(usdc.balanceOf(address(credit)), 3e6);
        // now request 4 (within cap, exceeds treasury)
        address last2 = address(uint160(0x10000 + 21));
        vm.prank(last2);
        registry.register(ROLE_WATCHDOG);
        vm.expectRevert(IDamanCredit.ExceedsTreasuryAvailable.selector);
        vm.prank(last2);
        credit.requestLoan(4e6);
    }

    function test_revert_repayWithNoDebt() public {
        vm.expectRevert(IDamanCredit.NoActiveDebt.selector);
        vm.prank(alice);
        credit.repay(1);
    }

    function test_revert_repayExceedsDebt() public {
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);
        vm.prank(alice);
        credit.requestLoan(3e6);
        vm.expectRevert(IDamanCredit.AmountExceedsDebt.selector);
        vm.prank(alice);
        credit.repay(4e6);
    }

    function test_multipleBorrowers_concurrent() public {
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);
        vm.prank(bob);
        registry.register(ROLE_WATCHDOG);
        vm.prank(charlie);
        registry.register(ROLE_WATCHDOG);

        vm.prank(alice);
        credit.requestLoan(5e6);
        vm.prank(bob);
        credit.requestLoan(4e6);
        vm.prank(charlie);
        credit.requestLoan(3e6);

        assertEq(credit.debtOf(alice), 5e6);
        assertEq(credit.debtOf(bob), 4e6);
        assertEq(credit.debtOf(charlie), 3e6);
        assertEq(usdc.balanceOf(address(credit)), 88e6);
    }

    function test_paused_blocksRequestLoan_allowsRepay() public {
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);
        vm.prank(alice);
        credit.requestLoan(3e6);

        vm.prank(pauser);
        credit.pause();

        vm.expectRevert();
        vm.prank(bob);
        credit.requestLoan(1e6);

        // repay still works
        vm.prank(alice);
        usdc.approve(address(credit), 3e6);
        vm.prank(alice);
        credit.repay(3e6);
        assertEq(credit.debtOf(alice), 0);
    }

    // ---------------------------------------------------------------
    // Signed-request (relief) path
    // ---------------------------------------------------------------

    function test_signedRequest_happyPath() public {
        uint256 borrowerKey = uint256(keccak256("borrower-key"));
        address borrower = vm.addr(borrowerKey);
        vm.prank(borrower);
        registry.register(ROLE_WATCHDOG);

        IDamanCredit.LoanRequest memory req = IDamanCredit.LoanRequest({
            borrower: borrower,
            amount: 5e6,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signLoanRequest(req, borrowerKey);

        vm.prank(relayer);
        credit.requestLoanWithSignature(req, sig);

        assertEq(credit.debtOf(borrower), 5e6);
        assertEq(usdc.balanceOf(borrower), 5e6);
        assertEq(credit.nonceOf(borrower), 1);
        assertEq(credit.lifetimeBorrowCount(borrower), 1);
    }

    function test_signedRequest_revert_expired() public {
        uint256 borrowerKey = uint256(keccak256("borrower-key"));
        address borrower = vm.addr(borrowerKey);
        vm.prank(borrower);
        registry.register(ROLE_WATCHDOG);

        IDamanCredit.LoanRequest memory req = IDamanCredit.LoanRequest({
            borrower: borrower,
            amount: 5e6,
            nonce: 0,
            deadline: block.timestamp - 1
        });
        bytes memory sig = _signLoanRequest(req, borrowerKey);

        vm.expectRevert(IDamanCredit.SignatureExpired.selector);
        vm.prank(relayer);
        credit.requestLoanWithSignature(req, sig);
    }

    function test_signedRequest_revert_wrongNonce() public {
        uint256 borrowerKey = uint256(keccak256("borrower-key"));
        address borrower = vm.addr(borrowerKey);
        vm.prank(borrower);
        registry.register(ROLE_WATCHDOG);

        IDamanCredit.LoanRequest memory req = IDamanCredit.LoanRequest({
            borrower: borrower,
            amount: 5e6,
            nonce: 7, // wrong
            deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signLoanRequest(req, borrowerKey);

        vm.expectRevert(IDamanCredit.InvalidNonce.selector);
        vm.prank(relayer);
        credit.requestLoanWithSignature(req, sig);
    }

    function test_signedRequest_revert_wrongSigner() public {
        uint256 borrowerKey = uint256(keccak256("borrower-key"));
        uint256 imposterKey = uint256(keccak256("imposter-key"));
        address borrower = vm.addr(borrowerKey);
        vm.prank(borrower);
        registry.register(ROLE_WATCHDOG);

        IDamanCredit.LoanRequest memory req = IDamanCredit.LoanRequest({
            borrower: borrower,
            amount: 5e6,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signLoanRequest(req, imposterKey);

        vm.expectRevert(IDamanCredit.InvalidSignature.selector);
        vm.prank(relayer);
        credit.requestLoanWithSignature(req, sig);
    }

    function test_signedRequest_replay_blocked() public {
        uint256 borrowerKey = uint256(keccak256("borrower-key"));
        address borrower = vm.addr(borrowerKey);
        vm.prank(borrower);
        registry.register(ROLE_WATCHDOG);

        IDamanCredit.LoanRequest memory req = IDamanCredit.LoanRequest({
            borrower: borrower,
            amount: 3e6,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signLoanRequest(req, borrowerKey);

        vm.prank(relayer);
        credit.requestLoanWithSignature(req, sig);

        // Second submit with same (req, sig) reverts.
        vm.expectRevert(IDamanCredit.InvalidNonce.selector);
        vm.prank(relayer);
        credit.requestLoanWithSignature(req, sig);
    }

    function test_signedRequest_ineligibleBorrower_relayerCannotBypass() public {
        uint256 borrowerKey = uint256(keccak256("borrower-key"));
        address borrower = vm.addr(borrowerKey);
        // Register + take a borrow + leave balance above bust threshold so
        // path B (active-but-bust) does not fire. Path A is already burnt.
        vm.prank(borrower);
        registry.register(ROLE_WATCHDOG);
        vm.prank(borrower);
        credit.requestLoan(3e6);
        // borrower now has 3 USDC > 1e6 threshold; lifetimeBorrowCount=1 so
        // path A blocked, balance above threshold so path B blocked.
        assertFalse(credit.isEligible(borrower));

        IDamanCredit.LoanRequest memory req = IDamanCredit.LoanRequest({
            borrower: borrower,
            amount: 1e6,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signLoanRequest(req, borrowerKey);

        vm.expectRevert(IDamanCredit.NotEligible.selector);
        vm.prank(relayer);
        credit.requestLoanWithSignature(req, sig);
    }

    function test_signedRequest_exceedsCap_relayerCannotBypass() public {
        uint256 borrowerKey = uint256(keccak256("borrower-key"));
        address borrower = vm.addr(borrowerKey);
        vm.prank(borrower);
        registry.register(ROLE_WATCHDOG);

        IDamanCredit.LoanRequest memory req = IDamanCredit.LoanRequest({
            borrower: borrower,
            amount: 6e6, // over cap
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signLoanRequest(req, borrowerKey);

        vm.expectRevert(IDamanCredit.ExceedsBorrowerCap.selector);
        vm.prank(relayer);
        credit.requestLoanWithSignature(req, sig);
    }

    function test_signedRequest_paused_blocks() public {
        uint256 borrowerKey = uint256(keccak256("borrower-key"));
        address borrower = vm.addr(borrowerKey);
        vm.prank(borrower);
        registry.register(ROLE_WATCHDOG);

        vm.prank(pauser);
        credit.pause();

        IDamanCredit.LoanRequest memory req = IDamanCredit.LoanRequest({
            borrower: borrower,
            amount: 3e6,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signLoanRequest(req, borrowerKey);

        vm.expectRevert();
        vm.prank(relayer);
        credit.requestLoanWithSignature(req, sig);
    }

    function test_signedRequest_anchorsDebtToBorrowerNotRelayer() public {
        uint256 borrowerKey = uint256(keccak256("borrower-key"));
        address borrower = vm.addr(borrowerKey);
        vm.prank(borrower);
        registry.register(ROLE_WATCHDOG);

        IDamanCredit.LoanRequest memory req = IDamanCredit.LoanRequest({
            borrower: borrower,
            amount: 3e6,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signLoanRequest(req, borrowerKey);

        vm.prank(relayer);
        credit.requestLoanWithSignature(req, sig);

        // Relayer accrues no debt.
        assertEq(credit.debtOf(relayer), 0);
        assertEq(credit.debtOf(borrower), 3e6);
        // Borrower receives USDC, not relayer.
        assertEq(usdc.balanceOf(relayer), 0);
        assertEq(usdc.balanceOf(borrower), 3e6);
    }

    // ---------------------------------------------------------------
    // Self-register tests (registry extension)
    // ---------------------------------------------------------------

    function test_register_happyPath() public {
        assertFalse(registry.isRegistered(alice));
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);
        assertTrue(registry.isRegistered(alice));
        assertEq(registry.roleOf(alice), ROLE_WATCHDOG);
        assertEq(registry.lastActivity(alice), block.timestamp);
    }

    function test_register_revert_alreadyRegistered() public {
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);
        vm.expectRevert(IDamanReputationRegistry.AlreadyRegistered.selector);
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);
    }

    function test_register_zeroRole_reverts() public {
        vm.expectRevert(DamanReputationRegistry.ZeroRole.selector);
        vm.prank(alice);
        registry.register(bytes32(0));
    }

    function test_register_doesNotWriteScore() public {
        vm.prank(alice);
        registry.register(ROLE_WATCHDOG);
        assertEq(registry.reputationScore(alice), 0);
        assertEq(registry.cumulativeUpheld(alice), 0);
        assertEq(registry.cumulativeRejected(alice), 0);
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _signLoanRequest(IDamanCredit.LoanRequest memory req, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                credit.LOAN_REQUEST_TYPEHASH(),
                req.borrower,
                req.amount,
                req.nonce,
                req.deadline
            )
        );
        bytes32 domain = credit.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
