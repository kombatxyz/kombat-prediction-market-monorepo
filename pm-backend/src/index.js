require('dotenv').config();

const express = require('express');
const cors = require('cors');
const path = require('path');

const { initDb } = require('./db/database');
const { initStorage } = require('./services/storage');
const { initBlockchain, isBlockchainReady } = require('./services/blockchain');
const marketsRouter = require('./routes/markets');
const uploadRouter = require('./routes/upload');
const orderbookRouter = require('./routes/orderbook');

const app = express();
const PORT = process.env.PORT || 3001;

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Static files
app.use('/uploads', express.static(path.join(__dirname, '../uploads')));
app.use(express.static(path.join(__dirname, '../public')));

// Routes
app.use('/api/markets', marketsRouter);
app.use('/api/upload', uploadRouter);
app.use('/api/orderbook', orderbookRouter);

// Admin interface
app.get('/admin', (req, res) => {
	res.sendFile(path.join(__dirname, '../public/admin.html'));
});

// API status
app.get('/api/status', (req, res) => {
	res.json({
		status: 'ok',
		timestamp: new Date().toISOString(),
		blockchain: isBlockchainReady(),
		network: {
			name: 'Mantle Sepolia',
			chainId: process.env.CHAIN_ID || '5003',
			rpcUrl: process.env.RPC_URL || null
		},
		contracts: {
			conditionalTokens: process.env.CONDITIONAL_TOKENS_ADDRESS || null,
			pmExchange: process.env.PM_EXCHANGE_ADDRESS || null,
			pmRouter: process.env.PM_ROUTER_ADDRESS || null,
			usdc: process.env.USDC_ADDRESS || null
		}
	});
});

// Health check
app.get('/health', (req, res) => {
	res.json({ status: 'ok' });
});

// API info
app.get('/api', (req, res) => {
	res.json({
		name: 'PM Backend API',
		version: '1.0.0',
		admin: '/admin',
		endpoints: {
			markets: {
				list: 'GET /api/markets',
				get: 'GET /api/markets/:id',
				create: 'POST /api/markets',
				update: 'PATCH /api/markets/:id',
				delete: 'DELETE /api/markets/:id',
				categories: 'GET /api/markets/categories/all'
			}
		}
	});
});

// Error handler
app.use((err, req, res, next) => {
	console.error('[Error]', err);
	res.status(500).json({ error: err.message || 'Internal server error' });
});

// Start server
async function start() {
	try {
		await initDb();
		console.log('[DB] Initialized');

		initStorage();
		initBlockchain();

		app.listen(PORT, () => {
			console.log('');
			console.log('='.repeat(50));
			console.log('  PM Backend API');
			console.log('='.repeat(50));
			console.log(`  Server:  http://localhost:${PORT}`);
			console.log(`  Admin:   http://localhost:${PORT}/admin`);
			console.log(`  API:     http://localhost:${PORT}/api`);
			console.log(`  Health:  http://localhost:${PORT}/health`);
			console.log('='.repeat(50));
			console.log('');
		});
	} catch (error) {
		console.error('[Startup] Failed:', error);
		process.exit(1);
	}
}

start();

module.exports = app;
