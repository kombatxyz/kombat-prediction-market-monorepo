// 	SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {LibBitmap} from "lib/solady/src/utils/LibBitmap.sol";
import {LibBit} from "lib/solady/src/utils/LibBit.sol";
import {ConditionalTokens} from "./ConditionalTokens.sol";

/// @dev O(1) price level operations via 256-bit bitmaps. Supports 0.01-0.99 prices (99 ticks).
contract PMExchange is ReentrancyGuard, EIP712, Ownable {
    using SafeERC20 for IERC20;
    using LibBitmap for LibBitmap.Bitmap;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Price precision: 1e18 = $1.00, tick = 0.01 = 1e16
    uint256 public constant PRICE_DENOMINATOR = 1e18;
    uint256 public constant TICK_SIZE = 1e16; // 0.01 in 1e18 format
    uint8 public constant MIN_TICK = 1; // 0.01
    uint8 public constant MAX_TICK = 99; // 0.99

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,bytes32 conditionId,uint8 side,uint256 tick,uint256 quantity,uint256 nonce,uint256 expiry,uint256 feeRateBps)"
    );

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    enum Side {
        BuyYes,
        SellYes,
        BuyNo,
        SellNo
    }

    enum TiF {
        GTC,
        IOC,
        FOK,
        POST_ONLY
    }
    enum OrderStatus {
        Active,
        Filled,
        PartiallyFilled,
        Cancelled
    }

    /// @dev Packed order struct for gas efficiency
    struct Order {
        uint64 orderId;
        address trader;
        bytes32 conditionId;
        uint8 tick; // 1-99 representing 0.01-0.99
        bool isBuy; // normalized: true = buying YES
        bool wantsNo; // true if user wants NO token
        uint128 quantity;
        uint128 filled;
        TiF tif;
        OrderStatus status;
        uint48 timestamp;
    }

    struct SignedOrder {
        address maker;
        bytes32 conditionId;
        Side side;
        uint8 tick;
        uint128 quantity;
        uint64 nonce;
        uint48 expiry;
        uint16 feeRateBps;
    }

    /// @dev Tick level with doubly-linked list for O(1) insert/remove
    struct TickLevel {
        uint128 totalQuantity; // total quantity at this tick
        uint64 head; // first order in queue (FIFO)
        uint64 tail; // last order in queue
        uint32 orderCount; // number of orders in queue
    }

    /// @dev Linked list pointers for each order
    struct OrderLink {
        uint64 prev; // previous order in queue (0 if head)
        uint64 next; // next order in queue (0 if tail)
    }

    struct Market {
        uint256 yesTokenId;
        uint256 noTokenId;
        uint48 endTime; // Unix timestamp when trading ends
        bool registered;
        bool paused;
        bool resolved;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidQuantity();
    error InvalidTick();
    error InvalidSignature();
    error OrderExpired();
    error OrderAlreadyUsed();
    error NotOrderOwner();
    error OrderNotActive();
    error InsufficientFill();
    error MarketNotRegistered();
    error MarketAlreadyRegistered();
    error MarketPaused();
    error MarketResolved();
    error MarketExpired();
    error NotOperator();
    error SelfTrade();
    error PostOnlyWouldTake();

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event MarketRegistered(bytes32 indexed conditionId, uint256 yesTokenId, uint256 noTokenId);
    event MarketPauseToggled(bytes32 indexed conditionId, bool paused);
    event MarketResolvedEvent(bytes32 indexed conditionId);

    event OrderPlaced(
        uint64 indexed orderId,
        address indexed trader,
        bytes32 indexed conditionId,
        Side side,
        uint8 tick,
        uint128 quantity
    );

    event OrderMatched(bytes32 indexed conditionId, uint64 indexed takerOrderId, uint64 indexed makerOrderId, uint8 tick, uint128 quantity);

    event OrderCancelled(uint64 indexed orderId, uint128 remainingQuantity);
    event OperatorUpdated(address indexed trader, address indexed operator, bool approved);

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 STATE
    // ═══════════════════════════════════════════════════════════════════════════

    ConditionalTokens public immutable conditionalTokens;
    IERC20 public immutable usdc;

    /// @dev Order storage
    mapping(uint64 => Order) public orders;
    uint64 public nextOrderId = 1;

    /// @dev Bid/Ask bitmaps: conditionId => isBid => active ticks bitmap
    mapping(bytes32 => mapping(bool => LibBitmap.Bitmap)) internal _activeTicks;

    /// @dev Tick levels: conditionId => isBid => tick => TickLevel
    mapping(bytes32 => mapping(bool => mapping(uint8 => TickLevel))) public tickLevels;

    /// @dev Order linked list pointers: orderId => OrderLink
    mapping(uint64 => OrderLink) internal _orderLinks;

    /// @dev Signed order tracking
    mapping(bytes32 => uint128) public signedOrderFills;
    mapping(address => uint64) public minNonce;

    /// @dev Markets
    mapping(bytes32 => Market) public markets;
    bytes32[] public marketList;

    /// @dev Operators
    mapping(address => mapping(address => bool)) public operators;

    /// @dev User tracking
    mapping(address => uint64[]) internal _userOrders;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _conditionalTokens, address _usdc) EIP712("PMExchange", "2") Ownable(msg.sender) {
        conditionalTokens = ConditionalTokens(_conditionalTokens);
        usdc = IERC20(_usdc);
        // Approve CT to spend USDC for splitting positions
        usdc.approve(_conditionalTokens, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    modifier marketActive(bytes32 conditionId) {
        Market storage m = markets[conditionId];
        if (!m.registered) revert MarketNotRegistered();
        if (m.paused) revert MarketPaused();
        if (m.resolved) revert MarketResolved();
        if (m.endTime != 0 && block.timestamp >= m.endTime) revert MarketExpired();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Register a new market with optional end time
    /// @param conditionId The condition ID from ConditionalTokens
    /// @param yesTokenId Token ID for YES position
    /// @param noTokenId Token ID for NO position
    /// @param endTime Unix timestamp when trading ends (0 = no expiry)
    function registerMarket(bytes32 conditionId, uint256 yesTokenId, uint256 noTokenId, uint48 endTime)
        external
        onlyOwner
    {
        if (markets[conditionId].registered) revert MarketAlreadyRegistered();
        markets[conditionId] = Market({
            yesTokenId: yesTokenId,
            noTokenId: noTokenId,
            endTime: endTime,
            registered: true,
            paused: false,
            resolved: false
        });
        marketList.push(conditionId);
        emit MarketRegistered(conditionId, yesTokenId, noTokenId);
    }

    /// @notice Get token IDs for a market
    function getTokenIds(bytes32 conditionId) external view returns (uint256 yesTokenId, uint256 noTokenId) {
        Market storage m = markets[conditionId];
        return (m.yesTokenId, m.noTokenId);
    }

    function resolveMarket(bytes32 conditionId) external onlyOwner {
        if (!markets[conditionId].registered) revert MarketNotRegistered();
        markets[conditionId].resolved = true;
        emit MarketResolvedEvent(conditionId);
    }

    function toggleMarketPause(bytes32 conditionId) external onlyOwner {
        markets[conditionId].paused = !markets[conditionId].paused;
        emit MarketPauseToggled(conditionId, markets[conditionId].paused);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          OPERATOR FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function setOperator(address operator, bool approved) external {
        operators[msg.sender][operator] = approved;
        emit OperatorUpdated(msg.sender, operator, approved);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ORDER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Place order with tick-based pricing (tick 1-99 = $0.01-$0.99)
    function placeOrder(bytes32 conditionId, Side side, uint8 tick, uint128 quantity, TiF tif)
        external
        nonReentrant
        marketActive(conditionId)
        returns (uint64 orderId)
    {
        return _placeOrder(msg.sender, conditionId, side, tick, quantity, tif);
    }

    /// @notice Place order on behalf of a user who signed an EIP-712 message (gasless)
    /// @param signedOrder The order parameters signed by the maker
    /// @param signature The EIP-712 signature from the maker
    /// @param tif Time-in-force for the order
    /// @return orderId The ID of the placed order
    function placeOrderWithSig(SignedOrder calldata signedOrder, bytes calldata signature, TiF tif)
        external
        nonReentrant
        marketActive(signedOrder.conditionId)
        returns (uint64 orderId)
    {
        // validate signature
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                signedOrder.maker,
                signedOrder.conditionId,
                signedOrder.side,
                uint256(signedOrder.tick),
                uint256(signedOrder.quantity),
                uint256(signedOrder.nonce),
                uint256(signedOrder.expiry),
                uint256(signedOrder.feeRateBps)
            )
        );
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, signature);

        if (signer != signedOrder.maker) revert InvalidSignature();
        if (block.timestamp > signedOrder.expiry) revert OrderExpired();
        if (signedOrder.nonce < minNonce[signedOrder.maker]) revert OrderAlreadyUsed();

        // mark nonce as used
        minNonce[signedOrder.maker] = signedOrder.nonce + 1;

        return _placeOrder(
            signedOrder.maker, signedOrder.conditionId, signedOrder.side, signedOrder.tick, signedOrder.quantity, tif
        );
    }

    function cancelOrder(uint64 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (msg.sender != o.trader && !operators[o.trader][msg.sender]) revert NotOrderOwner();
        if (o.status != OrderStatus.Active && o.status != OrderStatus.PartiallyFilled) revert OrderNotActive();
        _removeFromBook(orderId);
        o.status = OrderStatus.Cancelled;
        emit OrderCancelled(orderId, uint128(o.quantity - o.filled));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get best bid tick (highest price buyer wants to pay for YES)
    function getBestBid(bytes32 conditionId) public view returns (uint8 tick, uint128 size) {
        tick = _findHighestActiveTick(conditionId, true);
        if (tick > 0) size = tickLevels[conditionId][true][tick].totalQuantity;
    }

    /// @notice Get best ask tick (lowest price seller wants for YES)
    function getBestAsk(bytes32 conditionId) public view returns (uint8 tick, uint128 size) {
        tick = _findLowestActiveTick(conditionId, false);
        if (tick > 0) size = tickLevels[conditionId][false][tick].totalQuantity;
    }

    /// @notice Get spread in ticks
    function getSpread(bytes32 conditionId) external view returns (uint8 bidTick, uint8 askTick, uint8 spreadTicks) {
        (bidTick,) = getBestBid(conditionId);
        (askTick,) = getBestAsk(conditionId);
        if (askTick > bidTick) spreadTicks = askTick - bidTick;
    }

    /// @notice Convert tick to 1e18 price
    function tickToPrice(uint8 tick) public pure returns (uint256) {
        return uint256(tick) * TICK_SIZE;
    }

    /// @notice Convert 1e18 price to tick
    function priceToTick(uint256 price) public pure returns (uint8) {
        return uint8(price / TICK_SIZE);
    }

    /// @notice Get YES orderbook depth (pure YES orders only)
    /// @dev Shows only orders where wantsNo=false:
    ///      - YES Bids = BuyYes only
    ///      - YES Asks = SellYes only
    function getOrderBookDepth(bytes32 conditionId, uint8 depth)
        external
        view
        returns (uint8[] memory bidTicks, uint128[] memory bidSizes, uint8[] memory askTicks, uint128[] memory askSizes)
    {
        // Get YES orders only (wantsNo=false)
        return _getFilteredBookDepth(conditionId, depth, false);
    }

    /// @notice Get NO orderbook depth (pure NO orders only)
    /// @dev Shows only orders where wantsNo=true:
    ///      - NO Bids = BuyNo (stored on ask side internally, swapped for display)
    ///      - NO Asks = SellNo (stored on bid side internally, swapped for display)
    ///      - Ticks inverted: 100 - tick
    function getNoBookDepth(bytes32 conditionId, uint8 depth)
        external
        view
        returns (uint8[] memory bidTicks, uint128[] memory bidSizes, uint8[] memory askTicks, uint128[] memory askSizes)
    {
        // Get pure NO orders (wantsNo=true), with bid/ask swapped for display
        (askTicks, askSizes, bidTicks, bidSizes) = _getFilteredBookDepth(conditionId, depth, true);

        // Invert ticks from YES-space to NO-space
        for (uint256 i; i < bidTicks.length;) {
            bidTicks[i] = 100 - bidTicks[i];
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < askTicks.length;) {
            askTicks[i] = 100 - askTicks[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Internal: get book depth filtered by wantsNo flag (used by getNoBookDepth)
    function _getFilteredBookDepth(bytes32 conditionId, uint8 depth, bool filterWantsNo)
        internal
        view
        returns (uint8[] memory bidTicks, uint128[] memory bidSizes, uint8[] memory askTicks, uint128[] memory askSizes)
    {
        bidTicks = new uint8[](depth);
        bidSizes = new uint128[](depth);
        askTicks = new uint8[](depth);
        askSizes = new uint128[](depth);

        // Find bid orders (isBuy=true) with matching wantsNo
        uint8 bidCount = 0;
        uint8 tick = _findHighestActiveTick(conditionId, true);
        while (tick > 0 && bidCount < depth) {
            uint128 qty = _sumOrdersFiltered(conditionId, true, tick, filterWantsNo);
            if (qty > 0) {
                bidTicks[bidCount] = tick;
                bidSizes[bidCount] = qty;
                bidCount++;
            }
            tick = _findPrevActiveTick(conditionId, true, tick);
        }

        assembly {
            mstore(bidTicks, bidCount)
            mstore(bidSizes, bidCount)
        }

        // Find ask orders (isBuy=false) with matching wantsNo
        uint8 askCount = 0;
        tick = _findLowestActiveTick(conditionId, false);
        while (tick > 0 && askCount < depth) {
            uint128 qty = _sumOrdersFiltered(conditionId, false, tick, filterWantsNo);
            if (qty > 0) {
                askTicks[askCount] = tick;
                askSizes[askCount] = qty;
                askCount++;
            }
            tick = _findNextActiveTick(conditionId, false, tick);
        }

        assembly {
            mstore(askTicks, askCount)
            mstore(askSizes, askCount)
        }
    }

    /// @dev Sum quantity at tick level, filtered by wantsNo
    function _sumOrdersFiltered(bytes32 conditionId, bool isBid, uint8 tick, bool filterWantsNo)
        internal
        view
        returns (uint128 total)
    {
        TickLevel storage level = tickLevels[conditionId][isBid][tick];
        uint64 orderId = level.head;

        while (orderId != 0) {
            Order storage o = orders[orderId];
            if (
                (o.status == OrderStatus.Active || o.status == OrderStatus.PartiallyFilled)
                    && o.wantsNo == filterWantsNo
            ) {
                total += o.quantity - o.filled;
            }
            orderId = _orderLinks[orderId].next;
        }
    }

    function getUserOrders(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint64[] memory orderIds, Order[] memory orderData)
    {
        uint256 total = _userOrders[user].length;
        if (offset >= total) return (new uint64[](0), new Order[](0));

        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 len = end - offset;
        orderIds = new uint64[](len);
        orderData = new Order[](len);

        for (uint256 i; i < len;) {
            orderIds[i] = _userOrders[user][offset + i];
            orderData[i] = orders[orderIds[i]];
            unchecked {
                ++i;
            }
        }
    }

    function getMarketCount() external view returns (uint256) {
        return marketList.length;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                      FRONTEND VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get mid price as tick (1-99) - average of best bid and ask
    /// @return midTick The mid price tick (0 if no liquidity)
    /// @return hasLiquidity True if both bid and ask exist
    function getMidPrice(bytes32 conditionId) external view returns (uint8 midTick, bool hasLiquidity) {
        (uint8 bidTick,) = getBestBid(conditionId);
        (uint8 askTick,) = getBestAsk(conditionId);

        if (bidTick > 0 && askTick > 0) {
            midTick = uint8((uint16(bidTick) + uint16(askTick)) / 2);
            hasLiquidity = true;
        } else if (bidTick > 0) {
            midTick = bidTick;
        } else if (askTick > 0) {
            midTick = askTick;
        }
    }

    /// @notice Get YES and NO prices for display
    /// @return yesPrice YES price in basis points (e.g., 5500 = 55%)
    /// @return noPrice NO price in basis points (always 10000 - yesPrice)
    /// @return spreadBps Spread in basis points
    function getMarketPrices(bytes32 conditionId)
        external
        view
        returns (uint256 yesPrice, uint256 noPrice, uint256 spreadBps)
    {
        (uint8 bidTick,) = getBestBid(conditionId);
        (uint8 askTick,) = getBestAsk(conditionId);

        uint256 midTick;
        if (bidTick > 0 && askTick > 0) {
            midTick = (uint256(bidTick) + uint256(askTick)) / 2;
            spreadBps = (uint256(askTick) - uint256(bidTick)) * 100; // ticks to bps
        } else if (bidTick > 0) {
            midTick = bidTick;
        } else if (askTick > 0) {
            midTick = askTick;
        } else {
            midTick = 50; // default to 50% if no liquidity
        }

        yesPrice = midTick * 100; // tick to bps (50 -> 5000)
        noPrice = 10000 - yesPrice;
    }

    /// @notice Get comprehensive market summary for frontend
    struct MarketSummary {
        uint256 yesTokenId;
        uint256 noTokenId;
        bool registered;
        bool paused;
        uint8 bestBidTick;
        uint128 bestBidSize;
        uint8 bestAskTick;
        uint128 bestAskSize;
        uint8 midPriceTick;
        uint8 spreadTicks;
        uint256 yesPriceBps; // yES price in basis points
        uint256 noPriceBps; // nO price in basis points
    }

    function getMarketSummary(bytes32 conditionId) external view returns (MarketSummary memory summary) {
        Market storage m = markets[conditionId];
        summary.yesTokenId = m.yesTokenId;
        summary.noTokenId = m.noTokenId;
        summary.registered = m.registered;
        summary.paused = m.paused;

        (summary.bestBidTick, summary.bestBidSize) = getBestBid(conditionId);
        (summary.bestAskTick, summary.bestAskSize) = getBestAsk(conditionId);

        if (summary.bestBidTick > 0 && summary.bestAskTick > 0) {
            summary.midPriceTick = uint8((uint16(summary.bestBidTick) + uint16(summary.bestAskTick)) / 2);
            summary.spreadTicks = summary.bestAskTick - summary.bestBidTick;
        } else if (summary.bestBidTick > 0) {
            summary.midPriceTick = summary.bestBidTick;
        } else if (summary.bestAskTick > 0) {
            summary.midPriceTick = summary.bestAskTick;
        } else {
            summary.midPriceTick = 50;
        }

        summary.yesPriceBps = uint256(summary.midPriceTick) * 100;
        summary.noPriceBps = 10000 - summary.yesPriceBps;
    }

    /// @notice Get multiple market summaries in one call (gas efficient for frontend)
    function getMultipleMarketSummaries(bytes32[] calldata conditionIds)
        external
        view
        returns (MarketSummary[] memory summaries)
    {
        summaries = new MarketSummary[](conditionIds.length);
        for (uint256 i = 0; i < conditionIds.length; i++) {
            summaries[i] = this.getMarketSummary(conditionIds[i]);
        }
    }

    /// @notice Get all registered markets with their summaries
    function getAllMarkets(uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory conditionIds, MarketSummary[] memory summaries)
    {
        uint256 total = marketList.length;
        if (offset >= total) return (new bytes32[](0), new MarketSummary[](0));

        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 len = end - offset;
        conditionIds = new bytes32[](len);
        summaries = new MarketSummary[](len);

        for (uint256 i = 0; i < len; i++) {
            conditionIds[i] = marketList[offset + i];
            summaries[i] = this.getMarketSummary(conditionIds[i]);
        }
    }

    /// @notice Check if a price level has liquidity
    function hasLiquidityAtTick(bytes32 conditionId, bool isBid, uint8 tick)
        external
        view
        returns (bool hasLiquidity, uint128 size)
    {
        size = tickLevels[conditionId][isBid][tick].totalQuantity;
        hasLiquidity = size > 0;
    }

    /// @notice Estimate fill for a market order (how much would be filled at what average price)
    function estimateFill(bytes32 conditionId, Side side, uint128 quantity)
        external
        view
        returns (uint128 fillableAmount, uint256 avgPriceBps, uint256 totalCost)
    {
        (bool isBuy,, bool wantsNo) = _normalize(side, 50); // tick doesn't matter for estimation

        // for buys, we look at asks; for sells, we look at bids
        bool lookAtAsks = isBuy;
        uint8 tick = lookAtAsks
            ? _findLowestActiveTick(conditionId, false)  // asks
            : _findHighestActiveTick(conditionId, true); // bids

        uint128 remaining = quantity;
        uint256 weightedPriceSum = 0;

        while (tick > 0 && remaining > 0) {
            uint128 available = tickLevels[conditionId][!lookAtAsks][tick].totalQuantity;
            uint128 fillAtTick = available > remaining ? remaining : available;

            if (fillAtTick > 0) {
                fillableAmount += fillAtTick;

                // calculate cost
                uint256 tickPrice = wantsNo ? (100 - tick) : tick;
                weightedPriceSum += uint256(fillAtTick) * tickPrice;
                totalCost += uint256(fillAtTick) * tickPrice * 1e16; // scale to 1e18

                remaining -= fillAtTick;
            }

            // move to next tick
            tick = lookAtAsks
                ? _findNextActiveTick(conditionId, false, tick)
                : _findPrevActiveTick(conditionId, true, tick);
        }

        if (fillableAmount > 0) {
            avgPriceBps = (weightedPriceSum * 100) / fillableAmount;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL - ORDER LOGIC
    // ═══════════════════════════════════════════════════════════════════════════

    function _placeOrder(address trader, bytes32 conditionId, Side side, uint8 tick, uint128 quantity, TiF tif)
        internal
        returns (uint64 orderId)
    {
        if (quantity == 0) revert InvalidQuantity();
        if (tick < MIN_TICK || tick > MAX_TICK) revert InvalidTick();

        (bool isBuy, uint8 yesTick, bool wantsNo) = _normalize(side, tick);

        orderId = nextOrderId++;
        orders[orderId] = Order({
            orderId: orderId,
            trader: trader,
            conditionId: conditionId,
            tick: yesTick,
            isBuy: isBuy,
            wantsNo: wantsNo,
            quantity: quantity,
            filled: 0,
            tif: tif,
            status: OrderStatus.Active,
            timestamp: uint48(block.timestamp)
        });

        _userOrders[trader].push(orderId);

        // pOST_ONLY check
        if (tif == TiF.POST_ONLY) {
            if (_wouldMatch(conditionId, isBuy, yesTick)) revert PostOnlyWouldTake();
            _addToBook(orderId);
            emit OrderPlaced(orderId, trader, conditionId, side, tick, quantity);
            return orderId;
        }

        // match
        uint128 filled = _matchOrder(orderId);

        // complement matching
        if (filled < quantity && orders[orderId].status == OrderStatus.Active) {
            filled += _tryComplementMatch(orderId);
        }

        if (tif == TiF.FOK && filled < quantity) revert InsufficientFill();

        if (tif == TiF.IOC && filled < quantity) {
            orders[orderId].status = OrderStatus.Cancelled;
        } else if (filled < quantity && orders[orderId].status == OrderStatus.Active) {
            _addToBook(orderId);
            if (filled > 0) orders[orderId].status = OrderStatus.PartiallyFilled;
        }

        emit OrderPlaced(orderId, trader, conditionId, side, tick, quantity);
    }

    /// @dev Normalize user-facing side to internal YES-based representation
    function _normalize(Side s, uint8 tick) internal pure returns (bool isBuy, uint8 yesTick, bool wantsNo) {
        if (s == Side.BuyYes) return (true, tick, false);
        if (s == Side.SellYes) return (false, tick, false);
        if (s == Side.BuyNo) return (false, 100 - tick, true); // buyNo@40 = SellYes@60
        return (true, 100 - tick, true); // sellNo@40 = BuyYes@60
    }

    function _wouldMatch(bytes32 cid, bool isBuy, uint8 tick) internal view returns (bool) {
        if (isBuy) {
            // buyer matches against asks (isBid=false)
            uint8 bestAsk = _findLowestActiveTick(cid, false);
            return bestAsk > 0 && bestAsk <= tick;
        } else {
            // seller matches against bids (isBid=true)
            uint8 bestBid = _findHighestActiveTick(cid, true);
            return bestBid > 0 && bestBid >= tick;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL - MATCHING
    // ═══════════════════════════════════════════════════════════════════════════

    function _matchOrder(uint64 orderId) internal returns (uint128 totalFilled) {
        Order storage t = orders[orderId];
        uint128 rem = t.quantity - t.filled;

        if (t.isBuy) {
            // buying YES: match against asks from lowest upward
            uint8 tick = _findLowestActiveTick(t.conditionId, false);
            while (tick > 0 && tick <= t.tick && rem > 0) {
                uint128 matched = _matchAtTick(orderId, tick, false, rem);
                rem -= matched;
                totalFilled += matched;
                tick = _findNextActiveTick(t.conditionId, false, tick);
            }
        } else {
            // selling YES: match against bids from highest downward
            uint8 tick = _findHighestActiveTick(t.conditionId, true);
            while (tick > 0 && tick >= t.tick && rem > 0) {
                uint128 matched = _matchAtTick(orderId, tick, true, rem);
                rem -= matched;
                totalFilled += matched;
                tick = _findPrevActiveTick(t.conditionId, true, tick);
            }
        }

        t.filled += totalFilled;
        if (t.filled == t.quantity) t.status = OrderStatus.Filled;
    }

    /// @param isBid true = match against bid orders (taker is seller), false = match against asks (taker is buyer)
    function _matchAtTick(uint64 takerOrderId, uint8 tick, bool isBid, uint128 remaining)
        internal
        returns (uint128 filled)
    {
        Order storage taker = orders[takerOrderId];
        TickLevel storage level = tickLevels[taker.conditionId][isBid][tick];

        // traverse linked list from head
        uint64 makerId = level.head;

        while (makerId != 0 && remaining > 0) {
            Order storage maker = orders[makerId];
            uint64 nextMakerId = _orderLinks[makerId].next;

            if (maker.status != OrderStatus.Active && maker.status != OrderStatus.PartiallyFilled) {
                makerId = nextMakerId;
                continue;
            }
            // Only skip if matching the exact same order
            if (maker.orderId == orders[takerOrderId].orderId) {
                makerId = nextMakerId;
                continue;
            }
            // check if this is a complement scenario or an impossible match:
            // complement = both have USDC, want opposite tokens -> mint together
            // impossible = both have tokens (different types) -> can't trade directly

            bool takerHasTokens = (taker.isBuy && taker.wantsNo) || (!taker.isBuy && !taker.wantsNo);
            bool makerHasTokens = (maker.isBuy && maker.wantsNo) || (!maker.isBuy && !maker.wantsNo);

            // skip if both have tokens (SellYes + SellNo) - can't trade directly
            if (takerHasTokens && makerHasTokens) {
                makerId = nextMakerId;
                continue;
            }

            // skip if different wantsNo flags and NOT a valid trade
            // (will be handled by _tryComplementMatch for complement minting)
            bool isComplement = (taker.wantsNo != maker.wantsNo);
            if (isComplement) {
                makerId = nextMakerId;
                continue;
            }

            uint128 available = maker.quantity - maker.filled;
            uint128 fillAmt = available > remaining ? remaining : available;

            // execute trade (regular settlement - seller has tokens, buyer has USDC)
            _settle(taker.trader, maker.trader, taker.conditionId, taker.isBuy, taker.wantsNo, tick, fillAmt);

            maker.filled += fillAmt;
            filled += fillAmt;
            remaining -= fillAmt;
            level.totalQuantity -= fillAmt;

            emit OrderMatched(taker.conditionId, takerOrderId, makerId, tick, fillAmt);

            if (maker.filled == maker.quantity) {
                maker.status = OrderStatus.Filled;
                // remove from linked list (O(1))
                _unlinkOrder(level, makerId);
            } else {
                maker.status = OrderStatus.PartiallyFilled;
            }

            makerId = nextMakerId;
        }

        // clear tick from bitmap if empty
        if (level.totalQuantity == 0) {
            _activeTicks[taker.conditionId][isBid].unset(tick);
        }
    }

    /// @dev Remove order from linked list without updating order storage (helper for matching)
    function _unlinkOrder(TickLevel storage level, uint64 orderId) internal {
        OrderLink storage link = _orderLinks[orderId];

        if (link.prev != 0) {
            _orderLinks[link.prev].next = link.next;
        } else {
            level.head = link.next;
        }

        if (link.next != 0) {
            _orderLinks[link.next].prev = link.prev;
        } else {
            level.tail = link.prev;
        }

        delete _orderLinks[orderId];
        level.orderCount--;
    }

    /// @dev Returns true if order is a pure buyer (buying with USDC, not selling tokens)
    /// Pure buyers are: BuyYes OR BuyNo
    /// - BuyYes: isBuy=true, wantsNo=false
    /// - BuyNo: isBuy=false, wantsNo=true (normalized from user's "buy NO" intent)
    /// @dev Check if order is a pure buyer (BuyYes or BuyNo with USDC)
    function isPureBuyer(Order storage o) internal view returns (bool) {
        return (o.isBuy && !o.wantsNo) // BuyYes
            || (!o.isBuy && o.wantsNo); // BuyNo
    }

    function _tryComplementMatch(uint64 orderId) internal returns (uint128 filled) {
        Order storage order = orders[orderId];

        // complement matching: Find an order at the SAME tick with OPPOSITE wantsNo flag
        // BuyYes@60 (tick=60, wantsNo=false) matches with BuyNo@40 (normalized tick=60, wantsNo=true)
        // SellYes@60 + SellNo@40 can also match via merge (both give tokens, get USDC)

        bytes32 cid = order.conditionId;
        uint8 tick = order.tick;
        uint128 rem = order.quantity - order.filled;

        // Look for complementary orders at the same tick on the OPPOSITE book
        // BuyYes (isBuy=true) is on bid book → search ask book for BuyNo (isBuy=false)
        // BuyNo (isBuy=false) is on ask book → search bid book for BuyYes (isBuy=true)
        bool searchBids = !order.isBuy; // if order is on asks, search bids

        if (!_activeTicks[cid][searchBids].get(tick)) {
            return 0;
        }

        TickLevel storage level = tickLevels[cid][searchBids][tick];
        if (level.totalQuantity == 0) return 0;

        uint64 makerId = level.head;

        while (makerId != 0 && rem > 0) {
            Order storage m = orders[makerId];
            uint64 nextMakerId = _orderLinks[makerId].next;

            // skip same order (not same trader - allows Router to work)
            if (m.orderId == orderId) {
                makerId = nextMakerId;
                continue;
            }
            // skip inactive orders
            if (m.status != OrderStatus.Active && m.status != OrderStatus.PartiallyFilled) {
                makerId = nextMakerId;
                continue;
            }
            // skip orders that want same token (no complement)
            if (m.wantsNo == order.wantsNo) {
                makerId = nextMakerId;
                continue;
            }

            // Only match if BOTH are pure buyers (BuyYes + BuyNo = mint)
            // Skip SellYes + SellNo (merge) - Polymarket doesn't do this
            if (!isPureBuyer(order) || !isPureBuyer(m)) {
                makerId = nextMakerId;
                continue;
            }

            uint128 fillAmt = m.quantity - m.filled;
            if (fillAmt > rem) fillAmt = rem;

            // Complement mint: both buyers have USDC, mint new tokens
            Order storage yesWanter = order.wantsNo ? m : order;
            Order storage noWanter = order.wantsNo ? order : m;
            bool success = _executeComplementMint(yesWanter, noWanter, fillAmt);

            if (success) {
                order.filled += fillAmt;
                m.filled += fillAmt;
                filled += fillAmt;
                rem -= fillAmt;
                level.totalQuantity -= fillAmt;

                if (m.filled == m.quantity) {
                    m.status = OrderStatus.Filled;
                    _unlinkOrder(level, makerId);
                }
            }

            makerId = nextMakerId;
        }

        if (level.totalQuantity == 0) {
            _activeTicks[cid][searchBids].unset(tick);
        }
        if (order.filled == order.quantity) order.status = OrderStatus.Filled;
    }

    function _executeComplementMint(Order storage yesOrder, Order storage noOrder, uint128 qty)
        internal
        returns (bool)
    {
        Market storage market = markets[yesOrder.conditionId];

        Order storage actualYes = yesOrder.wantsNo ? noOrder : yesOrder;
        Order storage actualNo = yesOrder.wantsNo ? yesOrder : noOrder;

        uint256 yesPrice = tickToPrice(actualYes.tick);
        uint256 noPrice = PRICE_DENOMINATOR - yesPrice;
        uint256 yesUsdc = (uint256(qty) * yesPrice) / PRICE_DENOMINATOR;
        uint256 noUsdc = (uint256(qty) * noPrice) / PRICE_DENOMINATOR;

        usdc.safeTransferFrom(actualYes.trader, address(this), yesUsdc);
        usdc.safeTransferFrom(actualNo.trader, address(this), noUsdc);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        conditionalTokens.splitPosition(usdc, bytes32(0), yesOrder.conditionId, partition, qty);

        conditionalTokens.transfer(actualYes.trader, market.yesTokenId, qty);
        conditionalTokens.transfer(actualNo.trader, market.noTokenId, qty);

        return true;
    }

    function _settle(
        address takerAddr,
        address makerAddr,
        bytes32 cid,
        bool takerBuysYes,
        bool takerWantsNo,
        uint8 tick,
        uint128 qty
    ) internal {
        Market storage m = markets[cid];
        uint256 price = tickToPrice(tick);
        uint256 usdcAmt = (uint256(qty) * price) / PRICE_DENOMINATOR;

        if (takerBuysYes && !takerWantsNo) {
            conditionalTokens.transferFrom(makerAddr, takerAddr, m.yesTokenId, qty);
            usdc.safeTransferFrom(takerAddr, makerAddr, usdcAmt);
        } else if (!takerBuysYes && !takerWantsNo) {
            conditionalTokens.transferFrom(takerAddr, makerAddr, m.yesTokenId, qty);
            usdc.safeTransferFrom(makerAddr, takerAddr, usdcAmt);
        } else if (!takerBuysYes && takerWantsNo) {
            uint256 noAmt = (uint256(qty) * (PRICE_DENOMINATOR - price)) / PRICE_DENOMINATOR;
            conditionalTokens.transferFrom(makerAddr, takerAddr, m.noTokenId, qty);
            usdc.safeTransferFrom(takerAddr, makerAddr, noAmt);
        } else {
            uint256 noAmt = (uint256(qty) * (PRICE_DENOMINATOR - price)) / PRICE_DENOMINATOR;
            conditionalTokens.transferFrom(takerAddr, makerAddr, m.noTokenId, qty);
            usdc.safeTransferFrom(makerAddr, takerAddr, noAmt);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          INTERNAL - BITMAP OPERATIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Add order to the end of the linked list (O(1))
    function _addToBook(uint64 orderId) internal {
        Order storage o = orders[orderId];
        bool isBid = o.isBuy;
        TickLevel storage level = tickLevels[o.conditionId][isBid][o.tick];

        // set bitmap bit (O(1))
        _activeTicks[o.conditionId][isBid].set(o.tick);

        uint128 remaining = o.quantity - o.filled;
        level.totalQuantity += remaining;

        // add to end of linked list (O(1))
        if (level.tail == 0) {
            // empty list - this is the first order
            level.head = orderId;
            level.tail = orderId;
        } else {
            // append to tail
            _orderLinks[level.tail].next = orderId;
            _orderLinks[orderId].prev = level.tail;
            level.tail = orderId;
        }
        level.orderCount++;
    }

    /// @dev Remove order from linked list (O(1))
    function _removeFromBook(uint64 orderId) internal {
        Order storage o = orders[orderId];
        bool isBid = o.isBuy;
        TickLevel storage level = tickLevels[o.conditionId][isBid][o.tick];

        uint128 rem = o.quantity - o.filled;
        if (level.totalQuantity >= rem) level.totalQuantity -= rem;

        // remove from linked list (O(1))
        OrderLink storage link = _orderLinks[orderId];

        if (link.prev != 0) {
            _orderLinks[link.prev].next = link.next;
        } else {
            // this was the head
            level.head = link.next;
        }

        if (link.next != 0) {
            _orderLinks[link.next].prev = link.prev;
        } else {
            // this was the tail
            level.tail = link.prev;
        }

        // clear the link data
        delete _orderLinks[orderId];
        level.orderCount--;

        // clear bitmap if empty
        if (level.totalQuantity == 0) {
            _activeTicks[o.conditionId][isBid].unset(o.tick);
        }
    }

    /// @dev Find highest active tick for the given side using O(1) bit manipulation
    function _findHighestActiveTick(bytes32 cid, bool isBid) internal view returns (uint8) {
        // get the raw bitmap bucket (ticks 0-255, we use 1-99)
        uint256 bucket = _activeTicks[cid][isBid].map[0];

        // mask to only consider bits 1-99 (clear bit 0 and bits 100+)
        bucket = bucket & (((1 << 100) - 1) ^ 1);

        if (bucket == 0) return 0;

        // find most significant bit (highest tick) - O(1)
        uint256 tick = LibBit.fls(bucket);

        return (tick >= MIN_TICK && tick <= MAX_TICK) ? uint8(tick) : 0;
    }

    /// @dev Find lowest active tick for the given side using O(1) bit manipulation
    function _findLowestActiveTick(bytes32 cid, bool isBid) internal view returns (uint8) {
        // get the raw bitmap bucket (ticks 0-255, we use 1-99)
        uint256 bucket = _activeTicks[cid][isBid].map[0];

        // mask to only consider bits 1-99
        bucket = bucket & (((1 << 100) - 1) ^ 1);

        if (bucket == 0) return 0;

        // find least significant bit (lowest tick) - O(1)
        uint256 tick = LibBit.ffs(bucket);

        return (tick >= MIN_TICK && tick <= MAX_TICK) ? uint8(tick) : 0;
    }

    /// @dev Find previous active tick for the given side using O(1) bit manipulation
    function _findPrevActiveTick(bytes32 cid, bool isBid, uint8 current) internal view returns (uint8) {
        if (current <= MIN_TICK) return 0;

        // get the raw bitmap bucket
        uint256 bucket = _activeTicks[cid][isBid].map[0];

        // mask to only bits below current tick (1 to current-1)
        uint256 mask = (1 << current) - 2; // bits 1 to (current-1)
        bucket = bucket & mask;

        if (bucket == 0) return 0;

        // find most significant bit in the masked range - O(1)
        uint256 tick = LibBit.fls(bucket);

        return (tick >= MIN_TICK && tick <= MAX_TICK) ? uint8(tick) : 0;
    }

    /// @dev Find next active tick for the given side using O(1) bit manipulation
    function _findNextActiveTick(bytes32 cid, bool isBid, uint8 current) internal view returns (uint8) {
        if (current >= MAX_TICK) return 0;

        // get the raw bitmap bucket
        uint256 bucket = _activeTicks[cid][isBid].map[0];

        // mask to only bits above current tick (current+1 to 99)
        uint256 mask = (((1 << 100) - 1) ^ ((1 << (current + 1)) - 1));
        bucket = bucket & mask;

        if (bucket == 0) return 0;

        // find least significant bit in the masked range - O(1)
        uint256 tick = LibBit.ffs(bucket);

        return (tick >= MIN_TICK && tick <= MAX_TICK) ? uint8(tick) : 0;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          SIGNED ORDERS
    // ═══════════════════════════════════════════════════════════════════════════

    function fillSignedOrder(SignedOrder calldata so, bytes calldata sig, uint128 amount)
        external
        nonReentrant
        marketActive(so.conditionId)
    {
        bytes32 h = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    so.maker,
                    so.conditionId,
                    so.side,
                    so.tick,
                    so.quantity,
                    so.nonce,
                    so.expiry,
                    so.feeRateBps
                )
            )
        );
        if (ECDSA.recover(h, sig) != so.maker) revert InvalidSignature();
        if (block.timestamp > so.expiry) revert OrderExpired();
        if (so.nonce < minNonce[so.maker]) revert OrderAlreadyUsed();
        if (so.maker == msg.sender) revert SelfTrade();

        uint128 filled = signedOrderFills[h];
        if (amount > so.quantity - filled) revert InsufficientFill();
        signedOrderFills[h] = filled + amount;

        (bool isBuy, uint8 yesTick, bool wantsNo) = _normalize(so.side, so.tick);
        _settle(so.maker, msg.sender, so.conditionId, isBuy, wantsNo, yesTick, amount);
    }
}
