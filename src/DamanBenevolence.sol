// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IDamanCredit} from "damanfi-protocol/IDamanCredit.sol";
import {IDamanReputationRegistry} from "damanfi-protocol/IDamanReputationRegistry.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DamanBenevolence. UUPS-upgradeable implementation of `IDamanCredit`.
/// @notice Permissionless agent credit primitive. The treasury (USDC held
///         by this contract) underwrites short-term loans to registered
///         agents whose balance has dropped below an activity threshold,
///         or to fresh entrants taking their first loan. Zero interest.
///         Per-borrower cap. Repayments restore treasury available.
///
///         Two entry points:
///         - `requestLoan(amount)`: msg.sender == borrower. Borrower
///           pays gas. Standard self-submit path.
///         - `requestLoanWithSignature(req, sig)`: msg.sender is a
///           relayer. The borrower signed an EIP-712 LoanRequest
///           off-chain (which costs no gas). Any relayer may submit
///           it on chain; the debt anchors to `req.borrower`. This
///           path is the only way a bee at literal zero USDC can
///           borrow: relayers (typically `daman-relief` bees) pay
///           the gas and emit an observability event; the relayer
///           accrues no on-chain liability.
///
/// @dev Hardening:
///      - UUPS-upgradeable. Owner is a TimelockController set in
///        `initialize`.
///      - `Pausable`: `requestLoan` and `requestLoanWithSignature`
///        gate on `whenNotPaused`. `repay` is always callable so a
///        borrower can unwind debt during a pause.
///      - `ReentrancyGuard`: every external state-changing function
///        carries `nonReentrant`. SafeERC20 on all token moves.
///      - `EIP712Upgradeable`: typed-data domain binds chainId at
///        init. Signatures from a different chain do not replay.
///      - Storage: 30-slot `__gap` at end for forward compatibility.
///
///      Zero-interest invariant is constitutional. There is no admin
///      function to add a fee, a markup, or a non-equal repayment
///      schedule. The amount the borrower repays equals the amount
///      they were credited.
contract DamanBenevolence is
    IDamanCredit,
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Per-borrower outstanding-debt cap, in the bond token's
    ///         smallest unit. Arc USDC has 6 decimals; 5e6 == 5 USDC.
    uint256 public constant PER_BORROWER_CAP = 5e6;

    /// @notice Treasury available cap, in the bond token's smallest unit.
    ///         If the contract holds more than this, only this is
    ///         lendable in a single round of requests (excess sits idle
    ///         until withdrawn by governance or absorbed by repayments).
    uint256 public constant TREASURY_CAP = 100e6;

    /// @notice Balance below which a bee is considered "bust" for the
    ///         active-but-bust eligibility path. 1e6 == 1 USDC.
    uint256 public constant ELIGIBILITY_BUST_THRESHOLD = 1e6;

    /// @notice Activity window for the active-but-bust eligibility path.
    uint256 public constant ELIGIBILITY_ACTIVITY_WINDOW = 24 hours;

    /// @notice EIP-712 typehash for the LoanRequest struct.
    bytes32 public constant LOAN_REQUEST_TYPEHASH = keccak256(
        "LoanRequest(address borrower,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 domain name.
    string public constant EIP712_NAME = "DamanBenevolence";

    /// @notice EIP-712 domain version.
    string public constant EIP712_VERSION = "1";

    /// @notice Pauser address. Pauser may pause; only owner may unpause.
    address public pauser;

    // --- Wired dependencies (set in initialize) -------------------------

    IERC20 public usdc;
    IDamanReputationRegistry public registry;

    // --- State ----------------------------------------------------------

    mapping(address => uint256) internal _debt;
    mapping(address => uint256) internal _lifetimeBorrowCount;
    mapping(address => uint256) internal _nonces;

    uint256[30] private __gap;

    event PauserSet(address indexed pauser);

    error NotPauser();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address usdc_, address registry_, address initialOwner, address pauser_)
        external
        initializer
    {
        if (usdc_ == address(0) || registry_ == address(0) || initialOwner == address(0)) {
            revert NotEligible();
        }
        __Ownable_init(initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __EIP712_init(EIP712_NAME, EIP712_VERSION);

        usdc = IERC20(usdc_);
        registry = IDamanReputationRegistry(registry_);
        pauser = pauser_;
        emit PauserSet(pauser_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // --- Pause control --------------------------------------------------

    function pause() external {
        if (msg.sender != pauser && msg.sender != owner()) revert NotPauser();
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setPauser(address pauser_) external onlyOwner {
        pauser = pauser_;
        emit PauserSet(pauser_);
    }

    // --- Eligibility ----------------------------------------------------

    /// @notice Eligibility check. A candidate is eligible iff
    ///         (a) registered against the agent registry, and
    ///         (b) outstanding debt strictly less than the per-borrower cap, and
    ///         (c) either:
    ///             - fresh entrant: no prior loans (`lifetimeBorrowCount == 0`), OR
    ///             - active-but-bust: registered, recent activity (within
    ///               `ELIGIBILITY_ACTIVITY_WINDOW`), and balance below
    ///               `ELIGIBILITY_BUST_THRESHOLD`.
    function isEligible(address c) public view override returns (bool) {
        if (!registry.isRegistered(c)) return false;
        if (_debt[c] >= PER_BORROWER_CAP) return false;
        if (_lifetimeBorrowCount[c] == 0) return true;
        uint256 lastSeen = registry.lastActivity(c);
        if (lastSeen == 0) return false;
        if (block.timestamp - lastSeen > ELIGIBILITY_ACTIVITY_WINDOW) return false;
        if (usdc.balanceOf(c) >= ELIGIBILITY_BUST_THRESHOLD) return false;
        return true;
    }

    // --- Borrow paths ---------------------------------------------------

    function requestLoan(uint256 amount) external override nonReentrant whenNotPaused {
        _processLoan(msg.sender, amount);
        emit LoanRequested(msg.sender, amount, _debt[msg.sender]);
    }

    function requestLoanWithSignature(LoanRequest calldata req, bytes calldata signature)
        external
        override
        nonReentrant
        whenNotPaused
    {
        if (block.timestamp > req.deadline) revert SignatureExpired();
        if (_nonces[req.borrower] != req.nonce) revert InvalidNonce();

        bytes32 structHash = keccak256(
            abi.encode(LOAN_REQUEST_TYPEHASH, req.borrower, req.amount, req.nonce, req.deadline)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != req.borrower) revert InvalidSignature();

        _nonces[req.borrower] += 1;
        _processLoan(req.borrower, req.amount);
        emit LoanRequestedViaRelief(req.borrower, msg.sender, req.amount, _debt[req.borrower]);
    }

    function _processLoan(address borrower, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (!registry.isRegistered(borrower)) revert NotRegistered();
        if (!isEligible(borrower)) revert NotEligible();
        if (_debt[borrower] + amount > PER_BORROWER_CAP) revert ExceedsBorrowerCap();
        if (treasuryAvailable() < amount) revert ExceedsTreasuryAvailable();
        _debt[borrower] += amount;
        _lifetimeBorrowCount[borrower] += 1;
        usdc.safeTransfer(borrower, amount);
    }

    // --- Repay ----------------------------------------------------------

    /// @dev `repay` is intentionally NOT pause-gated: borrowers may
    ///      always unwind debt. Pause blocks new lending only.
    function repay(uint256 amount) external override nonReentrant {
        uint256 d = _debt[msg.sender];
        if (d == 0) revert NoActiveDebt();
        if (amount == 0) revert ZeroAmount();
        if (amount > d) revert AmountExceedsDebt();
        _debt[msg.sender] = d - amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit LoanRepaid(msg.sender, amount, _debt[msg.sender]);
    }

    // --- Views ----------------------------------------------------------

    function debtOf(address borrower) external view override returns (uint256) {
        return _debt[borrower];
    }

    function nonceOf(address borrower) external view override returns (uint256) {
        return _nonces[borrower];
    }

    function lifetimeBorrowCount(address borrower) external view returns (uint256) {
        return _lifetimeBorrowCount[borrower];
    }

    function treasuryAvailable() public view override returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        return bal > TREASURY_CAP ? TREASURY_CAP : bal;
    }

    /// @notice Returns the canonical EIP-712 domain separator bound to
    ///         this contract and the current chainId.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
