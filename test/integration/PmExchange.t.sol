pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {PMExchange} from "src/PMExchange.sol";
import {ConditionalTokens} from "src/ConditionalTokens.sol";
import {MockUSDC} from "test/PMExchange.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract ExchangeTest is Test {
    PMExchange public exchange;
    ConditionalTokens public conditionalTokens;
    MockUSDC public usdc;

    address oracle = makeAddr("oracle");
    address admin = address(this);
    address maker1 = makeAddr("maker1");
    address maker2 = makeAddr("maker2");
    address taker = makeAddr("taker");

    address[10] public makers;
    address[5] public takers;
    uint256[10] public makerUsdcStart;
    uint256[5] public takerUsdcStart;
    bool private _participantsSetup;

    bytes32 questionId;
    bytes32 conditionId;
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        conditionalTokens = new ConditionalTokens();
        usdc = new MockUSDC();
        exchange = new PMExchange(address(conditionalTokens), address(usdc));

        usdc.mint(maker1, 10_000e6);
        usdc.mint(maker2, 10_000e6);
        usdc.mint(taker, 10_000e6);

        vm.prank(maker1);
        usdc.approve(address(conditionalTokens), type(uint256).max);
        vm.prank(maker1);
        usdc.approve(address(exchange), type(uint256).max);

        vm.prank(maker2);
        usdc.approve(address(conditionalTokens), type(uint256).max);
        vm.prank(maker2);
        usdc.approve(address(exchange), type(uint256).max);

        vm.prank(taker);
        usdc.approve(address(conditionalTokens), type(uint256).max);
        vm.prank(taker);
        usdc.approve(address(exchange), type(uint256).max);
    }

    function _approveTokens(address user) internal {
        vm.startPrank(user);
        conditionalTokens.approve(address(exchange), yesTokenId, type(uint256).max);
        conditionalTokens.approve(address(exchange), noTokenId, type(uint256).max);
        vm.stopPrank();
    }

    function _setupParticipants() internal {
        if (_participantsSetup) return;
        _participantsSetup = true;

        for (uint256 i = 0; i < 10; i++) {
            makers[i] = makeAddr(string.concat("maker", vm.toString(i)));
            usdc.mint(makers[i], 10_000e6);
            vm.prank(makers[i]);
            usdc.approve(address(conditionalTokens), type(uint256).max);
            vm.prank(makers[i]);
            usdc.approve(address(exchange), type(uint256).max);
            makerUsdcStart[i] = usdc.balanceOf(makers[i]);
        }

        for (uint256 i = 0; i < 5; i++) {
            takers[i] = makeAddr(string.concat("taker", vm.toString(i)));
            usdc.mint(takers[i], 10_000e6);
            vm.prank(takers[i]);
            usdc.approve(address(conditionalTokens), type(uint256).max);
            vm.prank(takers[i]);
            usdc.approve(address(exchange), type(uint256).max);
            takerUsdcStart[i] = usdc.balanceOf(takers[i]);
        }
    }

    function test_fullMarketLifecycle_YesWins() public {
        questionId = keccak256("BTC > $100k by Dec 31 2024?");

        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesCollectionId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noCollectionId);

        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        _approveTokens(maker1);
        _approveTokens(maker2);
        _approveTokens(taker);

        uint256 maker1UsdcBefore = usdc.balanceOf(maker1);

        vm.prank(maker1);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        conditionalTokens.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, 1000e6);

        console2.log("USDC spent:", (maker1UsdcBefore - usdc.balanceOf(maker1)) / 1e6);
        console2.log("YES tokens received:", conditionalTokens.balanceOf(maker1, yesTokenId) / 1e6);
        console2.log("NO tokens received:", conditionalTokens.balanceOf(maker1, noTokenId) / 1e6);

        vm.prank(maker1);
        exchange.placeOrder(conditionId, PMExchange.Side.SellNo, 40, 1000e6, PMExchange.TiF.GTC);

        uint256 takerUsdcBefore = usdc.balanceOf(taker);
        uint256 takerNoBefore = conditionalTokens.balanceOf(taker, noTokenId);

        vm.prank(taker);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, 40, 500e6, PMExchange.TiF.GTC);

        (uint8 bestBidTick, uint128 bidSize) = exchange.getBestBid(conditionId);
        (uint8 bestAskTick, uint128 askSize) = exchange.getBestAsk(conditionId);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(oracle);
        conditionalTokens.reportPayouts(questionId, payouts);

        uint256 maker1UsdcBeforeRedeem = usdc.balanceOf(maker1);
        uint256 maker1YesBefore = conditionalTokens.balanceOf(maker1, yesTokenId);

        vm.prank(maker1);
        conditionalTokens.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, partition);

        uint256 takerNoBefore2 = conditionalTokens.balanceOf(taker, noTokenId);
        uint256 takerUsdcBeforeRedeem = usdc.balanceOf(taker);

        vm.prank(taker);
        conditionalTokens.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, partition);
    }

    function test_complementMatching() public {
        questionId = keccak256("ETH > $5000 by Jan 2026?");

        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesCollectionId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noCollectionId);

        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        _approveTokens(maker1);
        _approveTokens(maker2);

        uint256 maker1UsdcBefore = usdc.balanceOf(maker1);
        uint256 maker1YesBefore = conditionalTokens.balanceOf(maker1, yesTokenId);

        vm.prank(maker1);
        uint64 orderId1 = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.GTC);

        (uint8 bidTick, uint128 bidSize) = exchange.getBestBid(conditionId);

        uint256 maker2UsdcBefore = usdc.balanceOf(maker2);
        uint256 maker2NoBefore = conditionalTokens.balanceOf(maker2, noTokenId);

        vm.prank(maker2);
        uint64 orderId2 = exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, 40, 100e6, PMExchange.TiF.GTC);

        uint256 maker1UsdcAfter = usdc.balanceOf(maker1);
        uint256 maker1YesAfter = conditionalTokens.balanceOf(maker1, yesTokenId);
        uint256 maker2UsdcAfter = usdc.balanceOf(maker2);
        uint256 maker2NoAfter = conditionalTokens.balanceOf(maker2, noTokenId);

        (bidTick, bidSize) = exchange.getBestBid(conditionId);
        (uint8 askTick, uint128 askSize) = exchange.getBestAsk(conditionId);

        assertEq(maker1UsdcBefore - maker1UsdcAfter, 60e6, "Maker1 should pay $60");
        assertEq(maker1YesAfter - maker1YesBefore, 100e6, "Maker1 should get 100 YES");

        assertEq(maker2UsdcBefore - maker2UsdcAfter, 40e6, "Maker2 should pay $40");
        assertEq(maker2NoAfter - maker2NoBefore, 100e6, "Maker2 should get 100 NO");

        uint256 ctBalance = usdc.balanceOf(address(conditionalTokens));
        assertEq(ctBalance, 100e6, "ConditionalTokens should hold $100");
    }

    function test_partialComplementMatching() public {
        questionId = keccak256("SOL > $500 by Feb 2026?");
        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesCollectionId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noCollectionId);

        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);
        _approveTokens(maker1);
        _approveTokens(maker2);

        vm.prank(maker1);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 70, 200e6, PMExchange.TiF.GTC);

        uint256 maker1UsdcBefore = usdc.balanceOf(maker1);
        uint256 maker2UsdcBefore = usdc.balanceOf(maker2);

        vm.prank(maker2);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, 30, 150e6, PMExchange.TiF.GTC);

        uint256 maker1Yes = conditionalTokens.balanceOf(maker1, yesTokenId);
        uint256 maker2No = conditionalTokens.balanceOf(maker2, noTokenId);

        (uint8 bidTick, uint128 bidSize) = exchange.getBestBid(conditionId);

        assertEq(maker1Yes, 150e6, "Maker1 should get 150 YES (partial fill)");
        assertEq(maker2No, 150e6, "Maker2 should get 150 NO");
        assertEq(bidTick, 70, "Remaining should be at tick 70");
        assertEq(bidSize, 50e6, "50 tokens should remain on book");
    }

    function test_complementMatching_thenResolution() public {
        questionId = keccak256("DOGE > $1 by March 2026?");
        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesCollectionId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noCollectionId);

        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);
        _approveTokens(maker1);
        _approveTokens(maker2);

        uint256 maker1UsdcStart = usdc.balanceOf(maker1);
        uint256 maker2UsdcStart = usdc.balanceOf(maker2);

        vm.prank(maker1);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 55, 100e6, PMExchange.TiF.GTC);

        vm.prank(maker2);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, 45, 100e6, PMExchange.TiF.GTC);

        assertEq(conditionalTokens.balanceOf(maker1, yesTokenId), 100e6);
        assertEq(conditionalTokens.balanceOf(maker2, noTokenId), 100e6);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(oracle);
        conditionalTokens.reportPayouts(questionId, payouts);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.prank(maker1);
        conditionalTokens.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, partition);

        vm.prank(maker2);
        conditionalTokens.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, partition);

        uint256 maker1UsdcEnd = usdc.balanceOf(maker1);
        uint256 maker2UsdcEnd = usdc.balanceOf(maker2);

        int256 maker1PnL = int256(maker1UsdcEnd) - int256(maker1UsdcStart);
        int256 maker2PnL = int256(maker2UsdcEnd) - int256(maker2UsdcStart);

        assertEq(maker1PnL, 45e6, "Maker1 should profit $45");
        assertEq(maker2PnL, -45e6, "Maker2 should lose $45");
    }

    function test_multiParticipant_TradingScenario() public {
        _setupParticipants();

        questionId = keccak256("Will ETH hit $5k by Q1 2026?");
        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 yesColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesColId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noColId);
        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        for (uint256 i = 0; i < 10; i++) {
            vm.startPrank(makers[i]);
            conditionalTokens.approve(address(exchange), yesTokenId, type(uint256).max);
            conditionalTokens.approve(address(exchange), noTokenId, type(uint256).max);
            vm.stopPrank();
        }

        uint8[5] memory askTicks = [uint8(36), uint8(37), uint8(38), uint8(40), uint8(42)];
        uint128[5] memory askSizes = [uint128(3469e6), uint128(200e6), uint128(1200e6), uint128(200e6), uint128(500e6)];

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(makers[i]);
            conditionalTokens.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, askSizes[i]);

            vm.prank(makers[i]);
            exchange.placeOrder(conditionId, PMExchange.Side.SellYes, askTicks[i], askSizes[i], PMExchange.TiF.GTC);
        }
        exchange.getOrderBookDepth(conditionId, 10);

        uint8[4] memory bidTicks = [uint8(34), uint8(33), uint8(32), uint8(31)];
        uint128[4] memory bidSizes = [uint128(40e6), uint128(292e6), uint128(2660e6), uint128(894e6)];

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(takers[i]);
            exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, bidTicks[i], bidSizes[i], PMExchange.TiF.GTC);
        }

        (uint8[] memory bids, uint128[] memory bidSizesOut, uint8[] memory asks, uint128[] memory askSizesOut) =
            exchange.getOrderBookDepth(conditionId, 10);

        uint8 spread = 0;
        if (bids.length > 0 && asks.length > 0) {
            spread = asks[0] - bids[0];
        }

        if (bids.length > 0 && asks.length > 0) {
            assertTrue(bids[0] < asks[0], "Orderbook should not be crossed");
        }

        for (uint256 i = 0; i < 10; i++) {
            makerUsdcStart[i] = usdc.balanceOf(makers[i]);
        }
        for (uint256 i = 0; i < 5; i++) {
            takerUsdcStart[i] = usdc.balanceOf(takers[i]);
        }

        vm.prank(takers[4]);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 50, 500e6, PMExchange.TiF.IOC);

        (bids, bidSizesOut, asks, askSizesOut) = exchange.getOrderBookDepth(conditionId, 10);
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(oracle);
        conditionalTokens.reportPayouts(questionId, payouts);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(makers[i]);
            conditionalTokens.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, partition);
        }
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(takers[i]);
            conditionalTokens.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId, partition);
        }

        int256 totalMakerPnL = 0;
        for (uint256 i = 0; i < 5; i++) {
            int256 pnl = int256(usdc.balanceOf(makers[i])) - int256(makerUsdcStart[i]);
            totalMakerPnL += pnl;
        }

        int256 totalTakerPnL = 0;
        for (uint256 i = 0; i < 5; i++) {
            int256 pnl = int256(usdc.balanceOf(takers[i])) - int256(takerUsdcStart[i]);
            totalTakerPnL += pnl;
        }
    }

    function test_multiParticipant_TradingScenario2() public {
        bytes32 questionId2 = keccak256("Will it rain tomorrow?");
        conditionalTokens.prepareCondition(oracle, questionId2, 2);
        bytes32 conditionId2 = conditionalTokens.getConditionId(oracle, questionId2, 2);

        bytes32 yesCollectionId2 = conditionalTokens.getCollectionId(bytes32(0), conditionId2, 1);
        bytes32 noCollectionId2 = conditionalTokens.getCollectionId(bytes32(0), conditionId2, 2);
        uint256 yesTokenId2 = conditionalTokens.getPositionId(IERC20(address(usdc)), yesCollectionId2);
        uint256 noTokenId2 = conditionalTokens.getPositionId(IERC20(address(usdc)), noCollectionId2);

        exchange.registerMarket(conditionId2, yesTokenId2, noTokenId2, 0);

        _setupParticipants();

        for (uint256 i = 0; i < 10; i++) {
            vm.startPrank(makers[i]);
            conditionalTokens.approve(address(exchange), yesTokenId2, type(uint256).max);
            conditionalTokens.approve(address(exchange), noTokenId2, type(uint256).max);
            vm.stopPrank();
        }
        for (uint256 i = 0; i < 5; i++) {
            vm.startPrank(takers[i]);
            conditionalTokens.approve(address(exchange), yesTokenId2, type(uint256).max);
            conditionalTokens.approve(address(exchange), noTokenId2, type(uint256).max);
            vm.stopPrank();
        }

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        console2.log("PHASE 1: INITIAL ORDERBOOK SETUP");

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(makers[i]);
            conditionalTokens.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId2, partition, 500e6);
            uint8 tick = uint8(40 + i * 2);
            vm.prank(makers[i]);
            exchange.placeOrder(conditionId2, PMExchange.Side.SellNo, tick, 500e6, PMExchange.TiF.GTC);
        }

        for (uint256 i = 5; i < 10; i++) {
            vm.prank(makers[i]);
            conditionalTokens.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId2, partition, 500e6);
            uint8 tick = uint8(50 + (i - 5) * 2);
            vm.prank(makers[i]);
            exchange.placeOrder(conditionId2, PMExchange.Side.SellYes, tick, 500e6, PMExchange.TiF.GTC);
        }
        exchange.getOrderBookDepth(conditionId2, 10);

        console2.log("adding BuyYes bids...");
        uint8[3] memory bidTicks = [uint8(45), uint8(48), uint8(42)];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(takers[i]);
            exchange.placeOrder(conditionId2, PMExchange.Side.BuyYes, bidTicks[i], 300e6, PMExchange.TiF.GTC);
        }

        exchange.getOrderBookDepth(conditionId2, 10);

        console2.log("PHASE 2: TRADING");

        vm.prank(takers[0]);
        exchange.placeOrder(conditionId2, PMExchange.Side.BuyYes, 60, 1500e6, PMExchange.TiF.GTC);
        vm.prank(takers[1]);
        exchange.placeOrder(conditionId2, PMExchange.Side.BuyYes, 60, 1000e6, PMExchange.TiF.GTC);
        vm.prank(takers[2]);
        exchange.placeOrder(conditionId2, PMExchange.Side.BuyNo, 60, 1000e6, PMExchange.TiF.GTC);
        vm.prank(takers[3]);
        exchange.placeOrder(conditionId2, PMExchange.Side.BuyNo, 60, 1000e6, PMExchange.TiF.GTC);
        vm.prank(takers[4]);
        exchange.placeOrder(conditionId2, PMExchange.Side.BuyNo, 60, 500e6, PMExchange.TiF.GTC);

        console2.log("PHASE 3: RESOLUTION - NO WINS!");

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0;
        payouts[1] = 1;
        vm.prank(oracle);
        conditionalTokens.reportPayouts(questionId2, payouts);

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(makers[i]);
            conditionalTokens.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId2, partition);
        }
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(takers[i]);
            conditionalTokens.redeemPositions(IERC20(address(usdc)), bytes32(0), conditionId2, partition);
        }

        console2.log("\nMAKERS P&L:");
        int256 totalMakerPnL = 0;
        for (uint256 i = 0; i < 10; i++) {
            int256 pnl = int256(usdc.balanceOf(makers[i])) - int256(makerUsdcStart[i]);
            totalMakerPnL += pnl;
            string memory position =
                i < 5 ? "Sold NO (BULLISH - loses when NO wins)" : "Sold YES (BEARISH - wins when NO wins)";
            console2.log("  Maker", i, position);
            console2.log("    P&L:", pnl / 1e6);
        }

        console2.log("\nTAKERS P&L:");
        int256 totalTakerPnL = 0;
        for (uint256 i = 0; i < 5; i++) {
            int256 pnl = int256(usdc.balanceOf(takers[i])) - int256(takerUsdcStart[i]);
            totalTakerPnL += pnl;
            string memory position = i <= 1 ? "Bought YES (loses when NO wins)" : "Bought NO (wins when NO wins)";
            console2.log("  Taker", i, position);
            console2.log("    P&L:", pnl / 1e6);
        }

        console2.log("\n========== SUMMARY ==========");
        console2.log("Total Maker P&L:", totalMakerPnL / 1e6);
        console2.log("Total Taker P&L:", totalTakerPnL / 1e6);

        for (uint256 i = 0; i < 5; i++) {
            assertLe(
                int256(usdc.balanceOf(makers[i])) - int256(makerUsdcStart[i]), 0, "Sold NO should lose when NO wins"
            );
        }
        for (uint256 i = 5; i < 10; i++) {
            assertGe(
                int256(usdc.balanceOf(makers[i])) - int256(makerUsdcStart[i]), 0, "Sold YES should profit when NO wins"
            );
        }
    }

    function test_complementMatch_BuyYesBuyNo() public {
        questionId = keccak256("Complement test market");
        conditionalTokens.prepareCondition(oracle, questionId, 2);
        conditionId = conditionalTokens.getConditionId(oracle, questionId, 2);

        bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesCollectionId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noCollectionId);

        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        address alice = vm.addr(300);
        address bob = vm.addr(301);
        vm.label(alice, "alice");
        vm.label(bob, "bob");

        usdc.mint(alice, 10000e6);
        usdc.mint(bob, 10000e6);

        vm.prank(alice);
        usdc.approve(address(exchange), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(exchange), type(uint256).max);

        uint256 aliceUsdcStart = usdc.balanceOf(alice);
        uint256 bobUsdcStart = usdc.balanceOf(bob);
        vm.prank(alice);
        uint64 aliceOrderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 1000e6, PMExchange.TiF.GTC);

        vm.prank(bob);
        uint64 bobOrderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, 40, 1000e6, PMExchange.TiF.GTC);

        (,,,,,,, uint128 aliceFilled,, PMExchange.OrderStatus aliceStatus,) = exchange.orders(aliceOrderId);
        (,,,,,,, uint128 bobFilled,, PMExchange.OrderStatus bobStatus,) = exchange.orders(bobOrderId);

        console2.log("  Alice order status:", uint8(aliceStatus) == 1 ? "FILLED" : "NOT FILLED");
        console2.log("  Bob order status:", uint8(bobStatus) == 1 ? "FILLED" : "NOT FILLED");

        assertEq(uint8(aliceStatus), 1, "Alice order should be FILLED");
        assertEq(uint8(bobStatus), 1, "Bob order should be FILLED");
        assertEq(aliceFilled, 1000e6, "Alice order should be fully filled");
        assertEq(bobFilled, 1000e6, "Bob order should be fully filled");

        uint256 aliceYes = conditionalTokens.balanceOf(alice, yesTokenId);
        uint256 aliceNo = conditionalTokens.balanceOf(alice, noTokenId);
        uint256 bobYes = conditionalTokens.balanceOf(bob, yesTokenId);
        uint256 bobNo = conditionalTokens.balanceOf(bob, noTokenId);

        assertEq(aliceYes, 1000e6, "Alice should have 1000 YES");
        assertEq(aliceNo, 0, "Alice should have 0 NO");
        assertEq(bobYes, 0, "Bob should have 0 YES");
        assertEq(bobNo, 1000e6, "Bob should have 1000 NO");

        uint256 aliceSpent = aliceUsdcStart - usdc.balanceOf(alice);
        uint256 bobSpent = bobUsdcStart - usdc.balanceOf(bob);

        assertEq(aliceSpent, 600e6, "Alice should spend $600 (60% of 1000)");
        assertEq(bobSpent, 400e6, "Bob should spend $400 (40% of 1000)");
    }

    function test_multiLevelFill_CrossesMultipleTicks() public {
        questionId = keccak256("BTC > $200k by Dec 2026?");
        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 yesColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesColId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noColId);
        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        _setupParticipants();

        uint8[5] memory askTicks = [uint8(55), uint8(58), uint8(60), uint8(62), uint8(65)];
        uint128[5] memory askSizes = [uint128(500e6), uint128(300e6), uint128(800e6), uint128(400e6), uint128(600e6)];

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(makers[i]);
            conditionalTokens.splitPosition(usdc, bytes32(0), conditionId, _partition(), 2000e6);

            vm.prank(makers[i]);
            conditionalTokens.approve(address(exchange), yesTokenId, type(uint256).max);

            vm.prank(makers[i]);
            exchange.placeOrder(conditionId, PMExchange.Side.SellYes, askTicks[i], askSizes[i], PMExchange.TiF.GTC);

            console2.log("  Maker:", i, "Sell at tick", askTicks[i]);
        }

        (
            uint8[] memory bidTicks,
            uint128[] memory bidSizes,
            uint8[] memory askTicksView,
            uint128[] memory askSizesView
        ) = exchange.getOrderBookDepth(conditionId, 10);

        console2.log("\nOrderbook before sweep:");
        console2.log("  Levels:", askTicksView.length);
        uint256 totalAskLiquidity;
        for (uint256 i = 0; i < askTicksView.length; i++) {
            console2.log("    Tick:", askTicksView[i], "size:", askSizesView[i] / 1e6);
            totalAskLiquidity += askSizesView[i];
        }
        console2.log("  Total ask liquidity:", totalAskLiquidity / 1e6);

        uint128 sweepSize = 2500e6;
        uint256 takerUsdcBefore = usdc.balanceOf(takers[0]);

        console2.log("  Taker: Buy", sweepSize / 1e6, "YES @ tick 70 (market order equivalent)");

        vm.prank(takers[0]);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 70, sweepSize, PMExchange.TiF.IOC);

        uint256 takerUsdcAfter = usdc.balanceOf(takers[0]);
        uint256 takerYesBalance = conditionalTokens.balanceOf(takers[0], yesTokenId);

        (,, askTicksView, askSizesView) = exchange.getOrderBookDepth(conditionId, 10);
        console2.log("\nOrderbook after sweep:");
        uint256 remainingLiquidity;
        for (uint256 i = 0; i < askTicksView.length; i++) {
            console2.log("    Tick:", askTicksView[i], "size:", askSizesView[i] / 1e6);
            remainingLiquidity += askSizesView[i];
        }

        assertTrue(takerYesBalance > 0, "Taker should have received YES tokens");
        assertEq(totalAskLiquidity - remainingLiquidity, takerYesBalance, "Filled amount should match");
    }

    function test_orderbookDepth_EmptyBook() public {
        questionId = keccak256("Empty book test");
        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 yesColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesColId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noColId);
        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        (uint8[] memory bidTicks, uint128[] memory bidSizes, uint8[] memory askTicks, uint128[] memory askSizes) =
            exchange.getOrderBookDepth(conditionId, 10);

        console2.log("  Bid levels:", bidTicks.length);
        console2.log("  Ask levels:", askTicks.length);

        assertEq(bidTicks.length, 0, "Empty book should have no bids");
        assertEq(askTicks.length, 0, "Empty book should have no asks");

        (uint8 bestBid, uint128 bidSize) = exchange.getBestBid(conditionId);
        (uint8 bestAsk, uint128 askSize) = exchange.getBestAsk(conditionId);

        assertEq(bestBid, 0, "Best bid should be 0");
        assertEq(bestAsk, 0, "Best ask should be 0");
    }

    function test_orderbookDepth_MaxOrdersAtSingleTick() public {
        questionId = keccak256("Max orders per tick test");
        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 yesColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesColId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noColId);
        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        _setupParticipants();

        uint8 targetTick = 50;
        uint128 baseSize = 100e6;

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(makers[i]);
            conditionalTokens.splitPosition(usdc, bytes32(0), conditionId, _partition(), 1000e6);

            vm.prank(makers[i]);
            conditionalTokens.approve(address(exchange), yesTokenId, type(uint256).max);

            uint128 orderSize = baseSize + uint128(i * 50e6);
            vm.prank(makers[i]);
            exchange.placeOrder(conditionId, PMExchange.Side.SellYes, targetTick, orderSize, PMExchange.TiF.GTC);
        }

        (,, uint8[] memory askTicks, uint128[] memory askSizes) = exchange.getOrderBookDepth(conditionId, 10);

        assertEq(askTicks.length, 1, "Should have 1 tick level");
        assertEq(askTicks[0], targetTick, "Tick should be 50");

        uint128 expectedTotal = 0;
        for (uint256 i = 0; i < 10; i++) {
            expectedTotal += baseSize + uint128(i * 50e6);
        }
        assertEq(askSizes[0], expectedTotal, "Total size should match sum of all orders");

        vm.prank(takers[0]);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 50, 500e6, PMExchange.TiF.IOC);

        (,, askTicks, askSizes) = exchange.getOrderBookDepth(conditionId, 10);
    }

    function test_orderbookDepth_BitmapClearing() public {
        questionId = keccak256("Bitmap clearing test");
        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 yesColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesColId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noColId);
        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        _setupParticipants();

        uint8[3] memory ticks = [uint8(40), uint8(50), uint8(60)];
        uint64[3] memory orderIds;

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(makers[i]);
            conditionalTokens.splitPosition(usdc, bytes32(0), conditionId, _partition(), 1000e6);

            vm.prank(makers[i]);
            conditionalTokens.approve(address(exchange), yesTokenId, type(uint256).max);

            vm.prank(makers[i]);
            orderIds[i] = exchange.placeOrder(conditionId, PMExchange.Side.SellYes, ticks[i], 500e6, PMExchange.TiF.GTC);
        }

        (,, uint8[] memory askTicks,) = exchange.getOrderBookDepth(conditionId, 10);
        assertEq(askTicks.length, 3, "Should have 3 tick levels");

        vm.prank(makers[1]);
        exchange.cancelOrder(orderIds[1]);

        (,, askTicks,) = exchange.getOrderBookDepth(conditionId, 10);
        assertEq(askTicks.length, 2, "Should have 2 tick levels after cancel");

        vm.prank(makers[0]);
        exchange.cancelOrder(orderIds[0]);
        vm.prank(makers[2]);
        exchange.cancelOrder(orderIds[2]);

        (,, askTicks,) = exchange.getOrderBookDepth(conditionId, 10);
        assertEq(askTicks.length, 0, "Should have 0 tick levels after all cancels");
    }

    function test_variedAmounts_TradingScenario() public {
        questionId = keccak256("AAPL > $300 by Q2 2026?");
        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 yesColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesColId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noColId);
        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        _setupParticipants();

        uint128[10] memory makerSplitAmounts = [
            uint128(500e6),
            uint128(2000e6),
            uint128(750e6),
            uint128(3000e6),
            uint128(1200e6),
            uint128(4500e6),
            uint128(300e6),
            uint128(1800e6),
            uint128(600e6),
            uint128(2500e6)
        ];

        uint8[10] memory makerTicks = [
            uint8(55), uint8(58), uint8(52), uint8(65), uint8(48), uint8(70), uint8(45), uint8(60), uint8(50), uint8(62)
        ];

        bool[10] memory sellsYes = [true, false, true, true, false, true, false, true, false, true];

        uint256 totalMakerLiquidity;

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(makers[i]);
            conditionalTokens.splitPosition(usdc, bytes32(0), conditionId, _partition(), makerSplitAmounts[i]);

            vm.prank(makers[i]);
            conditionalTokens.approve(address(exchange), yesTokenId, type(uint256).max);
            vm.prank(makers[i]);
            conditionalTokens.approve(address(exchange), noTokenId, type(uint256).max);

            uint128 orderSize = makerSplitAmounts[i] / 2;
            PMExchange.Side side = sellsYes[i] ? PMExchange.Side.SellYes : PMExchange.Side.SellNo;

            vm.prank(makers[i]);
            exchange.placeOrder(conditionId, side, makerTicks[i], orderSize, PMExchange.TiF.GTC);

            totalMakerLiquidity += orderSize;
        }

        exchange.getOrderBookDepth(conditionId, 10);

        uint128[5] memory takerAmounts =
            [uint128(1500e6), uint128(400e6), uint128(2800e6), uint128(900e6), uint128(3500e6)];

        PMExchange.Side[5] memory takerSides = [
            PMExchange.Side.BuyYes,
            PMExchange.Side.BuyNo,
            PMExchange.Side.BuyYes,
            PMExchange.Side.BuyNo,
            PMExchange.Side.BuyYes
        ];

        uint8[5] memory takerTicks = [uint8(60), uint8(55), uint8(72), uint8(48), uint8(75)];

        uint256 totalTakerVolume;
        uint256[5] memory takerFills;

        for (uint256 i = 0; i < 5; i++) {
            uint256 usdcBefore = usdc.balanceOf(takers[i]);
            uint256 yesBefore = conditionalTokens.balanceOf(takers[i], yesTokenId);
            uint256 noBefore = conditionalTokens.balanceOf(takers[i], noTokenId);

            vm.prank(takers[i]);
            exchange.placeOrder(conditionId, takerSides[i], takerTicks[i], takerAmounts[i], PMExchange.TiF.IOC);

            uint256 usdcSpent = usdcBefore - usdc.balanceOf(takers[i]);
            uint256 yesGained = conditionalTokens.balanceOf(takers[i], yesTokenId) - yesBefore;
            uint256 noGained = conditionalTokens.balanceOf(takers[i], noTokenId) - noBefore;

            takerFills[i] = yesGained > 0 ? yesGained : noGained;
            totalTakerVolume += takerFills[i];

            string memory sideStr = takerSides[i] == PMExchange.Side.BuyYes ? "YES" : "NO ";
        }

        (uint8[] memory bidTicks, uint128[] memory bidSizes, uint8[] memory askTicks, uint128[] memory askSizes) =
            exchange.getOrderBookDepth(conditionId, 10);

        for (uint256 i = 0; i < 10; i++) {
            uint256 yesHeld = conditionalTokens.balanceOf(makers[i], yesTokenId);
            uint256 noHeld = conditionalTokens.balanceOf(makers[i], noTokenId);
            uint256 usdcHeld = usdc.balanceOf(makers[i]);
        }

        for (uint256 i = 0; i < 5; i++) {
            uint256 yesHeld = conditionalTokens.balanceOf(takers[i], yesTokenId);
            uint256 noHeld = conditionalTokens.balanceOf(takers[i], noTokenId);
            uint256 usdcHeld = usdc.balanceOf(takers[i]);
        }

        assertTrue(totalTakerVolume > 0, "Some trades should have executed");
    }

    function test_OrderbookDepth() external {
        questionId = keccak256("AAPL > $300 by Q2 2026?");
        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 yesColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noColId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesColId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noColId);
        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        _setupParticipants();

        uint128[10] memory makerSplitAmounts = [
            uint128(500e6),
            uint128(2000e6),
            uint128(750e6),
            uint128(3000e6),
            uint128(1200e6),
            uint128(4500e6),
            uint128(300e6),
            uint128(1800e6),
            uint128(600e6),
            uint128(2500e6)
        ];

        uint8[10] memory makerTicks = [
            uint8(55), uint8(58), uint8(52), uint8(65), uint8(48), uint8(70), uint8(45), uint8(60), uint8(50), uint8(62)
        ];

        bool[10] memory sellsYes = [true, false, true, true, false, true, false, true, false, true];

        uint256 totalMakerLiquidity;

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(makers[i]);
            conditionalTokens.splitPosition(usdc, bytes32(0), conditionId, _partition(), makerSplitAmounts[i]);

            vm.prank(makers[i]);
            conditionalTokens.approve(address(exchange), yesTokenId, type(uint256).max);
            vm.prank(makers[i]);
            conditionalTokens.approve(address(exchange), noTokenId, type(uint256).max);

            uint128 orderSize = makerSplitAmounts[i] / 2;
            PMExchange.Side side = sellsYes[i] ? PMExchange.Side.SellYes : PMExchange.Side.SellNo;

            vm.prank(makers[i]);
            exchange.placeOrder(conditionId, side, makerTicks[i], orderSize, PMExchange.TiF.GTC);

            totalMakerLiquidity += orderSize;
        }

        uint8[3] memory buyYesTicks = [uint8(45), uint8(48), uint8(50)];
        uint128[3] memory buyYesSizes = [uint128(500e6), uint128(800e6), uint128(300e6)];

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(takers[i]);
            exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, buyYesTicks[i], buyYesSizes[i], PMExchange.TiF.GTC);
        }

        uint8[2] memory buyNoTicks = [uint8(35), uint8(38)];
        uint128[2] memory buyNoSizes = [uint128(400e6), uint128(600e6)];

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(takers[3 + i]);
            exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, buyNoTicks[i], buyNoSizes[i], PMExchange.TiF.GTC);
        }

        (uint8[] memory yesBids, uint128[] memory yesBidSizes, uint8[] memory yesAsks, uint128[] memory yesAskSizes) =
            exchange.getOrderBookDepth(conditionId, 10);

        (uint8[] memory noBids, uint128[] memory noBidSizes, uint8[] memory noAsks, uint128[] memory noAskSizes) =
            exchange.getNoBookDepth(conditionId, 10);
    }

    function _partition() internal pure returns (uint256[] memory) {
        uint256[] memory p = new uint256[](2);
        p[0] = 1;
        p[1] = 2;
        return p;
    }
}

