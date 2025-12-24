// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {PMExchange} from "../src/PMExchange.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
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

contract CTFExchangeTest is Test {
    PMExchange public exchange;
    ConditionalTokens public ct;
    MockUSDC public usdc;

    address oracle = makeAddr("oracle");
    address alice;
    address bob;
    address operator = makeAddr("operator");

    bytes32 questionId = keccak256("BTC > 100k?");
    bytes32 conditionId;
    uint256 yesTokenId;
    uint256 noTokenId;

    uint256 alicePrivateKey = 0xa11ce;
    uint256 bobPrivateKey = 0xb0b;

    function setUp() public {
        alice = vm.addr(alicePrivateKey);
        bob = vm.addr(bobPrivateKey);

        ct = new ConditionalTokens();
        usdc = new MockUSDC();
        exchange = new PMExchange(address(ct), address(usdc));

        ct.prepareCondition(oracle, questionId, 2);
        conditionId = ct.getConditionId(oracle, questionId, 2);

        bytes32 yesCollectionId = ct.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = ct.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = ct.getPositionId(IERC20(address(usdc)), yesCollectionId);
        noTokenId = ct.getPositionId(IERC20(address(usdc)), noCollectionId);

        exchange.registerMarket(conditionId, yesTokenId, noTokenId, 0);

        usdc.mint(alice, 10000e6);
        usdc.mint(bob, 10000e6);
        usdc.mint(address(exchange), 10000e6);

        vm.prank(alice);
        usdc.approve(address(exchange), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(exchange), type(uint256).max);

        vm.prank(alice);
        usdc.approve(address(ct), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(ct), type(uint256).max);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.prank(alice);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, 1000e6);
        vm.prank(bob);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, 1000e6);

        vm.prank(alice);
        ct.approve(address(exchange), yesTokenId, type(uint256).max);
        vm.prank(alice);
        ct.approve(address(exchange), noTokenId, type(uint256).max);
        vm.prank(bob);
        ct.approve(address(exchange), yesTokenId, type(uint256).max);
        vm.prank(bob);
        ct.approve(address(exchange), noTokenId, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           BASIC ORDER TESTS (TICK-BASED)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_placeOrder_BuyYes() public {
        // Tick 60 = $0.60
        vm.prank(alice);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.GTC);

        (uint64 id, address trader,, uint8 tick, bool isBuy,,,,,,) = exchange.orders(orderId);
        assertEq(id, orderId);
        assertEq(trader, alice);
        assertEq(tick, 60);
        assertTrue(isBuy);
    }

    function test_placeOrder_SellYes() public {
        vm.prank(alice);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 100e6, PMExchange.TiF.GTC);

        (,,, uint8 tick, bool isBuy,,,,,,) = exchange.orders(orderId);
        assertEq(tick, 60);
        assertFalse(isBuy);
    }

    function test_placeOrder_BuyNo_convertedToSellYes() public {
        // BuyNo at tick 40 = SellYes at tick 60
        vm.prank(alice);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, 40, 100e6, PMExchange.TiF.GTC);

        (,,, uint8 tick, bool isBuy, bool wantsNo,,,,,) = exchange.orders(orderId);
        assertFalse(isBuy); // Stored as selling YES
        assertTrue(wantsNo); // Originally wanted NO
        assertEq(tick, 60); // Converted: 100 - 40 = 60
    }

    function test_placeOrder_SellNo_convertedToBuyYes() public {
        vm.prank(alice);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.SellNo, 40, 100e6, PMExchange.TiF.GTC);

        (,,, uint8 tick, bool isBuy, bool wantsNo,,,,,) = exchange.orders(orderId);
        assertTrue(isBuy);
        assertTrue(wantsNo);
        assertEq(tick, 60);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           MATCHING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_matching_BuyYes_SellYes() public {
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 100e6, PMExchange.TiF.GTC);

        uint256 bobYesBefore = ct.balanceOf(bob, yesTokenId);

        vm.prank(bob);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.GTC);

        assertEq(ct.balanceOf(bob, yesTokenId), bobYesBefore + 100e6);
    }

    function test_matching_BuyNo_SellNo() public {
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellNo, 40, 100e6, PMExchange.TiF.GTC);

        uint256 bobNoBefore = ct.balanceOf(bob, noTokenId);

        vm.prank(bob);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, 40, 100e6, PMExchange.TiF.GTC);

        assertEq(ct.balanceOf(bob, noTokenId), bobNoBefore + 100e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           OPERATOR TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_setOperator() public {
        vm.prank(alice);
        exchange.setOperator(operator, true);

        assertTrue(exchange.operators(alice, operator));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           SIGNED ORDER TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function _createSignedOrder(address maker, uint8 tick, uint128 quantity, uint64 nonce)
        internal
        view
        returns (PMExchange.SignedOrder memory)
    {
        return PMExchange.SignedOrder({
            maker: maker,
            conditionId: conditionId,
            side: PMExchange.Side.BuyYes,
            tick: tick,
            quantity: quantity,
            nonce: nonce,
            expiry: uint48(block.timestamp + 1 hours),
            feeRateBps: 10
        });
    }

    function _signOrder(PMExchange.SignedOrder memory order, uint256 privateKey) internal view returns (bytes memory) {
        bytes32 ORDER_TYPEHASH = keccak256(
            "Order(address maker,bytes32 conditionId,uint8 side,uint256 tick,uint256 quantity,uint256 nonce,uint256 expiry,uint256 feeRateBps)"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.maker,
                order.conditionId,
                order.side,
                uint256(order.tick),
                uint256(order.quantity),
                uint256(order.nonce),
                uint256(order.expiry),
                uint256(order.feeRateBps)
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PMExchange"),
                keccak256("2"),
                block.chainid,
                address(exchange)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_placeOrderWithSig() public {
        PMExchange.SignedOrder memory order = _createSignedOrder(alice, 60, 100e6, 0);
        bytes memory sig = _signOrder(order, alicePrivateKey);

        // Relayer submits signed order
        vm.prank(operator);
        uint64 orderId = exchange.placeOrderWithSig(order, sig, PMExchange.TiF.GTC);

        // Verify order was placed for alice
        (, address trader,,,,,,,,,) = exchange.orders(orderId);
        assertEq(trader, alice);

        // Verify best bid
        (uint8 bestBid, uint128 size) = exchange.getBestBid(conditionId);
        assertEq(bestBid, 60);
        assertEq(size, 100e6);
    }

    function test_placeOrderWithSig_invalidSignature() public {
        PMExchange.SignedOrder memory order = _createSignedOrder(alice, 60, 100e6, 0);
        // Sign with wrong key
        bytes memory sig = _signOrder(order, bobPrivateKey);

        vm.prank(operator);
        vm.expectRevert(PMExchange.InvalidSignature.selector);
        exchange.placeOrderWithSig(order, sig, PMExchange.TiF.GTC);
    }

    function test_placeOrderWithSig_expired() public {
        PMExchange.SignedOrder memory order = _createSignedOrder(alice, 60, 100e6, 0);
        order.expiry = uint48(block.timestamp - 1); // Already expired
        bytes memory sig = _signOrder(order, alicePrivateKey);

        vm.prank(operator);
        vm.expectRevert(PMExchange.OrderExpired.selector);
        exchange.placeOrderWithSig(order, sig, PMExchange.TiF.GTC);
    }

    function test_placeOrderWithSig_replayPrevention() public {
        PMExchange.SignedOrder memory order = _createSignedOrder(alice, 60, 100e6, 0);
        bytes memory sig = _signOrder(order, alicePrivateKey);

        // First submission works
        vm.prank(operator);
        exchange.placeOrderWithSig(order, sig, PMExchange.TiF.GTC);

        // Second submission fails (nonce already used)
        vm.prank(operator);
        vm.expectRevert(PMExchange.OrderAlreadyUsed.selector);
        exchange.placeOrderWithSig(order, sig, PMExchange.TiF.GTC);
    }

    function test_placeOrderWithSig_gaslessBuyAndMatch() public {
        // Alice sells YES (on-chain)
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 100e6, PMExchange.TiF.GTC);

        uint256 bobYesBefore = ct.balanceOf(bob, yesTokenId);

        // Bob signs order to buy (gasless)
        PMExchange.SignedOrder memory order = PMExchange.SignedOrder({
            maker: bob,
            conditionId: conditionId,
            side: PMExchange.Side.BuyYes,
            tick: 60,
            quantity: 100e6,
            nonce: 0,
            expiry: uint48(block.timestamp + 1 hours),
            feeRateBps: 10
        });
        bytes memory sig = _signOrder(order, bobPrivateKey);

        // Relayer submits bob's order - should match with alice
        vm.prank(operator);
        exchange.placeOrderWithSig(order, sig, PMExchange.TiF.GTC);

        // Bob received YES tokens
        assertEq(ct.balanceOf(bob, yesTokenId), bobYesBefore + 100e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           POST_ONLY TEST
    // ═══════════════════════════════════════════════════════════════════════════

    function test_postOnly_addedToBook() public {
        vm.prank(alice);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 50, 100e6, PMExchange.TiF.POST_ONLY);

        (,,,,,,,,, PMExchange.OrderStatus status,) = exchange.orders(orderId);
        assertEq(uint8(status), uint8(PMExchange.OrderStatus.Active));
    }

    function test_postOnly_reverts_wouldTake() public {
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 100e6, PMExchange.TiF.GTC);

        vm.prank(bob);
        vm.expectRevert(PMExchange.PostOnlyWouldTake.selector);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.POST_ONLY);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           ORDERBOOK VIEW TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_orderbook_tickDepth() public {
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 55, 50e6, PMExchange.TiF.GTC);

        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 70, 30e6, PMExchange.TiF.GTC);

        vm.prank(bob);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 75, 20e6, PMExchange.TiF.GTC);

        (uint8[] memory bidTicks,, uint8[] memory askTicks,) = exchange.getOrderBookDepth(conditionId, 5);

        assertGe(bidTicks.length, 1);
        assertGe(askTicks.length, 2);

        assertEq(bidTicks[0], 55);
        assertEq(askTicks[0], 70);
        assertEq(askTicks[1], 75);
    }

    function test_getBestBidAsk() public {
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 55, 50e6, PMExchange.TiF.GTC);

        vm.prank(bob);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 30e6, PMExchange.TiF.GTC);

        (uint8 bidTick, uint128 bidSize) = exchange.getBestBid(conditionId);
        (uint8 askTick, uint128 askSize) = exchange.getBestAsk(conditionId);

        assertEq(bidTick, 55);
        assertEq(bidSize, 50e6);
        assertEq(askTick, 60);
        assertEq(askSize, 30e6);
    }

    function test_getSpread() public {
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 55, 50e6, PMExchange.TiF.GTC);

        vm.prank(bob);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 30e6, PMExchange.TiF.GTC);

        (uint8 bidTick, uint8 askTick, uint8 spreadTicks) = exchange.getSpread(conditionId);

        assertEq(bidTick, 55);
        assertEq(askTick, 60);
        assertEq(spreadTicks, 5); // 5 cents spread
    }

    function test_tickToPrice_priceToTick() public {
        // Tick 60 = $0.60 = 0.6e18
        assertEq(exchange.tickToPrice(60), 0.6e18);
        assertEq(exchange.priceToTick(0.6e18), 60);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           CANCEL TEST
    // ═══════════════════════════════════════════════════════════════════════════

    function test_cancelOrder() public {
        vm.prank(alice);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.GTC);

        vm.prank(alice);
        exchange.cancelOrder(orderId);

        (,,,,,,,,, PMExchange.OrderStatus status,) = exchange.orders(orderId);
        assertEq(uint8(status), uint8(PMExchange.OrderStatus.Cancelled));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           USER ORDER QUERIES
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getUserOrders() public {
        vm.startPrank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 50, 50e6, PMExchange.TiF.GTC);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 55, 50e6, PMExchange.TiF.GTC);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 70, 50e6, PMExchange.TiF.GTC);
        vm.stopPrank();

        (uint64[] memory orderIds, PMExchange.Order[] memory orderData) = exchange.getUserOrders(alice, 0, 10);

        assertEq(orderIds.length, 3);
        assertEq(orderData.length, 3);
        assertEq(orderData[0].trader, alice);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           ADMIN TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_toggleMarketPause() public {
        exchange.toggleMarketPause(conditionId);

        vm.prank(alice);
        vm.expectRevert(PMExchange.MarketPaused.selector);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.GTC);
    }

    function test_getMarketCount() public {
        assertEq(exchange.getMarketCount(), 1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           GAS BENCHMARK
    // ═══════════════════════════════════════════════════════════════════════════

    function test_gas_manyOrders() public {
        // Place orders at many different ticks to test bitmap performance
        vm.startPrank(alice);
        for (uint8 tick = 1; tick <= 90; tick++) {
            exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, tick, 10e6, PMExchange.TiF.GTC);
        }
        vm.stopPrank();

        // Verify best bid is at 90
        (uint8 bestBid,) = exchange.getBestBid(conditionId);
        assertEq(bestBid, 90);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           EDGE CASE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_revert_invalidTick_zero() public {
        vm.prank(alice);
        vm.expectRevert(PMExchange.InvalidTick.selector);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 0, 100e6, PMExchange.TiF.GTC);
    }

    function test_revert_invalidTick_hundred() public {
        vm.prank(alice);
        vm.expectRevert(PMExchange.InvalidTick.selector);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 100, 100e6, PMExchange.TiF.GTC);
    }

    function test_revert_invalidTick_tooHigh() public {
        vm.prank(alice);
        vm.expectRevert(PMExchange.InvalidTick.selector);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 150, 100e6, PMExchange.TiF.GTC);
    }

    function test_revert_zeroQuantity() public {
        vm.prank(alice);
        vm.expectRevert(PMExchange.InvalidQuantity.selector);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 50, 0, PMExchange.TiF.GTC);
    }

    function test_revert_marketNotRegistered() public {
        bytes32 fakeCondition = keccak256("fake");
        vm.prank(alice);
        vm.expectRevert(PMExchange.MarketNotRegistered.selector);
        exchange.placeOrder(fakeCondition, PMExchange.Side.BuyYes, 50, 100e6, PMExchange.TiF.GTC);
    }

    function test_revert_cancelNonExistentOrder() public {
        vm.prank(alice);
        vm.expectRevert();
        exchange.cancelOrder(9999);
    }

    function test_revert_cancelOtherUsersOrder() public {
        vm.prank(alice);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.GTC);

        vm.prank(bob);
        vm.expectRevert(PMExchange.NotOrderOwner.selector);
        exchange.cancelOrder(orderId);
    }

    function test_selfTradeAllowed() public {
        // Alice places a sell order
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 100e6, PMExchange.TiF.GTC);

        // Alice places a buy order at same price - self-trades ARE now allowed (for Router support)
        vm.prank(alice);
        uint64 buyOrderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.GTC);

        // Orders should match (self-trade is allowed now)
        (uint8 bestAsk,) = exchange.getBestAsk(conditionId);
        (uint8 bestBid,) = exchange.getBestBid(conditionId);
        assertEq(bestAsk, 0, "Ask should be empty after self-trade match");
        assertEq(bestBid, 0, "Bid should be empty after self-trade match");
    }

    function test_partialFill() public {
        // Alice sells 100 YES at tick 60
        vm.prank(alice);
        uint64 sellOrderId = exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 100e6, PMExchange.TiF.GTC);

        // Bob buys only 30 YES at tick 60
        vm.prank(bob);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 30e6, PMExchange.TiF.GTC);

        // Seller's order should be partially filled
        (,,,,,, uint128 qty, uint128 filled,,,) = exchange.orders(sellOrderId);
        assertEq(qty, 100e6);
        assertEq(filled, 30e6);
    }

    function test_FOK_success() public {
        // Alice sells 100 YES at tick 60
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 100e6, PMExchange.TiF.GTC);

        // Bob FOK buys 100 - should succeed
        vm.prank(bob);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.FOK);

        (,,,,,,, uint128 filled,,,) = exchange.orders(orderId);
        assertEq(filled, 100e6);
    }

    function test_FOK_revert_insufficientLiquidity() public {
        // Alice sells only 50 YES at tick 60
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 50e6, PMExchange.TiF.GTC);

        // Bob FOK buys 100 - should revert
        vm.prank(bob);
        vm.expectRevert(PMExchange.InsufficientFill.selector);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.FOK);
    }

    function test_IOC_partialFill() public {
        // Alice sells 50 YES at tick 60
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 50e6, PMExchange.TiF.GTC);

        // Bob IOC buys 100 - should fill 50 and cancel rest
        vm.prank(bob);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.IOC);

        (,,,,,,, uint128 filled, PMExchange.TiF tif, PMExchange.OrderStatus status,) = exchange.orders(orderId);
        assertEq(filled, 50e6);
        assertEq(uint256(status), uint256(PMExchange.OrderStatus.Cancelled));
    }

    function test_matchAcrossMultipleTicks() public {
        // Place asks at multiple ticks
        vm.startPrank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 50, 30e6, PMExchange.TiF.GTC);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 55, 30e6, PMExchange.TiF.GTC);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 60, 30e6, PMExchange.TiF.GTC);
        vm.stopPrank();

        // Bob buys 90 - should match all three
        vm.prank(bob);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 90e6, PMExchange.TiF.GTC);

        (,,,,,,, uint128 filled,,,) = exchange.orders(orderId);
        assertEq(filled, 90e6);
    }

    function test_priceImprovement() public {
        // Alice sells at tick 50 (asking $0.50)
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 50, 100e6, PMExchange.TiF.GTC);

        // Bob buys at tick 60 (willing to pay $0.60)
        // Should match at maker's price (tick 50)
        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 60, 100e6, PMExchange.TiF.GTC);

        // Bob should only pay 50e6 (tick 50), not 60e6
        uint256 bobUsdcAfter = usdc.balanceOf(bob);
        assertEq(bobUsdcBefore - bobUsdcAfter, 50e6);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           STRESS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_stress_100OrdersSameTick() public {
        vm.startPrank(alice);
        for (uint256 i = 0; i < 100; i++) {
            exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 50, 1e6, PMExchange.TiF.GTC);
        }
        vm.stopPrank();

        // Verify depth
        (, uint128 quantity) = exchange.getBestBid(conditionId);
        assertEq(quantity, 100e6);
    }

    function test_stress_cancelAllOrders() public {
        // Place many orders
        uint64[] memory orderIds = new uint64[](20);
        vm.startPrank(alice);
        for (uint256 i = 0; i < 20; i++) {
            orderIds[i] =
                exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, uint8(30 + i), 10e6, PMExchange.TiF.GTC);
        }

        // Cancel all
        for (uint256 i = 0; i < 20; i++) {
            exchange.cancelOrder(orderIds[i]);
        }
        vm.stopPrank();

        // Verify no bids
        (uint8 bestBid,) = exchange.getBestBid(conditionId);
        assertEq(bestBid, 0);
    }

    function test_stress_bidAskSpread() public {
        // Create an orderbook with tight spread
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 49, 100e6, PMExchange.TiF.GTC);

        vm.prank(bob);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 51, 100e6, PMExchange.TiF.GTC);

        (uint8 bidTick, uint8 askTick, uint8 spread) = exchange.getSpread(conditionId);
        assertEq(bidTick, 49);
        assertEq(askTick, 51);
        assertEq(spread, 2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           BOUNDARY TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_minTick() public {
        vm.prank(alice);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 1, 100e6, PMExchange.TiF.GTC);

        (,,, uint8 tick,,,,,,,) = exchange.orders(orderId);
        assertEq(tick, 1);
    }

    function test_maxTick() public {
        vm.prank(alice);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 99, 100e6, PMExchange.TiF.GTC);

        (,,, uint8 tick,,,,,,,) = exchange.orders(orderId);
        assertEq(tick, 99);
    }

    function test_tickToPrice_boundaries() public {
        assertEq(exchange.tickToPrice(1), 1e16); // $0.01
        assertEq(exchange.tickToPrice(50), 50e16); // $0.50
        assertEq(exchange.tickToPrice(99), 99e16); // $0.99
    }

    function test_priceToTick_validPrices() public {
        assertEq(exchange.priceToTick(1e16), 1); // $0.01 -> tick 1
        assertEq(exchange.priceToTick(50e16), 50); // $0.50 -> tick 50
        assertEq(exchange.priceToTick(99e16), 99); // $0.99 -> tick 99
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           TIME IN FORCE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_GTC_remainsOnBook() public {
        vm.prank(alice);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 50, 100e6, PMExchange.TiF.GTC);

        // Order should be on book
        (uint8 bestBid, uint128 qty) = exchange.getBestBid(conditionId);
        assertEq(bestBid, 50);
        assertEq(qty, 100e6);
    }

    function test_IOC_noMatch_cancelled() public {
        // No liquidity on book
        vm.prank(alice);
        uint64 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 50, 100e6, PMExchange.TiF.IOC);

        (,,,,,,,, PMExchange.TiF tif, PMExchange.OrderStatus status,) = exchange.orders(orderId);
        // Order is cancelled when IOC has no match
        assertTrue(status == PMExchange.OrderStatus.Cancelled);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           NO SIDE DEPTH TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getNoBookDepth() public {
        // Place BuyNo at 40 -> shows as bid on NO book at 40
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, 40, 100e6, PMExchange.TiF.GTC);

        // Place SellNo at 50 -> shows as ask on NO book at 50 (won't match since 50 > 40)
        vm.prank(bob);
        exchange.placeOrder(conditionId, PMExchange.Side.SellNo, 50, 50e6, PMExchange.TiF.GTC);

        // Get NO-side depth
        (uint8[] memory noBidTicks, uint128[] memory noBidQtys, uint8[] memory noAskTicks, uint128[] memory noAskQtys) =
            exchange.getNoBookDepth(conditionId, 5);

        // BuyNo@40 -> NO bids at 40
        assertEq(noBidTicks.length, 1);
        assertEq(noBidTicks[0], 40);
        assertEq(noBidQtys[0], 100e6);

        // SellNo@50 -> NO asks at 50
        assertEq(noAskTicks.length, 1);
        assertEq(noAskTicks[0], 50);
        assertEq(noAskQtys[0], 50e6);
    }
}
