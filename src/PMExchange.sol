// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title PMExchange
/// @notice Onchain Orderbook for conditional token trading
contract PMExchange {
    enum Side {
        BuyYes,
        SellYes,
        BuyNo,
        SellNo
    }

    enum TiF {
        GTC, // Good-Til-Cancelled
        IOC, // Immediate-Or-Cancel
        FOK // Fill-Or-Kill
    }

    enum OrderStatus {
        Active,
        Filled,
        PartiallyFilled,
        Cancelled
    }
}
