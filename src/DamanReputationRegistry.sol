// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IReputationRegistry} from "reverbprotocol/IReputationRegistry.sol";

/// @title DamanReputationRegistry
/// @notice Daman-specific implementation of `IReputationRegistry`.
///         Single recorder (the DamanCopyBond contract) with admin-set
///         rotation so the deployer can wire the recorder address
///         after the copy-bond is deployed. Deltas are fixed at
///         construction (default: upheld +1, rejected -2 to bias
///         against false claims).
///
/// @dev    Substrate-conformant via `is IReputationRegistry`. The
///         substrate's `ReputationRegistryVanilla` fixes the recorder
///         set at construction, which conflicts with the deploy-order
///         circularity (copy-bond needs the registry address; registry
///         needs the copy-bond address as recorder). This impl breaks
///         the cycle with admin-controlled recorder rotation. Once
///         the copy-bond is deployed, the deployer calls
///         `setRecorder(copyBondAddress)` and the registry is sealed
///         from further rotation by transferring admin to address(0).
contract DamanReputationRegistry is IReputationRegistry {
    int256 public immutable upheldDelta;
    int256 public immutable rejectedDelta;
    address public recorder;
    address public admin;

    mapping(address => int256) internal _score;
    mapping(address => uint256) internal _cumulativeUpheld;
    mapping(address => uint256) internal _cumulativeRejected;

    event RecorderSet(address indexed recorder);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error CallerNotRecorder();
    error CallerNotAdmin();
    error ZeroAddress();
    error InvalidUpheldDelta();
    error InvalidRejectedDelta();

    constructor(address _admin, int256 _upheldDelta, int256 _rejectedDelta) {
        if (_admin == address(0)) revert ZeroAddress();
        if (_upheldDelta <= 0) revert InvalidUpheldDelta();
        if (_rejectedDelta >= 0) revert InvalidRejectedDelta();
        admin = _admin;
        upheldDelta = _upheldDelta;
        rejectedDelta = _rejectedDelta;
        emit AdminTransferred(address(0), _admin);
    }

    /// @notice Set the single recorder (typically the deployed DamanCopyBond).
    function setRecorder(address _recorder) external {
        if (msg.sender != admin) revert CallerNotAdmin();
        if (_recorder == address(0)) revert ZeroAddress();
        recorder = _recorder;
        emit RecorderSet(_recorder);
    }

    /// @notice Rotate admin or renounce by transferring to address(0).
    function transferAdmin(address _newAdmin) external {
        if (msg.sender != admin) revert CallerNotAdmin();
        emit AdminTransferred(admin, _newAdmin);
        admin = _newAdmin;
    }

    function recordUpheld(address agent) external override {
        if (msg.sender != recorder) revert CallerNotRecorder();
        _score[agent] += upheldDelta;
        _cumulativeUpheld[agent] += 1;
        emit ReputationUpdated(agent, upheldDelta, _score[agent]);
    }

    function recordRejected(address agent) external override {
        if (msg.sender != recorder) revert CallerNotRecorder();
        _score[agent] += rejectedDelta;
        _cumulativeRejected[agent] += 1;
        emit ReputationUpdated(agent, rejectedDelta, _score[agent]);
    }

    function reputationScore(address agent) external view override returns (int256) {
        return _score[agent];
    }

    /// @notice Daman-side accessor consumed by the storefront reputation panel.
    function cumulativeUpheld(address agent) external view returns (uint256) {
        return _cumulativeUpheld[agent];
    }

    /// @notice Daman-side accessor consumed by the storefront reputation panel.
    function cumulativeRejected(address agent) external view returns (uint256) {
        return _cumulativeRejected[agent];
    }
}
