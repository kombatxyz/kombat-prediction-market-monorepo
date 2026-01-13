// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {PMFactory} from "../src/PMFactory.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {PMExchange} from "../src/PMExchange.sol";
import {PMMultiMarketAdapter} from "../src/PMMultiMarketAdapter.sol";
import {Resolver} from "../src/Resolver.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

/// @notice Deploy script for PMFactory contract
/// @dev Requires PRIVATE_KEY and RESOLVER_ADDRESS env vars
/// Usage: forge script script/DeployFactory.s.sol --rpc-url $RPC_URL --broadcast
contract DeployFactory is Script {
    // Deployed contract addresses on Mantle Sepolia
    address constant CONDITIONAL_TOKENS = 0xFdA547973c86fd6F185eF6b50d5B3A6ecCE9FF8b;
    address constant PM_EXCHANGE = 0x4acEaEeA1EbC1C4B86a3Efe4525Cd4F6443E0CCF;
    address constant PM_ADAPTER = 0x6F3e6F69ca4992B12F3FDAc0d1ec366b57D6De48;
    address constant USDC = 0xDdB5BAFf948169775df9B0cd0d5aA067b8856c70;

    function run() public {
        // Get resolver address from env (must be deployed first)
        address resolverAddress = address(0xD9cA55faCBCF561BeB4eB064D873E2A0e2305dc5);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        PMFactory factory = new PMFactory(
            ConditionalTokens(CONDITIONAL_TOKENS),
            PMExchange(PM_EXCHANGE),
            PMMultiMarketAdapter(PM_ADAPTER),
            Resolver(resolverAddress),
            IERC20(USDC)
        );

        vm.stopBroadcast();

        console.log("PMFactory deployed to:", address(factory));
        console.log("ConditionalTokens:", CONDITIONAL_TOKENS);
        console.log("PMExchange:", PM_EXCHANGE);
        console.log("PMMultiMarketAdapter:", PM_ADAPTER);
        console.log("Resolver:", resolverAddress);
        console.log("Collateral (USDC):", USDC);
    }
}
