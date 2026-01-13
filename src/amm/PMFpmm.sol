// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ERC6909} from "lib/solady/src/tokens/ERC6909.sol";
import {ConditionalTokens} from "../ConditionalTokens.sol";

/// @notice Uniswap V4-style singleton FPMM with ERC6909 LP tokens (using Solady)
/// @dev One contract manages all pools. Each pool is identified by poolId.
///      LP tokens use ERC6909 multi-token standard (poolId = tokenId).
contract PMFpmm is ERC6909, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAmount();
    error InvalidOutcomeIndex();
    error InsufficientBuyAmount();
    error ExcessiveSellAmount();
    error MustHaveNonZeroBalances();
    error InvalidDistributionHint();
    error HintNotAllowedAfterInit();
    error PoolNotInitialized();
    error PoolAlreadyExists();
    error InvalidPool();

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event PoolCreated(bytes32 indexed poolId, bytes32 indexed conditionId, address indexed collateral);

    event FundingAdded(
        bytes32 indexed poolId, address indexed funder, uint256 amountYes, uint256 amountNo, uint256 sharesMinted
    );

    event FundingRemoved(
        bytes32 indexed poolId, address indexed funder, uint256 amountYes, uint256 amountNo, uint256 sharesBurnt
    );

    event Buy(
        bytes32 indexed poolId, address indexed buyer, uint256 investmentAmount, bool isYes, uint256 tokensBought
    );

    event Sell(bytes32 indexed poolId, address indexed seller, uint256 returnAmount, bool isYes, uint256 tokensSold);

    // ═══════════════════════════════════════════════════════════════════════════
    //                                CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 public constant ONE = 1e18;

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 STATE
    // ═══════════════════════════════════════════════════════════════════════════

    ConditionalTokens public immutable conditionalTokens;

    struct Pool {
        IERC20 collateral;
        bytes32 conditionId;
        uint256 yesTokenId;
        uint256 noTokenId;
        uint256 lpSupply;
        bool initialized;
    }

    /// @notice All pools by poolId
    mapping(bytes32 => Pool) public pools;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(ConditionalTokens _conditionalTokens) {
        conditionalTokens = _conditionalTokens;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        ERC6909 METADATA (required)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Returns the name for token `id` (poolId).
    function name(uint256 id) public pure override returns (string memory) {
        id; // silence warning
        return "FPMM LP Token";
    }

    /// @dev Returns the symbol for token `id`.
    function symbol(uint256 id) public pure override returns (string memory) {
        id; // silence warning
        return "FPMM-LP";
    }

    /// @dev Returns the number of decimals (6 to match USDC).
    function decimals(uint256 id) public pure override returns (uint8) {
        id; // silence warning
        return 6;
    }

    /// @dev Returns URI for token (empty for now).
    function tokenURI(uint256 id) public pure override returns (string memory) {
        id; // silence warning
        return "";
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           POOL MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Create a new pool for a market
    /// @param conditionId The condition ID from ConditionalTokens
    /// @param collateral The collateral token (e.g., USDC)
    /// @return poolId The unique pool identifier
    function createPool(bytes32 conditionId, IERC20 collateral) external returns (bytes32 poolId) {
        poolId = getPoolId(conditionId, address(collateral));
        if (pools[poolId].conditionId != bytes32(0)) revert PoolAlreadyExists();

        // Calculate position IDs
        bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        uint256 yesTokenId = conditionalTokens.getPositionId(collateral, yesCollectionId);
        uint256 noTokenId = conditionalTokens.getPositionId(collateral, noCollectionId);

        pools[poolId] = Pool({
            collateral: collateral,
            conditionId: conditionId,
            yesTokenId: yesTokenId,
            noTokenId: noTokenId,
            lpSupply: 0,
            initialized: false
        });

        // Approve collateral for ConditionalTokens
        collateral.approve(address(conditionalTokens), type(uint256).max);

        emit PoolCreated(poolId, conditionId, address(collateral));
    }

    /// @notice Get pool ID from parameters
    function getPoolId(bytes32 conditionId, address collateral) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(conditionId, collateral));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                            VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get pool balances (YES, NO)
    function getPoolBalances(bytes32 poolId) public view returns (uint256 yesBalance, uint256 noBalance) {
        Pool storage pool = pools[poolId];
        if (pool.conditionId == bytes32(0)) revert InvalidPool();
        yesBalance = conditionalTokens.balanceOf(address(this), pool.yesTokenId);
        noBalance = conditionalTokens.balanceOf(address(this), pool.noTokenId);
    }

    /// @notice Calculate buy amount for YES/NO
    function calcBuyAmount(bytes32 poolId, uint256 investmentAmount, bool isYes) public view returns (uint256) {
        Pool storage pool = pools[poolId];
        if (pool.conditionId == bytes32(0)) revert InvalidPool();

        (uint256 yesBalance, uint256 noBalance) = getPoolBalances(poolId);

        uint256 buyBalance = isYes ? yesBalance : noBalance;
        uint256 otherBalance = isYes ? noBalance : yesBalance;

        // Constant product: y' = y * x / (x + dx)
        uint256 newOtherBalance = otherBalance + investmentAmount;
        uint256 newBuyBalance = _ceildiv(buyBalance * otherBalance * ONE, newOtherBalance * ONE);

        if (newBuyBalance == 0) revert MustHaveNonZeroBalances();

        return buyBalance + investmentAmount - _ceildiv(newBuyBalance, 1);
    }

    /// @notice Calculate sell amount for YES/NO
    function calcSellAmount(bytes32 poolId, uint256 returnAmount, bool isYes) public view returns (uint256) {
        Pool storage pool = pools[poolId];
        if (pool.conditionId == bytes32(0)) revert InvalidPool();

        (uint256 yesBalance, uint256 noBalance) = getPoolBalances(poolId);

        uint256 sellBalance = isYes ? yesBalance : noBalance;
        uint256 otherBalance = isYes ? noBalance : yesBalance;

        uint256 newOtherBalance = otherBalance - returnAmount;
        uint256 newSellBalance = _ceildiv(sellBalance * otherBalance * ONE, newOtherBalance * ONE);

        if (newSellBalance == 0) revert MustHaveNonZeroBalances();

        return returnAmount + _ceildiv(newSellBalance, 1) - sellBalance;
    }

    /// @notice Get YES price (0-1e18)
    function yesPrice(bytes32 poolId) external view returns (uint256) {
        (uint256 yesBalance, uint256 noBalance) = getPoolBalances(poolId);
        if (yesBalance + noBalance == 0) return ONE / 2;
        return (noBalance * ONE) / (yesBalance + noBalance);
    }

    /// @notice Get NO price (0-1e18)
    function noPrice(bytes32 poolId) external view returns (uint256) {
        (uint256 yesBalance, uint256 noBalance) = getPoolBalances(poolId);
        if (yesBalance + noBalance == 0) return ONE / 2;
        return (yesBalance * ONE) / (yesBalance + noBalance);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                            TRADING FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Buy YES tokens
    function buyYes(bytes32 poolId, uint256 investmentAmount, uint256 minTokens)
        external
        nonReentrant
        returns (uint256 tokensBought)
    {
        Pool storage pool = pools[poolId];
        if (!pool.initialized) revert PoolNotInitialized();
        if (investmentAmount == 0) revert ZeroAmount();

        tokensBought = calcBuyAmount(poolId, investmentAmount, true);
        if (tokensBought < minTokens) revert InsufficientBuyAmount();

        pool.collateral.safeTransferFrom(msg.sender, address(this), investmentAmount);

        _splitPosition(pool, investmentAmount);
        conditionalTokens.transfer(msg.sender, pool.yesTokenId, tokensBought);

        emit Buy(poolId, msg.sender, investmentAmount, true, tokensBought);
    }

    /// @notice Buy NO tokens
    function buyNo(bytes32 poolId, uint256 investmentAmount, uint256 minTokens)
        external
        nonReentrant
        returns (uint256 tokensBought)
    {
        Pool storage pool = pools[poolId];
        if (!pool.initialized) revert PoolNotInitialized();
        if (investmentAmount == 0) revert ZeroAmount();

        tokensBought = calcBuyAmount(poolId, investmentAmount, false);
        if (tokensBought < minTokens) revert InsufficientBuyAmount();

        pool.collateral.safeTransferFrom(msg.sender, address(this), investmentAmount);

        _splitPosition(pool, investmentAmount);
        conditionalTokens.transfer(msg.sender, pool.noTokenId, tokensBought);

        emit Buy(poolId, msg.sender, investmentAmount, false, tokensBought);
    }

    /// @notice Sell YES tokens
    function sellYes(bytes32 poolId, uint256 returnAmount, uint256 maxTokens)
        external
        nonReentrant
        returns (uint256 tokensSold)
    {
        Pool storage pool = pools[poolId];
        if (!pool.initialized) revert PoolNotInitialized();
        if (returnAmount == 0) revert ZeroAmount();

        tokensSold = calcSellAmount(poolId, returnAmount, true);
        if (tokensSold > maxTokens) revert ExcessiveSellAmount();

        conditionalTokens.transferFrom(msg.sender, address(this), pool.yesTokenId, tokensSold);

        _mergePosition(pool, returnAmount);
        pool.collateral.safeTransfer(msg.sender, returnAmount);

        emit Sell(poolId, msg.sender, returnAmount, true, tokensSold);
    }

    /// @notice Sell NO tokens
    function sellNo(bytes32 poolId, uint256 returnAmount, uint256 maxTokens)
        external
        nonReentrant
        returns (uint256 tokensSold)
    {
        Pool storage pool = pools[poolId];
        if (!pool.initialized) revert PoolNotInitialized();
        if (returnAmount == 0) revert ZeroAmount();

        tokensSold = calcSellAmount(poolId, returnAmount, false);
        if (tokensSold > maxTokens) revert ExcessiveSellAmount();

        conditionalTokens.transferFrom(msg.sender, address(this), pool.noTokenId, tokensSold);

        _mergePosition(pool, returnAmount);
        pool.collateral.safeTransfer(msg.sender, returnAmount);

        emit Sell(poolId, msg.sender, returnAmount, false, tokensSold);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           LIQUIDITY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Add funding/liquidity to a pool
    function addFunding(bytes32 poolId, uint256 addedFunds, uint256[] calldata distributionHint) external nonReentrant {
        if (addedFunds == 0) revert ZeroAmount();

        Pool storage pool = pools[poolId];
        if (pool.conditionId == bytes32(0)) revert InvalidPool();

        uint256 sendBackYes;
        uint256 sendBackNo;
        uint256 mintAmount;

        if (pool.lpSupply > 0) {
            if (distributionHint.length > 0) revert HintNotAllowedAfterInit();

            (uint256 yesBalance, uint256 noBalance) = getPoolBalances(poolId);
            uint256 maxBalance = yesBalance > noBalance ? yesBalance : noBalance;

            sendBackYes = addedFunds - (addedFunds * yesBalance) / maxBalance;
            sendBackNo = addedFunds - (addedFunds * noBalance) / maxBalance;
            mintAmount = (addedFunds * pool.lpSupply) / maxBalance;
        } else {
            if (distributionHint.length > 0) {
                if (distributionHint.length != 2) revert InvalidDistributionHint();
                uint256 maxHint = distributionHint[0] > distributionHint[1] ? distributionHint[0] : distributionHint[1];
                if (maxHint == 0) revert InvalidDistributionHint();

                sendBackYes = addedFunds - (addedFunds * distributionHint[0]) / maxHint;
                sendBackNo = addedFunds - (addedFunds * distributionHint[1]) / maxHint;
            }
            mintAmount = addedFunds;
            pool.initialized = true;
        }

        // Transfer collateral
        pool.collateral.safeTransferFrom(msg.sender, address(this), addedFunds);

        // Split into outcome tokens
        _splitPosition(pool, addedFunds);

        // Mint LP tokens (ERC6909 from Solady)
        _mint(msg.sender, uint256(poolId), mintAmount);
        pool.lpSupply += mintAmount;

        // Send back excess tokens
        if (sendBackYes > 0) {
            conditionalTokens.transfer(msg.sender, pool.yesTokenId, sendBackYes);
        }
        if (sendBackNo > 0) {
            conditionalTokens.transfer(msg.sender, pool.noTokenId, sendBackNo);
        }

        emit FundingAdded(poolId, msg.sender, addedFunds - sendBackYes, addedFunds - sendBackNo, mintAmount);
    }

    /// @notice Remove funding/liquidity from a pool
    function removeFunding(bytes32 poolId, uint256 sharesToBurn) external nonReentrant {
        if (sharesToBurn == 0) revert ZeroAmount();

        Pool storage pool = pools[poolId];
        if (pool.conditionId == bytes32(0)) revert InvalidPool();

        (uint256 yesBalance, uint256 noBalance) = getPoolBalances(poolId);

        uint256 sendYes = (yesBalance * sharesToBurn) / pool.lpSupply;
        uint256 sendNo = (noBalance * sharesToBurn) / pool.lpSupply;

        // Burn LP tokens (ERC6909 from Solady)
        _burn(msg.sender, uint256(poolId), sharesToBurn);
        pool.lpSupply -= sharesToBurn;

        // Transfer outcome tokens
        if (sendYes > 0) {
            conditionalTokens.transfer(msg.sender, pool.yesTokenId, sendYes);
        }
        if (sendNo > 0) {
            conditionalTokens.transfer(msg.sender, pool.noTokenId, sendNo);
        }

        emit FundingRemoved(poolId, msg.sender, sendYes, sendNo, sharesToBurn);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function _splitPosition(Pool storage pool, uint256 amount) internal {
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        conditionalTokens.splitPosition(pool.collateral, bytes32(0), pool.conditionId, partition, amount);
    }

    function _mergePosition(Pool storage pool, uint256 amount) internal {
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        conditionalTokens.mergePositions(pool.collateral, bytes32(0), pool.conditionId, partition, amount);
    }

    function _ceildiv(uint256 x, uint256 y) internal pure returns (uint256) {
        if (x > 0) return ((x - 1) / y) + 1;
        return 0;
    }
}
