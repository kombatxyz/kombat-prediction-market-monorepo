const express = require('express');
const { ethers } = require('ethers');
const { getExchangeContract, getExchangeAddress, getProvider, getMarketSummary } = require('../services/blockchain');

const router = express.Router();

// PMExchange ABI for orderbook operations
const PM_EXCHANGE_ABI = [
	'function getOrderBookDepth(bytes32 conditionId, uint8 depth) external view returns (uint8[] bidTicks, uint128[] bidSizes, uint8[] askTicks, uint128[] askSizes)',
	'function getNoBookDepth(bytes32 conditionId, uint8 depth) external view returns (uint8[] bidTicks, uint128[] bidSizes, uint8[] askTicks, uint128[] askSizes)',
	'function getBestBid(bytes32 conditionId) external view returns (uint8 tick, uint128 size)',
	'function getBestAsk(bytes32 conditionId) external view returns (uint8 tick, uint128 size)',
	'function getSpread(bytes32 conditionId) external view returns (uint8 bidTick, uint8 askTick, uint8 spreadTicks)',
	'function getMarketSummary(bytes32 conditionId) external view returns (tuple(uint256 yesTokenId, uint256 noTokenId, bool registered, bool paused, uint8 bestBidTick, uint128 bestBidSize, uint8 bestAskTick, uint128 bestAskSize, uint8 midPriceTick, uint8 spreadTicks, uint256 yesPriceBps, uint256 noPriceBps))',
	'function getMarketPrices(bytes32 conditionId) external view returns (uint256 yesPrice, uint256 noPrice, uint256 spreadBps)',
	'function estimateFill(bytes32 conditionId, uint8 side, uint128 quantity) external view returns (uint128 fillableAmount, uint256 avgPriceBps, uint256 totalCost)'
];

// Side enum from PMExchange
const Side = {
	BuyYes: 0,
	SellYes: 1,
	BuyNo: 2,
	SellNo: 3
};

// Helper to get exchange contract
function getExchange() {
	const provider = getProvider();
	const exchangeAddress = getExchangeAddress();
	if (!provider || !exchangeAddress || exchangeAddress === '0x...') {
		return null;
	}
	return new ethers.Contract(exchangeAddress, PM_EXCHANGE_ABI, provider);
}

