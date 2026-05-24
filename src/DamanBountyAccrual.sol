// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IBountyAccrual} from "reverbprotocol/IBountyAccrual.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DamanBountyAccrual. UUPS-upgradeable implementation of `IBountyAccrual`.
/// @notice Funded by any caller (typically `DamanCopyBond` on an
///         upheld slash) that has approved this contract to pull the
///         bounty asset; recipients claim their accrued amounts on
///         demand. Daman's funding policy (10% top-slice of slashed
///         bond) lives in the caller (`DamanCopyBond.arbiterRule`);
///         this contract holds no opinion on the source.
///
/// @dev Hardening:
///      - UUPS-upgradeable. Owner is a TimelockController set via
///        `initialize`.
///      - `Pausable`: `claimBounty` for net-new claims pauses;
///        accrual stays unpaused so the arbiter ruling that triggers
///        it does not strand mid-flight. Pending unclaimed bounties
///        remain claimable across pauses (they are settled state,
///        not new actions). Pausing `claimBounty` covers the case
///        where the operator wants to halt withdrawals during
///        incident response.
///      - `ReentrancyGuard`: every external state-changing function
///        carries `nonReentrant`; SafeERC20 used for token moves.
///      - Storage: 30-slot `__gap` at end.
contract DamanBountyAccrual is
    IBountyAccrual,
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    struct ClaimRecord {
        address recipient;
        uint256 amount;
        bool claimed;
    }

    IERC20 public bountyAsset;
    uint256 public nextClaimId;
    mapping(uint256 => ClaimRecord) internal _claims;

    uint256[30] private __gap;

    error BountyNotFound();
    error BountyAlreadyClaimed();
    error CallerNotRecipient();
    error ZeroRecipient();
    error ZeroAmount();
    error ZeroAsset();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address bountyAsset_, address initialOwner) external initializer {
        if (bountyAsset_ == address(0)) revert ZeroAsset();
        if (initialOwner == address(0)) revert ZeroRecipient();
        __Ownable_init(initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        bountyAsset = IERC20(bountyAsset_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc IBountyAccrual
    function accrueBounty(address recipient, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256 claimId)
    {
        if (recipient == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();

        claimId = nextClaimId;
        unchecked {
            nextClaimId = claimId + 1;
        }
        _claims[claimId] = ClaimRecord({recipient: recipient, amount: amount, claimed: false});

        bountyAsset.safeTransferFrom(msg.sender, address(this), amount);
        emit BountyAccrued(claimId, recipient, amount);
    }

    /// @inheritdoc IBountyAccrual
    function claimBounty(uint256 claimId) external override nonReentrant whenNotPaused {
        ClaimRecord storage c = _claims[claimId];
        if (c.recipient == address(0)) revert BountyNotFound();
        if (c.claimed) revert BountyAlreadyClaimed();
        if (msg.sender != c.recipient) revert CallerNotRecipient();

        c.claimed = true;
        uint256 amount = c.amount;
        bountyAsset.safeTransfer(c.recipient, amount);
        emit BountyClaimed(claimId, c.recipient, amount);
    }

    function getClaim(uint256 claimId) external view returns (ClaimRecord memory) {
        return _claims[claimId];
    }

    /// @inheritdoc IBountyAccrual
    function bountyAmount(uint256 claimId) external view override returns (uint256) {
        return _claims[claimId].amount;
    }

    /// @inheritdoc IBountyAccrual
    function bountyRecipient(uint256 claimId) external view override returns (address) {
        return _claims[claimId].recipient;
    }

    /// @inheritdoc IBountyAccrual
    function bountyClaimed(uint256 claimId) external view override returns (bool) {
        return _claims[claimId].claimed;
    }
}
