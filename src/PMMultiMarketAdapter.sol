// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ConditionalTokens} from "./ConditionalTokens.sol";
import {WUsdc} from "./WUsdc.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @notice Adapter for NegRisk style multi-outcome markets
 * @dev Enables position conversion with proper collateral accounting
 * NO_A + NO_B ≡ YES_C + (n-1) USDC (in payout space)
 */
contract PMMultiMarketAdapter is Ownable {
    ConditionalTokens public immutable conditionalTokens;
    IERC20 public immutable collateral;
    WUsdc public immutable wrappedCollateral;

    struct Market {
        bytes32[] questionIds;
        address authorizedResolver;
        uint8 questionCount;
        bool registered;
    }

    mapping(bytes32 => Market) public markets;

    mapping(bytes32 => bool) public resolved;

    mapping(bytes32 => mapping(bytes32 => uint256)) public adapterNOExposure;

    event MarketRegistered(bytes32 indexed marketId, uint8 questionCount);
    event PositionSplit(address indexed user, bytes32 indexed questionId, uint256 amount);
    event PositionMerged(address indexed user, bytes32 indexed questionId, uint256 amount);
    event PositionsConverted(
        address indexed user,
        bytes32 indexed marketId,
        uint256 noPositionsBurned,
        uint256 yesPositionsMinted,
        uint256 usdcReleased,
        uint256 amount
    );
    event OutcomeReported(bytes32 indexed marketId, bytes32 indexed questionId, bool yesWins);
    event PositionRedeemed(address indexed user, bytes32 indexed questionId, uint256 payout);

    error MarketNotRegistered();
    error InvalidIndexSet();
    error NoConvertiblePositions();
    error InsufficientBalance();
    error InsufficientWUSDC();
    error NotOracle();
    error MarketAlreadyResolved();

    constructor(address _conditionalTokens, address _collateral) Ownable(msg.sender) {
        conditionalTokens = ConditionalTokens(_conditionalTokens);
        collateral = IERC20(_collateral);

        // deploy WUsdc and set this contract as authorized adapter
        wrappedCollateral = new WUsdc(_collateral);
        wrappedCollateral.setAdapter(address(this));

        // Approve CT to spend wUSDC
        IERC20(address(wrappedCollateral)).approve(_conditionalTokens, type(uint256).max);
    }

    function registerMarket(bytes32 marketId, address authorizedResolver, bytes32[] calldata questionIds)
        external
        onlyOwner
    {
        require(questionIds.length >= 2, "Need at least 2 outcomes");
        require(authorizedResolver != address(0), "Invalid resolver");

        markets[marketId] = Market({
            questionIds: questionIds,
            authorizedResolver: authorizedResolver,
            questionCount: uint8(questionIds.length),
            registered: true
        });

        emit MarketRegistered(marketId, uint8(questionIds.length));
    }

    function getConditionId(address oracle, bytes32 questionId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(oracle, questionId, uint256(2)));
    }

    function getCollectionId(address oracle, bytes32 questionId, bool outcome) public pure returns (bytes32) {
        bytes32 conditionId = getConditionId(oracle, questionId);
        uint256 indexSet = outcome ? 1 : 2; // 0b01 for YES, 0b10 for NO

        // Match CTHelpers.getCollectionId formula
        return keccak256(abi.encodePacked(conditionId, indexSet));
    }

    function getPositionId(address oracle, bytes32 questionId, bool outcome) public view returns (uint256) {
        bytes32 collectionId = getCollectionId(oracle, questionId, outcome);

        // Match CTHelpers.getPositionId formula
        return uint256(keccak256(abi.encodePacked(address(wrappedCollateral), collectionId)));
    }

    function splitPosition(address oracle, bytes32 questionId, uint256 amount) external {
        if (resolved[questionId]) revert MarketAlreadyResolved();

        collateral.transferFrom(msg.sender, address(this), amount);

        collateral.approve(address(wrappedCollateral), amount);
        wrappedCollateral.wrap(address(this), amount);

        bytes32 conditionId = getConditionId(oracle, questionId);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1; // YES
        partition[1] = 2; // NO

        conditionalTokens.splitPosition(IERC20(address(wrappedCollateral)), bytes32(0), conditionId, partition, amount);

        // Transfer YES and NO tokens to user
        uint256 yesTokenId = getPositionId(oracle, questionId, true);
        uint256 noTokenId = getPositionId(oracle, questionId, false);

        conditionalTokens.transfer(msg.sender, yesTokenId, amount);
        conditionalTokens.transfer(msg.sender, noTokenId, amount);

        emit PositionSplit(msg.sender, questionId, amount);
    }

    function mergePositions(address oracle, bytes32 questionId, uint256 amount) external {
        uint256 yesTokenId = getPositionId(oracle, questionId, true);
        uint256 noTokenId = getPositionId(oracle, questionId, false);

        conditionalTokens.transferFrom(msg.sender, address(this), yesTokenId, amount);
        conditionalTokens.transferFrom(msg.sender, address(this), noTokenId, amount);

        bytes32 conditionId = getConditionId(oracle, questionId);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1; // YES
        partition[1] = 2; // NO

        conditionalTokens.mergePositions(IERC20(address(wrappedCollateral)), bytes32(0), conditionId, partition, amount);

        // Unwrap wUSDC to USDC
        wrappedCollateral.unwrap(msg.sender, amount);

        emit PositionMerged(msg.sender, questionId, amount);
    }

    function convertPositions(bytes32 marketId, uint256 indexSet, uint256 amount) external {
        Market storage market = markets[marketId];
        if (!market.registered) revert MarketNotRegistered();
        if (market.questionCount <= 1) revert NoConvertiblePositions();
        if (indexSet == 0) revert InvalidIndexSet();
        if (indexSet >= (1 << market.questionCount)) revert InvalidIndexSet();
        if (amount == 0) return;

        // Check no questions are resolved
        for (uint8 i = 0; i < market.questionCount; i++) {
            if (resolved[market.questionIds[i]]) revert MarketAlreadyResolved();
        }

        // Count and validate positions
        uint256 noPositionCount = _countPositions(market.questionCount, indexSet);
        if (noPositionCount == 0) revert InvalidIndexSet();
        if (noPositionCount == market.questionCount) revert InvalidIndexSet();
        if (market.questionCount - noPositionCount != 1) revert InvalidIndexSet();

        address ctOracle = address(this);

        _validateAndPullNO(market.questionIds, market.questionCount, ctOracle, indexSet, amount);

        _splitAndMergeNO(market.questionIds, market.questionCount, ctOracle, indexSet, amount, noPositionCount);

        _mintComplementYES(marketId, market.questionIds, market.questionCount, ctOracle, indexSet, amount);

        uint256 usdcToReturn = (noPositionCount - 1) * amount;
        if (usdcToReturn > 0) {
            wrappedCollateral.unwrap(msg.sender, usdcToReturn);
        }

        emit PositionsConverted(msg.sender, marketId, noPositionCount, 1, usdcToReturn, amount);
    }

    function _countPositions(uint8 questionCount, uint256 indexSet) internal pure returns (uint256) {
        uint256 count = 0;
        for (uint8 i = 0; i < questionCount; i++) {
            if ((indexSet & (1 << i)) > 0) count++;
        }
        return count;
    }

    function _validateAndPullNO(
        bytes32[] storage questionIds,
        uint8 questionCount,
        address oracle,
        uint256 indexSet,
        uint256 amount
    ) internal {
        for (uint8 i = 0; i < questionCount; i++) {
            if ((indexSet & (1 << i)) > 0) {
                uint256 noTokenId = getPositionId(oracle, questionIds[i], false);
                if (conditionalTokens.balanceOf(msg.sender, noTokenId) < amount) {
                    revert InsufficientBalance();
                }
                conditionalTokens.transferFrom(msg.sender, address(this), noTokenId, amount);
            }
        }
    }

    function _splitAndMergeNO(
        bytes32[] storage questionIds,
        uint8 questionCount,
        address oracle,
        uint256 indexSet,
        uint256 amount,
        uint256 noPositionCount
    ) internal {
        // Adapter must hold sufficient wUSDC from previous: splits, redeems, or deposits
        uint256 wusdcNeeded = noPositionCount * amount;
        uint256 wusdcBalance = IERC20(address(wrappedCollateral)).balanceOf(address(this));
        if (wusdcBalance < wusdcNeeded) revert InsufficientWUSDC();

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        for (uint8 i = 0; i < questionCount; i++) {
            if ((indexSet & (1 << i)) > 0) {
                bytes32 conditionId = getConditionId(oracle, questionIds[i]);

                // Split: wUSDC → YES + NO (temp NO becomes orphan)
                conditionalTokens.splitPosition(
                    IERC20(address(wrappedCollateral)), bytes32(0), conditionId, partition, amount
                );

                // Merge: user NO + temp YES → wUSDC (recovered)
                conditionalTokens.mergePositions(
                    IERC20(address(wrappedCollateral)), bytes32(0), conditionId, partition, amount
                );
            }
        }
    }

    function _mintComplementYES(
        bytes32 marketId,
        bytes32[] storage questionIds,
        uint8 questionCount,
        address oracle,
        uint256 indexSet,
        uint256 amount
    ) internal {
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        for (uint8 i = 0; i < questionCount; i++) {
            if ((indexSet & (1 << i)) == 0) {
                bytes32 qId = questionIds[i];
                bytes32 conditionId = getConditionId(oracle, qId);

                // Split ONCE: wUSDC → YES + NO
                conditionalTokens.splitPosition(
                    IERC20(address(wrappedCollateral)), bytes32(0), conditionId, partition, amount
                );

                // Give YES to user
                conditionalTokens.transfer(msg.sender, getPositionId(oracle, qId, true), amount);

                // TRACK orphan NO exposure per market/question
                adapterNOExposure[marketId][qId] += amount;
            }
        }
    }

    function reportOutcome(bytes32 marketId, bytes32 questionId, bool yesWins) external {
        Market storage market = markets[marketId];
        if (!market.registered) revert MarketNotRegistered();
        if (msg.sender != market.authorizedResolver) revert NotOracle();

        // Payout array: [YES, NO] with binary outcomes
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = yesWins ? 1 : 0; // YES payout
        payouts[1] = yesWins ? 0 : 1; // NO payout

        // Call CT reportPayouts (adapter is the oracle, CT builds conditionId from msg.sender)
        conditionalTokens.reportPayouts(questionId, payouts);

        // Mark as resolved to prevent future splits/conversions
        resolved[questionId] = true;

        emit OutcomeReported(marketId, questionId, yesWins);
    }

    function redeemPositions(address ctOracle, bytes32 questionId) external {
        bytes32 conditionId = getConditionId(ctOracle, questionId);

        // Build index sets for redemption [YES, NO]
        uint256[] memory indexSets = new uint256[](2);
        indexSets[0] = 1; // YES
        indexSets[1] = 2; // NO

        // Check balances before redemption
        uint256 yesTokenId = getPositionId(ctOracle, questionId, true);
        uint256 noTokenId = getPositionId(ctOracle, questionId, false);
        uint256 yesBal = conditionalTokens.balanceOf(msg.sender, yesTokenId);
        uint256 noBal = conditionalTokens.balanceOf(msg.sender, noTokenId);

        // Transfer tokens to adapter for redemption
        if (yesBal > 0) {
            conditionalTokens.transferFrom(msg.sender, address(this), yesTokenId, yesBal);
        }
        if (noBal > 0) {
            conditionalTokens.transferFrom(msg.sender, address(this), noTokenId, noBal);
        }

        // Get wUSDC balance before
        uint256 wusdcBefore = IERC20(address(wrappedCollateral)).balanceOf(address(this));

        // Redeem via CT (redeems to wUSDC)
        conditionalTokens.redeemPositions(IERC20(address(wrappedCollateral)), bytes32(0), conditionId, indexSets);

        // Calculate payout
        uint256 wusdcAfter = IERC20(address(wrappedCollateral)).balanceOf(address(this));
        uint256 payout = wusdcAfter - wusdcBefore;

        // Unwrap wUSDC to USDC and send to user
        if (payout > 0) {
            wrappedCollateral.unwrap(msg.sender, payout);
        }

        emit PositionRedeemed(msg.sender, questionId, payout);
    }

    function depositCollateral(uint256 amount) external {
        collateral.transferFrom(msg.sender, address(this), amount);
        collateral.approve(address(wrappedCollateral), amount);
        wrappedCollateral.wrap(address(this), amount);
    }

    function redeemAdapterNO(bytes32 marketId, bytes32 questionId) external onlyOwner {
        uint256 exposure = adapterNOExposure[marketId][questionId];
        if (exposure == 0) return;

        adapterNOExposure[marketId][questionId] = 0;

        bytes32 conditionId = getConditionId(address(this), questionId);
        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 2;

        conditionalTokens.redeemPositions(IERC20(address(wrappedCollateral)), bytes32(0), conditionId, indexSets);
    }

    /**
     * @notice Get adapter's wUSDC balance
     */
    function getWUSDCBalance() external view returns (uint256) {
        return IERC20(address(wrappedCollateral)).balanceOf(address(this));
    }
}
