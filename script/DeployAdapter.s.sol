//// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {PMMultiMarketAdapter} from "../src/PMMultiMarketAdapter.sol";
import {console} from "forge-std/console.sol";

contract DeployAdapter is Script {
    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        PMMultiMarketAdapter adapter = new PMMultiMarketAdapter(address(0), address(0));
        vm.stopBroadcast();
        console.log("Adapter deployed to:", address(adapter));
        console.log("WUsdc deployed to:", address(adapter.wrappedCollateral()));
    }
}