// GET /api/orderbook/market/:marketId - Get depth for all options in a market
router.get('/market/:marketId', async (req, res) => {
	try {
		const { getMarket, getOptions } = require('../db/database');
		const { marketId } = req.params;
		const depth = parseInt(req.query.depth) || 10;

		// Get market info
		const market = await getMarket(marketId);
		if (!market) {
			return res.status(404).json({ error: 'Market not found' });
		}

		const result = {
			marketId,
			title: market.title,
			type: market.type,
			conditionId: market.condition_id,
			options: []
		};

		const exchange = getExchange();

		if (market.type === 'binary') {
			if (exchange && market.condition_id) {
				try {
					// Get YES orderbook depth
					const [bidTicks, bidSizes, askTicks, askSizes] = await exchange.getOrderBookDepth(market.condition_id, depth);

					const bids = bidTicks.map((tick, i) => ({
						tick: Number(tick),
						price: Number(tick), // tick 1-99 = $0.01-$0.99
						size: ethers.formatUnits(bidSizes[i], 6),
						total: parseFloat(ethers.formatUnits(bidSizes[i], 6)) * Number(tick) / 100
					})).filter(b => b.tick > 0);

					const asks = askTicks.map((tick, i) => ({
						tick: Number(tick),
						price: Number(tick),
						size: ethers.formatUnits(askSizes[i], 6),
						total: parseFloat(ethers.formatUnits(askSizes[i], 6)) * Number(tick) / 100
					})).filter(a => a.tick > 0);

					const bestBid = bids[0]?.price || 0;
					const bestAsk = asks[0]?.price || 100;

					result.options.push({
						name: 'YES',
						bestBid,
						bestAsk,
						spread: bestAsk - bestBid,
						midPrice: Math.round((bestBid + bestAsk) / 2),
						bids,
						asks
					});

					// Get NO orderbook depth
					const [noBidTicks, noBidSizes, noAskTicks, noAskSizes] = await exchange.getNoBookDepth(market.condition_id, depth);

					const noBids = noBidTicks.map((tick, i) => ({
						tick: Number(tick),
						price: Number(tick),
						size: ethers.formatUnits(noBidSizes[i], 6),
						total: parseFloat(ethers.formatUnits(noBidSizes[i], 6)) * Number(tick) / 100
					})).filter(b => b.tick > 0);

					const noAsks = noAskTicks.map((tick, i) => ({
						tick: Number(tick),
						price: Number(tick),
						size: ethers.formatUnits(noAskSizes[i], 6),
						total: parseFloat(ethers.formatUnits(noAskSizes[i], 6)) * Number(tick) / 100
					})).filter(a => a.tick > 0);

					const noBestBid = noBids[0]?.price || 0;
					const noBestAsk = noAsks[0]?.price || 100;

					result.options.push({
						name: 'NO',
						bestBid: noBestBid,
						bestAsk: noBestAsk,
						spread: noBestAsk - noBestBid,
						midPrice: Math.round((noBestBid + noBestAsk) / 2),
						bids: noBids,
						asks: noAsks
					});
				} catch (e) {
					console.error('[Orderbook] Contract call error:', e.message);
					// Return empty orderbook
					result.options.push({
						name: 'YES',
						bestBid: 0,
						bestAsk: 100,
						spread: 100,
						midPrice: 50,
						bids: [],
						asks: [],
						error: 'Failed to fetch on-chain data'
					});
				}
			} else {
				// No blockchain connection
				result.options.push({
					name: 'YES',
					bestBid: 0,
					bestAsk: 100,
					spread: 100,
					midPrice: 50,
					bids: [],
					asks: [],
					noBlockchain: true
				});
			}
		} else {
			// Multi-outcome market - each option has its own exchange
			const options = await getOptions(marketId);

			for (const opt of options) {
				if (exchange && opt.condition_id) {
					try {
						const [bidTicks, bidSizes, askTicks, askSizes] = await exchange.getOrderBookDepth(opt.condition_id, depth);

						const bids = bidTicks.map((tick, i) => ({
							tick: Number(tick),
							price: Number(tick),
							size: ethers.formatUnits(bidSizes[i], 6),
							total: parseFloat(ethers.formatUnits(bidSizes[i], 6)) * Number(tick) / 100
						})).filter(b => b.tick > 0);

						const asks = askTicks.map((tick, i) => ({
							tick: Number(tick),
							price: Number(tick),
							size: ethers.formatUnits(askSizes[i], 6),
							total: parseFloat(ethers.formatUnits(askSizes[i], 6)) * Number(tick) / 100
						})).filter(a => a.tick > 0);

						result.options.push({
							index: opt.option_index,
							name: opt.name,
							bestBid: bids[0]?.price || 0,
							bestAsk: asks[0]?.price || 100,
							spread: (asks[0]?.price || 100) - (bids[0]?.price || 0),
							midPrice: Math.round(((bids[0]?.price || 0) + (asks[0]?.price || 100)) / 2),
							bids,
							asks
						});
					} catch (e) {
						result.options.push({
							index: opt.option_index,
							name: opt.name,
							bestBid: 0,
							bestAsk: 100,
							spread: 100,
							midPrice: 50,
							bids: [],
							asks: [],
							error: e.message
						});
					}
				} else {
					result.options.push({
						index: opt.option_index,
						name: opt.name,
						bestBid: 0,
						bestAsk: 100,
						spread: 100,
						midPrice: 50,
						bids: [],
						asks: [],
						noBlockchain: true
					});
				}
			}
		}

		res.json(result);
	} catch (error) {
		console.error('[Orderbook] Market error:', error.message);
		res.status(500).json({ error: 'Failed to fetch market orderbook' });
	}
});

