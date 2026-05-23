// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IUniverseWhitelist} from "damanfi-protocol/IUniverseWhitelist.sol";

/// @notice Test-only universe whitelist. Permissive by default.
contract MockUniverse is IUniverseWhitelist {
    mapping(address => bool) public eligible;
    bytes32 private _tag;
    uint64 private _ts;

    constructor() {
        _tag = bytes32("MOCK");
        _ts = uint64(block.timestamp);
    }

    function setEligible(address asset, bool v) external {
        eligible[asset] = v;
        _ts = uint64(block.timestamp);
        if (v) {
            emit AssetAdded(asset, bytes32("test"));
        } else {
            emit AssetRemoved(asset, bytes32("test"));
        }
    }

    function isEligible(address asset) external view returns (bool) {
        return eligible[asset];
    }

    function listAssets() external pure returns (address[] memory) {
        return new address[](0);
    }

    function addAsset(address asset, bytes32 source) external {
        eligible[asset] = true;
        emit AssetAdded(asset, source);
    }

    function removeAsset(address asset, bytes32 reason) external {
        eligible[asset] = false;
        emit AssetRemoved(asset, reason);
    }

    function sourceTag() external view returns (bytes32) {
        return _tag;
    }

    function lastUpdatedAt() external view returns (uint64) {
        return _ts;
    }
}
