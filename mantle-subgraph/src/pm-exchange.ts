import { BigInt } from "@graphprotocol/graph-ts";
import {
  MarketRegistered,
  OrderMatched
} from "../generated/PMExchange/PMExchange";
import {
  Market,
  Trade,
  Candle,
  DailyCandle
} from "../generated/schema";

const HOUR = BigInt.fromI32(3600);
const DAY = BigInt.fromI32(86400);

// ═══════════════════════════════════════════════════════════════════════════════
//                            HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

function getOrCreateHourlyCandle(marketId: string, timestamp: BigInt, tick: i32): Candle {
  let hourTimestamp = timestamp.div(HOUR).times(HOUR);
  let id = marketId + "-" + hourTimestamp.toString();
  
  let candle = Candle.load(id);
  if (!candle) {
    candle = new Candle(id);
    candle.market = marketId;
    candle.timestamp = hourTimestamp;
    candle.open = tick;
    candle.high = tick;
    candle.low = tick;
    candle.close = tick;
    candle.volume = BigInt.fromI32(0);
    candle.numTrades = 0;
  }
  return candle;
}

function getOrCreateDailyCandle(marketId: string, timestamp: BigInt, tick: i32): DailyCandle {
  let dayTimestamp = timestamp.div(DAY).times(DAY);
  let id = marketId + "-" + dayTimestamp.toString();
  
  let candle = DailyCandle.load(id);
  if (!candle) {
    candle = new DailyCandle(id);
    candle.market = marketId;
    candle.timestamp = dayTimestamp;
    candle.open = tick;
    candle.high = tick;
    candle.low = tick;
    candle.close = tick;
    candle.volume = BigInt.fromI32(0);
    candle.numTrades = 0;
  }
  return candle;
}

// ═══════════════════════════════════════════════════════════════════════════════
//                            EVENT HANDLERS
// ═══════════════════════════════════════════════════════════════════════════════

export function handleMarketRegistered(event: MarketRegistered): void {
  let id = event.params.conditionId.toHexString();
  
  let market = new Market(id);
  market.conditionId = event.params.conditionId;
  market.yesTokenId = event.params.yesTokenId;
  market.noTokenId = event.params.noTokenId;
  market.registered = true;
  market.lastPrice = 50; // Default to 50% ($0.50)
  market.createdAt = event.block.timestamp;
  market.save();
}

export function handleOrderMatched(event: OrderMatched): void {
  let marketId = event.params.conditionId.toHexString();
  let market = Market.load(marketId);
  
  if (!market) {
    // Market should exist, but handle gracefully
    return;
  }
  
  let tick = event.params.tick;
  let quantity = event.params.quantity;
  let volume = quantity.times(BigInt.fromI32(tick)).div(BigInt.fromI32(100));
  
  // Create trade record
  let tradeId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let trade = new Trade(tradeId);
  trade.market = marketId;
  trade.tick = tick;
  trade.quantity = quantity;
  trade.volume = volume;
  trade.timestamp = event.block.timestamp;
  trade.blockNumber = event.block.number;
  trade.transactionHash = event.transaction.hash;
  trade.save();
  
  // Update market last price
  market.lastPrice = tick;
  market.lastTradeAt = event.block.timestamp;
  market.save();
  
  // Update hourly candle
  let hourlyCandle = getOrCreateHourlyCandle(marketId, event.block.timestamp, tick);
  if (tick > hourlyCandle.high) hourlyCandle.high = tick;
  if (tick < hourlyCandle.low) hourlyCandle.low = tick;
  hourlyCandle.close = tick;
  hourlyCandle.volume = hourlyCandle.volume.plus(volume);
  hourlyCandle.numTrades = hourlyCandle.numTrades + 1;
  hourlyCandle.save();
  
  // Update daily candle
  let dailyCandle = getOrCreateDailyCandle(marketId, event.block.timestamp, tick);
  if (tick > dailyCandle.high) dailyCandle.high = tick;
  if (tick < dailyCandle.low) dailyCandle.low = tick;
  dailyCandle.close = tick;
  dailyCandle.volume = dailyCandle.volume.plus(volume);
  dailyCandle.numTrades = dailyCandle.numTrades + 1;
  dailyCandle.save();
}
