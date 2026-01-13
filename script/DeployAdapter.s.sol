//// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {PMMultiMarketAdapter} from "../src/PMMultiMarketAdapter.sol";
import {console} from "forge-std/console.sol";

contract DeployAdapter is Script {
    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        PMMultiMarketAdapter adapter = new PMMultiMarketAdapter(
            address(0xFdA547973c86fd6F185eF6b50d5B3A6ecCE9FF8b), address(0xDdB5BAFf948169775df9B0cd0d5aA067b8856c70)
        );
        vm.stopBroadcast();
        console.log("Adapter deployed to:", address(adapter));
        console.log("WUsdc deployed to:", address(adapter.wrappedCollateral()));
    }
}
