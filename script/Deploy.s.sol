// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";
import "../src/ConditionalTokens.sol";
import "../src/PMExchange.sol";
import "../src/PMExchangeRouter.sol";
import "./TestnetUsdc.sol";

contract DeployAll is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        TestNetUsdc usdc = new TestNetUsdc();
        console.log("TestNetUSDC deployed at:", address(usdc));

        ConditionalTokens ct = new ConditionalTokens();
        console.log("ConditionalTokens deployed at:", address(ct));

        PMExchange exchange = new PMExchange(address(ct), address(usdc));
        console.log("PMExchange deployed at:", address(exchange));

        PMExchangeRouter router = new PMExchangeRouter(address(exchange), address(ct), address(usdc));
        console.log("PMExchangeRouter deployed at:", address(router));

        //mint to testnet bots and initial market makers
        address[15] memory traders = [
            0xB79F2d5182D8F9526647C419166C085Ae91bc10C,
            0xc0dBe102ACE70983f56c8871A1ACa18706845F57,
            0x4C71AC3Af7Bf749632f13C705008730E46DA60Ac,
            0x70A241307bAFd39c5d822B71f37083581CEdB71B,
            0x14Bec5b972933130862a16eE17ac8196403fD500,
            0x976aAc1BC6323a47fa06A5ec56aEA84671b9e7a1,
            0x066875e988C1A703Dc5961deFDA008EF58502D21,
            0x00896D91E3E3d731db811f3d96FcB2c79ABD6176,
            0x61d6A8C61A01D31DD5AB86300E29b2E5604D1521,
            0xA78C9f3a7B17aD276A9EF8D12F7aCE7b78b5e84F,
            0xF2081aa5Eb318B1E32f0bDD0F432B82C8De4CA20,
            0x375e91174C515d6541f70799cD4595BBC6704D71,
            0x0c36C35DCCE9044181130365ff5496481888AA93,
            0xF874544127F54972F2dC0707Da5cb77439424f48,
            0x687393267F4B247dA353B24B10eC2f9e4d77Ef61
        ];

        for (uint256 i = 0; i < traders.length; i++) {
            usdc.mint(traders[i], 10_000_000 * 10 ** 6); // 10M USDC each
            address(traders[i]).call{value: 0.5 * 1e18}(""); //send 0.5 MNT to each trader
        }

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("MockUSDC:", address(usdc));
        console.log("ConditionalTokens:", address(ct));
        console.log("PMExchange:", address(exchange));
        console.log("PMExchangeRouter:", address(router));
    }
}

