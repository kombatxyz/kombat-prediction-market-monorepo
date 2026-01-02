//// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PMExchange} from "src/PMExchange.sol";
import {PMExchangeRouter} from "src/PMExchangeRouter.sol";
import {ConditionalTokens} from "src/ConditionalTokens.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract RouterTxFlowTest is Test {
    PMExchange public exchange;
    PMExchangeRouter public router;
    ConditionalTokens public ct;
    MockUSDC public usdc;

    address oracle = makeAddr("oracle");

    address[20] makers;
    address[10] takers;
    address smartMoney = makeAddr("smartMoney");

    bytes32 questionId;
    bytes32 conditionId;
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        ct = new ConditionalTokens();
        usdc = new MockUSDC();
        exchange = new PMExchange(address(ct), address(usdc));
        router = new PMExchangeRouter(address(exchange), address(ct), address(usdc));

        questionId = keccak256("Will the underdog win?");
        vm.prank(oracle);
        conditionId = ct.prepareCondition(oracle, questionId, 2);

        bytes32 yesColId = ct.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noColId = ct.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = ct.getPositionId(IERC20(address(usdc)), yesColId);
        noTokenId = ct.getPositionId(IERC20(address(usdc)), noColId);
        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        for (uint256 i = 0; i < 20; i++) {
            makers[i] = makeAddr(string(abi.encodePacked("maker", vm.toString(i))));
            usdc.mint(makers[i], 100_000e6);
            _approveRouter(makers[i]);
        }

        for (uint256 i = 0; i < 10; i++) {
            takers[i] = makeAddr(string(abi.encodePacked("taker", vm.toString(i))));
            usdc.mint(takers[i], 50_000e6);
            _approveRouter(takers[i]);
        }

        usdc.mint(smartMoney, 600e6);
        _approveRouter(smartMoney);
    }

    function _approveRouter(address user) internal {
        vm.startPrank(user);
        usdc.approve(address(router), type(uint256).max);
        ct.setApprovalForAll(address(router), true);
        vm.stopPrank();
    }

    function test_routerFlow_PriceManipulation() public {
        console2.log("=== ROUTER TX FLOW TEST ===");
        console2.log("Price: 50/50 -> 95/5 | Winner: NO | Smart money: ~2x return");

        for (uint256 i = 0; i < 5; i++) {
            uint8 tick = uint8(51 + i);
            vm.prank(makers[i]);
            router.limitSellYes(conditionId, tick, 10_000e6);
        }

        for (uint256 i = 5; i < 10; i++) {
            uint8 tick = uint8(51 + (i - 5));
            vm.prank(makers[i]);
            router.limitSellNo(conditionId, tick, 10_000e6);
        }

        console2.log("Phase 1: Market initialized at 50/50");

        uint256 smartMoneyBalanceBefore = usdc.balanceOf(smartMoney);
        vm.prank(smartMoney);
        router.marketBuyNo(conditionId, 1000e6);

        uint256 smartMoneyNoTokens = ct.balanceOf(smartMoney, noTokenId);
        uint256 smartMoneySpent = smartMoneyBalanceBefore - usdc.balanceOf(smartMoney);

        console2.log("Phase 2: Smart money market buys NO at ~50c");
        console2.log("  Spent: $%s | Tokens: %s NO", smartMoneySpent / 1e6, smartMoneyNoTokens / 1e6);

        uint8[8] memory priceStages = [uint8(55), 60, 65, 70, 75, 80, 85, 95];

        for (uint256 stage = 0; stage < 8; stage++) {
            uint8 basePrice = priceStages[stage];

            for (uint256 i = 0; i < 5; i++) {
                uint8 askTick = basePrice + uint8(i);
                if (askTick > 95) askTick = 95;

                vm.prank(makers[i]);
                router.limitSellYes(conditionId, askTick, 5_000e6);
            }

            for (uint256 i = 5; i < 10; i++) {
                uint8 noTick = 100 - basePrice - uint8(i - 5);
                if (noTick < 5) noTick = 5;

                vm.prank(makers[i]);
                router.limitSellNo(conditionId, noTick, 5_000e6);
            }

            if (stage < 10) {
                vm.prank(takers[stage]);
                router.limitBuyYes(conditionId, basePrice + 4, 20_000e6);
            }
        }

        console2.log("Phase 3: YES price pushed to ~95c");

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0;
        payouts[1] = 1;

        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        console2.log("Phase 4: NO WINS (underdog)");

        uint256 noTokensBeforeRedeem = ct.balanceOf(smartMoney, noTokenId);

        vm.prank(smartMoney);
        router.redeem(conditionId);

        uint256 smartMoneyFinal = usdc.balanceOf(smartMoney);
        uint256 profit = smartMoneyFinal - (smartMoneyBalanceBefore - smartMoneySpent);
        uint256 roi = (smartMoneyFinal * 100) / smartMoneySpent;

        console2.log("Phase 5: Smart money redeems");
        console2.log("  NO tokens: %s | Payout: $%s", noTokensBeforeRedeem / 1e6, smartMoneyFinal / 1e6);
        console2.log("  Profit: $%s | ROI: %sx", profit / 1e6, roi / 100);

        assertGe(smartMoneyNoTokens, 1000e6, "Should have at least 1000 NO tokens");
        assertGe(smartMoneySpent, 400e6, "Should have spent at least $400 at ~50c");
        assertLe(smartMoneySpent, 600e6, "Should have spent at most $600 at ~50c");
        assertGe(smartMoneyFinal, 1000e6, "Should have at least $1000 after redemption");
        assertGt(profit, 0, "Should profit");

        uint256 actualRoi = smartMoneyFinal / smartMoneySpent;
        console2.log("\n=== SUMMARY ===");
        console2.log("Router handled all trades - users only needed USDC");
        console2.log("Price moved: 50c -> 95c (YES)");
        console2.log("Smart money: $%s -> $%s (%sx return)", smartMoneySpent / 1e6, smartMoneyFinal / 1e6, actualRoi);
    }

    function test_routerFlow_ThreeTraders() public {
        console2.log("=== THREE TRADERS AT DIFFERENT PRICES ===");

        address traderA = makeAddr("TraderA");
        address traderB = makeAddr("TraderB");
        address traderC = makeAddr("TraderC");

        usdc.mint(traderA, 1000e6);
        usdc.mint(traderB, 1000e6);
        usdc.mint(traderC, 1000e6);
        _approveRouter(traderA);
        _approveRouter(traderB);
        _approveRouter(traderC);

        console2.log("\n--- Phase 1: Market at 50c YES ---");

        vm.prank(makers[0]);
        router.limitSellYes(conditionId, 50, 5000e6);

        uint256 traderABefore = usdc.balanceOf(traderA);
        vm.prank(traderA);
        router.marketBuyYes(conditionId, 500e6);
        uint256 traderAYes = ct.balanceOf(traderA, yesTokenId);
        uint256 traderASpent = traderABefore - usdc.balanceOf(traderA);
        console2.log(
            "Trader A buys YES: %s tokens for $%s (avg ~%sc)",
            traderAYes / 1e6,
            traderASpent / 1e6,
            (traderASpent * 100) / traderAYes
        );

        console2.log("\n--- Phase 2: Price drops to 40c YES ---");

        vm.prank(makers[1]);
        router.limitSellYes(conditionId, 40, 5000e6);

        uint256 traderBBefore = usdc.balanceOf(traderB);
        vm.prank(traderB);
        router.marketBuyYes(conditionId, 500e6);
        uint256 traderBYes = ct.balanceOf(traderB, yesTokenId);
        uint256 traderBSpent = traderBBefore - usdc.balanceOf(traderB);
        console2.log(
            "Trader B buys YES: %s tokens for $%s (avg ~%sc)",
            traderBYes / 1e6,
            traderBSpent / 1e6,
            (traderBSpent * 100) / traderBYes
        );

        console2.log("\n--- Phase 3: Price rises to 60c YES (40c NO) ---");

        vm.prank(makers[2]);
        router.limitSellNo(conditionId, 40, 5000e6);

        uint256 traderCBefore = usdc.balanceOf(traderC);
        vm.prank(traderC);
        router.marketBuyNo(conditionId, 500e6);
        uint256 traderCNo = ct.balanceOf(traderC, noTokenId);
        uint256 traderCSpent = traderCBefore - usdc.balanceOf(traderC);
        console2.log(
            "Trader C buys NO: %s tokens for $%s (avg ~%sc)",
            traderCNo / 1e6,
            traderCSpent / 1e6,
            (traderCSpent * 100) / traderCNo
        );

        console2.log("\n--- Phase 4: YES WINS ---");

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        console2.log("\n--- Phase 5: Redemptions ---");

        vm.prank(traderA);
        router.redeem(conditionId);
        uint256 traderAFinal = usdc.balanceOf(traderA);
        console2.log("Trader A (bought YES at 50c): $1000 -> $%s", traderAFinal / 1e6);

        vm.prank(traderB);
        router.redeem(conditionId);
        uint256 traderBFinal = usdc.balanceOf(traderB);
        console2.log("Trader B (bought YES at 40c): $1000 -> $%s", traderBFinal / 1e6);

        vm.prank(traderC);
        router.redeem(conditionId);
        uint256 traderCFinal = usdc.balanceOf(traderC);
        console2.log("Trader C (bought NO at 40c): $1000 -> $%s", traderCFinal / 1e6);

        console2.log("\n=== SUMMARY ===");
        console2.log("Trader A: Bought YES@50c -> 2x return when YES wins");
        console2.log("Trader B: Bought YES@40c -> 2.5x return when YES wins");
        console2.log("Trader C: Bought NO@40c -> LOST (YES won)");

        assertGt(traderAFinal, 1000e6, "Trader A should profit");
        assertGt(traderBFinal, 1000e6, "Trader B should profit");

        assertLt(traderCFinal, 1000e6, "Trader C should lose (bought NO, YES won)");
    }
}
