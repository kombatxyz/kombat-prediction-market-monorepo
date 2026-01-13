// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ConditionalTokens} from "./ConditionalTokens.sol";
import {PMExchange} from "./PMExchange.sol";
import {PMMultiMarketAdapter} from "./PMMultiMarketAdapter.sol";

/// @title Resolver
/// @notice This contract IS the oracle - it calls reportPayouts on ConditionalTokens
/// @dev Markets must be prepared with address(this) as the oracle
contract Resolver is Ownable {
    // ═══════════════════════════════════════════════════════════════════════════
    //                                 TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    enum ResolutionStatus {
        Pending,
        Resolved,
        Voided
    }

    struct Market {
        bytes32 questionId;
        uint48 endTime;
        uint256[] payouts;
        ResolutionStatus status;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 STATE
    // ═══════════════════════════════════════════════════════════════════════════

    ConditionalTokens public immutable conditionalTokens;
    PMExchange public immutable exchange;
    PMMultiMarketAdapter public immutable multiMarketAdapter;

    /// @notice questionId => Market info
    mapping(bytes32 => Market) public markets;

    /// @notice Authorized resolvers (can call resolve functions)
    mapping(address => bool) public authorizedResolvers;

    /// @notice Authorized factories (can call registerMarket)
    mapping(address => bool) public authorizedFactories;

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event MarketRegistered(bytes32 indexed questionId, uint48 endTime);
    event MarketResolved(bytes32 indexed questionId, uint256[] payouts, address resolver);
    event MarketVoided(bytes32 indexed questionId);
    event ResolverAuthorized(address indexed resolver, bool authorized);
    event FactoryAuthorized(address indexed factory, bool authorized);

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error MarketNotRegistered();
    error MarketAlreadyResolved();
    error NotAuthorizedResolver();
    error MarketNotEnded();
    error InvalidPayouts();

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(
        address _conditionalTokens,
        address _exchange,
        address _multiMarketAdapter
    ) Ownable(msg.sender) {
        conditionalTokens = ConditionalTokens(_conditionalTokens);
        exchange = PMExchange(_exchange);
        multiMarketAdapter = PMMultiMarketAdapter(_multiMarketAdapter);
        
        // Owner is authorized by default
        authorizedResolvers[msg.sender] = true;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Authorize or revoke a resolver
    function setAuthorizedResolver(address resolver, bool authorized) external onlyOwner {
        authorizedResolvers[resolver] = authorized;
        emit ResolverAuthorized(resolver, authorized);
    }

    /// @notice Authorize or revoke a factory
    function setAuthorizedFactory(address factory, bool authorized) external onlyOwner {
        authorizedFactories[factory] = authorized;
        emit FactoryAuthorized(factory, authorized);
    }

    /// @notice Register a market for resolution tracking
    /// @dev Can be called by owner or authorized factory
    function registerMarket(bytes32 questionId, uint48 endTime) external {
        require(msg.sender == owner() || authorizedFactories[msg.sender], "Not authorized");
        markets[questionId] = Market({
            questionId: questionId,
            endTime: endTime,
            payouts: new uint256[](2),
            status: ResolutionStatus.Pending
        });

        emit MarketRegistered(questionId, endTime);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          RESOLUTION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    modifier onlyResolver() {
        if (!authorizedResolvers[msg.sender] && msg.sender != owner()) {
            revert NotAuthorizedResolver();
        }
        _;
    }

    /// @notice Resolve a binary market: YES wins
    function resolveYes(bytes32 questionId) external onlyResolver {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1; // YES
        payouts[1] = 0; // NO
        _resolve(questionId, payouts);
    }

    /// @notice Resolve a binary market: NO wins
    function resolveNo(bytes32 questionId) external onlyResolver {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0; // YES
        payouts[1] = 1; // NO
        _resolve(questionId, payouts);
    }

    /// @notice Resolve with custom split (e.g., 50:50 for void)
    function resolveSplit(bytes32 questionId, uint256 yesPayout, uint256 noPayout) external onlyResolver {
        if (yesPayout == 0 && noPayout == 0) revert InvalidPayouts();
        
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = yesPayout;
        payouts[1] = noPayout;
        _resolve(questionId, payouts);
    }

    /// @notice Void a market (50:50 split)
    function voidMarket(bytes32 questionId) external onlyResolver {
        Market storage market = markets[questionId];
        if (market.status != ResolutionStatus.Pending) revert MarketAlreadyResolved();

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1; // 50%
        payouts[1] = 1; // 50%

        // This contract IS the oracle, so this works
        conditionalTokens.reportPayouts(questionId, payouts);

        // Sync exchange
        bytes32 conditionId = _getConditionId(questionId);
        try exchange.resolveMarket(conditionId) {} catch {}

        market.payouts = payouts;
        market.status = ResolutionStatus.Voided;

        emit MarketVoided(questionId);
    }

    /// @notice Resolve a multi-outcome market
    /// @dev For multi-outcome, this Resolver must be the authorizedResolver on PMMultiMarketAdapter
    function resolveMultiOutcome(bytes32 marketId, bytes32 winnerQuestionId) external onlyResolver {
        // PMMultiMarketAdapter handles the resolution
        multiMarketAdapter.reportOutcome(marketId, winnerQuestionId, true);
        
        emit MarketResolved(winnerQuestionId, new uint256[](0), msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function _resolve(bytes32 questionId, uint256[] memory payouts) internal {
        Market storage market = markets[questionId];
        
        if (market.questionId == bytes32(0)) revert MarketNotRegistered();
        if (market.status != ResolutionStatus.Pending) revert MarketAlreadyResolved();
        if (block.timestamp < market.endTime) revert MarketNotEnded();

        // This contract IS the oracle - msg.sender for reportPayouts
        conditionalTokens.reportPayouts(questionId, payouts);

        // Sync exchange status
        bytes32 conditionId = _getConditionId(questionId);
        try exchange.resolveMarket(conditionId) {} catch {}

        market.payouts = payouts;
        market.status = ResolutionStatus.Resolved;

        emit MarketResolved(questionId, payouts, msg.sender);
    }

    function _getConditionId(bytes32 questionId) internal view returns (bytes32) {
        // conditionId = keccak256(oracle, questionId, outcomeSlotCount)
        // oracle = address(this)
        return keccak256(abi.encodePacked(address(this), questionId, uint256(2)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                            VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get the conditionId for a questionId (this contract is oracle)
    function getConditionId(bytes32 questionId) external view returns (bytes32) {
        return _getConditionId(questionId);
    }

    /// @notice Get market resolution status
    function getMarketStatus(bytes32 questionId) external view returns (
        ResolutionStatus status,
        uint256[] memory payouts,
        uint48 endTime
    ) {
        Market storage market = markets[questionId];
        return (market.status, market.payouts, market.endTime);
    }

    /// @notice Check if a market is resolved
    function isResolved(bytes32 questionId) external view returns (bool) {
        return markets[questionId].status == ResolutionStatus.Resolved 
            || markets[questionId].status == ResolutionStatus.Voided;
    }
}