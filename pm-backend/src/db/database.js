const { Pool } = require('pg');

let pool = null;

async function initDb() {
	if (pool) return Promise.resolve();

	// Cloud SQL connection
	const connectionName = process.env.CLOUD_SQL_CONNECTION_NAME;
	const dbUser = process.env.DB_USER || 'postgres';
	const dbPass = process.env.DB_PASS;
	const dbName = process.env.DB_NAME || 'markets';

	if (connectionName) {
		// Running on App Engine with Cloud SQL
		pool = new Pool({
			user: dbUser,
			password: dbPass,
			database: dbName,
			host: `/cloudsql/${connectionName}`,
		});
	} else if (process.env.DATABASE_URL) {
		// Direct connection string
		pool = new Pool({ connectionString: process.env.DATABASE_URL });
	} else {
		// Local development - use SQLite fallback
		console.log('[DB] No PostgreSQL config, using SQLite');
		return initSqlite();
	}

	await createTables();
	console.log('[DB] PostgreSQL initialized');
}

async function createTables() {
	const client = await pool.connect();
	try {
		// Markets table
		await client.query(`
			CREATE TABLE IF NOT EXISTS markets (
				id SERIAL PRIMARY KEY,
				market_id TEXT UNIQUE,
				condition_id TEXT,
				question_id TEXT,
				title TEXT,
				description TEXT,
				type TEXT DEFAULT 'binary',
				category TEXT,
				image_url TEXT,
				end_time BIGINT,
				volume TEXT DEFAULT '0',
				liquidity TEXT DEFAULT '0',
				status TEXT DEFAULT 'active',
				outcome TEXT,
				yes_token_id TEXT,
				no_token_id TEXT,
				creator_address TEXT,
				created_at BIGINT
			)
		`);

		// Tags table
		await client.query(`
			CREATE TABLE IF NOT EXISTS market_tags (
				id SERIAL PRIMARY KEY,
				market_id TEXT,
				tag TEXT
			)
		`);

		// Options table for multi-outcome
		await client.query(`
			CREATE TABLE IF NOT EXISTS market_options (
				id SERIAL PRIMARY KEY,
				market_id TEXT,
				option_index INTEGER,
				name TEXT,
				short_name TEXT,
				image_url TEXT,
				probability REAL DEFAULT 0,
				condition_id TEXT,
				exchange_address TEXT,
				yes_token_id TEXT,
				no_token_id TEXT,
				is_winner INTEGER DEFAULT 0
			)
		`);
	} finally {
		client.release();
	}
}

// SQLite fallback for local development
let sqliteDb = null;
function initSqlite() {
	const initSqlJs = require('sql.js');
	const fs = require('fs');
	const path = require('path');

	return initSqlJs().then(SQL => {
		const dbPath = path.join(__dirname, '../../data/markets.db');
		try {
			const dataDir = path.dirname(dbPath);
			if (!fs.existsSync(dataDir)) {
				fs.mkdirSync(dataDir, { recursive: true });
			}
			if (fs.existsSync(dbPath)) {
				const buffer = fs.readFileSync(dbPath);
				sqliteDb = new SQL.Database(buffer);
			} else {
				sqliteDb = new SQL.Database();
			}
		} catch (e) {
			sqliteDb = new SQL.Database();
		}

		// Create tables
		sqliteDb.run(`
			CREATE TABLE IF NOT EXISTS markets (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				market_id TEXT UNIQUE,
				condition_id TEXT,
				question_id TEXT,
				title TEXT,
				description TEXT,
				type TEXT DEFAULT 'binary',
				category TEXT,
				image_url TEXT,
				end_time INTEGER,
				volume TEXT DEFAULT '0',
				liquidity TEXT DEFAULT '0',
				status TEXT DEFAULT 'active',
				outcome TEXT,
				yes_token_id TEXT,
				no_token_id TEXT,
				creator_address TEXT,
				created_at INTEGER
			)
		`);
		sqliteDb.run(`CREATE TABLE IF NOT EXISTS market_tags (id INTEGER PRIMARY KEY, market_id TEXT, tag TEXT)`);
		sqliteDb.run(`CREATE TABLE IF NOT EXISTS market_options (id INTEGER PRIMARY KEY, market_id TEXT, option_index INTEGER, name TEXT, short_name TEXT, image_url TEXT, probability REAL DEFAULT 0, condition_id TEXT, exchange_address TEXT, yes_token_id TEXT, no_token_id TEXT, is_winner INTEGER DEFAULT 0)`);

		console.log('[DB] SQLite initialized');
	});
}

