// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract WUsdc is ERC20, Ownable {
    ERC20 public immutable collateral;
    address public adapter;

    error InsufficientBalance();
    error TransferFailed();
    error Unauthorized();

    constructor(address _collateral) ERC20("Wrapped USDC", "wUSDC") Ownable(msg.sender) {
        collateral = ERC20(_collateral);
    }

    function setAdapter(address _adapter) external onlyOwner {
        adapter = _adapter;
    }

    function wrap(address to, uint256 amount) external {
        if (msg.sender != adapter) revert Unauthorized();

        bool success = collateral.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();

        _mint(to, amount);
    }

    function unwrap(address to, uint256 amount) external {
        if (msg.sender != adapter) revert Unauthorized();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();

        _burn(msg.sender, amount);

        bool success = collateral.transfer(to, amount);
        if (!success) revert TransferFailed();
    }

    function mint(uint256 amount) external {
        if (msg.sender != adapter) revert Unauthorized();
        _mint(msg.sender, amount);
    }

    function burn(uint256 amount) external {
        if (msg.sender != adapter) revert Unauthorized();
        _burn(msg.sender, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return collateral.decimals();
    }
}

