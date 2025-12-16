//// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {PMExchange} from "../src/PMExchange.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PMExchangeTest is Test {
    PMExchange public exchange;
    ConditionalTokens public ct;
    MockUSDC public usdc;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    bytes32 public conditionId;
    bytes32 public questionId = keccak256("Will ETH hit 10k?");
    uint256 public yesTokenId;
    uint256 public noTokenId;

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockUSDC();
        ct = new ConditionalTokens();
        exchange = new PMExchange(address(ct), address(usdc));

        ct.prepareCondition(admin, questionId, 2);
        conditionId = ct.getConditionId(admin, questionId, 2);

        bytes32 yesColId = ct.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noColId = ct.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = ct.getPositionId(IERC20(address(usdc)), yesColId);
        noTokenId = ct.getPositionId(IERC20(address(usdc)), noColId);

        exchange.registerMarket(conditionId, yesTokenId, noTokenId);

        vm.stopPrank();

        usdc.mint(alice, 10000e18);
        usdc.mint(bob, 10000e18);
        usdc.mint(charlie, 10000e18);

        vm.prank(alice);
        usdc.approve(address(exchange), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(exchange), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(exchange), type(uint256).max);

        vm.prank(alice);
        ct.setApprovalForAll(address(exchange), true);
        vm.prank(bob);
        ct.setApprovalForAll(address(exchange), true);
    }

    function test_MarketRegistration() public view {
        (uint256 yesId, uint256 noId, bool registered, bool paused) = exchange.markets(conditionId);
        assertEq(yesId, yesTokenId);
        assertEq(noId, noTokenId);
        assertTrue(registered);
        assertFalse(paused);
    }

    function test_PlaceOrder_GTC_Maker() public {
        vm.prank(alice);
        uint256 orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 0.6e18, 100e18, PMExchange.TiF.GTC);

        (uint256 price, uint256 size) = exchange.getBestBid(conditionId);
        assertEq(price, 0.6e18);
        assertEq(size, 100e18);

        (,,,,,,, uint256 filled,, PMExchange.OrderStatus status,) = exchange.orders(orderId);
        assertEq(uint256(status), uint256(PMExchange.OrderStatus.Active));
    }

    function test_MatchOrder_Standard() public {
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 0.6e18, 100e18, PMExchange.TiF.GTC);

        _mintTokensTo(bob, 100e18);

        vm.prank(bob);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 0.6e18, 50e18, PMExchange.TiF.IOC);

        (,,,,,,, uint256 filled,,,) = exchange.orders(1);
        assertEq(filled, 50e18);
    }

    function test_MatchOrder_Complement_Mint() public {
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 0.6e18, 100e18, PMExchange.TiF.GTC);

        vm.prank(bob);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, 0.4e18, 50e18, PMExchange.TiF.GTC);

        (,,,,,,, uint256 filledAlice,,,) = exchange.orders(1);
        assertEq(filledAlice, 50e18);

        assertEq(ct.balanceOf(bob, noTokenId), 50e18);
        assertEq(ct.balanceOf(alice, yesTokenId), 50e18);
    }

    function test_CancelOrder() public {
        vm.prank(alice);
        uint256 id = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 0.5e18, 100e18, PMExchange.TiF.GTC);

        vm.prank(alice);
        exchange.cancelOrder(id);

        (,,,,,,,,, PMExchange.OrderStatus status,) = exchange.orders(id);
        assertEq(uint256(status), uint256(PMExchange.OrderStatus.Cancelled));

        (uint256 price, uint256 size) = exchange.getBestBid(conditionId);
        assertEq(size, 0);
    }

    function test_FOK_Revert_If_Unfilled() public {
        vm.prank(alice);
        vm.expectRevert(PMExchange.InsufficientFill.selector);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 0.5e18, 100e18, PMExchange.TiF.FOK);
    }

    function test_PostOnly_Revert_If_Matches() public {
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, 0.6e18, 100e18, PMExchange.TiF.GTC);

        vm.prank(bob);
        vm.expectRevert(PMExchange.PostOnlyWouldTake.selector);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 0.6e18, 100e18, PMExchange.TiF.POST_ONLY);
    }

    function test_View_Depth() public {
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 0.5e18, 100e18, PMExchange.TiF.GTC);
        vm.prank(alice);
        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, 0.4e18, 50e18, PMExchange.TiF.GTC);

        (uint256[] memory bp, uint256[] memory bs,,) = exchange.getOrderBookDepth(conditionId, 10);

        assertEq(bp[0], 0.5e18);
        assertEq(bs[0], 100e18);
        assertEq(bp[1], 0.4e18);
        assertEq(bs[1], 50e18);
    }

    function _mintTokensTo(address to, uint256 amount) internal {
        vm.startPrank(admin);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        usdc.mint(admin, amount);
        usdc.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, amount);
        ct.transfer(to, yesTokenId, amount);
        vm.stopPrank();
    }
}
