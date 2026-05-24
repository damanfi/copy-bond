// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {BountyAccrualVanilla} from "reverbprotocol/reference/BountyAccrualVanilla.sol";

/// @title DamanBountyAccrual
/// @notice Daman-side wrapper around the substrate's reference bounty
///         accrual. Pins the bounty asset to USDC at construction.
///         Carries `is IBountyAccrual` conformance via inheritance so
///         consumer products can read the bounty surface uniformly
///         with any other substrate-conformant Daman deployment.
/// @dev    Daman's funding policy lives in `DamanCopyBond.arbiterRule`:
///         on `upheld` rulings, copy-bond pulls 10% of the slashed
///         bond, approves this contract, and calls `accrueBounty` on
///         behalf of the watchdog. The remaining 90% goes to the
///         treasury. This contract holds no opinion on the funding
///         source; it only records and dispatches accruals.
contract DamanBountyAccrual is BountyAccrualVanilla {
    constructor(address usdc) BountyAccrualVanilla(usdc) {}
}
