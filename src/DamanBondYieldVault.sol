// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IBondYieldVault} from "reverbprotocol/IBondYieldVault.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DamanBondYieldVault. UUPS-upgradeable implementation of `IBondYieldVault`.
/// @notice Holds principal in the configured underlying asset (USDC
///         in the flagship deployment) on behalf of accounts. The
///         vault declares conformance to `IBondYieldVault`; the
///         actual yield-bearing wrapper (USYC Teller subscription
///         + aggregation policy) is swapped in at upgrade time
///         without changing the interface or the consumer side.
///
/// @dev Hardening:
///      - UUPS-upgradeable. Owner is a TimelockController set via
///        `initialize`.
///      - `Pausable`: `depositPrincipal` and
///        `withdrawPrincipalWithYield` gate on `whenNotPaused`;
///        `accruedYield` reads stay open.
///      - `ReentrancyGuard`: every external state-changing function
///        carries `nonReentrant`; SafeERC20 used for token moves.
///      - Storage: 30-slot `__gap` at end.
///
///      v1 yield model: `accruedYield` returns 0; the vault is
///      principal-only. Production upgrade substitutes a USYC
///      Teller-backed impl that subscribes principal into USYC
///      shares and computes per-account claims pro-rata of the
///      pool's USYC share balance. The upgrade preserves the
///      principal accounting; new yield state appends in the
///      __gap region.
contract DamanBondYieldVault is
    IBondYieldVault,
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    IERC20 public asset;
    mapping(address => uint256) public principalOf;
    uint256 public totalPrincipal;

    uint256[30] private __gap;

    error WrongAsset();
    error ZeroAccount();
    error ZeroAmount();
    error ZeroAddress();
    error NoBalance();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address asset_, address initialOwner) external initializer {
        if (asset_ == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        asset = IERC20(asset_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc IBondYieldVault
    function depositPrincipal(address depositAsset, uint256 amount, address account)
        external
        override
        whenNotPaused
        nonReentrant
    {
        if (depositAsset != address(asset)) revert WrongAsset();
        if (amount == 0) revert ZeroAmount();
        if (account == address(0)) revert ZeroAccount();

        principalOf[account] += amount;
        totalPrincipal += amount;

        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit PrincipalDeposited(account, depositAsset, amount);
    }

    /// @inheritdoc IBondYieldVault
    function withdrawPrincipalWithYield(address account)
        external
        override
        whenNotPaused
        nonReentrant
    {
        uint256 principal = principalOf[account];
        if (principal == 0) revert NoBalance();

        principalOf[account] = 0;
        totalPrincipal -= principal;

        // v1: yield is zero. Production upgrade substitutes a USYC
        // Teller-backed impl that computes yield from share-balance
        // delta and forwards principal + yield to the account.
        uint256 yieldAmount = 0;
        asset.safeTransfer(account, principal);
        emit PrincipalWithdrawn(account, principal, yieldAmount);
    }

    /// @inheritdoc IBondYieldVault
    function accruedYield(address) external pure override returns (uint256) {
        return 0;
    }
}
