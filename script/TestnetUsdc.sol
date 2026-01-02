// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract TestNetUsdc is ERC20 {
    constructor() ERC20("TestNet USDC", "USDC") {
        _mint(msg.sender, 1000000 * 1e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
