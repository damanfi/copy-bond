// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "../src/IERC20.sol";

/// @notice Test-only mock USDC. Mint freely; no real authorization.
contract MockUSDC is IERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowances[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balances[from] >= amount, "insufficient balance");
        require(allowances[from][msg.sender] >= amount, "insufficient allowance");
        allowances[from][msg.sender] -= amount;
        balances[from] -= amount;
        balances[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "insufficient balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }
}
