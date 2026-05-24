// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DamanCopyBond} from "../src/DamanCopyBond.sol";
import {DamanBountyAccrual} from "../src/DamanBountyAccrual.sol";
import {DamanReputationRegistry} from "../src/DamanReputationRegistry.sol";
import {DamanBondYieldVault} from "../src/DamanBondYieldVault.sol";
import {DamanBenevolence} from "../src/DamanBenevolence.sol";

/// @notice Asserts that every external function selector and every
///         emitted event topic hash across the Daman contract surface
///         is byte-for-byte stable. Any upgrade that silently changes
///         a signature breaks the bridge bee's topic-hash lookup and
///         the storefront's ABI decoding. This test fires in CI; a
///         red bar is the only protection against drift.
contract SelectorFreezeTest is Test {
    // --- DamanCopyBond selectors ----------------------------------------

    function test_selectorFrozen_registerLeader() public pure {
        assertEq(DamanCopyBond.registerLeader.selector, bytes4(0x67e1cddc));
    }

    function test_selectorFrozen_postBond() public pure {
        assertEq(DamanCopyBond.postBond.selector, bytes4(0xd89b73d0));
    }

    function test_selectorFrozen_withdrawBond() public pure {
        assertEq(DamanCopyBond.withdrawBond.selector, bytes4(0xc3daab96));
    }

    function test_selectorFrozen_subscribe() public pure {
        assertEq(DamanCopyBond.subscribe.selector, bytes4(0xfb7e3d74));
    }

    function test_selectorFrozen_unsubscribe() public pure {
        assertEq(DamanCopyBond.unsubscribe.selector, bytes4(0x7262561c));
    }

    function test_selectorFrozen_recordTrade() public pure {
        assertEq(DamanCopyBond.recordTrade.selector, bytes4(0x6d7f09ed));
    }

    function test_selectorFrozen_recordSettlement() public pure {
        assertEq(DamanCopyBond.recordSettlement.selector, bytes4(0xa5788922));
    }

    function test_selectorFrozen_attestDegradation() public pure {
        assertEq(DamanCopyBond.attestDegradation.selector, bytes4(0xc0dd590e));
    }

    function test_selectorFrozen_disputeAttestation() public pure {
        assertEq(DamanCopyBond.disputeAttestation.selector, bytes4(0x588d11c2));
    }

    function test_selectorFrozen_arbiterRule() public pure {
        assertEq(DamanCopyBond.arbiterRule.selector, bytes4(0xd3a0ce31));
    }

    function test_selectorFrozen_postBondFromCCTP() public pure {
        assertEq(DamanCopyBond.postBondFromCCTP.selector, bytes4(0x4933f2c7));
    }

    function test_selectorFrozen_onCCTPReceive() public pure {
        assertEq(DamanCopyBond.onCCTPReceive.selector, bytes4(0x8654db53));
    }

    function test_selectorFrozen_pause() public pure {
        assertEq(DamanCopyBond.pause.selector, bytes4(0x8456cb59));
    }

    function test_selectorFrozen_unpause() public pure {
        assertEq(DamanCopyBond.unpause.selector, bytes4(0x3f4ba83a));
    }

    // --- DamanCopyBond event topics ------------------------------------

    function test_eventTopicFrozen_LeaderRegistered() public pure {
        assertEq(
            keccak256("LeaderRegistered(address,uint8,uint256,uint256)"),
            bytes32(0x122408e356e49ba4256434f6f4a0b1030b10eeb9986cad632c872d0d30e5768a)
        );
    }

    function test_eventTopicFrozen_LeaderBondPosted() public pure {
        assertEq(
            keccak256("LeaderBondPosted(address,uint256,uint256)"),
            bytes32(0x2402c0dbbc8b5765a080ccdfb859dcedece472471154be2ace8e133a66a55a74)
        );
    }

    function test_eventTopicFrozen_FollowerSubscribed() public pure {
        assertEq(
            keccak256("FollowerSubscribed(address,address,uint256,bytes32)"),
            bytes32(0x280b764b9470803b4cbc9e9eecffcea68b7b006326b3930d323357e028ee9169)
        );
    }

    function test_eventTopicFrozen_TradeExecuted() public pure {
        assertEq(
            keccak256("TradeExecuted(address,address,uint256,bool,uint64)"),
            bytes32(0x603cb2da5b85976e49206b625f4f1f78e4384923ce706c0b3a4c4cb93851d117)
        );
    }

    function test_eventTopicFrozen_SettlementCompleted() public pure {
        assertEq(
            keccak256("SettlementCompleted(address,uint256,int256,uint64)"),
            bytes32(0x3d85cdff0b00c15c15d1a7459865cb295331ee8a24e01acbca48b3d6a6da5401)
        );
    }

    function test_eventTopicFrozen_DegradationFlagged() public pure {
        assertEq(
            keccak256("DegradationFlagged(uint256,address,address,bytes32,bytes32)"),
            bytes32(0xd54d936c28f8d47712d08e21e7299b689ebf6f06e2ead8568012533e18ce4223)
        );
    }

    function test_eventTopicFrozen_ArbiterRuled() public pure {
        assertEq(
            keccak256("ArbiterRuled(uint256,uint256,bool,bytes32,bytes32)"),
            bytes32(0x5ff61d0316330e2f0785d6b332f5a84c857315d428d8c3f82d0342b0d765c85d)
        );
    }

    function test_eventTopicFrozen_BondSlashed() public pure {
        assertEq(
            keccak256("BondSlashed(address,uint256,uint256)"),
            bytes32(0x7aa0d00094a98c2ebaf11dd04c9480f67f70b8040d5f1dbc89a7f61808c02053)
        );
    }

    // --- DamanBountyAccrual selectors ----------------------------------

    function test_selectorFrozen_accrueBounty() public pure {
        assertEq(DamanBountyAccrual.accrueBounty.selector, bytes4(0x25917981));
    }

    function test_selectorFrozen_claimBounty() public pure {
        assertEq(DamanBountyAccrual.claimBounty.selector, bytes4(0x44021ad7));
    }

    function test_eventTopicFrozen_BountyAccrued() public pure {
        assertEq(
            keccak256("BountyAccrued(uint256,address,uint256)"),
            bytes32(0xac498d71c2dd80c23436f10ddc705db16406fcc85a5a61d77c48a6e0bc182298)
        );
    }

    function test_eventTopicFrozen_BountyClaimed() public pure {
        assertEq(
            keccak256("BountyClaimed(uint256,address,uint256)"),
            bytes32(0x23c972d46b3251ae358ad69fb3761ef8f5c38c5131502ed9e9bde9b129da9215)
        );
    }

    // --- DamanReputationRegistry selectors -----------------------------

    function test_selectorFrozen_recordUpheld() public pure {
        assertEq(DamanReputationRegistry.recordUpheld.selector, bytes4(0xd9d34106));
    }

    function test_selectorFrozen_recordRejected() public pure {
        assertEq(DamanReputationRegistry.recordRejected.selector, bytes4(0xcdd947da));
    }

    function test_selectorFrozen_reputationScore() public pure {
        assertEq(DamanReputationRegistry.reputationScore.selector, bytes4(0x50d061cb));
    }

    function test_eventTopicFrozen_ReputationUpdated() public pure {
        assertEq(
            keccak256("ReputationUpdated(address,int256,int256)"),
            bytes32(0x16d27e2cff7b6c62796ec35e40b30e11f94675cc9fded1762c7c11aaa15cb220)
        );
    }

    // --- DamanBondYieldVault selectors ---------------------------------

    function test_selectorFrozen_depositPrincipal() public pure {
        assertEq(DamanBondYieldVault.depositPrincipal.selector, bytes4(0x7dfdaffb));
    }

    function test_selectorFrozen_withdrawPrincipalWithYield() public pure {
        assertEq(DamanBondYieldVault.withdrawPrincipalWithYield.selector, bytes4(0xe398e98c));
    }

    function test_selectorFrozen_accruedYield() public pure {
        assertEq(DamanBondYieldVault.accruedYield.selector, bytes4(0xc744ad19));
    }

    // --- DamanBenevolence selectors -----------------------------------

    function test_selectorFrozen_requestLoan() public pure {
        assertEq(DamanBenevolence.requestLoan.selector, bytes4(0x8d5d3429));
    }

    function test_selectorFrozen_requestLoanWithSignature() public pure {
        assertEq(DamanBenevolence.requestLoanWithSignature.selector, bytes4(0x102fabc6));
    }

    function test_selectorFrozen_repay() public pure {
        assertEq(DamanBenevolence.repay.selector, bytes4(0x371fd8e6));
    }

    // --- DamanBenevolence + extended registry events ------------------

    function test_eventTopicFrozen_LoanRequested() public pure {
        assertEq(
            keccak256("LoanRequested(address,uint256,uint256)"),
            bytes32(0x7468760830aff5679376e50470c0493d21c88c599388e89b08c9512b3f3fbc7d)
        );
    }

    function test_eventTopicFrozen_LoanRequestedViaRelief() public pure {
        assertEq(
            keccak256("LoanRequestedViaRelief(address,address,uint256,uint256)"),
            bytes32(0xc4e40abbd8f4f338f61c8fbaa0aa4bb346f44e48181a84734980c7355c8a5592)
        );
    }

    function test_eventTopicFrozen_LoanRepaid() public pure {
        assertEq(
            keccak256("LoanRepaid(address,uint256,uint256)"),
            bytes32(0xc7ce0a35f17b490de2a317e7fecb2cae86b1abffb03800b2f492823521382698)
        );
    }

    function test_eventTopicFrozen_AgentRegistered() public pure {
        assertEq(
            keccak256("AgentRegistered(address,bytes32)"),
            bytes32(0x2f1f603fdbf809c5197d557d6fe61c1fd7f3ce5e6d39cc413670069565749437)
        );
    }

    /// @dev LoanRequest typed-data hash. Frozen because consumers (the
    ///      daman-relief bee, the bee policy ticks) rely on this exact
    ///      typehash to construct EIP-712 signatures.
    function test_typedDataFrozen_LoanRequest() public pure {
        assertEq(
            keccak256("LoanRequest(address borrower,uint256 amount,uint256 nonce,uint256 deadline)"),
            bytes32(0xa83f31e81f00f584649c96e7ea478e4d4a7efacd274edebfcf063f130cc62327)
        );
    }

    // --- Extended reputation-registry selectors -----------------------

    function test_selectorFrozen_register() public pure {
        assertEq(DamanReputationRegistry.register.selector, bytes4(0xe1fa8e84));
    }

    function test_selectorFrozen_lastActivity() public pure {
        assertEq(DamanReputationRegistry.lastActivity.selector, bytes4(0xf07e96b3));
    }

    function test_selectorFrozen_isRegistered() public pure {
        assertEq(DamanReputationRegistry.isRegistered.selector, bytes4(0xc3c5a547));
    }
}
