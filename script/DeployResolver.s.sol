// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {Resolver} from "../src/Resolver.sol";
import {console} from "forge-std/console.sol";

/// @notice Deploy script for Resolver contract
/// @dev Requires PRIVATE_KEY env var
/// Usage: forge script script/DeployResolver.s.sol --rpc-url $RPC_URL --broadcast
contract DeployResolver is Script {
    // Deployed contract addresses on Mantle Sepolia
    address constant CONDITIONAL_TOKENS = 0xFdA547973c86fd6F185eF6b50d5B3A6ecCE9FF8b;
    address constant PM_EXCHANGE = 0x4acEaEeA1EbC1C4B86a3Efe4525Cd4F6443E0CCF;
    address constant PM_ADAPTER = 0x6F3e6F69ca4992B12F3FDAc0d1ec366b57D6De48;

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        Resolver resolver = new Resolver(
            CONDITIONAL_TOKENS,
            PM_EXCHANGE,
            PM_ADAPTER
        );

        vm.stopBroadcast();

        console.log("Resolver deployed to:", address(resolver));
        console.log("ConditionalTokens:", CONDITIONAL_TOKENS);
        console.log("PMExchange:", PM_EXCHANGE);
        console.log("PMMultiMarketAdapter:", PM_ADAPTER);
        console.log("Owner:", resolver.owner());
    }
}
