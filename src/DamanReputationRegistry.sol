// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IReputationRegistry} from "reverbprotocol/IReputationRegistry.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title DamanReputationRegistry. UUPS-upgradeable implementation of `IReputationRegistry`.
/// @notice Single-recorder model: only the address designated via
///         `setRecorder` (the DamanCopyBond proxy in production) may
///         call `recordUpheld` / `recordRejected`. Deltas are
///         immutable per upgrade slot, set on `initialize`. Score
///         reads are open.
///
/// @dev Hardening:
///      - UUPS-upgradeable. Owner is a TimelockController set via
///        `initialize`.
///      - `Pausable`: `recordUpheld` / `recordRejected` gate on
///        `whenNotPaused`; reads stay open.
///      - Recorder rotation: admin (set at initialize) can rotate
///        the recorder or renounce admin by transferring to
///        address(0). This breaks the deploy-order cycle where the
///        copy-bond address is not known when the registry is being
///        initialized.
///      - Storage: 30-slot `__gap` at end.
contract DamanReputationRegistry is
    IReputationRegistry,
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    int256 public upheldDelta;
    int256 public rejectedDelta;
    address public recorder;
    address public admin;

    mapping(address => int256) internal _score;
    mapping(address => uint256) internal _cumulativeUpheld;
    mapping(address => uint256) internal _cumulativeRejected;

    uint256[30] private __gap;

    event RecorderSet(address indexed recorder);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error CallerNotRecorder();
    error CallerNotAdmin();
    error ZeroAddress();
    error InvalidUpheldDelta();
    error InvalidRejectedDelta();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        int256 upheldDelta_,
        int256 rejectedDelta_,
        address initialOwner
    ) external initializer {
        if (admin_ == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();
        if (upheldDelta_ <= 0) revert InvalidUpheldDelta();
        if (rejectedDelta_ >= 0) revert InvalidRejectedDelta();

        __Ownable_init(initialOwner);
        __Pausable_init();
        __UUPSUpgradeable_init();

        admin = admin_;
        upheldDelta = upheldDelta_;
        rejectedDelta = rejectedDelta_;
        emit AdminTransferred(address(0), admin_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setRecorder(address recorder_) external {
        if (msg.sender != admin) revert CallerNotAdmin();
        if (recorder_ == address(0)) revert ZeroAddress();
        recorder = recorder_;
        emit RecorderSet(recorder_);
    }

    function transferAdmin(address newAdmin) external {
        if (msg.sender != admin) revert CallerNotAdmin();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    function recordUpheld(address agent) external override whenNotPaused {
        if (msg.sender != recorder) revert CallerNotRecorder();
        _score[agent] += upheldDelta;
        _cumulativeUpheld[agent] += 1;
        emit ReputationUpdated(agent, upheldDelta, _score[agent]);
    }

    function recordRejected(address agent) external override whenNotPaused {
        if (msg.sender != recorder) revert CallerNotRecorder();
        _score[agent] += rejectedDelta;
        _cumulativeRejected[agent] += 1;
        emit ReputationUpdated(agent, rejectedDelta, _score[agent]);
    }

    function reputationScore(address agent) external view override returns (int256) {
        return _score[agent];
    }

    function cumulativeUpheld(address agent) external view returns (uint256) {
        return _cumulativeUpheld[agent];
    }

    function cumulativeRejected(address agent) external view returns (uint256) {
        return _cumulativeRejected[agent];
    }
}
