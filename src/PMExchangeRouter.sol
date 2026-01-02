//// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PMExchange} from "./PMExchange.sol";
import {ConditionalTokens} from "./ConditionalTokens.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract PMExchangeRouter {
    using SafeERC20 for IERC20;

    PMExchange public immutable exchange;
    ConditionalTokens public immutable ct;
    IERC20 public immutable usdc;

    event Trade(address indexed trader, bytes32 indexed conditionId, bool isYes, bool isBuy, uint256 amount);
    event OrderPlaced(
        address indexed trader,
        bytes32 indexed conditionId,
        uint64 orderId,
        bool isYes,
        bool isBuy,
        uint8 tick,
        uint128 size
    );

    constructor(address _exchange, address _ct, address _usdc) {
        exchange = PMExchange(_exchange);
        ct = ConditionalTokens(_ct);
        usdc = IERC20(_usdc);

        usdc.approve(_ct, type(uint256).max);
        usdc.approve(_exchange, type(uint256).max);

        ct.setApprovalForAll(_exchange, true);
    }

    function marketBuyYes(bytes32 conditionId, uint128 size) external returns (uint256 cost) {
        (uint256 yesTokenId,) = exchange.getTokenIds(conditionId);

        (uint8 tick,) = exchange.getBestAsk(conditionId);
        require(tick > 0, "No asks");

        cost = (uint256(size) * tick * 1e16) / 1e18;

        usdc.safeTransferFrom(msg.sender, address(this), cost);

        exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, tick, size, PMExchange.TiF.FOK);

        ct.transfer(msg.sender, yesTokenId, size);

        emit Trade(msg.sender, conditionId, true, true, size);
    }

    function marketBuyNo(bytes32 conditionId, uint128 size) external returns (uint256 cost) {
        (, uint256 noTokenId) = exchange.getTokenIds(conditionId);

        (uint8 yesTick,) = exchange.getBestBid(conditionId);
        require(yesTick > 0, "No NO asks");

        uint8 noTick = 100 - yesTick;
        cost = (uint256(size) * noTick * 1e16) / 1e18;

        usdc.safeTransferFrom(msg.sender, address(this), cost);

        exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, noTick, size, PMExchange.TiF.FOK);

        ct.transfer(msg.sender, noTokenId, size);

        emit Trade(msg.sender, conditionId, false, true, size);
    }

    function marketSellYes(bytes32 conditionId, uint128 size) external returns (uint256 received) {
        (uint256 yesTokenId,) = exchange.getTokenIds(conditionId);

        (uint8 tick,) = exchange.getBestBid(conditionId);
        require(tick > 0, "No bids");

        received = (uint256(size) * tick * 1e16) / 1e18;

        ct.transferFrom(msg.sender, address(this), yesTokenId, size);

        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, tick, size, PMExchange.TiF.FOK);

        usdc.safeTransfer(msg.sender, received);

        emit Trade(msg.sender, conditionId, true, false, size);
    }

    function marketSellNo(bytes32 conditionId, uint128 size) external returns (uint256 received) {
        (, uint256 noTokenId) = exchange.getTokenIds(conditionId);

        (uint8 yesTick,) = exchange.getBestAsk(conditionId);
        require(yesTick > 0, "No NO bids");

        uint8 noTick = 100 - yesTick;
        received = (uint256(size) * noTick * 1e16) / 1e18;

        ct.transferFrom(msg.sender, address(this), noTokenId, size);

        exchange.placeOrder(conditionId, PMExchange.Side.SellNo, noTick, size, PMExchange.TiF.FOK);

        usdc.safeTransfer(msg.sender, received);

        emit Trade(msg.sender, conditionId, false, false, size);
    }

    function limitBuyYes(bytes32 conditionId, uint8 tick, uint128 size) external returns (uint64 orderId) {
        (uint256 yesTokenId, uint256 noTokenId) = exchange.getTokenIds(conditionId);

        uint256 noBefore = ct.balanceOf(address(this), noTokenId);

        uint256 cost = (uint256(size) * tick * 1e16) / 1e18;
        usdc.safeTransferFrom(msg.sender, address(this), cost);

        orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyYes, tick, size, PMExchange.TiF.GTC);

        (,,,,,,, uint128 filled,,,) = exchange.orders(orderId);

        if (filled > 0) {
            ct.transfer(msg.sender, yesTokenId, filled);
        }

        uint256 noAfter = ct.balanceOf(address(this), noTokenId);
        if (noAfter > noBefore) {
            ct.transfer(msg.sender, noTokenId, noAfter - noBefore);
        }

        emit OrderPlaced(msg.sender, conditionId, orderId, true, true, tick, size);
    }

    function limitBuyNo(bytes32 conditionId, uint8 tick, uint128 size) external returns (uint64 orderId) {
        (uint256 yesTokenId, uint256 noTokenId) = exchange.getTokenIds(conditionId);

        uint256 yesBefore = ct.balanceOf(address(this), yesTokenId);

        uint256 cost = (uint256(size) * tick * 1e16) / 1e18;
        usdc.safeTransferFrom(msg.sender, address(this), cost);

        orderId = exchange.placeOrder(conditionId, PMExchange.Side.BuyNo, tick, size, PMExchange.TiF.GTC);

        (,,,,,,, uint128 filled,,,) = exchange.orders(orderId);

        if (filled > 0) {
            ct.transfer(msg.sender, noTokenId, filled);
        }

        uint256 yesAfter = ct.balanceOf(address(this), yesTokenId);
        if (yesAfter > yesBefore) {
            ct.transfer(msg.sender, yesTokenId, yesAfter - yesBefore);
        }

        emit OrderPlaced(msg.sender, conditionId, orderId, false, true, tick, size);
    }

    function limitSellYes(bytes32 conditionId, uint8 tick, uint128 size) external returns (uint64 orderId) {
        (uint256 yesTokenId, uint256 noTokenId) = exchange.getTokenIds(conditionId);

        uint256 userYes = ct.balanceOf(msg.sender, yesTokenId);

        if (userYes >= size) {
            ct.transferFrom(msg.sender, address(this), yesTokenId, size);
        } else {
            uint256 toMint = size - userYes;
            usdc.safeTransferFrom(msg.sender, address(this), toMint);

            uint256[] memory partition = new uint256[](2);
            partition[0] = 1;
            partition[1] = 2;
            ct.splitPosition(usdc, bytes32(0), conditionId, partition, toMint);

            ct.transfer(msg.sender, noTokenId, toMint);

            if (userYes > 0) {
                ct.transferFrom(msg.sender, address(this), yesTokenId, userYes);
            }
        }

        orderId = exchange.placeOrder(conditionId, PMExchange.Side.SellYes, tick, size, PMExchange.TiF.GTC);

        uint256 usdcBal = usdc.balanceOf(address(this));
        if (usdcBal > 0) {
            usdc.safeTransfer(msg.sender, usdcBal);
        }

        emit OrderPlaced(msg.sender, conditionId, orderId, true, false, tick, size);
    }

    function limitSellNo(bytes32 conditionId, uint8 tick, uint128 size) external returns (uint64 orderId) {
        (uint256 yesTokenId, uint256 noTokenId) = exchange.getTokenIds(conditionId);

        uint256 userNo = ct.balanceOf(msg.sender, noTokenId);

        if (userNo >= size) {
            ct.transferFrom(msg.sender, address(this), noTokenId, size);
        } else {
            uint256 toMint = size - userNo;
            usdc.safeTransferFrom(msg.sender, address(this), toMint);

            uint256[] memory partition = new uint256[](2);
            partition[0] = 1;
            partition[1] = 2;
            ct.splitPosition(usdc, bytes32(0), conditionId, partition, toMint);

            ct.transfer(msg.sender, yesTokenId, toMint);

            if (userNo > 0) {
                ct.transferFrom(msg.sender, address(this), noTokenId, userNo);
            }
        }

        orderId = exchange.placeOrder(conditionId, PMExchange.Side.SellNo, tick, size, PMExchange.TiF.GTC);

        uint256 usdcBal = usdc.balanceOf(address(this));
        if (usdcBal > 0) {
            usdc.safeTransfer(msg.sender, usdcBal);
        }

        emit OrderPlaced(msg.sender, conditionId, orderId, false, false, tick, size);
    }

    function split(bytes32 conditionId, uint128 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        ct.splitPosition(usdc, bytes32(0), conditionId, partition, amount);

        (uint256 yesTokenId, uint256 noTokenId) = exchange.getTokenIds(conditionId);
        ct.transfer(msg.sender, yesTokenId, amount);
        ct.transfer(msg.sender, noTokenId, amount);
    }

    function merge(bytes32 conditionId, uint128 amount) external {
        (uint256 yesTokenId, uint256 noTokenId) = exchange.getTokenIds(conditionId);

        ct.transferFrom(msg.sender, address(this), yesTokenId, amount);
        ct.transferFrom(msg.sender, address(this), noTokenId, amount);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        ct.mergePositions(usdc, bytes32(0), conditionId, partition, amount);

        usdc.safeTransfer(msg.sender, amount);
    }

    function redeem(bytes32 conditionId) external {
        (uint256 yesTokenId, uint256 noTokenId) = exchange.getTokenIds(conditionId);

        uint256 userYes = ct.balanceOf(msg.sender, yesTokenId);
        uint256 userNo = ct.balanceOf(msg.sender, noTokenId);

        if (userYes > 0) ct.transferFrom(msg.sender, address(this), yesTokenId, userYes);
        if (userNo > 0) ct.transferFrom(msg.sender, address(this), noTokenId, userNo);

        uint256 den = ct.payoutDenominator(conditionId);

        uint256 userPayout = 0;
        if (den > 0) {
            uint256 yesNumerator = ct.payoutNumerators(conditionId, 0);
            uint256 noNumerator = ct.payoutNumerators(conditionId, 1);

            userPayout += (userYes * yesNumerator) / den;
            userPayout += (userNo * noNumerator) / den;
        }

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        ct.redeemPositions(usdc, bytes32(0), conditionId, partition);

        if (userPayout > 0) {
            usdc.safeTransfer(msg.sender, userPayout);
        }
    }

    function cancelOrder(uint64 orderId) external {
        exchange.cancelOrder(orderId);
    }
}
