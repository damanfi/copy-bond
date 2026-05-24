// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {MockUSDC} from "./MockUSDC.sol";
import {IMessageTransmitterV2} from "reverbprotocol/ICCTPReceiver.sol";

/// @notice Test-only mock of Circle's MessageTransmitterV2. Skips
///         attestation verification; tests prime the next-mint
///         recipient and amount via `setNextMint`. `receiveMessage`
///         performs the mint and returns true. Real deployments use
///         Circle's iris-attestation service plus the actual on-chain
///         MessageTransmitterV2 deployed on the destination chain.
contract MockMessageTransmitterV2 is IMessageTransmitterV2 {
    MockUSDC public immutable usdc;
    address public mintRecipient;
    uint256 public mintAmount;

    constructor(address _usdc) {
        usdc = MockUSDC(_usdc);
    }

    function setNextMint(address _recipient, uint256 _amount) external {
        mintRecipient = _recipient;
        mintAmount = _amount;
    }

    function receiveMessage(bytes calldata, bytes calldata) external returns (bool) {
        usdc.mint(mintRecipient, mintAmount);
        return true;
    }
}
