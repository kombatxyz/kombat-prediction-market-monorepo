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
6. [Multi-Outcome Markets](#6-multi-outcome-markets)
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

Kombat Protocol is a **Central Limit Order Book (CLOB)** exchange designed specifically for prediction markets using **Conditional Tokens (CTF)**. Unlike standard ERC20 exchanges, it handles the unique property of prediction market tokens where **YES + NO = $1.00**. Also unlike traditional prediction markets that use off-chain matching engines and depend on order signing, the Kombat matching engine is completely on-chain, the liquidity level and orderbook is completely on-chain, using a **LibBitmap** for tick lookup and **doubly-linked lists** for order management, with ticks ranging from `$0.01 to $0.99`, leveraging mantle's fast throughput, low gas fees and and fast block times on mantle.

This architecture allows for full integration of prediction markets with other DeFi protocols, such as AMMs, yield farming, and more.

### Key Features

- **O(1) Operations**: LibBitmap for tick lookup, doubly-linked lists for order management
- **Complement Minting**: Automatically mint new tokens when BuyYes + BuyNo orders match
- **Multi-Outcome Markets**: Position conversion for 3+ outcome markets

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
├── PMMultiMarketAdapter.sol  # Multi-outcome market adapter
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



---

## 3. Order Model & Normalization

### The "One Token" Principle

Users can place 4 types of orders, but the engine converts them into just 2 internal representations:

```mermaid
flowchart LR
    subgraph User Input
        BuyYes[Buy YES @ $0.60]
        SellYes[Sell YES @ $0.65]
        BuyNo[Buy NO @ $0.40]
        SellNo[Sell NO @ $0.35]
    end
    
    subgraph Normalization
        BuyYes -->|No change| N1["isBuy=true<br/>tick=60<br/>wantsNo=false"]
        SellYes -->|No change| N2["isBuy=false<br/>tick=65<br/>wantsNo=false"]
        BuyNo -->|Invert price| N3["isBuy=false<br/>tick=60<br/>wantsNo=true"]
        SellNo -->|Invert price| N4["isBuy=true<br/>tick=65<br/>wantsNo=true"]
    end
    
    subgraph Order Book Placement
        N1 --> Bid1[Bid @ 60]
        N2 --> Ask1[Ask @ 65]
        N3 --> Ask2[Ask @ 60]
        N4 --> Bid2[Bid @ 65]
    end
```

### Normalization Logic

```solidity
function _normalize(Side s, uint8 tick) internal pure returns (bool isBuy, uint8 yesTick, bool wantsNo) {
    if (s == Side.BuyYes)  return (true, tick, false);
    if (s == Side.SellYes) return (false, tick, false);
    if (s == Side.BuyNo)   return (false, 100 - tick, true);  // buyNo@40 = SellYes@60
    return (true, 100 - tick, true);                          // sellNo@40 = BuyYes@60
}
```

### Order Type Mapping

| User Side | isBuy | yesTick | wantsNo | Book Side |
|-----------|-------|---------|---------|-----------|
| BuyYes @ P | true | P | false | Bid @ P |
| SellYes @ P | false | P | false | Ask @ P |
| BuyNo @ P | false | 100-P | true | Ask @ (100-P) |
| SellNo @ P | true | 100-P | true | Bid @ (100-P) |

### Time-in-Force Options

| TiF | Description |
|-----|-------------|
| `GTC` | Good-Till-Cancelled - stays on book until filled or cancelled |
| `IOC` | Immediate-Or-Cancel - fill what you can, cancel rest |
| `FOK` | Fill-Or-Kill - must fill entirely or revert |
| `POST_ONLY` | Must be maker only - reverts if would take liquidity |

## 4. Trade Execution Flow

```mermaid
flowchart TD
    Start([User: placeOrder]) --> Normalize[Normalize Order<br/>Side -> isBuy, tick, wantsNo]
    Normalize --> PostOnly{POST_ONLY?}
    
    PostOnly -->|Yes| WouldMatch{Would<br/>match?}
    WouldMatch -->|Yes| Revert([Revert: PostOnlyWouldTake])
    WouldMatch -->|No| AddBook[Add to Book]
    
    PostOnly -->|No| Match{Standard<br/>Matching}
    
    Match -->|Found match| Settle[_settle:<br/>Transfer tokens & USDC]
    Match -->|No match| Complement{Complement<br/>Matching}
    
    Settle --> CheckFilled{Fully Filled?}
    Complement -->|Found complement| Mint[_executeComplementMint:<br/>Mint new YES+NO pairs]
    Complement -->|No complement| CheckFilled
    
    Mint --> CheckFilled
    CheckFilled -->|Yes| Done([Order Complete])
    CheckFilled -->|No + GTC| AddBook2[Add to Book]
    CheckFilled -->|No + IOC| Cancel([Cancel Remaining])
    CheckFilled -->|No + FOK| RevertFill([Revert: InsufficientFill])
    
    AddBook --> Done
    AddBook2 --> Done
```

### Step-by-Step

1. **Normalization**: Convert user-facing Side to internal (isBuy, yesTick, wantsNo)
2. **POST_ONLY Check**: If POST_ONLY, verify order won't match immediately
3. **Standard Matching**: Match against opposite book (buyers match asks, sellers match bids)
4. **Complement Matching**: If unfilled, try to match BuyYes with BuyNo for minting
5. **Book Placement**: If GTC and unfilled, add remaining to order book
6. **TiF Enforcement**: Cancel or revert based on time-in-force

---

## 5. Matching Engine

### Standard Matching

```mermaid
flowchart LR
    subgraph Taker Order
        T1[BuyYes @ 60<br/>isBuy=true]
    end
    
    subgraph Search Ask Book
        T1 --> Search[Find lowest Ask]
        Search --> Check{Ask <= 60?}
        Check -->|Yes| Match[Match & Settle]
        Check -->|No| NoMatch[No Match]
    end
    
    subgraph Settlement
        Match --> Transfer1[Maker sends YES tokens]
        Match --> Transfer2[Taker sends USDC]
    end
```

The engine uses **price-time priority (FIFO)**:
- Buyers match against asks from lowest price upward
- Sellers match against bids from highest price downward
- Within a price level, orders are matched in order of submission

### Complement Matching (Minting)

```mermaid
flowchart TD
    Start[Order not fully filled] --> Check{Same tick<br/>opposite wantsNo<br/>on other book?}
    
    Check -->|No| Exit([Return unfilled])
    Check -->|Yes| ValidateBoth{Both parties<br/>pure buyers?}
    
    ValidateBoth -->|No| Exit
    ValidateBoth -->|Yes| Pool[Pool USDC:<br/>$0.60 + $0.40 = $1.00]
    
    Pool --> Mint[ConditionalTokens<br/>splitPosition]
    Mint --> Create[Create 1 YES + 1 NO]
    Create --> Distribute1[YES -> BuyYes trader]
    Create --> Distribute2[NO -> BuyNo trader]
    
    Distribute1 --> Complete([Orders Filled])
    Distribute2 --> Complete
```

**The Innovation**: Instead of requiring existing token liquidity, the exchange:
1. Takes $0.60 USDC from BuyYes trader
2. Takes $0.40 USDC from BuyNo trader
3. Combines to $1.00 USDC
4. Calls `splitPosition` to mint 1 YES + 1 NO
5. Distributes tokens to respective traders

---

## 6. Multi-Outcome Markets (NegRisk)

For markets with more than 2 outcomes (e.g., presidential elections), the adapter enables efficient position management.

### Position Conversion

```mermaid
flowchart TD
    Start["User holds NO_A + NO_B"] --> Burn["Burn NO_A + NO_B"]
    Burn --> Split["Split wUSDC to YES + NO for each position"]
    Split --> Merge["Merge user NO + temp YES to wUSDC"]
    Merge --> MintC["Mint YES_C for user"]
    MintC --> Return["Return n-1 x amount USDC"]
    Return --> Done["User gets YES_C + 1000 USDC"]
    
    style Start fill:#ffcccc
    style Done fill:#ccffcc
```

### Capital Efficiency Example

**3-Candidate Election (A, B, C):**

| Scenario | Without Conversion | With Conversion |
|----------|-------------------|-----------------|
| Belief | "C will win" | "C will win" |
| Action | Buy YES_C directly | Buy NO_A + NO_B, convert |
| Collateral Needed | $1000 for 1000 YES_C | $1000 for 1000 NO_A + $1000 for 1000 NO_B = $2000 |
| After Conversion | N/A | Get back $1000 + 1000 YES_C |
| **Effective Cost** | $1000 | $1000 |
| **Capital Efficiency** | 1x | 3x (can reuse returned USDC) |

---

## 7. Data Structures

```mermaid
graph TB
    subgraph Order Book State
        ActiveTicks["_activeTicks[conditionId][isBid]<br/>(LibBitmap - 256 bits)"]
        TickLevels["tickLevels[conditionId][isBid][tick]<br/>(head, tail, totalQuantity)"]
        OrderLinks["_orderLinks[orderId]<br/>(next, prev pointers)"]
        Orders["orders[orderId]<br/>(Order struct)"]
    end
    
    ActiveTicks -->|"Bit set at tick N"| TickLevels
    TickLevels -->|"Head points to"| Orders
    Orders -->|"Linked via"| OrderLinks
    OrderLinks -->|"Points to next"| Orders
    
    style ActiveTicks fill:#e1f5ff
    style TickLevels fill:#fff4e1
    style OrderLinks fill:#ffe1f5
    style Orders fill:#e1ffe1
```

### `_activeTicks` (Bitmap)
- **What**: A 256-bit map of which ticks have orders
- **Why**: O(1) lookup for best bid/ask using bit manipulation (`fls`/`ffs`)
- **Operations**: `set()`, `unset()`, `get()`

### `tickLevels` (Price Levels)
- **What**: Stores head/tail order IDs and total quantity per tick
- **Why**: O(1) access to order queue at any price level

### `_orderLinks` (Doubly Linked List)
- **What**: Stores prev/next pointers for each order
- **Why**: O(1) insertion (append to tail) and removal (unlink)

### Bitmap Operations

```solidity
// Find highest active tick (best bid) - O(1)
function _findHighestActiveTick(bytes32 cid, bool isBid) internal view returns (uint8) {
    uint256 bucket = _activeTicks[cid][isBid].map[0];
    bucket = bucket & (((1 << 100) - 1) ^ 1);  // mask to bits 1-99
    if (bucket == 0) return 0;
    return uint8(LibBit.fls(bucket));  // find most significant bit
}

// Find lowest active tick (best ask) - O(1)
function _findLowestActiveTick(bytes32 cid, bool isBid) internal view returns (uint8) {
    uint256 bucket = _activeTicks[cid][isBid].map[0];
    bucket = bucket & (((1 << 100) - 1) ^ 1);
    if (bucket == 0) return 0;
    return uint8(LibBit.ffs(bucket));  // find least significant bit
}
```

---

## 8. Execution Scenarios

### Scenario A: Secondary Market Match

```mermaid
sequenceDiagram
    participant Maker
    participant OrderBook
    participant Taker
    participant Exchange
    
    Note over Maker: Has 1000 YES tokens
    Maker->>OrderBook: SellYes @ $0.60
    Note over OrderBook: Order sits on Ask book
    
    Taker->>Exchange: BuyYes @ $0.60
    Exchange->>OrderBook: Find match at tick 60
    OrderBook-->>Exchange: Found Maker order
    
    Exchange->>Maker: Transfer 1000 YES
    Exchange->>Taker: Receive 1000 YES
    Exchange->>Taker: Transfer $600 USDC
    Exchange->>Maker: Receive $600 USDC
    
    Note over Maker,Taker: Secondary market trade complete
```

### Scenario B: Complement Minting

```mermaid
sequenceDiagram
    participant Alice
    participant Bob
    participant Exchange
    participant ConditionalTokens
    
    Note over Alice,Bob: Both have USDC only<br/>No token inventory
    
    Alice->>Exchange: BuyYes @ $0.60
    Note over Exchange: Placed on Bid book at tick 60
    
    Bob->>Exchange: BuyNo @ $0.40
    Note over Exchange: Normalized to tick 60<br/>Searches Bid book
    
    Exchange->>Alice: Request $600 USDC
    Alice-->>Exchange: Send $600
    Exchange->>Bob: Request $400 USDC
    Bob-->>Exchange: Send $400
    
    Exchange->>ConditionalTokens: splitPosition($1000)
    ConditionalTokens-->>Exchange: Mint 1000 YES + 1000 NO
    
    Exchange->>Alice: Send 1000 YES
    Exchange->>Bob: Send 1000 NO
    
    Note over Alice,Bob: Complement minting complete<br/>No pre-existing liquidity needed!
```

### Scenario C: Multi-Outcome Conversion

```mermaid
sequenceDiagram
    participant User
    participant Adapter
    participant CT as ConditionalTokens
    participant wUSDC
    
    Note over User: Holds 1000 NO_A + 1000 NO_B
    
    User->>Adapter: convertPositions indexSet=3, amount=1000
    
    Adapter->>CT: Transfer NO_A from User
    Adapter->>CT: Transfer NO_B from User
    
    Note over Adapter: Split wUSDC for each NO
    Adapter->>CT: Split to YES_A + NO_A
    Adapter->>CT: Merge NO_A + YES_A to wUSDC
    Adapter->>CT: Split to YES_B + NO_B
    Adapter->>CT: Merge NO_B + YES_B to wUSDC
    
    Note over Adapter: Mint complement YES
    Adapter->>CT: Split to YES_C + NO_C
    Adapter->>CT: Transfer YES_C to User
    
    Adapter->>wUSDC: Unwrap n-1 x amount
    wUSDC->>User: Send 1000 USDC
    
    Note over User: Now holds 1000 YES_C + 1000 USDC
```