// Prepare statement adapter - returns an object with .get(), .all(), .run() methods
function prepare(query) {
	return {
		get: (...params) => {
			if (sqliteDb) {
				const stmt = sqliteDb.prepare(query);
				params.forEach((p, i) => stmt.bind([p]));
				if (stmt.step()) {
					const row = stmt.getAsObject();
					stmt.free();
					return row;
				}
				stmt.free();
				return undefined;
			}
			// PostgreSQL synchronous fallback - not ideal but works
			throw new Error('Sync queries not supported with PostgreSQL');
		},
		all: (...params) => {
			if (sqliteDb) {
				const results = [];
				const stmt = sqliteDb.prepare(query);
				while (stmt.step()) {
					results.push(stmt.getAsObject());
				}
				stmt.free();
				// Filter by params manually (simplified)
				return results;
			}
			throw new Error('Sync queries not supported with PostgreSQL');
		},
		run: (...params) => {
			if (sqliteDb) {
				sqliteDb.run(query, params);
				return { lastInsertRowid: sqliteDb.exec("SELECT last_insert_rowid()")[0]?.values[0]?.[0] };
			}
			throw new Error('Sync queries not supported with PostgreSQL');
		}
	};
}

function saveDb() {
	if (sqliteDb) {
		const fs = require('fs');
		const path = require('path');
		const dbPath = path.join(__dirname, '../../data/markets.db');
		try {
			const data = sqliteDb.export();
			fs.writeFileSync(dbPath, Buffer.from(data));
			console.log('[DB] Saved');
		} catch (e) {
			console.log('[DB] Save failed:', e.message);
		}
	}
}

// Async query functions for PostgreSQL
async function query(text, params) {
	if (!pool) throw new Error('DB not initialized');
	return pool.query(text, params);
}

async function getMarkets(filters = {}) {
	if (sqliteDb) {
		// SQLite path
		let query = 'SELECT * FROM markets WHERE 1=1';
		if (filters.status) query += ` AND status = '${filters.status}'`;
		if (filters.category) query += ` AND category = '${filters.category}'`;
		if (filters.type) query += ` AND type = '${filters.type}'`;
		query += ' ORDER BY created_at DESC';
		if (filters.limit) query += ` LIMIT ${filters.limit}`;
		if (filters.offset) query += ` OFFSET ${filters.offset}`;

		const results = [];
		const stmt = sqliteDb.prepare(query);
		while (stmt.step()) {
			results.push(stmt.getAsObject());
		}
		stmt.free();
		return results;
	}

	// PostgreSQL
	let queryStr = 'SELECT * FROM markets WHERE 1=1';
	const params = [];
	let paramCount = 1;

	if (filters.status) {
		queryStr += ` AND status = $${paramCount}`;
		params.push(filters.status);
		paramCount++;
	}
	if (filters.category) {
		queryStr += ` AND category = $${paramCount}`;
		params.push(filters.category);
		paramCount++;
	}
	if (filters.type) {
		queryStr += ` AND type = $${paramCount}`;
		params.push(filters.type);
		paramCount++;
	}

	queryStr += ' ORDER BY created_at DESC';

	if (filters.limit) {
		queryStr += ` LIMIT $${paramCount}`;
		params.push(filters.limit);
		paramCount++;
	}
	if (filters.offset) {
		queryStr += ` OFFSET $${paramCount}`;
		params.push(filters.offset);
	}

	const result = await pool.query(queryStr, params);
	return result.rows;
}

async function getMarket(id) {
	if (sqliteDb) {
		const stmt = sqliteDb.prepare('SELECT * FROM markets WHERE id = ? OR market_id = ?');
		stmt.bind([id, id]);
		if (stmt.step()) {
			const row = stmt.getAsObject();
			stmt.free();
			return row;
		}
		stmt.free();
		return null;
	}

	// PostgreSQL: Check if id is numeric (for id column) or string (for market_id)
	const isNumeric = /^\d+$/.test(String(id));
	let result;
	if (isNumeric) {
		result = await pool.query('SELECT * FROM markets WHERE id = $1', [parseInt(id)]);
	} else {
		result = await pool.query('SELECT * FROM markets WHERE market_id = $1', [id]);
	}
	return result.rows[0] || null;
}

