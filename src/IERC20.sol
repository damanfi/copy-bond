// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Minimal IERC20 surface used by `DamanCopyBond`. Avoids
///         pulling OpenZeppelin into the substrate; production
///         deployments may swap in the audited interface freely.
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
