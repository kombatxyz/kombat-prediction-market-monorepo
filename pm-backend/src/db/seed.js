const { initDb, prepare, exec, saveDb } = require('./database');

const sampleMarkets = [
	{
		title: 'Will Bitcoin reach $100k by end of 2025?',
		description: 'Prediction on whether Bitcoin will hit the $100,000 price milestone before December 31, 2025.',
		type: 'binary',
		category: 'crypto',
		tags: ['Bitcoin', 'Price'],
		endTime: '2025-12-31T23:59:59Z'
	},
	{
		title: 'Who will win the 2024 US Presidential Election?',
		description: 'Multi-outcome market for the 2024 US Presidential Election.',
		type: 'multi',
		category: 'elections',
		tags: ['USA', 'Politics', '2024'],
		endTime: '2024-11-05T23:59:59Z',
		options: [
			{ name: 'Donald Trump', shortName: 'Trump', probability: 48 },
			{ name: 'Kamala Harris', shortName: 'Harris', probability: 45 },
			{ name: 'Other', shortName: 'Other', probability: 7 }
		]
	},
	{
		title: 'Manchester United vs Liverpool - Premier League',
		description: 'Match outcome prediction for the Premier League fixture.',
		type: 'multi',
		category: 'sports',
		tags: ['Football', 'Premier League'],
		endTime: '2025-03-15T15:00:00Z',
		options: [
			{ name: 'Manchester United', shortName: 'Man Utd', probability: 35 },
			{ name: 'Liverpool', shortName: 'Liverpool', probability: 45 },
			{ name: 'Draw', shortName: 'Draw', probability: 20 }
		]
	},
	{
		title: 'Will the Fed cut rates in Q1 2025?',
		description: 'Prediction on whether the Federal Reserve will announce a rate cut in Q1 2025.',
		type: 'binary',
		category: 'finance',
		tags: ['Fed', 'Interest Rates', 'Macro'],
		endTime: '2025-03-31T23:59:59Z'
	},
	{
		title: 'Will Ethereum reach $5000 in 2025?',
		description: 'Prediction on ETH price milestone.',
		type: 'binary',
		category: 'crypto',
		tags: ['Ethereum', 'Price'],
		endTime: '2025-12-31T23:59:59Z'
	},
	{
		title: 'Next UK Prime Minister after 2024 Election',
		description: 'Multi-outcome market for UK leadership.',
		type: 'multi',
		category: 'politics',
		tags: ['UK', 'Elections'],
		endTime: '2024-07-04T23:59:59Z',
		options: [
			{ name: 'Keir Starmer', shortName: 'Starmer', probability: 65 },
			{ name: 'Rishi Sunak', shortName: 'Sunak', probability: 30 },
			{ name: 'Other', shortName: 'Other', probability: 5 }
		]
	}
];

async function seed() {
	console.log('Seeding database...');

	await initDb();

	// Clear existing data
	exec('DELETE FROM market_options');
	exec('DELETE FROM market_tags');
	exec('DELETE FROM markets');

	for (const market of sampleMarkets) {
		const marketId = require('uuid').v4();
		const endTimestamp = Math.floor(new Date(market.endTime).getTime() / 1000);

		// Insert market
		prepare(`
      INSERT INTO markets (market_id, title, description, type, category, end_time, status)
      VALUES (?, ?, ?, ?, ?, ?, 'active')
    `).run(marketId, market.title, market.description, market.type, market.category, endTimestamp);

		// Insert tags
		for (const tag of market.tags || []) {
			prepare('INSERT INTO market_tags (market_id, tag) VALUES (?, ?)').run(marketId, tag);
		}

		// Insert options for multi-outcome
		if (market.options) {
			for (let i = 0; i < market.options.length; i++) {
				const opt = market.options[i];
				prepare(`
          INSERT INTO market_options (market_id, option_index, name, short_name, probability)
          VALUES (?, ?, ?, ?, ?)
        `).run(marketId, i, opt.name, opt.shortName || null, opt.probability || 0);
			}
		}

		console.log(`  Created: ${market.title}`);
	}

	saveDb();
	console.log(`\nSeeded ${sampleMarkets.length} markets`);
}

seed().catch(console.error);
