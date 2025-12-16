// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ConditionalTokens} from "./ConditionalTokens.sol";

contract PMExchange is ReentrancyGuard, EIP712, Ownable {
    using SafeERC20 for IERC20;

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

    struct Order {
        uint256 orderId;
        address trader;
        bytes32 conditionId;
        bool isBuy; // Normalized: true = buying YES
        bool wantsNo; // true if user wants NO token
        uint256 price; // YES price (normalized) in 1e18
        uint256 quantity;
        uint256 filled;
        TiF tif;
        OrderStatus status;
        uint256 timestamp;
    }

    struct SignedOrder {
        address maker;
        bytes32 conditionId;
        Side side;
        uint256 price;
        uint256 quantity;
        uint256 nonce;
        uint256 expiry;
        uint256 feeRateBps; // Max fee rate maker accepts
    }

    struct PriceLevel {
        uint256 price;
        uint256 totalQuantity;
        uint256[] orderIds;
    }

    struct Market {
        uint256 yesTokenId;
        uint256 noTokenId;
        bool registered;
        bool paused;
    }

    struct FeeConfig {
        uint16 makerFeeBps; // Fee charged to maker (can be negative = rebate)
        uint16 takerFeeBps; // Fee charged to taker
        uint16 protocolFeeBps; // Protocol fee
    }
    error InvalidQuantity();
    error InvalidPrice();
    error InvalidSignature();
    error OrderExpired();
    error OrderAlreadyUsed();
    error NotOrderOwner();
    error OrderNotActive();
    error InsufficientFill();
    error MarketNotRegistered();
    error MarketAlreadyRegistered();
    error MarketPaused();
    error NotOperator();
    error SelfTrade();
    error PostOnlyWouldTake();
    error InvalidFeeRate();
    error ArrayLengthMismatch();

    event MarketRegistered(bytes32 indexed conditionId, uint256 yesTokenId, uint256 noTokenId);
    event MarketPauseToggled(bytes32 indexed conditionId, bool paused);

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed trader,
        bytes32 indexed conditionId,
        Side side,
        uint256 price,
        uint256 quantity,
        TiF tif
    );

    event OrderMatched(
        uint256 indexed takerOrderId,
        uint256 indexed makerOrderId,
        uint256 price,
        uint256 quantity,
        uint256 takerFee,
        uint256 makerFee
    );

    event ComplementMint(
        bytes32 indexed conditionId, address indexed buyYesTrader, address indexed buyNoTrader, uint256 quantity
    );

    event ComplementBurn(
        bytes32 indexed conditionId, address indexed sellYesTrader, address indexed sellNoTrader, uint256 quantity
    );

    event OrderCancelled(uint256 indexed orderId, uint256 remainingQuantity);
    event SignedOrderFilled(
        bytes32 indexed orderHash, address indexed maker, address indexed taker, uint256 quantity, uint256 price
    );
    event OperatorUpdated(address indexed trader, address indexed operator, bool approved);
    event FeesUpdated(uint16 makerFeeBps, uint16 takerFeeBps, uint16 protocolFeeBps);
    event FeesCollected(address indexed collector, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    uint256 public constant PRICE_DENOMINATOR = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_FEE_BPS = 500; // 5% max

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,bytes32 conditionId,uint8 side,uint256 price,uint256 quantity,uint256 nonce,uint256 expiry,uint256 feeRateBps)"
    );

    // ═══════════════════════════════════════════════════════════════════════════
    //                                 STATE
    // ═══════════════════════════════════════════════════════════════════════════

    ConditionalTokens public immutable conditionalTokens;
    IERC20 public immutable usdc;

    // Orders
    mapping(uint256 => Order) public orders;
    mapping(bytes32 => mapping(bool => mapping(uint256 => PriceLevel))) public priceLevels;
    mapping(bytes32 => uint256[]) public bidPrices;
    mapping(bytes32 => uint256[]) public askPrices;
    uint256 public nextOrderId = 1;

    // Signed orders
    mapping(bytes32 => uint256) public signedOrderFills;
    mapping(address => uint256) public minNonce;

    // Markets
    mapping(bytes32 => Market) public markets;
    bytes32[] public marketList;

    // Fees
    FeeConfig public fees;
    uint256 public collectedFees;
    address public feeCollector;

    // Operators
    mapping(address => mapping(address => bool)) public operators;

    // User tracking
    mapping(address => uint256[]) public userOrders;
    mapping(address => uint256) public userOrderCount;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address _conditionalTokens, address _usdc) EIP712("PMExchange", "1") Ownable(msg.sender) {
        conditionalTokens = ConditionalTokens(_conditionalTokens);
        usdc = IERC20(_usdc);
        feeCollector = msg.sender;

        // Default fees: 0.1% taker, 0% maker, 0.05% protocol
        fees = FeeConfig({makerFeeBps: 0, takerFeeBps: 10, protocolFeeBps: 5});
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    modifier onlyOperatorOrSelf(address trader) {
        if (msg.sender != trader && !operators[trader][msg.sender]) revert NotOperator();
        _;
    }

    modifier marketActive(bytes32 conditionId) {
        if (!markets[conditionId].registered) revert MarketNotRegistered();
        if (markets[conditionId].paused) revert MarketPaused();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function registerMarket(bytes32 conditionId, uint256 yesTokenId, uint256 noTokenId) external onlyOwner {
        if (markets[conditionId].registered) revert MarketAlreadyRegistered();
        markets[conditionId] = Market(yesTokenId, noTokenId, true, false);
        marketList.push(conditionId);

        // Approve CT for complement operations
        usdc.approve(address(conditionalTokens), type(uint256).max);

        emit MarketRegistered(conditionId, yesTokenId, noTokenId);
    }

    function toggleMarketPause(bytes32 conditionId) external onlyOwner {
        markets[conditionId].paused = !markets[conditionId].paused;
        emit MarketPauseToggled(conditionId, markets[conditionId].paused);
    }

    function setFees(uint16 makerBps, uint16 takerBps, uint16 protocolBps) external onlyOwner {
        if (makerBps > MAX_FEE_BPS || takerBps > MAX_FEE_BPS || protocolBps > MAX_FEE_BPS) {
            revert InvalidFeeRate();
        }
        fees = FeeConfig(makerBps, takerBps, protocolBps);
        emit FeesUpdated(makerBps, takerBps, protocolBps);
    }

    function setFeeCollector(address _collector) external onlyOwner {
        feeCollector = _collector;
    }

    function collectFees() external {
        uint256 amount = collectedFees;
        collectedFees = 0;
        usdc.safeTransfer(feeCollector, amount);
        emit FeesCollected(feeCollector, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          OPERATOR FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function setOperator(address operator, bool approved) external {
        operators[msg.sender][operator] = approved;
        emit OperatorUpdated(msg.sender, operator, approved);
    }

    function isOperator(address trader, address operator) external view returns (bool) {
        return operators[trader][operator];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ORDER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Place a single order
    function placeOrder(bytes32 conditionId, Side side, uint256 price, uint256 quantity, TiF tif)
        external
        nonReentrant
        marketActive(conditionId)
        returns (uint256 orderId)
    {
        return _placeOrder(msg.sender, conditionId, side, price, quantity, tif);
    }

    /// @notice Place order on behalf of trader (operator only)
    function placeOrderFor(address trader, bytes32 conditionId, Side side, uint256 price, uint256 quantity, TiF tif)
        external
        nonReentrant
        onlyOperatorOrSelf(trader)
        marketActive(conditionId)
        returns (uint256 orderId)
    {
        return _placeOrder(trader, conditionId, side, price, quantity, tif);
    }

    /// @notice Place multiple orders in one transaction
    function batchPlaceOrders(
        bytes32[] calldata conditionIds,
        Side[] calldata sides,
        uint256[] calldata prices,
        uint256[] calldata quantities,
        TiF[] calldata tifs
    ) external nonReentrant returns (uint256[] memory orderIds) {
        uint256 len = conditionIds.length;
        if (len != sides.length || len != prices.length || len != quantities.length || len != tifs.length) {
            revert ArrayLengthMismatch();
        }

        orderIds = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            if (!markets[conditionIds[i]].registered || markets[conditionIds[i]].paused) continue;
            orderIds[i] = _placeOrder(msg.sender, conditionIds[i], sides[i], prices[i], quantities[i], tifs[i]);
        }
    }

    /// @notice Cancel a single order
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (msg.sender != o.trader && !operators[o.trader][msg.sender]) revert NotOrderOwner();
        if (o.status != OrderStatus.Active && o.status != OrderStatus.PartiallyFilled) revert OrderNotActive();

        _removeFromBook(orderId);
        o.status = OrderStatus.Cancelled;
        emit OrderCancelled(orderId, o.quantity - o.filled);
    }

    /// @notice Cancel multiple orders
    function batchCancelOrders(uint256[] calldata orderIds) external nonReentrant {
        for (uint256 i = 0; i < orderIds.length; i++) {
            Order storage o = orders[orderIds[i]];
            if (msg.sender != o.trader && !operators[o.trader][msg.sender]) continue;
            if (o.status != OrderStatus.Active && o.status != OrderStatus.PartiallyFilled) continue;

            _removeFromBook(orderIds[i]);
            o.status = OrderStatus.Cancelled;
            emit OrderCancelled(orderIds[i], o.quantity - o.filled);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                       SIGNED ORDER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function fillSignedOrder(SignedOrder calldata so, bytes calldata sig, uint256 amount)
        external
        nonReentrant
        marketActive(so.conditionId)
    {
        _fillSignedOrder(so, sig, amount, msg.sender);
    }

    function batchFillSignedOrders(SignedOrder[] calldata orders_, bytes[] calldata sigs, uint256[] calldata amounts)
        external
        nonReentrant
    {
        if (orders_.length != sigs.length || orders_.length != amounts.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < orders_.length; i++) {
            if (!markets[orders_[i].conditionId].registered || markets[orders_[i].conditionId].paused) continue;
            _fillSignedOrder(orders_[i], sigs[i], amounts[i], msg.sender);
        }
    }

    function cancelAllOrders(uint256 newMinNonce) external {
        minNonce[msg.sender] = newMinNonce;
    }

    function getOrderHash(SignedOrder calldata o) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH, o.maker, o.conditionId, o.side, o.price, o.quantity, o.nonce, o.expiry, o.feeRateBps
                )
            )
        );
    }

    function getRemainingFillable(SignedOrder calldata o) external view returns (uint256) {
        return o.quantity - signedOrderFills[getOrderHash(o)];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function getBestBid(bytes32 c) external view returns (uint256 price, uint256 size) {
        if (bidPrices[c].length == 0) return (0, 0);
        price = bidPrices[c][0];
        size = priceLevels[c][true][price].totalQuantity;
    }

    function getBestAsk(bytes32 c) external view returns (uint256 price, uint256 size) {
        if (askPrices[c].length == 0) return (0, 0);
        price = askPrices[c][0];
        size = priceLevels[c][false][price].totalQuantity;
    }

    function getSpread(bytes32 c) external view returns (uint256 bidPrice, uint256 askPrice, uint256 spread) {
        if (bidPrices[c].length > 0) bidPrice = bidPrices[c][0];
        if (askPrices[c].length > 0) askPrice = askPrices[c][0];
        if (bidPrice > 0 && askPrice > 0 && askPrice > bidPrice) {
            spread = askPrice - bidPrice;
        }
    }

    function getOrderBookDepth(bytes32 c, uint256 depth)
        external
        view
        returns (uint256[] memory bp, uint256[] memory bs, uint256[] memory ap, uint256[] memory as_)
    {
        uint256 bd = bidPrices[c].length < depth ? bidPrices[c].length : depth;
        uint256 ad = askPrices[c].length < depth ? askPrices[c].length : depth;
        bp = new uint256[](bd);
        bs = new uint256[](bd);
        ap = new uint256[](ad);
        as_ = new uint256[](ad);
        for (uint256 i = 0; i < bd; i++) {
            bp[i] = bidPrices[c][i];
            bs[i] = priceLevels[c][true][bp[i]].totalQuantity;
        }
        for (uint256 i = 0; i < ad; i++) {
            ap[i] = askPrices[c][i];
            as_[i] = priceLevels[c][false][ap[i]].totalQuantity;
        }
    }

    /// @notice Get NO book view (computed from YES book)
    function getNoBookDepth(bytes32 c, uint256 depth)
        external
        view
        returns (uint256[] memory bp, uint256[] memory bs, uint256[] memory ap, uint256[] memory as_)
    {
        // NO bids = 1 - YES asks
        // NO asks = 1 - YES bids
        uint256 ad = bidPrices[c].length < depth ? bidPrices[c].length : depth;
        uint256 bd = askPrices[c].length < depth ? askPrices[c].length : depth;
        bp = new uint256[](bd);
        bs = new uint256[](bd);
        ap = new uint256[](ad);
        as_ = new uint256[](ad);

        for (uint256 i = 0; i < bd; i++) {
            bp[i] = PRICE_DENOMINATOR - askPrices[c][i];
            bs[i] = priceLevels[c][false][askPrices[c][i]].totalQuantity;
        }
        for (uint256 i = 0; i < ad; i++) {
            ap[i] = PRICE_DENOMINATOR - bidPrices[c][i];
            as_[i] = priceLevels[c][true][bidPrices[c][i]].totalQuantity;
        }
    }

    function getUserOrders(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds, Order[] memory orderData)
    {
        uint256 total = userOrders[user].length;
        if (offset >= total) return (new uint256[](0), new Order[](0));

        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 len = end - offset;
        orderIds = new uint256[](len);
        orderData = new Order[](len);

        for (uint256 i = 0; i < len; i++) {
            orderIds[i] = userOrders[user][offset + i];
            orderData[i] = orders[orderIds[i]];
        }
    }

    function getActiveOrdersCount(bytes32 conditionId) external view returns (uint256 bidCount, uint256 askCount) {
        for (uint256 i = 0; i < bidPrices[conditionId].length; i++) {
            bidCount += priceLevels[conditionId][true][bidPrices[conditionId][i]].orderIds.length;
        }
        for (uint256 i = 0; i < askPrices[conditionId].length; i++) {
            askCount += priceLevels[conditionId][false][askPrices[conditionId][i]].orderIds.length;
        }
    }

    function getMarketCount() external view returns (uint256) {
        return marketList.length;
    }

    function getMarkets(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        uint256 total = marketList.length;
        if (offset >= total) return new bytes32[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        bytes32[] memory result = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = marketList[i];
        }
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════

    function _placeOrder(address trader, bytes32 conditionId, Side side, uint256 price, uint256 quantity, TiF tif)
        internal
        returns (uint256 orderId)
    {
        if (quantity == 0) revert InvalidQuantity();
        if (price == 0 || price > PRICE_DENOMINATOR) revert InvalidPrice();

        (bool isBuy, uint256 yesPrice, bool wantsNo) = _normalize(side, price);

        orderId = nextOrderId++;
        orders[orderId] = Order({
            orderId: orderId,
            trader: trader,
            conditionId: conditionId,
            isBuy: isBuy,
            wantsNo: wantsNo,
            price: yesPrice,
            quantity: quantity,
            filled: 0,
            tif: tif,
            status: OrderStatus.Active,
            timestamp: block.timestamp
        });

        userOrders[trader].push(orderId);
        userOrderCount[trader]++;

        // POST_ONLY check
        if (tif == TiF.POST_ONLY) {
            if (_wouldMatch(conditionId, isBuy, yesPrice)) revert PostOnlyWouldTake();
            _addToBook(orderId);
            emit OrderPlaced(orderId, trader, conditionId, side, price, quantity, tif);
            return orderId;
        }

        // Match
        uint256 filled = _matchOrder(orderId);

        // Try complement matching if still unfilled
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

        emit OrderPlaced(orderId, trader, conditionId, side, price, quantity, tif);
    }

    function _normalize(Side s, uint256 p) internal pure returns (bool isBuy, uint256 yesPrice, bool wantsNo) {
        if (s == Side.BuyYes) return (true, p, false);
        if (s == Side.SellYes) return (false, p, false);
        if (s == Side.BuyNo) return (false, PRICE_DENOMINATOR - p, true);
        return (true, PRICE_DENOMINATOR - p, true); // SellNo
    }

    function _wouldMatch(bytes32 cid, bool isBuy, uint256 price) internal view returns (bool) {
        if (isBuy) {
            if (askPrices[cid].length == 0) return false;
            return askPrices[cid][0] <= price;
        } else {
            if (bidPrices[cid].length == 0) return false;
            return bidPrices[cid][0] >= price;
        }
    }

    function _matchOrder(uint256 tid) internal returns (uint256 totalFilled) {
        Order storage t = orders[tid];
        uint256[] storage opp = t.isBuy ? askPrices[t.conditionId] : bidPrices[t.conditionId];
        uint256 rem = t.quantity - t.filled;

        uint256 i = 0;
        while (i < opp.length && rem > 0) {
            uint256 p = opp[i];
            if (t.isBuy && p > t.price) break;
            if (!t.isBuy && p < t.price) break;

            PriceLevel storage lvl = priceLevels[t.conditionId][!t.isBuy][p];

            uint256 j = 0;
            while (j < lvl.orderIds.length && rem > 0) {
                Order storage m = orders[lvl.orderIds[j]];
                if (m.status != OrderStatus.Active && m.status != OrderStatus.PartiallyFilled) j++;
                continue;
                if (m.trader == t.trader) j++; // Self-trade prevention
                continue;

                uint256 fill = m.quantity - m.filled;
                if (fill > rem) fill = rem;

                (uint256 takerFee, uint256 makerFee) = _calculateFees(fill, p);
                _settle(t.trader, m.trader, t.conditionId, t.isBuy, t.wantsNo, m.isBuy, m.wantsNo, p, fill);
                _collectProtocolFee(fill, p);

                t.filled += fill;
                m.filled += fill;
                totalFilled += fill;
                rem -= fill;
                lvl.totalQuantity -= fill;

                emit OrderMatched(tid, m.orderId, p, fill, takerFee, makerFee);

                if (m.filled == m.quantity) {
                    m.status = OrderStatus.Filled;
                    lvl.orderIds[j] = lvl.orderIds[lvl.orderIds.length - 1];
                    lvl.orderIds.pop();
                } else {
                    m.status = OrderStatus.PartiallyFilled;
                    j++;
                }
            }

            if (lvl.totalQuantity == 0) {
                _removePriceLevel(t.conditionId, !t.isBuy, p, i);
            } else {
                i++;
            }
        }

        if (t.filled == t.quantity) t.status = OrderStatus.Filled;
    }

    /// @dev Try matching BuyYes + BuyNo via complement minting
    function _tryComplementMatch(uint256 orderId) internal returns (uint256 filled) {
        Order storage order = orders[orderId];
        if (!order.isBuy) return 0; // Only works for buy orders

        bytes32 cid = order.conditionId;
        uint256 rem = order.quantity - order.filled;

        // Look for opposite buy orders that would sum to >= 1
        // If this is BuyYes at 0.6, look for BuyNo at >= 0.4 (stored as BuyYes at 0.6)
        // Actually for complement: BuyYes matches with orders where wantsNo=true and same isBuy=true

        uint256[] storage sameSidePrices = bidPrices[cid];

        for (uint256 i = 0; i < sameSidePrices.length && rem > 0; i++) {
            uint256 p = sameSidePrices[i];

            // Check if prices complement (sum >= 1)
            if (order.price + p < PRICE_DENOMINATOR) continue;

            PriceLevel storage lvl = priceLevels[cid][true][p];

            for (uint256 j = 0; j < lvl.orderIds.length && rem > 0; j++) {
                Order storage m = orders[lvl.orderIds[j]];
                if (m.orderId == orderId) continue;
                if (m.status != OrderStatus.Active && m.status != OrderStatus.PartiallyFilled) continue;
                if (m.trader == order.trader) continue;
                if (m.wantsNo == order.wantsNo) continue; // Need opposite wants

                uint256 fill = m.quantity - m.filled;
                if (fill > rem) fill = rem;

                // Execute complement mint
                bool success = _executeComplementMint(order, m, fill);
                if (!success) continue;

                order.filled += fill;
                m.filled += fill;
                filled += fill;
                rem -= fill;
                lvl.totalQuantity -= fill;

                if (m.filled == m.quantity) {
                    m.status = OrderStatus.Filled;
                    lvl.orderIds[j] = lvl.orderIds[lvl.orderIds.length - 1];
                    lvl.orderIds.pop();
                } else {
                    m.status = OrderStatus.PartiallyFilled;
                }
            }
        }

        if (order.filled == order.quantity) order.status = OrderStatus.Filled;
    }

    function _executeComplementMint(Order storage yesOrder, Order storage noOrder, uint256 qty)
        internal
        returns (bool)
    {
        Market storage market = markets[yesOrder.conditionId];

        // Determine who wants YES vs NO
        Order storage actualYes = yesOrder.wantsNo ? noOrder : yesOrder;
        Order storage actualNo = yesOrder.wantsNo ? yesOrder : noOrder;

        uint256 yesUsdcAmt = (qty * actualYes.price) / PRICE_DENOMINATOR;
        uint256 noUsdcAmt = (qty * (PRICE_DENOMINATOR - actualYes.price)) / PRICE_DENOMINATOR;

        // Pull USDC from both
        usdc.safeTransferFrom(actualYes.trader, address(this), yesUsdcAmt);
        usdc.safeTransferFrom(actualNo.trader, address(this), noUsdcAmt);

        // Mint via splitPosition
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        conditionalTokens.splitPosition(usdc, bytes32(0), yesOrder.conditionId, partition, qty);

        // Distribute
        conditionalTokens.transfer(actualYes.trader, market.yesTokenId, qty);
        conditionalTokens.transfer(actualNo.trader, market.noTokenId, qty);

        emit ComplementMint(yesOrder.conditionId, actualYes.trader, actualNo.trader, qty);
        return true;
    }

    function _fillSignedOrder(SignedOrder calldata so, bytes calldata sig, uint256 amount, address taker) internal {
        bytes32 h = getOrderHash(so);
        if (ECDSA.recover(h, sig) != so.maker) revert InvalidSignature();
        if (block.timestamp > so.expiry) revert OrderExpired();
        if (so.nonce < minNonce[so.maker]) revert OrderAlreadyUsed();
        if (so.maker == taker) revert SelfTrade();

        uint256 filled = signedOrderFills[h];
        if (amount > so.quantity - filled) revert InsufficientFill();
        signedOrderFills[h] = filled + amount;

        (bool isBuy, uint256 yesPrice, bool wantsNo) = _normalize(so.side, so.price);
        _settle(so.maker, taker, so.conditionId, isBuy, wantsNo, !isBuy, !wantsNo, yesPrice, amount);

        emit SignedOrderFilled(h, so.maker, taker, amount, so.price);
    }

    function _settle(
        address takerAddr,
        address makerAddr,
        bytes32 cid,
        bool takerBuysYes,
        bool takerWantsNo,
        bool,
        bool,
        uint256 yesPrice,
        uint256 qty
    ) internal {
        Market storage m = markets[cid];
        uint256 usdcAmt = (qty * yesPrice) / PRICE_DENOMINATOR;

        if (takerBuysYes && !takerWantsNo) {
            conditionalTokens.transferFrom(makerAddr, takerAddr, m.yesTokenId, qty);
            usdc.safeTransferFrom(takerAddr, makerAddr, usdcAmt);
        } else if (!takerBuysYes && !takerWantsNo) {
            conditionalTokens.transferFrom(takerAddr, makerAddr, m.yesTokenId, qty);
            usdc.safeTransferFrom(makerAddr, takerAddr, usdcAmt);
        } else if (!takerBuysYes && takerWantsNo) {
            uint256 noAmt = (qty * (PRICE_DENOMINATOR - yesPrice)) / PRICE_DENOMINATOR;
            conditionalTokens.transferFrom(makerAddr, takerAddr, m.noTokenId, qty);
            usdc.safeTransferFrom(takerAddr, makerAddr, noAmt);
        } else {
            uint256 noAmt = (qty * (PRICE_DENOMINATOR - yesPrice)) / PRICE_DENOMINATOR;
            conditionalTokens.transferFrom(takerAddr, makerAddr, m.noTokenId, qty);
            usdc.safeTransferFrom(makerAddr, takerAddr, noAmt);
        }
    }

    function _calculateFees(uint256 qty, uint256 price) internal view returns (uint256 takerFee, uint256 makerFee) {
        uint256 notional = (qty * price) / PRICE_DENOMINATOR;
        takerFee = (notional * fees.takerFeeBps) / BPS_DENOMINATOR;
        makerFee = (notional * fees.makerFeeBps) / BPS_DENOMINATOR;
    }

    function _collectProtocolFee(uint256 qty, uint256 price) internal {
        uint256 notional = (qty * price) / PRICE_DENOMINATOR;
        uint256 protocolFee = (notional * fees.protocolFeeBps) / BPS_DENOMINATOR;
        collectedFees += protocolFee;
    }

    function _addToBook(uint256 oid) internal {
        Order storage o = orders[oid];
        PriceLevel storage lvl = priceLevels[o.conditionId][o.isBuy][o.price];
        if (lvl.totalQuantity == 0) {
            lvl.price = o.price;
            _insertPrice(o.conditionId, o.isBuy, o.price);
        }
        lvl.totalQuantity += o.quantity - o.filled;
        lvl.orderIds.push(oid);
    }

    function _removeFromBook(uint256 oid) internal {
        Order storage o = orders[oid];
        PriceLevel storage lvl = priceLevels[o.conditionId][o.isBuy][o.price];
        uint256 rem = o.quantity - o.filled;
        if (lvl.totalQuantity >= rem) lvl.totalQuantity -= rem;

        for (uint256 i = 0; i < lvl.orderIds.length; i++) {
            if (lvl.orderIds[i] == oid) {
                lvl.orderIds[i] = lvl.orderIds[lvl.orderIds.length - 1];
                lvl.orderIds.pop();
                break;
            }
        }
        if (lvl.totalQuantity == 0) _removePriceLevel(o.conditionId, o.isBuy, o.price, type(uint256).max);
    }

    function _insertPrice(bytes32 c, bool isBid, uint256 p) internal {
        uint256[] storage arr = isBid ? bidPrices[c] : askPrices[c];
        uint256 i = 0;
        if (isBid) while (i < arr.length && p < arr[i]) i++;
        else while (i < arr.length && p > arr[i]) i++;
        arr.push(0);
        for (uint256 j = arr.length - 1; j > i; j--) {
            arr[j] = arr[j - 1];
        }
        arr[i] = p;
    }

    function _removePriceLevel(bytes32 c, bool isBid, uint256 p, uint256 hint) internal {
        uint256[] storage arr = isBid ? bidPrices[c] : askPrices[c];
        uint256 idx = hint;
        if (idx == type(uint256).max) {
            for (uint256 i = 0; i < arr.length; i++) {
                if (arr[i] == p) idx = i;
                break;
            }
        }
        if (idx < arr.length) {
            for (uint256 i = idx; i < arr.length - 1; i++) {
                arr[i] = arr[i + 1];
            }
            arr.pop();
        }
        delete priceLevels[c][isBid][p];
    }
}
