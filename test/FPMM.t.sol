// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {PMFpmm} from "src/amm/PMFpmm.sol";
import {ConditionalTokens} from "src/ConditionalTokens.sol";
import {TestNetUsdc} from "script/TestnetUsdc.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract PMFpmmTest is Test {
    PMFpmm public fpmm;
    ConditionalTokens public conditionalTokens;
    TestNetUsdc public usdc;

    // participants
    address oracle = makeAddr("oracle");
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    // market identifiers
    bytes32 questionId;
    bytes32 conditionId;
    bytes32 poolId;
    uint256 yesTokenId;
    uint256 noTokenId;

    function setUp() public {
        // deploy core contracts
        conditionalTokens = new ConditionalTokens();
        usdc = new TestNetUsdc();

        // deploy FPMM singleton
        fpmm = new PMFpmm(conditionalTokens);

        // prepare condition
        questionId = keccak256("Will ETH hit $10k by 2025?");
        vm.prank(oracle);
        conditionId = conditionalTokens.prepareCondition(oracle, questionId, 2);

        // calculate token IDs
        bytes32 yesCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = conditionalTokens.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), yesCollectionId);
        noTokenId = conditionalTokens.getPositionId(IERC20(address(usdc)), noCollectionId);

        // create pool
        poolId = fpmm.createPool(conditionId, IERC20(address(usdc)));

        // fund participants
        usdc.mint(lp, 10_000e6);
        usdc.mint(trader, 10_000e6);

        // approvals
        vm.prank(lp);
        usdc.approve(address(fpmm), type(uint256).max);
        vm.prank(lp);
        conditionalTokens.approve(address(fpmm), yesTokenId, type(uint256).max);
        vm.prank(lp);
        conditionalTokens.approve(address(fpmm), noTokenId, type(uint256).max);

        vm.prank(trader);
        usdc.approve(address(fpmm), type(uint256).max);
        vm.prank(trader);
        conditionalTokens.approve(address(fpmm), yesTokenId, type(uint256).max);
        vm.prank(trader);
        conditionalTokens.approve(address(fpmm), noTokenId, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                             POOL TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_createPool() public {
        bytes32 newQuestionId = keccak256("New question?");
        vm.prank(oracle);
        bytes32 newConditionId = conditionalTokens.prepareCondition(oracle, newQuestionId, 2);

        bytes32 newPoolId = fpmm.createPool(newConditionId, IERC20(address(usdc)));

        (IERC20 collateral, bytes32 storedConditionId, uint256 yId, uint256 nId,, bool initialized) =
            fpmm.pools(newPoolId);

        assertEq(address(collateral), address(usdc), "Collateral set");
        assertEq(storedConditionId, newConditionId, "Condition ID set");
        assertGt(yId, 0, "YES token ID");
        assertGt(nId, 0, "NO token ID");
        assertFalse(initialized, "Not initialized yet");
    }

    function test_getPoolId() public view {
        bytes32 computedId = fpmm.getPoolId(conditionId, address(usdc));
        assertEq(computedId, poolId, "Pool ID matches");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                           LIQUIDITY TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_addFunding_initial() public {
        uint256[] memory hint = new uint256[](0);

        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        // LP should receive LP tokens (ERC6909)
        assertEq(fpmm.balanceOf(lp, uint256(poolId)), 1000e6, "LP tokens minted");

        // pool should have equal YES and NO tokens
        (uint256 yesBalance, uint256 noBalance) = fpmm.getPoolBalances(poolId);
        assertEq(yesBalance, 1000e6, "YES balance");
        assertEq(noBalance, 1000e6, "NO balance");
    }

    function test_addFunding_withHint() public {
        // hint: 60% YES, 100% NO (implies YES is more likely)
        uint256[] memory hint = new uint256[](2);
        hint[0] = 60; // YES
        hint[1] = 100; // NO (max)

        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        // pool should have unequal balances based on hint
        (uint256 yesBalance, uint256 noBalance) = fpmm.getPoolBalances(poolId);
        assertEq(yesBalance, 600e6, "YES balance with hint");
        assertEq(noBalance, 1000e6, "NO balance with hint");
    }

    function test_addFunding_subsequent() public {
        // first add initial funding
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        uint256 lpTokensBefore = fpmm.balanceOf(lp, uint256(poolId));

        // add more funding
        vm.prank(lp);
        fpmm.addFunding(poolId, 500e6, hint);

        // LP tokens should increase proportionally
        assertGt(fpmm.balanceOf(lp, uint256(poolId)), lpTokensBefore, "More LP tokens");

        // pool balances should increase
        (uint256 yesBalance, uint256 noBalance) = fpmm.getPoolBalances(poolId);
        assertEq(yesBalance, 1500e6, "YES balance after");
        assertEq(noBalance, 1500e6, "NO balance after");
    }

    function test_removeFunding() public {
        // add initial funding
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        uint256 lpTokens = fpmm.balanceOf(lp, uint256(poolId));

        // remove half the funding
        vm.prank(lp);
        fpmm.removeFunding(poolId, lpTokens / 2);

        // LP tokens should be halved
        assertEq(fpmm.balanceOf(lp, uint256(poolId)), lpTokens / 2, "LP tokens halved");

        // pool balances should be halved
        (uint256 yesBalance, uint256 noBalance) = fpmm.getPoolBalances(poolId);
        assertEq(yesBalance, 500e6, "YES balance halved");
        assertEq(noBalance, 500e6, "NO balance halved");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                            TRADING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_buyYes() public {
        // setup: add liquidity
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        uint256 investmentAmount = 100e6;
        uint256 expectedTokens = fpmm.calcBuyAmount(poolId, investmentAmount, true);
        uint256 traderUsdcBefore = usdc.balanceOf(trader);

        vm.prank(trader);
        uint256 tokensBought = fpmm.buyYes(poolId, investmentAmount, expectedTokens);

        assertEq(tokensBought, expectedTokens, "buyYes returns correct amount");
        assertEq(conditionalTokens.balanceOf(trader, yesTokenId), tokensBought, "YES tokens received");
        assertEq(usdc.balanceOf(trader), traderUsdcBefore - investmentAmount, "USDC paid");

        console2.log("buyYes: Got %s YES for %s USDC", tokensBought / 1e6, investmentAmount / 1e6);
    }

    function test_buyNo() public {
        // setup: add liquidity
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        uint256 investmentAmount = 100e6;
        uint256 expectedTokens = fpmm.calcBuyAmount(poolId, investmentAmount, false);
        uint256 traderUsdcBefore = usdc.balanceOf(trader);

        vm.prank(trader);
        uint256 tokensBought = fpmm.buyNo(poolId, investmentAmount, expectedTokens);

        assertEq(tokensBought, expectedTokens, "buyNo returns correct amount");
        assertEq(conditionalTokens.balanceOf(trader, noTokenId), tokensBought, "NO tokens received");
        assertEq(usdc.balanceOf(trader), traderUsdcBefore - investmentAmount, "USDC paid");

        console2.log("buyNo: Got %s NO for %s USDC", tokensBought / 1e6, investmentAmount / 1e6);
    }

    function test_sellYes() public {
        // setup: add liquidity and buy tokens
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        vm.prank(trader);
        fpmm.buyYes(poolId, 100e6, 0);

        uint256 yesBalance = conditionalTokens.balanceOf(trader, yesTokenId);
        uint256 traderUsdcBefore = usdc.balanceOf(trader);

        uint256 returnAmount = 40e6;
        uint256 expectedTokensToSell = fpmm.calcSellAmount(poolId, returnAmount, true);

        vm.prank(trader);
        uint256 tokensSold = fpmm.sellYes(poolId, returnAmount, expectedTokensToSell);

        assertEq(tokensSold, expectedTokensToSell, "sellYes returns correct amount");
        assertEq(usdc.balanceOf(trader), traderUsdcBefore + returnAmount, "USDC received");
        assertEq(conditionalTokens.balanceOf(trader, yesTokenId), yesBalance - tokensSold, "YES tokens sold");

        console2.log("sellYes: Sold %s YES for %s USDC", tokensSold / 1e6, returnAmount / 1e6);
    }

    function test_sellNo() public {
        // setup: add liquidity and buy tokens
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        vm.prank(trader);
        fpmm.buyNo(poolId, 100e6, 0);

        uint256 noBalance = conditionalTokens.balanceOf(trader, noTokenId);
        uint256 traderUsdcBefore = usdc.balanceOf(trader);

        uint256 returnAmount = 40e6;
        uint256 expectedTokensToSell = fpmm.calcSellAmount(poolId, returnAmount, false);

        vm.prank(trader);
        uint256 tokensSold = fpmm.sellNo(poolId, returnAmount, expectedTokensToSell);

        assertEq(tokensSold, expectedTokensToSell, "sellNo returns correct amount");
        assertEq(usdc.balanceOf(trader), traderUsdcBefore + returnAmount, "USDC received");
        assertEq(conditionalTokens.balanceOf(trader, noTokenId), noBalance - tokensSold, "NO tokens sold");

        console2.log("sellNo: Sold %s NO for %s USDC", tokensSold / 1e6, returnAmount / 1e6);
    }

    function test_buy_movesPrice() public {
        // setup: add liquidity
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        // get initial prices
        uint256 yesPriceBefore = fpmm.yesPrice(poolId);
        uint256 noPriceBefore = fpmm.noPrice(poolId);
        console2.log("Price before YES:", yesPriceBefore * 100 / 1e18, "%");
        console2.log("Price before NO:", noPriceBefore * 100 / 1e18, "%");

        // buy YES tokens (should increase YES price)
        vm.prank(trader);
        fpmm.buyYes(poolId, 200e6, 0);

        // get new prices
        uint256 yesPriceAfter = fpmm.yesPrice(poolId);
        uint256 noPriceAfter = fpmm.noPrice(poolId);
        console2.log("Price after YES:", yesPriceAfter * 100 / 1e18, "%");
        console2.log("Price after NO:", noPriceAfter * 100 / 1e18, "%");

        assertGt(yesPriceAfter, yesPriceBefore, "YES price increased");
        assertLt(noPriceAfter, noPriceBefore, "NO price decreased");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          SLIPPAGE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_slippage_protection_buy() public {
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        vm.prank(trader);
        vm.expectRevert(PMFpmm.InsufficientBuyAmount.selector);
        fpmm.buyYes(poolId, 100e6, 1000e6); // expect 1000 tokens for 100 USDC - impossible
    }

    function test_slippage_protection_sell() public {
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        vm.prank(trader);
        fpmm.buyYes(poolId, 100e6, 0);

        vm.prank(trader);
        vm.expectRevert(PMFpmm.ExcessiveSellAmount.selector);
        fpmm.sellYes(poolId, 50e6, 1); // want 50 USDC but only willing to sell 1 token
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                            PRICE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_initialPrices_equal() public {
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        uint256 yPrice = fpmm.yesPrice(poolId);
        uint256 nPrice = fpmm.noPrice(poolId);

        // prices should be 50/50
        assertEq(yPrice, 5e17, "YES price 50%");
        assertEq(nPrice, 5e17, "NO price 50%");
    }

    function test_initialPrices_withHint() public {
        // hint implies 60% YES, 40% NO probability
        uint256[] memory hint = new uint256[](2);
        hint[0] = 40; // YES (less in pool = higher price)
        hint[1] = 60; // NO (more in pool = lower price)

        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        uint256 yPrice = fpmm.yesPrice(poolId);
        uint256 nPrice = fpmm.noPrice(poolId);

        console2.log("YES price:", yPrice * 100 / 1e18, "%");
        console2.log("NO price:", nPrice * 100 / 1e18, "%");

        // YES should have higher price (less supply)
        assertGt(yPrice, nPrice, "YES price > NO price");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          REVERT TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_revert_buyBeforeInit() public {
        // Create new pool but don't fund it
        bytes32 newQuestionId = keccak256("Another question?");
        vm.prank(oracle);
        bytes32 newConditionId = conditionalTokens.prepareCondition(oracle, newQuestionId, 2);
        bytes32 newPoolId = fpmm.createPool(newConditionId, IERC20(address(usdc)));

        vm.prank(trader);
        vm.expectRevert(PMFpmm.PoolNotInitialized.selector);
        fpmm.buyYes(newPoolId, 100e6, 0);
    }

    function test_revert_sellBeforeInit() public {
        bytes32 newQuestionId = keccak256("Another question?");
        vm.prank(oracle);
        bytes32 newConditionId = conditionalTokens.prepareCondition(oracle, newQuestionId, 2);
        bytes32 newPoolId = fpmm.createPool(newConditionId, IERC20(address(usdc)));

        vm.prank(trader);
        vm.expectRevert(PMFpmm.PoolNotInitialized.selector);
        fpmm.sellYes(newPoolId, 100e6, 0);
    }

    function test_revert_zeroAmount() public {
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        vm.expectRevert(PMFpmm.ZeroAmount.selector);
        fpmm.addFunding(poolId, 0, hint);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          ERC6909 TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_erc6909_transfer() public {
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        uint256 lpBalance = fpmm.balanceOf(lp, uint256(poolId));

        // transfer half to trader
        vm.prank(lp);
        fpmm.transfer(trader, uint256(poolId), lpBalance / 2);

        assertEq(fpmm.balanceOf(lp, uint256(poolId)), lpBalance / 2, "LP balance after");
        assertEq(fpmm.balanceOf(trader, uint256(poolId)), lpBalance / 2, "Trader balance after");
    }

    function test_erc6909_approve_transferFrom() public {
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        uint256 lpBalance = fpmm.balanceOf(lp, uint256(poolId));

        // approve trader to spend
        vm.prank(lp);
        fpmm.approve(trader, uint256(poolId), lpBalance);

        // trader transfers from lp
        vm.prank(trader);
        fpmm.transferFrom(lp, trader, uint256(poolId), lpBalance / 2);

        assertEq(fpmm.balanceOf(trader, uint256(poolId)), lpBalance / 2, "Trader got tokens");
    }

    function test_erc6909_setOperator() public {
        uint256[] memory hint = new uint256[](0);
        vm.prank(lp);
        fpmm.addFunding(poolId, 1000e6, hint);

        uint256 lpBalance = fpmm.balanceOf(lp, uint256(poolId));

        // set trader as operator
        vm.prank(lp);
        fpmm.setOperator(trader, true);

        assertTrue(fpmm.isOperator(lp, trader), "Operator set");

        // trader can transfer without specific approval
        vm.prank(trader);
        fpmm.transferFrom(lp, trader, uint256(poolId), lpBalance / 2);

        assertEq(fpmm.balanceOf(trader, uint256(poolId)), lpBalance / 2, "Trader got tokens via operator");
    }
}
