const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { getMarkets, getMarket, insertMarket, updateMarket, deleteMarket, getTags, addTag, getOptions, addOption, saveDb } = require('../db/database');
const { upload, uploadImage } = require('../services/storage');
const { createBinaryMarket, isBlockchainReady, pauseMarket } = require('../services/blockchain');

const router = express.Router();

// Format market for API response
async function formatMarketResponse(row) {
	if (!row) return null;

	const market = {
		id: row.id,
		marketId: row.market_id,
		conditionId: row.condition_id,
		questionId: row.question_id,
		title: row.title,
		description: row.description,
		type: row.type,
		category: row.category,
		imageUrl: row.image_url,
		endTime: row.end_time,
		endTimeISO: row.end_time ? new Date(row.end_time * 1000).toISOString() : null,
		volume: row.volume,
		liquidity: row.liquidity,
		status: row.status,
		outcome: row.outcome,
		yesTokenId: row.yes_token_id,
		noTokenId: row.no_token_id,
		creatorAddress: row.creator_address,
		createdAt: row.created_at
	};

	// Get tags
	try {
		market.tags = await getTags(row.market_id);
	} catch {
		market.tags = [];
	}

	// Get options for multi-outcome
	if (row.type === 'multi') {
		try {
			const options = await getOptions(row.market_id);
			market.options = options.map(opt => ({
				index: opt.option_index,
				name: opt.name,
				shortName: opt.short_name,
				imageUrl: opt.image_url,
				probability: opt.probability,
				conditionId: opt.condition_id,
				exchangeAddress: opt.exchange_address,
				yesTokenId: opt.yes_token_id,
				noTokenId: opt.no_token_id,
				isWinner: opt.is_winner === 1
			}));
		} catch {
			market.options = [];
		}
	}

	return market;
}

// GET /api/markets - List markets
router.get('/', async (req, res) => {
	try {
		const { category, status = 'active', type, limit = 50, offset = 0 } = req.query;

		const rows = await getMarkets({
			category,
			status,
			type,
			limit: Number(limit),
			offset: Number(offset)
		});

		const markets = await Promise.all(rows.map(formatMarketResponse));
		res.json({ markets, count: markets.length });
	} catch (error) {
		console.error('[Markets] List error:', error);
		res.status(500).json({ error: 'Failed to fetch markets' });
	}
});

// GET /api/markets/categories/all - must be before /:id
router.get('/categories/all', async (req, res) => {
	try {
		res.json([
			{ id: 'politics', name: 'Politics' },
			{ id: 'sports', name: 'Sports' },
			{ id: 'finance', name: 'Finance' },
			{ id: 'rwa', name: 'RWA' },
			{ id: 'elections', name: 'Elections' },
			{ id: 'crypto', name: 'Crypto' }
		]);
	} catch (error) {
		res.status(500).json({ error: 'Failed to fetch categories' });
	}
});

// GET /api/markets/:id - Get single market
router.get('/:id', async (req, res) => {
	try {
		const { id } = req.params;
		const row = await getMarket(id);

		if (!row) {
			return res.status(404).json({ error: 'Market not found' });
		}

		const market = await formatMarketResponse(row);
		res.json(market);
	} catch (error) {
		console.error('[Markets] Get error:', error);
		res.status(500).json({ error: 'Failed to fetch market' });
	}
});

// POST /api/markets - Create market (Admin)
router.post('/', upload.single('image'), async (req, res) => {
	try {
		const {
			title,
			description,
			type = 'binary',
			category,
			tags,
			endTime,
			options,
			deployToChain = 'false'
		} = req.body;

		if (!title) return res.status(400).json({ error: 'Title is required' });
		if (!category) return res.status(400).json({ error: 'Category is required' });
		if (!endTime) return res.status(400).json({ error: 'End time is required' });

		const marketId = uuidv4();
		const endTimestamp = Math.floor(new Date(endTime).getTime() / 1000);

		let imageUrl = null;
		if (req.file) {
			imageUrl = await uploadImage(req.file, 'markets');
		}

		let chainData = null;

		// Deploy to blockchain if requested
		if (deployToChain === 'true' && isBlockchainReady()) {
			try {
				if (type === 'binary') {
					chainData = await createBinaryMarket(title, endTime);
				}
			} catch (chainError) {
				console.error('[Markets] Chain deploy failed:', chainError.message);
			}
		}

		// Insert market
		await insertMarket({
			marketId,
			conditionId: chainData?.conditionId || null,
			questionId: chainData?.questionId || null,
			title,
			description: description || null,
			type,
			category,
			imageUrl,
			endTime: endTimestamp,
			yesTokenId: chainData?.yesTokenId || null,
			noTokenId: chainData?.noTokenId || null,
			creatorAddress: null
		});

		// Insert tags
		if (tags) {
			const tagList = typeof tags === 'string' ? JSON.parse(tags) : tags;
			for (const tag of tagList) {
				await addTag(marketId, tag);
			}
		}

		// Insert options for multi-outcome
		if (type === 'multi' && options) {
			const parsedOptions = JSON.parse(options);
			for (let i = 0; i < parsedOptions.length; i++) {
				const opt = parsedOptions[i];
				await addOption(marketId, {
					index: i,
					name: opt.name,
					shortName: opt.shortName || null,
					imageUrl: opt.imageUrl || null
				});
			}
		}

		const market = await getMarket(marketId);
		res.status(201).json(await formatMarketResponse(market));
	} catch (error) {
		console.error('[Markets] Create error:', error);
		res.status(500).json({ error: 'Failed to create market' });
	}
});

// PATCH /api/markets/:id - Update market
router.patch('/:id', upload.single('image'), async (req, res) => {
	try {
		const { id } = req.params;
		const updates = req.body;

		const existing = await getMarket(id);
		if (!existing) {
			return res.status(404).json({ error: 'Market not found' });
		}

		const marketId = existing.market_id;

		// Handle image upload
		if (req.file) {
			updates.imageUrl = await uploadImage(req.file, 'markets');
		}

		// Filter to allowed fields
		const allowedFields = ['title', 'description', 'category', 'imageUrl', 'status', 'outcome', 'volume', 'liquidity'];
		const filteredUpdates = {};
		for (const [key, value] of Object.entries(updates)) {
			if (allowedFields.includes(key)) {
				filteredUpdates[key] = value;
			}
		}

		if (Object.keys(filteredUpdates).length > 0) {
			await updateMarket(marketId, filteredUpdates);
		}

		const market = await getMarket(marketId);
		res.json(await formatMarketResponse(market));
	} catch (error) {
		console.error('[Markets] Update error:', error);
		res.status(500).json({ error: 'Failed to update market' });
	}
});

// DELETE /api/markets/:id
router.delete('/:id', async (req, res) => {
	try {
		const { id } = req.params;
		const existing = await getMarket(id);

		if (!existing) {
			return res.status(404).json({ error: 'Market not found' });
		}

		// Pause on-chain if market has conditionId and blockchain is ready
		if (existing.condition_id && isBlockchainReady()) {
			try {
				await pauseMarket(existing.condition_id);
				console.log('[Markets] Paused market on-chain:', existing.condition_id);
			} catch (chainError) {
				console.error('[Markets] Failed to pause on-chain:', chainError.message);
			}
		}

		await deleteMarket(existing.market_id);
		res.json({ message: 'Market deleted', paused: !!existing.condition_id });
	} catch (error) {
		console.error('[Markets] Delete error:', error);
		res.status(500).json({ error: 'Failed to delete market' });
	}
});

module.exports = router;
