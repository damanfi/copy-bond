// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IReputationRegistry} from "reverbprotocol/IReputationRegistry.sol";
import {IDamanReputationRegistry} from "damanfi-protocol/IDamanReputationRegistry.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title DamanReputationRegistry. UUPS-upgradeable implementation of `IReputationRegistry`
///        and the Daman-specific extension `IDamanReputationRegistry`.
/// @notice Single-recorder model for ruling deltas: only the address designated
///         via `setRecorder` (the DamanCopyBond proxy in production) may call
///         `recordUpheld` / `recordRejected`. Reads are open.
///
///         The Daman extension surface adds permissionless agent self-registration
///         and a public `lastActivity` getter consumed by `DamanBenevolence` for
///         the active-but-bust credit-eligibility path. Self-register declares
///         existence and role; it does not write reputation score.
///
/// @dev Hardening:
///      - UUPS-upgradeable. Owner is a TimelockController set via `initialize`.
///      - `Pausable`: `recordUpheld` / `recordRejected` and `register` gate on
///        `whenNotPaused`; reads stay open.
///      - Recorder rotation: admin (set at initialize) can rotate the recorder
///        or transfer admin. Breaks the deploy-order cycle where the copy-bond
///        address is not known when the registry is initialized.
///      - Storage: 3 new mappings consume slots from the prior `__gap[30]`;
///        gap shrinks to `__gap[27]`. Layout-compatible with the v1 proxy via
///        the gap-reservation pattern.
contract DamanReputationRegistry is
    IReputationRegistry,
    IDamanReputationRegistry,
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

    /// Daman extension. Agent self-registration + activity timestamp.
    mapping(address => bytes32) internal _role;
    mapping(address => uint256) internal _registeredAt;
    mapping(address => uint256) internal _lastActivity;

    uint256[27] private __gap;

    event RecorderSet(address indexed recorder);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error CallerNotRecorder();
    error CallerNotAdmin();
    error ZeroAddress();
    error InvalidUpheldDelta();
    error InvalidRejectedDelta();
    error ZeroRole();

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
        _lastActivity[agent] = block.timestamp;
        emit ReputationUpdated(agent, upheldDelta, _score[agent]);
    }

    function recordRejected(address agent) external override whenNotPaused {
        if (msg.sender != recorder) revert CallerNotRecorder();
        _score[agent] += rejectedDelta;
        _cumulativeRejected[agent] += 1;
        _lastActivity[agent] = block.timestamp;
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

    /// @notice Permissionless self-register. Sets the role anchor and
    ///         initial activity timestamp; does not write reputation
    ///         score (only authorized recorders can do that).
    function register(bytes32 role) external override whenNotPaused {
        if (role == bytes32(0)) revert ZeroRole();
        if (_role[msg.sender] != bytes32(0)) revert AlreadyRegistered();
        _role[msg.sender] = role;
        _registeredAt[msg.sender] = block.timestamp;
        _lastActivity[msg.sender] = block.timestamp;
        emit AgentRegistered(msg.sender, role);
    }

    function isRegistered(address agent) external view override returns (bool) {
        return _role[agent] != bytes32(0);
    }

    function lastActivity(address agent) external view override returns (uint256) {
        return _lastActivity[agent];
    }

    function roleOf(address agent) external view returns (bytes32) {
        return _role[agent];
    }

    function registeredAt(address agent) external view returns (uint256) {
        return _registeredAt[agent];
    }
}
