// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test-only mock USDC. Mint freely; no real authorization.
///         Satisfies the OpenZeppelin IERC20 surface so it composes
///         with SafeERC20 wrappers in the contracts under test.
contract MockUSDC is IERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    string public name = "Mock USDC";
    string public symbol = "MUSDC";
    uint8 public decimals = 18;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balances[from] >= amount, "insufficient balance");
        if (from != msg.sender) {
            require(allowances[from][msg.sender] >= amount, "insufficient allowance");
            allowances[from][msg.sender] -= amount;
        }
        balances[from] -= amount;
        balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "insufficient balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }
}
