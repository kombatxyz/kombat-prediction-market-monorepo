const { ethers } = require('ethers');

// ABIs for deployed contracts
const CONDITIONAL_TOKENS_ABI = [
	'function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external returns (bytes32)',
	'function reportPayouts(bytes32 questionId, uint256[] payouts) external',
	'function balanceOf(address owner, uint256 tokenId) external view returns (uint256)',
	'function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet) external pure returns (bytes32)',
	'function getPositionId(address collateralToken, bytes32 collectionId) external pure returns (uint256)'
];

const PM_EXCHANGE_ABI = [
	// Admin
	'function registerMarket(bytes32 conditionId, uint256 yesTokenId, uint256 noTokenId, uint48 endTime) external',
	'function toggleMarketPause(bytes32 conditionId) external',
	'function resolveMarket(bytes32 conditionId) external',

	// View functions
	'function getTokenIds(bytes32 conditionId) external view returns (uint256 yesTokenId, uint256 noTokenId)',
	'function getBestBid(bytes32 conditionId) external view returns (uint8 tick, uint128 size)',
	'function getBestAsk(bytes32 conditionId) external view returns (uint8 tick, uint128 size)',
	'function getSpread(bytes32 conditionId) external view returns (uint8 bidTick, uint8 askTick, uint8 spreadTicks)',
	'function getOrderBookDepth(bytes32 conditionId, uint8 depth) external view returns (uint8[] bidTicks, uint128[] bidSizes, uint8[] askTicks, uint128[] askSizes)',
	'function getNoBookDepth(bytes32 conditionId, uint8 depth) external view returns (uint8[] bidTicks, uint128[] bidSizes, uint8[] askTicks, uint128[] askSizes)',
	'function getMarketSummary(bytes32 conditionId) external view returns (tuple(uint256 yesTokenId, uint256 noTokenId, bool registered, bool paused, uint8 bestBidTick, uint128 bestBidSize, uint8 bestAskTick, uint128 bestAskSize, uint8 midPriceTick, uint8 spreadTicks, uint256 yesPriceBps, uint256 noPriceBps))',
	'function getMarketPrices(bytes32 conditionId) external view returns (uint256 yesPrice, uint256 noPrice, uint256 spreadBps)',
	'function getMidPrice(bytes32 conditionId) external view returns (uint8 midTick, bool hasLiquidity)',
	'function estimateFill(bytes32 conditionId, uint8 side, uint128 quantity) external view returns (uint128 fillableAmount, uint256 avgPriceBps, uint256 totalCost)',
	'function getAllMarkets(uint256 offset, uint256 limit) external view returns (bytes32[] conditionIds, tuple(uint256 yesTokenId, uint256 noTokenId, bool registered, bool paused, uint8 bestBidTick, uint128 bestBidSize, uint8 bestAskTick, uint128 bestAskSize, uint8 midPriceTick, uint8 spreadTicks, uint256 yesPriceBps, uint256 noPriceBps)[] summaries)',
	'function getMarketCount() external view returns (uint256)',
	'function markets(bytes32) external view returns (uint256 yesTokenId, uint256 noTokenId, uint48 endTime, bool registered, bool paused, bool resolved)',

	// Events
	'event MarketRegistered(bytes32 indexed conditionId, uint256 yesTokenId, uint256 noTokenId)',
	'event MarketPauseToggled(bytes32 indexed conditionId, bool paused)'
];

let provider = null;
let signer = null;
let conditionalTokens = null;
let exchange = null;
let usdcAddress = null;

function initBlockchain() {
	const rpcUrl = process.env.RPC_URL;
	const privateKey = process.env.ADMIN_PRIVATE_KEY;
	const ctAddress = process.env.CONDITIONAL_TOKENS_ADDRESS;
	const exchangeAddress = process.env.PM_EXCHANGE_ADDRESS;
	usdcAddress = process.env.USDC_ADDRESS;

	if (!rpcUrl) {
		console.log('[Blockchain] RPC_URL not set - blockchain features disabled');
		return false;
	}

	try {
		provider = new ethers.JsonRpcProvider(rpcUrl);

		if (privateKey && privateKey !== '0x...') {
			signer = new ethers.Wallet(privateKey, provider);
			console.log('[Blockchain] Signer:', signer.address);
		}

		if (ctAddress && ctAddress !== '0x...') {
			conditionalTokens = new ethers.Contract(ctAddress, CONDITIONAL_TOKENS_ABI, signer || provider);
			console.log('[Blockchain] ConditionalTokens:', ctAddress);
		}

		if (exchangeAddress && exchangeAddress !== '0x...') {
			exchange = new ethers.Contract(exchangeAddress, PM_EXCHANGE_ABI, signer || provider);
			console.log('[Blockchain] PMExchange:', exchangeAddress);
		}

		return true;
	} catch (error) {
		console.log('[Blockchain] Init failed:', error.message);
		return false;
	}
}

// Generate a unique questionId from market data
function generateQuestionId(title, endTime) {
	return ethers.keccak256(
		ethers.solidityPacked(
			['string', 'uint256', 'uint256'],
			[title, endTime, Date.now()]
		)
	);
}

// Calculate conditionId (same formula as CT uses)
function getConditionId(oracle, questionId, outcomeSlotCount = 2) {
	return ethers.keccak256(
		ethers.solidityPacked(
			['address', 'bytes32', 'uint256'],
			[oracle, questionId, outcomeSlotCount]
		)
	);
}

// Calculate token IDs from conditionId
async function calculateTokenIds(conditionId) {
	// YES = indexSet 1, NO = indexSet 2
	const yesCollectionId = await conditionalTokens.getCollectionId(ethers.ZeroHash, conditionId, 1);
	const noCollectionId = await conditionalTokens.getCollectionId(ethers.ZeroHash, conditionId, 2);

	const yesTokenId = await conditionalTokens.getPositionId(usdcAddress, yesCollectionId);
	const noTokenId = await conditionalTokens.getPositionId(usdcAddress, noCollectionId);

	return { yesTokenId, noTokenId };
}

