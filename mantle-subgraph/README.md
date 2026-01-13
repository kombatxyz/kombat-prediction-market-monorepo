# Kombat Protocol Price History Subgraph

Subgraph for indexing **price history** on Mantle.

## How It Works

### The Flow

1. **Trade happens on-chain** → User buys/sells YES tokens at a price (tick 1-99)
2. **`OrderMatched` event is emitted** → Contains `conditionId`, `tick` (price), `quantity`
3. **Subgraph indexes the event** → Creates a `Trade` entity and updates `Candle` entities
4. **You query the subgraph** → Get historical prices via GraphQL

### What is "tick"?

The `tick` **IS the YES price**:
- `tick = 50` means YES = $0.50 (50%)
- `tick = 75` means YES = $0.75 (75%)
- NO price is always `100 - tick`

## Entities

| Entity | Description |
|--------|-------------|
| `Market` | Market info with `lastPrice` (current YES price) |
| `Trade` | Every matched trade with tick, quantity, volume |
| `Candle` | Hourly OHLC (open, high, low, close) + volume |
| `DailyCandle` | Daily OHLC + volume |

## Query Examples

### Get All Trades for a Market (Raw Price History)

```graphql
query GetPriceHistory($conditionId: String!) {
  trades(
    where: { market: $conditionId }
    orderBy: timestamp
    orderDirection: asc
  ) {
    tick          # YES price (1-99 = $0.01-$0.99)
    quantity      # Amount traded (6 decimals)
    timestamp     # Unix timestamp
  }
}
```

**Variables:**
```json
{
  "conditionId": "0x9881cf439292ce869cb3bc68b8c239d2192b33cffbe0cf576786faee953a0b97"
}
```

### Get Hourly Candles (For Charts)

```graphql
query GetHourlyPrices($conditionId: String!) {
  candles(
    where: { market: $conditionId }
    orderBy: timestamp
    orderDirection: desc
    first: 24
  ) {
    timestamp
    open    # First price of the hour
    high    # Highest price
    low     # Lowest price
    close   # Last price of the hour
    volume
    numTrades
  }
}
```

### Get Daily Candles

```graphql
query GetDailyPrices($conditionId: String!) {
  dailyCandles(
    where: { market: $conditionId }
    orderBy: timestamp
    orderDirection: desc
    first: 30
  ) {
    timestamp
    open
    high
    low
    close
    volume
  }
}
```

### Get Current Price

```graphql
query GetCurrentPrice($conditionId: String!) {
  market(id: $conditionId) {
    lastPrice      # Most recent trade price (tick 1-99)
    lastTradeAt    # When it happened
  }
}
```

## JavaScript Example

```javascript
const SUBGRAPH_URL = "https://subgraph.mantle.xyz/subgraphs/name/kombat-protocol/kombat-sepolia";

async function getPriceHistory(conditionId) {
  const query = `
    query GetPrices($id: String!) {
      trades(where: { market: $id }, orderBy: timestamp, orderDirection: asc) {
        tick
        quantity
        timestamp
      }
    }
  `;
  
  const response = await fetch(SUBGRAPH_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ 
      query, 
      variables: { id: conditionId.toLowerCase() } 
    })
  });
  
  const { data } = await response.json();
  
  // Convert to price array
  return data.trades.map(t => ({
    yesPrice: t.tick / 100,           // 50 -> 0.50
    noPrice: (100 - t.tick) / 100,    // 50 -> 0.50
    timestamp: new Date(t.timestamp * 1000)
  }));
}

// Usage
const history = await getPriceHistory("0x9881cf439292ce869cb3bc68b8c239d2192b33cffbe0cf576786faee953a0b97");
console.log(history);
// [
//   { yesPrice: 0.50, noPrice: 0.50, timestamp: 2025-01-12T... },
//   { yesPrice: 0.52, noPrice: 0.48, timestamp: 2025-01-12T... },
//   ...
// ]
```

## Quick Reference

| What You Want | Query |
|--------------|-------|
| All trades (raw) | `trades(where: { market: "0x..." })` |
| Hourly candles | `candles(where: { market: "0x..." })` |
| Daily candles | `dailyCandles(where: { market: "0x..." })` |
| Current price | `market(id: "0x...") { lastPrice }` |

The `conditionId` IS the market ID - the unique identifier from `ConditionalTokens.prepareCondition()`.

---

## Setup

```bash
cd mantle-subgraph

# Install dependencies
npm install

# Generate types from schema & ABI
npm run codegen

# Build
npm run build
```

## Deploy

1. Create account at https://subgraph.mantle.xyz/
2. Create a subgraph project
3. Get your deploy key

```bash
# Authenticate
graph auth --node https://subgraph.mantle.xyz/deploy <DEPLOY_KEY>

# Deploy
npm run deploy:sepolia
```

## Contracts

| Contract | Address (Sepolia) |
|----------|-------------------|
| PMExchange | `0x4acEaEeA1EbC1C4B86a3Efe4525Cd4F6443E0CCF` |

## Before Mainnet

Update `subgraph.yaml`:
1. Change `address` to mainnet PMExchange
2. Set `startBlock` to deployment block
3. Change `network` from `mantle-sepolia` to `mantle`

## Regenerate ABI

If PMExchange changes:
```bash
cd .. && forge inspect src/PMExchange.sol:PMExchange abi > mantle-subgraph/abis/PMExchange.json
```
