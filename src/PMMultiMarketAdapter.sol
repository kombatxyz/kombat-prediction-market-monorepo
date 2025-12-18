// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ConditionalTokens} from "./ConditionalTokens.sol";
import {WUsdc} from "./Wusdc.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract PMMultiMarketAdapter {
    ConditionalTokens public immutable conditionalTokens;
    IERC20 public immutable collateral;
    WrappedCollateral public immutable wrappedCollateral;

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
    error MarketNotRegistered();
    error InvalidIndexSet();

    constructor(address _conditionalTokens, address _collateral) Ownable(msg.sender) {
        conditionalTokens = ConditionalTokens(_conditionalTokens);
        collateral = IERC20(_collateral);
        wrappedCollateral = new WrappedCollateral(_collateral);
        wrappedCollateral.setAdapter(address(this));
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
}