// GET /api/orderbook/summary/:conditionId - Get market summary from chain
router.get('/summary/:conditionId', async (req, res) => {
	try {
		const { conditionId } = req.params;
		const exchange = getExchange();

		if (!exchange) {
			return res.status(503).json({ error: 'Blockchain not configured' });
		}

		const summary = await exchange.getMarketSummary(conditionId);

		res.json({
			conditionId,
			yesTokenId: summary.yesTokenId.toString(),
			noTokenId: summary.noTokenId.toString(),
			registered: summary.registered,
			paused: summary.paused,
			bestBidTick: Number(summary.bestBidTick),
			bestBidSize: ethers.formatUnits(summary.bestBidSize, 6),
			bestAskTick: Number(summary.bestAskTick),
			bestAskSize: ethers.formatUnits(summary.bestAskSize, 6),
			midPriceTick: Number(summary.midPriceTick),
			spreadTicks: Number(summary.spreadTicks),
			yesPriceBps: Number(summary.yesPriceBps),
			noPriceBps: Number(summary.noPriceBps),
			// Friendly percentages
			yesPercent: Number(summary.yesPriceBps) / 100,
			noPercent: Number(summary.noPriceBps) / 100
		});
	} catch (error) {
		console.error('[Orderbook] Summary error:', error.message);
		res.status(500).json({ error: 'Failed to fetch market summary' });
	}
});

// GET /api/orderbook/estimate - Estimate fill for a trade
router.get('/estimate', async (req, res) => {
	try {
		const { conditionId, side, quantity } = req.query;

		if (!conditionId || side === undefined || !quantity) {
			return res.status(400).json({ error: 'Missing required params: conditionId, side, quantity' });
		}

		const exchange = getExchange();
		if (!exchange) {
			return res.status(503).json({ error: 'Blockchain not configured' });
		}

		const sideNum = parseInt(side);
		const qty = ethers.parseUnits(quantity, 6);

		const [fillableAmount, avgPriceBps, totalCost] = await exchange.estimateFill(conditionId, sideNum, qty);

		res.json({
			conditionId,
			side: ['BuyYes', 'SellYes', 'BuyNo', 'SellNo'][sideNum],
			requestedQuantity: quantity,
			fillableAmount: ethers.formatUnits(fillableAmount, 6),
			avgPriceBps: Number(avgPriceBps),
			avgPricePercent: Number(avgPriceBps) / 100,
			totalCost: ethers.formatUnits(totalCost, 18) // cost is in 1e18 format
		});
	} catch (error) {
		console.error('[Orderbook] Estimate error:', error.message);
		res.status(500).json({ error: 'Failed to estimate fill' });
	}
});

// GET /api/orderbook/prices/:conditionId - Get market prices
router.get('/prices/:conditionId', async (req, res) => {
	try {
		const { conditionId } = req.params;
		const exchange = getExchange();

		if (!exchange) {
			return res.status(503).json({ error: 'Blockchain not configured' });
		}

		const [yesPrice, noPrice, spreadBps] = await exchange.getMarketPrices(conditionId);

		res.json({
			conditionId,
			yesPriceBps: Number(yesPrice),
			noPriceBps: Number(noPrice),
			spreadBps: Number(spreadBps),
			// Friendly percentages
			yesPercent: Number(yesPrice) / 100,
			noPercent: Number(noPrice) / 100,
			spreadPercent: Number(spreadBps) / 100
		});
	} catch (error) {
		console.error('[Orderbook] Prices error:', error.message);
		res.status(500).json({ error: 'Failed to fetch market prices' });
	}
});

// GET /api/orderbook/:conditionId - Direct condition query (simplified)
router.get('/:conditionId', async (req, res) => {
	try {
		const { conditionId } = req.params;
		const depth = parseInt(req.query.depth) || 10;

		const exchange = getExchange();
		if (!exchange) {
			return res.status(503).json({ error: 'Blockchain not configured' });
		}

		// Get YES orderbook
		const [bidTicks, bidSizes, askTicks, askSizes] = await exchange.getOrderBookDepth(conditionId, depth);

		const bids = bidTicks.map((tick, i) => ({
			tick: Number(tick),
			size: ethers.formatUnits(bidSizes[i], 6)
		})).filter(b => b.tick > 0);

		const asks = askTicks.map((tick, i) => ({
			tick: Number(tick),
			size: ethers.formatUnits(askSizes[i], 6)
		})).filter(a => a.tick > 0);

		const bestBid = bids[0]?.tick || 0;
		const bestAsk = asks[0]?.tick || 100;

		res.json({
			conditionId,
			bestBid,
			bestAsk,
			spread: bestAsk - bestBid,
			midPrice: (bestBid + bestAsk) / 2,
			bids,
			asks
		});
	} catch (error) {
		console.error('[Orderbook] Error:', error.message);
		res.status(500).json({ error: 'Failed to fetch orderbook' });
	}
});

module.exports = router;
