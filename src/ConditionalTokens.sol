// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {CTHelpers} from "./libraries/CTHelpers.sol";

contract ConditionalTokens is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidAddress();
    error InvalidAmount();
    error TooManyOutcomes();
    error TooFewOutcomes();
    error ConditionAlreadyPrepared();
    error ConditionNotPrepared();
    error ConditionAlreadyResolved();
    error ConditionNotResolved();
    error InvalidPartition();
    error PartitionNotDisjoint();
    error InvalidIndexSet();
    error PayoutAllZeroes();
    error PayoutAlreadySet();

    event ConditionPreparation(
        bytes32 indexed conditionId, address indexed oracle, bytes32 indexed questionId, uint256 outcomeSlotCount
    );

    event ConditionResolution(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount,
        uint256[] payoutNumerators
    );

    event PositionSplit(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint256[] partition,
        uint256 amount
    );

    event PositionsMerge(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint256[] partition,
        uint256 amount
    );

    event PayoutRedemption(
        address indexed redeemer,
        IERC20 indexed collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 conditionId,
        uint256[] indexSets,
        uint256 payout
    );

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId, uint256 amount);

    event Approval(address indexed owner, address indexed spender, uint256 indexed tokenId, uint256 amount);

    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    mapping(bytes32 => uint256[]) public payoutNumerators;

    mapping(bytes32 => uint256) public payoutDenominator;

    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

    mapping(address => mapping(address => bool)) public isApprovedForAll;

    mapping(uint256 => uint256) public totalSupply;

    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        returns (bytes32 conditionId)
    {
        if (outcomeSlotCount > 256) revert TooManyOutcomes();
        if (outcomeSlotCount < 2) revert TooFewOutcomes();

        conditionId = CTHelpers.getConditionId(oracle, questionId, outcomeSlotCount);
        if (payoutNumerators[conditionId].length > 0) revert ConditionAlreadyPrepared();

        payoutNumerators[conditionId] = new uint256[](outcomeSlotCount);

        emit ConditionPreparation(conditionId, oracle, questionId, outcomeSlotCount);
    }

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external {
        uint256 outcomeSlotCount = payouts.length;
        if (outcomeSlotCount < 2) revert TooFewOutcomes();

        bytes32 conditionId = CTHelpers.getConditionId(msg.sender, questionId, outcomeSlotCount);

        if (payoutNumerators[conditionId].length != outcomeSlotCount) revert ConditionNotPrepared();
        if (payoutDenominator[conditionId] != 0) revert ConditionAlreadyResolved();

        uint256 den = 0;
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            uint256 num = payouts[i];
            den += num;

            if (payoutNumerators[conditionId][i] != 0) revert PayoutAlreadySet();
            payoutNumerators[conditionId][i] = num;
        }

        if (den == 0) revert PayoutAllZeroes();
        payoutDenominator[conditionId] = den;

        emit ConditionResolution(conditionId, msg.sender, questionId, outcomeSlotCount, payoutNumerators[conditionId]);
    }

    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external nonReentrant {
        if (partition.length < 2) revert InvalidPartition();
        if (amount == 0) revert InvalidAmount();

        uint256 outcomeSlotCount = payoutNumerators[conditionId].length;
        if (outcomeSlotCount == 0) revert ConditionNotPrepared();

        uint256 fullIndexSet = (1 << outcomeSlotCount) - 1;
        uint256 freeIndexSet = fullIndexSet;

        uint256[] memory positionIds = new uint256[](partition.length);
        for (uint256 i = 0; i < partition.length; i++) {
            uint256 indexSet = partition[i];
            if (indexSet == 0 || indexSet > fullIndexSet) revert InvalidIndexSet();
            if ((indexSet & freeIndexSet) != indexSet) revert PartitionNotDisjoint();

            freeIndexSet ^= indexSet;
            positionIds[i] = CTHelpers.getPositionId(
                collateralToken, CTHelpers.getCollectionId(parentCollectionId, conditionId, indexSet)
            );
        }

        if (freeIndexSet == 0) {
            if (parentCollectionId == bytes32(0)) {
                collateralToken.safeTransferFrom(msg.sender, address(this), amount);
            } else {
                uint256 parentPositionId = CTHelpers.getPositionId(collateralToken, parentCollectionId);
                _burn(msg.sender, parentPositionId, amount);
            }
        } else {
            uint256 sourcePositionId = CTHelpers.getPositionId(
                collateralToken, CTHelpers.getCollectionId(parentCollectionId, conditionId, fullIndexSet ^ freeIndexSet)
            );
            _burn(msg.sender, sourcePositionId, amount);
        }

        for (uint256 i = 0; i < partition.length; i++) {
            _mint(msg.sender, positionIds[i], amount);
        }

        emit PositionSplit(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external nonReentrant {
        if (partition.length < 2) revert InvalidPartition();
        if (amount == 0) revert InvalidAmount();

        uint256 outcomeSlotCount = payoutNumerators[conditionId].length;
        if (outcomeSlotCount == 0) revert ConditionNotPrepared();

        uint256 fullIndexSet = (1 << outcomeSlotCount) - 1;
        uint256 freeIndexSet = fullIndexSet;

        for (uint256 i = 0; i < partition.length; i++) {
            uint256 indexSet = partition[i];
            if (indexSet == 0 || indexSet > fullIndexSet) revert InvalidIndexSet();
            if ((indexSet & freeIndexSet) != indexSet) revert PartitionNotDisjoint();

            freeIndexSet ^= indexSet;
            uint256 positionId = CTHelpers.getPositionId(
                collateralToken, CTHelpers.getCollectionId(parentCollectionId, conditionId, indexSet)
            );
            _burn(msg.sender, positionId, amount);
        }

        if (freeIndexSet == 0) {
            if (parentCollectionId == bytes32(0)) {
                collateralToken.safeTransfer(msg.sender, amount);
            } else {
                uint256 parentPositionId = CTHelpers.getPositionId(collateralToken, parentCollectionId);
                _mint(msg.sender, parentPositionId, amount);
            }
        } else {
            uint256 destPositionId = CTHelpers.getPositionId(
                collateralToken, CTHelpers.getCollectionId(parentCollectionId, conditionId, fullIndexSet ^ freeIndexSet)
            );
            _mint(msg.sender, destPositionId, amount);
        }

        emit PositionsMerge(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external nonReentrant {
        uint256 den = payoutDenominator[conditionId];
        if (den == 0) revert ConditionNotResolved();

        uint256 outcomeSlotCount = payoutNumerators[conditionId].length;
        if (outcomeSlotCount == 0) revert ConditionNotPrepared();

        uint256 totalPayout = 0;
        uint256 fullIndexSet = (1 << outcomeSlotCount) - 1;

        for (uint256 i = 0; i < indexSets.length; i++) {
            uint256 indexSet = indexSets[i];
            if (indexSet == 0 || indexSet > fullIndexSet) revert InvalidIndexSet();

            uint256 positionId = CTHelpers.getPositionId(
                collateralToken, CTHelpers.getCollectionId(parentCollectionId, conditionId, indexSet)
            );

            uint256 payoutNumerator = 0;
            for (uint256 j = 0; j < outcomeSlotCount; j++) {
                if ((indexSet & (1 << j)) != 0) {
                    payoutNumerator += payoutNumerators[conditionId][j];
                }
            }

            uint256 payoutStake = balanceOf[msg.sender][positionId];
            if (payoutStake > 0) {
                totalPayout += (payoutStake * payoutNumerator) / den;
                _burn(msg.sender, positionId, payoutStake);
            }
        }

        if (totalPayout > 0) {
            if (parentCollectionId == bytes32(0)) {
                collateralToken.safeTransfer(msg.sender, totalPayout);
            } else {
                uint256 parentPositionId = CTHelpers.getPositionId(collateralToken, parentCollectionId);
                _mint(msg.sender, parentPositionId, totalPayout);
            }
        }

        emit PayoutRedemption(msg.sender, collateralToken, parentCollectionId, conditionId, indexSets, totalPayout);
    }

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return payoutNumerators[conditionId].length;
    }

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32)
    {
        return CTHelpers.getConditionId(oracle, questionId, outcomeSlotCount);
    }

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        pure
        returns (bytes32)
    {
        return CTHelpers.getCollectionId(parentCollectionId, conditionId, indexSet);
    }

    function getPositionId(IERC20 collateralToken, bytes32 collectionId) external pure returns (uint256) {
        return CTHelpers.getPositionId(collateralToken, collectionId);
    }

    function transfer(address to, uint256 tokenId, uint256 amount) external returns (bool) {
        if (to == address(0)) revert InvalidAddress();

        balanceOf[msg.sender][tokenId] -= amount;
        unchecked {
            balanceOf[to][tokenId] += amount;
        }
        emit Transfer(msg.sender, to, tokenId, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 tokenId, uint256 amount) external returns (bool) {
        if (to == address(0)) revert InvalidAddress();

        if (!isApprovedForAll[from][msg.sender]) {
            uint256 allowed = allowance[from][msg.sender][tokenId];
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender][tokenId] = allowed - amount;
            }
        }

        balanceOf[from][tokenId] -= amount;
        balanceOf[to][tokenId] += amount;
        emit Transfer(from, to, tokenId, amount);
        return true;
    }

    function approve(address spender, uint256 tokenId, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender][tokenId] = amount;
        emit Approval(msg.sender, spender, tokenId, amount);
        return true;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function _mint(address to, uint256 tokenId, uint256 amount) internal {
        balanceOf[to][tokenId] += amount;
        totalSupply[tokenId] += amount;
        emit Transfer(address(0), to, tokenId, amount);
    }

    function _burn(address from, uint256 tokenId, uint256 amount) internal {
        balanceOf[from][tokenId] -= amount;
        totalSupply[tokenId] -= amount;
        emit Transfer(from, address(0), tokenId, amount);
    }
}
