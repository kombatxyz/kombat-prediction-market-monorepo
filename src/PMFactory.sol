// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ConditionalTokens} from "./ConditionalTokens.sol";
import {PMExchange} from "./PMExchange.sol";
import {PMMultiMarketAdapter} from "./PMMultiMarketAdapter.sol";
import {Resolver} from "./Resolver.sol";

/// @title PMFactory
/// @notice Factory for creating prediction markets on the orderbook exchange
/// @dev Creates condition, registers on exchange, and registers on resolver in one tx
contract PMFactory {
    // ═══════════════════════════════════════════════════════════════════════════
    //                                 EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event MarketCreated(
        bytes32 indexed conditionId,
        bytes32 indexed questionId,
        address indexed creator,
        uint256 yesTokenId,
        uint256 noTokenId,
        uint48 endTime
    );

    event MultiOutcomeMarketCreated(
        bytes32 indexed marketId,
        address indexed resolver,
        uint8 outcomeCount,
        bytes32[] questionIds
    );

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAmount();
    error InvalidOracle();
    error MarketAlreadyExists();
    error InvalidOutcomeCount();

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 STATE
    // ═══════════════════════════════════════════════════════════════════════════

    ConditionalTokens public immutable conditionalTokens;
    PMExchange public immutable exchange;
    PMMultiMarketAdapter public immutable multiMarketAdapter;
    Resolver public immutable resolver;
    IERC20 public immutable collateral;

    /// @notice All created markets
    mapping(bytes32 => bool) public marketExists;

    /// @notice Multi-outcome markets
    mapping(bytes32 => bool) public multiOutcomeMarketExists;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(
        ConditionalTokens _conditionalTokens,
        PMExchange _exchange,
        PMMultiMarketAdapter _multiMarketAdapter,
        Resolver _resolver,
        IERC20 _collateral
    ) {
        conditionalTokens = _conditionalTokens;
        exchange = _exchange;
        multiMarketAdapter = _multiMarketAdapter;
        resolver = _resolver;
        collateral = _collateral;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           BINARY MARKET CREATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Create a new binary prediction market
    /// @dev Uses the Resolver as the oracle so markets can be resolved via Resolver contract
    /// @param questionId Unique question identifier (e.g., keccak256 of question text)
    /// @param endTime Market end timestamp
    /// @return conditionId The condition ID for the market
    function createMarket(
        bytes32 questionId,
        uint48 endTime
    ) external returns (bytes32 conditionId) {
        // Use the Resolver as the oracle - this allows resolution via Resolver contract
        address oracle = address(resolver);

        // 1. Prepare condition on ConditionalTokens
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);
        
        if (marketExists[conditionId]) revert MarketAlreadyExists();

        // Get token IDs
        bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        uint256 yesTokenId = conditionalTokens.getPositionId(collateral, yesCollectionId);
        uint256 noTokenId = conditionalTokens.getPositionId(collateral, noCollectionId);

        // 2. Register market on exchange (orderbook)
        exchange.registerMarket(conditionId, yesTokenId, noTokenId, endTime);

        // 3. Register on resolver for resolution tracking
        resolver.registerMarket(questionId, endTime);

        marketExists[conditionId] = true;

        emit MarketCreated(conditionId, questionId, msg.sender, yesTokenId, noTokenId, endTime);
    }

    /// @notice Create a new binary prediction market with custom oracle
    /// @param oracle The oracle address that will resolve the market (not using Resolver)
    /// @param questionId Unique question identifier
    /// @param endTime Market end timestamp
    /// @return conditionId The condition ID for the market
    function createMarketWithOracle(
        address oracle,
        bytes32 questionId,
        uint48 endTime
    ) external returns (bytes32 conditionId) {
        if (oracle == address(0)) revert InvalidOracle();

        // 1. Prepare condition on ConditionalTokens
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);
        
        if (marketExists[conditionId]) revert MarketAlreadyExists();

        // Get token IDs
        bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        uint256 yesTokenId = conditionalTokens.getPositionId(collateral, yesCollectionId);
        uint256 noTokenId = conditionalTokens.getPositionId(collateral, noCollectionId);

        // 2. Register market on exchange (orderbook)
        exchange.registerMarket(conditionId, yesTokenId, noTokenId, endTime);

        // Note: Not registering on resolver since custom oracle is used

        marketExists[conditionId] = true;

        emit MarketCreated(conditionId, questionId, msg.sender, yesTokenId, noTokenId, endTime);
    }

    /// @notice Create market and seed with initial liquidity on orderbook
    /// @param questionId Question identifier
    /// @param endTime Market end timestamp
    /// @param liquidity Amount of collateral to seed orderbook
    /// @param yesPrice Initial YES price (1-99 as tick, e.g., 50 = 50%)
    /// @return conditionId The condition ID
    function createMarketWithLiquidity(
        bytes32 questionId,
        uint48 endTime,
        uint256 liquidity,
        uint8 yesPrice
    ) external returns (bytes32 conditionId) {
        require(yesPrice >= 1 && yesPrice <= 99, "Invalid price");
        if (liquidity == 0) revert ZeroAmount();

        // Use the Resolver as the oracle
        address oracle = address(resolver);

        // 1. Prepare condition
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);
        
        if (marketExists[conditionId]) revert MarketAlreadyExists();

        // Get token IDs
        bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        uint256 yesTokenId = conditionalTokens.getPositionId(collateral, yesCollectionId);
        uint256 noTokenId = conditionalTokens.getPositionId(collateral, noCollectionId);

        // 2. Register on exchange
        exchange.registerMarket(conditionId, yesTokenId, noTokenId, endTime);

        // 3. Register on resolver
        resolver.registerMarket(questionId, endTime);

        // 4. Seed orderbook with limit orders
        // Pull collateral and split into YES + NO tokens
        collateral.transferFrom(msg.sender, address(this), liquidity);
        collateral.approve(address(conditionalTokens), liquidity);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        conditionalTokens.splitPosition(collateral, bytes32(0), conditionId, partition, liquidity);

        // Approve exchange
        conditionalTokens.setApprovalForAll(address(exchange), true);

        // Place sell orders (provide liquidity on both sides)
        // SellYes at yesPrice tick
        exchange.placeOrder(conditionId, PMExchange.Side.SellYes, yesPrice, uint128(liquidity), PMExchange.TiF.GTC);
        // SellNo at noPrice tick (100 - yesPrice)
        exchange.placeOrder(conditionId, PMExchange.Side.SellNo, 100 - yesPrice, uint128(liquidity), PMExchange.TiF.GTC);

        marketExists[conditionId] = true;

        emit MarketCreated(conditionId, questionId, msg.sender, yesTokenId, noTokenId, endTime);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       MULTI-OUTCOME MARKET CREATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Create a multi-outcome market
    /// @dev Creates N binary conditions linked via PMMultiMarketAdapter
    /// @param marketId Unique identifier for the multi-outcome market
    /// @param questionIds Array of question IDs (one per outcome)
    /// @param endTime Market end timestamp
    /// @param registerOnExchange Whether to also register each binary pair on exchange
    function createMultiOutcomeMarket(
        bytes32 marketId,
        bytes32[] calldata questionIds,
        uint48 endTime,
        bool registerOnExchange
    ) external {
        if (questionIds.length < 2) revert InvalidOutcomeCount();
        if (multiOutcomeMarketExists[marketId]) revert MarketAlreadyExists();

        // Use Resolver as the authorized resolver for the multi-outcome market
        address resolverAddr = address(resolver);

        // 1. Prepare conditions for each outcome
        // NOTE: PMMultiMarketAdapter is the oracle for all conditions (enables conversion)
        for (uint256 i = 0; i < questionIds.length; i++) {
            conditionalTokens.prepareCondition(address(multiMarketAdapter), questionIds[i], 2);
        }

        // 2. Register with PMMultiMarketAdapter (links all outcomes together)
        multiMarketAdapter.registerMarket(marketId, resolverAddr, questionIds);

        // 3. Optionally register each binary pair on exchange for orderbook trading
        if (registerOnExchange) {
            IERC20 wCollateral = IERC20(address(multiMarketAdapter.wrappedCollateral()));
            
            for (uint256 i = 0; i < questionIds.length; i++) {
                bytes32 conditionId = _getConditionId(address(multiMarketAdapter), questionIds[i]);

                bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
                bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);

                uint256 yesTokenId = conditionalTokens.getPositionId(wCollateral, yesCollectionId);
                uint256 noTokenId = conditionalTokens.getPositionId(wCollateral, noCollectionId);

                exchange.registerMarket(conditionId, yesTokenId, noTokenId, endTime);
            }
        }

        multiOutcomeMarketExists[marketId] = true;

        emit MultiOutcomeMarketCreated(marketId, resolverAddr, uint8(questionIds.length), questionIds);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                            VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get condition ID for a question (helper)
    function getConditionId(address oracle, bytes32 questionId) external pure returns (bytes32) {
        return _getConditionId(oracle, questionId);
    }

    /// @notice Get condition ID using the resolver as oracle
    function getConditionIdForResolver(bytes32 questionId) external view returns (bytes32) {
        return _getConditionId(address(resolver), questionId);
    }

    function _getConditionId(address oracle, bytes32 questionId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(oracle, questionId, uint256(2)));
    }

    /// @notice Get market token IDs
    function getTokenIds(bytes32 conditionId) external view returns (uint256 yesTokenId, uint256 noTokenId) {
        bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(collateral, yesCollectionId);
        noTokenId = conditionalTokens.getPositionId(collateral, noCollectionId);
    }

    /// @notice Get market info from exchange
    function getMarketInfo(bytes32 conditionId)
        external
        view
        returns (
            bool exists,
            uint256 yesTokenId,
            uint256 noTokenId,
            uint8 bestBidTick,
            uint8 bestAskTick
        )
    {
        exists = marketExists[conditionId];
        if (!exists) return (exists, 0, 0, 0, 0);

        (yesTokenId, noTokenId) = exchange.getTokenIds(conditionId);
        (bestBidTick,) = exchange.getBestBid(conditionId);
        (bestAskTick,) = exchange.getBestAsk(conditionId);
    }

    /// @notice Check if a market is resolved
    function isResolved(bytes32 questionId) external view returns (bool) {
        return resolver.isResolved(questionId);
    }
}
