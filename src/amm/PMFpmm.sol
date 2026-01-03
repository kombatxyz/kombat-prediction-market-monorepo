//// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ERC6909} from "lib/solady/src/tokens/ERC6909.sol";
import {ConditionalTokens} from "src/ConditionalTokens.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Uniswap V4-style singleton FPMM with ERC6909 LP tokens (using Solady)
contract PMFpmm is ERC6909 {
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

        function createPool(bytes32 conditionId, IERC20 collateral) external returns (bytes32 poolId) {
        poolId = getPoolId(conditionId, address(collateral));

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
    }

    function getPoolId(bytes32 conditionId, address collateral) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(conditionId, collateral));
    }

    function BuyYes() external {}

    function sellYes() external {}

    function BuyNo() external {}

    function SellNo() external {}
}