async function insertMarket(market) {
	const { marketId, conditionId, questionId, title, description, type, category, imageUrl, endTime, yesTokenId, noTokenId, creatorAddress } = market;
	const createdAt = Math.floor(Date.now() / 1000);

	if (sqliteDb) {
		sqliteDb.run(`
			INSERT INTO markets (market_id, condition_id, question_id, title, description, type, category, image_url, end_time, yes_token_id, no_token_id, creator_address, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		`, [marketId, conditionId, questionId, title, description, type, category, imageUrl, endTime, yesTokenId, noTokenId, creatorAddress, createdAt]);
		saveDb();
		return sqliteDb.exec("SELECT last_insert_rowid()")[0]?.values[0]?.[0];
	}

	const result = await pool.query(
		`INSERT INTO markets (market_id, condition_id, question_id, title, description, type, category, image_url, end_time, yes_token_id, no_token_id, creator_address, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
		 RETURNING id`,
		[marketId, conditionId, questionId, title, description, type, category, imageUrl, endTime, yesTokenId, noTokenId, creatorAddress, createdAt]
	);
	console.log('[DB] Saved');
	return result.rows[0].id;
}

async function updateMarket(marketId, updates) {
	if (sqliteDb) {
		const sets = Object.entries(updates).map(([k, v]) => {
			const col = k.replace(/([A-Z])/g, '_$1').toLowerCase();
			return `${col} = '${v}'`;
		}).join(', ');
		sqliteDb.run(`UPDATE markets SET ${sets} WHERE market_id = ?`, [marketId]);
		saveDb();
		return true;
	}

	const sets = [];
	const vals = [];
	let i = 1;
	for (const [k, v] of Object.entries(updates)) {
		const col = k.replace(/([A-Z])/g, '_$1').toLowerCase();
		sets.push(`${col} = $${i}`);
		vals.push(v);
		i++;
	}
	vals.push(marketId);
	await pool.query(`UPDATE markets SET ${sets.join(', ')} WHERE market_id = $${i}`, vals);
	console.log('[DB] Saved');
	return true;
}

async function deleteMarket(marketId) {
	if (sqliteDb) {
		sqliteDb.run('DELETE FROM markets WHERE market_id = ?', [marketId]);
		sqliteDb.run('DELETE FROM market_tags WHERE market_id = ?', [marketId]);
		sqliteDb.run('DELETE FROM market_options WHERE market_id = ?', [marketId]);
		saveDb();
		return true;
	}

	await pool.query('DELETE FROM market_tags WHERE market_id = $1', [marketId]);
	await pool.query('DELETE FROM market_options WHERE market_id = $1', [marketId]);
	const result = await pool.query('DELETE FROM markets WHERE market_id = $1', [marketId]);
	return result.rowCount > 0;
}

async function getTags(marketId) {
	if (sqliteDb) {
		const results = [];
		const stmt = sqliteDb.prepare('SELECT tag FROM market_tags WHERE market_id = ?');
		stmt.bind([marketId]);
		while (stmt.step()) results.push(stmt.getAsObject());
		stmt.free();
		return results.map(r => r.tag);
	}

	const result = await pool.query('SELECT tag FROM market_tags WHERE market_id = $1', [marketId]);
	return result.rows.map(r => r.tag);
}

async function addTag(marketId, tag) {
	if (sqliteDb) {
		sqliteDb.run('INSERT INTO market_tags (market_id, tag) VALUES (?, ?)', [marketId, tag]);
		saveDb();
		return;
	}
	await pool.query('INSERT INTO market_tags (market_id, tag) VALUES ($1, $2)', [marketId, tag]);
}

async function getOptions(marketId) {
	if (sqliteDb) {
		const results = [];
		const stmt = sqliteDb.prepare('SELECT * FROM market_options WHERE market_id = ? ORDER BY option_index');
		stmt.bind([marketId]);
		while (stmt.step()) results.push(stmt.getAsObject());
		stmt.free();
		return results;
	}

	const result = await pool.query('SELECT * FROM market_options WHERE market_id = $1 ORDER BY option_index', [marketId]);
	return result.rows;
}

async function addOption(marketId, option) {
	if (sqliteDb) {
		sqliteDb.run(`
			INSERT INTO market_options (market_id, option_index, name, short_name, image_url)
			VALUES (?, ?, ?, ?, ?)
		`, [marketId, option.index, option.name, option.shortName, option.imageUrl]);
		saveDb();
		return;
	}

	await pool.query(
		`INSERT INTO market_options (market_id, option_index, name, short_name, image_url) VALUES ($1, $2, $3, $4, $5)`,
		[marketId, option.index, option.name, option.shortName, option.imageUrl]
	);
}

module.exports = {
	initDb,
	prepare,
	saveDb,
	query,
	getMarkets,
	getMarket,
	insertMarket,
	updateMarket,
	deleteMarket,
	getTags,
	addTag,
	getOptions,
	addOption
};
