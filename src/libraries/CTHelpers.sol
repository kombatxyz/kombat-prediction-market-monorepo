//// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

library CTHelpers {
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        internal
        pure
        returns (bytes32)
    {
        bytes32 outcomeHash = keccak256(abi.encodePacked(conditionId, indexSet));

        if (parentCollectionId == bytes32(0)) {
            return outcomeHash;
        }

        return keccak256(abi.encodePacked(parentCollectionId, outcomeHash));
    }

    function getPositionId(IERC20 collateralToken, bytes32 collectionId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }
}
