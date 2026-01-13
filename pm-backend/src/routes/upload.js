const express = require('express');
const { upload, uploadImage } = require('../services/storage');
const { prepare, saveDb } = require('../db/database');

const router = express.Router();

// POST /api/upload/market/:id - Upload market image
router.post('/market/:id', upload.single('image'), async (req, res) => {
	try {
		const { id } = req.params;
		const market = prepare('SELECT market_id FROM markets WHERE id = ? OR market_id = ?').get(id, id);

		if (!market) {
			return res.status(404).json({ error: 'Market not found' });
		}

		if (!req.file) {
			return res.status(400).json({ error: 'No image provided' });
		}

		const imageUrl = await uploadImage(req.file, 'markets');
		prepare('UPDATE markets SET image_url = ? WHERE market_id = ?').run(imageUrl, market.market_id);
		saveDb();

		res.json({ imageUrl });
	} catch (error) {
		console.error('[Upload] Market image error:', error);
		res.status(500).json({ error: 'Failed to upload image' });
	}
});

// POST /api/upload/option/:marketId/:optionIndex - Upload option image
router.post('/option/:marketId/:optionIndex', upload.single('image'), async (req, res) => {
	try {
		const { marketId, optionIndex } = req.params;

		const option = prepare(`
      SELECT id FROM market_options 
      WHERE market_id = ? AND option_index = ?
    `).get(marketId, Number(optionIndex));

		if (!option) {
			return res.status(404).json({ error: 'Option not found' });
		}

		if (!req.file) {
			return res.status(400).json({ error: 'No image provided' });
		}

		const imageUrl = await uploadImage(req.file, 'options');
		prepare('UPDATE market_options SET image_url = ? WHERE id = ?').run(imageUrl, option.id);
		saveDb();

		res.json({ imageUrl, optionIndex: Number(optionIndex) });
	} catch (error) {
		console.error('[Upload] Option image error:', error);
		res.status(500).json({ error: 'Failed to upload image' });
	}
});

// POST /api/upload/options/:marketId - Upload multiple option images
router.post('/options/:marketId', upload.array('images', 10), async (req, res) => {
	try {
		const { marketId } = req.params;

		if (!req.files || req.files.length === 0) {
			return res.status(400).json({ error: 'No images provided' });
		}

		const results = [];
		for (let i = 0; i < req.files.length; i++) {
			const file = req.files[i];
			const imageUrl = await uploadImage(file, 'options');

			prepare(`
        UPDATE market_options SET image_url = ? 
        WHERE market_id = ? AND option_index = ?
      `).run(imageUrl, marketId, i);

			results.push({ optionIndex: i, imageUrl });
		}

		saveDb();
		res.json({ uploaded: results });
	} catch (error) {
		console.error('[Upload] Options images error:', error);
		res.status(500).json({ error: 'Failed to upload images' });
	}
});

module.exports = router;
