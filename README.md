# Kombat Protocol – Technical Documentation

> **A High-Performance Prediction Market Infrastructure on Mantle**

[![Solidity](https://img.shields.io/badge/Solidity-^0.8.30-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Foundry-Framework-orange)](https://getfoundry.sh/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Order Model & Normalization](#3-order-model--normalization)
4. [Trade Execution Flow](#4-trade-execution-flow)
5. [Matching Engine](#5-matching-engine)
6. [Multi-Outcome Markets (NegRisk)](#6-multi-outcome-markets-negrisk)
7. [Data Structures](#7-data-structures)
8. [Execution Scenarios](#8-execution-scenarios)
9. [Deployment](#9-deployment)
10. [Core Contracts](#10-core-contracts)
    - [ConditionalTokens](#101-conditionaltokens)
    - [PMExchange](#102-pmexchange)
    - [PMExchangeRouter](#103-pmexchangerouter)
    - [PMMultiMarketAdapter](#104-pmmultimarketadapter)
    - [WUsdc](#105-wusdc)

---

## 1. Overview

Kombat Protocol is a **Central Limit Order Book (CLOB)** exchange designed specifically for prediction markets using **Conditional Tokens (CTF)**. Unlike standard ERC20 exchanges, it handles the unique property of prediction market tokens where **YES + NO = $1.00**. Also unlike traditional prediction markets that use off-chain matching engines and depend on order signing, the Kombat matching engine is completely on-chain, the liquidity level and orderbook is completely on-chain, using a **LibBitmap** for tick lookup and **doubly-linked lists** for order management, with ticks ranging from `$0.01 to $0.99`, leveraging mantle's fast throughput,low gas fees and and fast block times

This architecture allows for full integration of prediction markets with other DeFi protocols, such as AMMs, yield farming, and more.

### Key Features

- **O(1) Operations**: LibBitmap for tick lookup, doubly-linked lists for order management
- **Complement Minting**: Automatically mint new tokens when BuyYes + BuyNo orders match
- **Multi-Outcome Markets**: NegRisk-style position conversion for 3+ outcome markets

- **Secure**: Reentrancy guards, safe ERC20 transfers, and access controls

### System Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `PRICE_DENOMINATOR` | 1e18 | Price precision ($1.00) |
| `TICK_SIZE` | 1e16 | 1 tick = $0.01 |
| `MIN_TICK` | 1 | Minimum price ($0.01) |
| `MAX_TICK` | 99 | Maximum price ($0.99) |

---

## 2. Architecture

![Architecture Flow](docs/flow.png)

### Directory Structure

```
src/
├── ConditionalTokens.sol     # ERC1155-like conditional token implementation
├── PMExchange.sol            # Central limit order book (CLOB) exchange
├── PMExchangeRouter.sol      # User-friendly router for common operations
├── PMMultiMarketAdapter.sol  # NegRisk-style multi-outcome market adapter
├── WUsdc.sol                 # Wrapped USDC for multi-market collateral
├── amm/                      # AMM implementations (future)
└── libraries/
    └── CTHelpers.sol         # Helper functions for conditional tokens

test/
├── ConditionalTokens.t.sol      # ConditionalTokens unit tests
├── PMExchange.t.sol             # PMExchange unit tests
├── PMMultiMarketAdapter.t.sol   # Multi-market adapter tests
├── RouterTxFlowTest.t.sol       # Router transaction flow tests
└── integration/                  # Integration tests
```
