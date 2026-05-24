// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {USYCBondVault} from "reverbprotocol/reference/USYCBondVault.sol";

/// @title DamanBondYieldVault
/// @notice Daman-side wrapper around the substrate's `USYCBondVault`
///         reference implementation. Pins the underlying asset to
///         USDC and the aggregation policy to AGGREGATED so retail-
///         tier bonds below the $100K USYC minimum can pool into a
///         single subscription. Carries `is IBondYieldVault`
///         conformance via inheritance.
/// @dev    Production deployments instantiate this contract pointed
///         at the live USYC Teller at
///         `0x9fdF14c5B14173D74C08Af27AebFf39240dC105A` on Arc
///         testnet. The DamanCopyBond constructor accepts the vault
///         address as an optional dependency; when set, postBond
///         routes principal into the vault and withdrawBond redeems
///         principal plus accrued yield. Yield-delta routing on slash
///         is the operator's policy (the substrate impl returns full
///         principal+yield on withdraw; the copy-bond contract may
///         partition on the way out).
contract DamanBondYieldVault is USYCBondVault {
    constructor(address usdc, address usycTeller)
        USYCBondVault(usdc, usycTeller, USYCBondVault.AggregationPolicy.AGGREGATED, 100_000e18)
    {}
}
