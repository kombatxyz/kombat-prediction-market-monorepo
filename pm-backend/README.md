# PM Backend

Prediction Market Backend API with Admin Interface for the Kombat Protocol.

## Quick Start

### Local Development (Docker)

```bash
# Copy env and add your config
cp .env.example .env

# Start with Docker Compose
docker compose up --build
```

### Local Development (Node)

```bash
npm install
npm run seed    # Seed sample data
npm run dev     # Start with auto-reload
```

## URLs

- Admin Interface: http://localhost:3001/admin
- API: http://localhost:3001/api
- Health: http://localhost:3001/health

## API Endpoints

### Markets

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /api/markets | List markets (query: category, tag, status, type) |
| GET | /api/markets/:id | Get single market |
| POST | /api/markets | Create market (multipart form) |
| PATCH | /api/markets/:id | Update market |
| DELETE | /api/markets/:id | Delete market |
| GET | /api/markets/categories/all | List categories |

### Orderbook

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /api/orderbook/market/:marketId | Get YES/NO orderbook depth for a market |
| GET | /api/orderbook/summary/:conditionId | Get on-chain market summary |
| GET | /api/orderbook/prices/:conditionId | Get YES/NO prices |
| GET | /api/orderbook/estimate | Estimate fill for a trade |
| GET | /api/orderbook/:conditionId | Direct orderbook query |

### Create Market Request

```bash
curl -X POST http://localhost:3001/api/markets \
  -F "title=Will BTC reach 100k?" \
  -F "category=crypto" \
  -F "type=binary" \
  -F "endTime=2025-12-31T23:59:59Z" \
  -F "tags=[\"Bitcoin\",\"Price\"]" \
  -F "deployToChain=true" \
  -F "image=@./market.png"
```

### Multi-Outcome Market

```bash
curl -X POST http://localhost:3001/api/markets \
  -F "title=Who will win?" \
  -F "category=elections" \
  -F "type=multi" \
  -F "endTime=2024-11-05T23:59:59Z" \
  -F 'options=[{"name":"Trump"},{"name":"Harris"},{"name":"Other"}]' \
  -F "deployToChain=true"
```

## Market JSON Response

```json
{
  "id": 1,
  "marketId": "uuid",
  "conditionId": "0x...",
  "title": "Will BTC reach 100k?",
  "type": "binary",
  "category": "crypto",
  "tags": ["Bitcoin", "Price"],
  "endTime": 1735689600,
  "endTimeISO": "2025-12-31T23:59:59.000Z",
  "status": "active",
  "yesTokenId": "...",
  "noTokenId": "...",
  "options": [
    {
      "index": 0,
      "name": "Trump",
      "conditionId": "0x..."
    }
  ]
}
```

## Categories

- politics
- sports
- finance
- rwa
- elections
- crypto

## Environment Variables

| Variable | Description |
|----------|-------------|
| PORT | Server port (default: 3001) |
| DATABASE_PATH | SQLite path |
| GCS_BUCKET | Google Cloud Storage bucket |
| GCS_PROJECT_ID | GCP project ID |
| GOOGLE_APPLICATION_CREDENTIALS | Path to service account JSON |
| RPC_URL | Blockchain RPC URL |
| CONDITIONAL_TOKENS_ADDRESS | ConditionalTokens contract (src/ConditionalTokens.sol) |
| PM_EXCHANGE_ADDRESS | PMExchange contract (src/PMExchange.sol) |
| USDC_ADDRESS | USDC token address |
| PM_ROUTER_ADDRESS | PMExchangeRouter contract |
| PM_ADAPTER_ADDRESS | PMMultiMarketAdapter contract (src/PMMultiMarketAdapter.sol) |
| WUSDC_ADDRESS | Wrapped USDC for multi-market adapter |
| ADMIN_PRIVATE_KEY | Private key for transactions |

## Deployed Contracts (Mantle Sepolia)

| Contract | Address |
|----------|---------|
| ConditionalTokens | 0xFdA547973c86fd6F185eF6b50d5B3A6ecCE9FF8b |
| PMExchange | 0x4acEaEeA1EbC1C4B86a3Efe4525Cd4F6443E0CCF |
| TestNetUsdc | 0xDdB5BAFf948169775df9B0cd0d5aA067b8856c70 |
| PMExchangeRouter | 0xD2F13Ef8190A5A91B83EC75346940a3C61572C32 |
| PMMultiMarketAdapter | 0x6F3e6F69ca4992B12F3FDAc0d1ec366b57D6De48 |
| WUsdc | 0x58a0dD26ACb69E0067EEF082D9484BE5D8DF3214 |

## Deploy to Cloud Run

```bash
# Build and push
gcloud builds submit --tag gcr.io/PROJECT_ID/pm-backend

# Deploy
gcloud run deploy pm-backend \
  --image gcr.io/PROJECT_ID/pm-backend \
  --platform managed \
  --allow-unauthenticated \
  --set-env-vars "GCS_BUCKET=your-bucket,GCS_PROJECT_ID=your-project"
```
