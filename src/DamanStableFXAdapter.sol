// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {FxEscrowAdapter} from "reverbprotocol/reference/FxEscrowAdapter.sol";

/// @title DamanStableFXAdapter
/// @notice Daman-side wrapper around the substrate's
///         `FxEscrowAdapter` reference impl. Routes Daman EURC bond
///         settlements through Circle's StableFX FxEscrow for atomic
///         same-block EURC-to-USDC conversion on slash payouts.
///         Carries `is IStableFXSwap` conformance via inheritance.
/// @dev    Production deployments instantiate this contract pointed
///         at the live FxEscrow at
///         `0x867650F5eAe8df91445971f14d89fd84F0C9a9f8` on Arc
///         testnet. The copy-bond's EURC bond path (optional) reads
///         a configured adapter address and calls `executeSwap` on
///         slash payouts to settle EURC bonds to USDC for treasury
///         routing.
contract DamanStableFXAdapter is FxEscrowAdapter {
    constructor(address fxEscrow) FxEscrowAdapter(fxEscrow) {}
}