// Create a binary market directly using ConditionalTokens + PMExchange
async function createBinaryMarket(title, endTime) {
	if (!conditionalTokens || !exchange || !signer) {
		throw new Error('Blockchain not configured - check ADMIN_PRIVATE_KEY');
	}

	const endTimestamp = Math.floor(new Date(endTime).getTime() / 1000);
	const questionId = generateQuestionId(title, endTimestamp);

	// Oracle is the signer (admin) who can resolve
	const oracle = signer.address;

	// 1. Prepare condition on ConditionalTokens
	console.log('[Blockchain] Preparing condition...');
	const prepareTx = await conditionalTokens.prepareCondition(oracle, questionId, 2);
	await prepareTx.wait();

	// 2. Calculate conditionId and token IDs
	const conditionId = getConditionId(oracle, questionId, 2);
	const { yesTokenId, noTokenId } = await calculateTokenIds(conditionId);

	console.log('[Blockchain] Condition prepared:', conditionId);
	console.log('[Blockchain] YES token:', yesTokenId.toString());
	console.log('[Blockchain] NO token:', noTokenId.toString());

	// 3. Register market on exchange
	console.log('[Blockchain] Registering on exchange...');
	const registerTx = await exchange.registerMarket(conditionId, yesTokenId, noTokenId, endTimestamp);
	const receipt = await registerTx.wait();

	console.log('[Blockchain] Market registered!');

	return {
		conditionId,
		questionId,
		yesTokenId: yesTokenId.toString(),
		noTokenId: noTokenId.toString(),
		txHash: receipt.hash
	};
}

// Resolve market - admin reports payouts
async function resolveMarket(questionId, yesWins) {
	if (!conditionalTokens || !signer) {
		throw new Error('Blockchain not configured');
	}

	console.log('[Blockchain] Resolving market:', questionId, yesWins ? 'YES wins' : 'NO wins');
	const payouts = yesWins ? [1, 0] : [0, 1];
	const tx = await conditionalTokens.reportPayouts(questionId, payouts);
	const receipt = await tx.wait();

	console.log('[Blockchain] Market resolved, tx:', receipt.hash);
	return { txHash: receipt.hash };
}

// Pause/unpause market on exchange
async function pauseMarket(conditionId) {
	if (!exchange || !signer) {
		throw new Error('Blockchain not configured');
	}

	console.log('[Blockchain] Toggling market pause:', conditionId);
	const tx = await exchange.toggleMarketPause(conditionId);
	const receipt = await tx.wait();
	console.log('[Blockchain] Market pause toggled, tx:', receipt.hash);

	return { txHash: receipt.hash };
}

// Get market summary from the exchange
async function getMarketSummary(conditionId) {
	if (!exchange) {
		return null;
	}

	try {
		const summary = await exchange.getMarketSummary(conditionId);
		return {
			yesTokenId: summary.yesTokenId.toString(),
			noTokenId: summary.noTokenId.toString(),
			registered: summary.registered,
			paused: summary.paused,
			bestBidTick: Number(summary.bestBidTick),
			bestBidSize: summary.bestBidSize.toString(),
			bestAskTick: Number(summary.bestAskTick),
			bestAskSize: summary.bestAskSize.toString(),
			midPriceTick: Number(summary.midPriceTick),
			spreadTicks: Number(summary.spreadTicks),
			yesPriceBps: Number(summary.yesPriceBps),
			noPriceBps: Number(summary.noPriceBps)
		};
	} catch (error) {
		console.error('[Blockchain] getMarketSummary error:', error.message);
		return null;
	}
}

// Get on-chain market count
async function getOnChainMarketCount() {
	if (!exchange) return 0;
	try {
		const count = await exchange.getMarketCount();
		return Number(count);
	} catch {
		return 0;
	}
}

// Get all on-chain markets
async function getOnChainMarkets(offset = 0, limit = 50) {
	if (!exchange) return { conditionIds: [], summaries: [] };
	try {
		const result = await exchange.getAllMarkets(offset, limit);
		return {
			conditionIds: result.conditionIds,
			summaries: result.summaries.map(s => ({
				yesTokenId: s.yesTokenId.toString(),
				noTokenId: s.noTokenId.toString(),
				registered: s.registered,
				paused: s.paused,
				bestBidTick: Number(s.bestBidTick),
				bestBidSize: s.bestBidSize.toString(),
				bestAskTick: Number(s.bestAskTick),
				bestAskSize: s.bestAskSize.toString(),
				midPriceTick: Number(s.midPriceTick),
				spreadTicks: Number(s.spreadTicks),
				yesPriceBps: Number(s.yesPriceBps),
				noPriceBps: Number(s.noPriceBps)
			}))
		};
	} catch (error) {
		console.error('[Blockchain] getOnChainMarkets error:', error.message);
		return { conditionIds: [], summaries: [] };
	}
}

function getExchangeAddress() {
	return process.env.PM_EXCHANGE_ADDRESS;
}

function getExchangeContract() {
	return exchange;
}

function getProvider() {
	return provider;
}

function isBlockchainReady() {
	return !!(conditionalTokens && exchange && signer);
}

module.exports = {
	initBlockchain,
	createBinaryMarket,
	resolveMarket,
	pauseMarket,
	getMarketSummary,
	getOnChainMarketCount,
	getOnChainMarkets,
	getExchangeAddress,
	getExchangeContract,
	getProvider,
	isBlockchainReady,
	generateQuestionId,
	getConditionId
};
