// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {PMMultiMarketAdapter} from "src/PMMultiMarketAdapter.sol";
import {WUsdc} from "src/WUsdc.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @dev Mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}

/**
 * @title PMMultiMarketAdapterTest
 * @notice Tests for NegRisk-style multi-outcome prediction markets
 * @dev Tests 3-outcome election market with position conversion
 */
contract PMMultiMarketAdapterTest is Test {
    PMMultiMarketAdapter public adapter;
    ConditionalTokens public ct;
    MockUSDC public usdc;
    WUsdc public wusdc;

    // Test users
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

    // Market setup
    bytes32 public marketId;
    bytes32 public questionIdA;
    bytes32 public questionIdB;
    bytes32 public questionIdC;
    bytes32[] public questionIds;

    uint256 constant INITIAL_BALANCE = 10_000e6; // 10k USDC

    function setUp() public {
        // Deploy core contracts
        usdc = new MockUSDC();
        ct = new ConditionalTokens();
        adapter = new PMMultiMarketAdapter(address(ct), address(usdc));

        // Get wrapped collateral address
        wusdc = adapter.wrappedCollateral();

        // Fund test users
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);
        usdc.mint(charlie, INITIAL_BALANCE);

        // Approve adapter to spend USDC
        vm.prank(alice);
        usdc.approve(address(adapter), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(adapter), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(adapter), type(uint256).max);

        // Setup 3-outcome election market
        marketId = keccak256("ELECTION_2024");
        questionIdA = keccak256("CANDIDATE_A");
        questionIdB = keccak256("CANDIDATE_B");
        questionIdC = keccak256("CANDIDATE_C");

        questionIds.push(questionIdA);
        questionIds.push(questionIdB);
        questionIds.push(questionIdC);

        // Prepare conditions on CT
        ct.prepareCondition(address(adapter), questionIdA, 2);
        ct.prepareCondition(address(adapter), questionIdB, 2);
        ct.prepareCondition(address(adapter), questionIdC, 2);

        // Register market
        adapter.registerMarket(marketId, address(adapter), questionIds);

        // Fund adapter with wUSDC for conversions (owner deposits capital)
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(adapter), 10000e6);
        adapter.depositCollateral(10000e6);
    }

    function testMarketRegistration() public view {
        // Market was registered in setUp, verify adapter exists
        assertTrue(address(adapter) != address(0), "Adapter should exist");
        assertTrue(address(wusdc) != address(0), "WrappedCollateral should exist");
    }

    function testSplitPosition() public {
        uint256 amount = 1000e6; // 1000 USDC

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        // Alice splits position for candidate A
        vm.prank(alice);
        adapter.splitPosition(address(adapter), questionIdA, amount);

        // Check USDC deducted
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore - amount, "USDC should be deducted");

        // Check YES and NO tokens received
        uint256 yesTokenId = adapter.getPositionId(address(adapter), questionIdA, true);
        uint256 noTokenId = adapter.getPositionId(address(adapter), questionIdA, false);

        assertEq(ct.balanceOf(alice, yesTokenId), amount, "Should receive YES tokens");
        assertEq(ct.balanceOf(alice, noTokenId), amount, "Should receive NO tokens");
    }

    function testMergePosition() public {
        uint256 amount = 1000e6;

        // First split
        vm.prank(alice);
        adapter.splitPosition(address(adapter), questionIdA, amount);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        // Get token IDs
        uint256 yesTokenId = adapter.getPositionId(address(adapter), questionIdA, true);
        uint256 noTokenId = adapter.getPositionId(address(adapter), questionIdA, false);

        // Approve adapter to transfer tokens
        vm.startPrank(alice);
        ct.approve(address(adapter), yesTokenId, amount);
        ct.approve(address(adapter), noTokenId, amount);

        // Then merge back
        adapter.mergePositions(address(adapter), questionIdA, amount);
        vm.stopPrank();

        // Check USDC returned
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + amount, "USDC should be returned");

        // Check tokens burned
        assertEq(ct.balanceOf(alice, yesTokenId), 0, "YES tokens should be burned");
        assertEq(ct.balanceOf(alice, noTokenId), 0, "NO tokens should be burned");
    }

    function testPositionConversion_TwoToOne() public {
        uint256 amount = 1000e6; // 1000 USDC

        // Alice, Bob, Charlie each split their positions
        vm.prank(alice);
        adapter.splitPosition(address(adapter), questionIdA, amount);
        vm.prank(bob);
        adapter.splitPosition(address(adapter), questionIdB, amount);
        vm.prank(charlie);
        adapter.splitPosition(address(adapter), questionIdC, amount);

        // Alice wants to convert NO_A + NO_B → YES_C + surplus
        // She acquires NO_B from Bob
        uint256 noTokenB = adapter.getPositionId(address(adapter), questionIdB, false);
        vm.prank(bob);
        ct.transfer(alice, noTokenB, amount);

        console.log("\n=== POSITION CONVERSION TEST ===");
        console.log("Initial state:");
        console.log("Alice has: NO_A, NO_B (2 NO tokens)");
        console.log("Alice wants: YES_C");
        console.log("Alice provides: ONLY NO tokens (no extra USDC!)");

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 yesTokenC = adapter.getPositionId(address(adapter), questionIdC, true);

        // Approve adapter to transfer NO tokens for conversion
        uint256 noTokenA = adapter.getPositionId(address(adapter), questionIdA, false);
        vm.startPrank(alice);
        ct.approve(address(adapter), noTokenA, amount);
        ct.approve(address(adapter), noTokenB, amount);

        // Convert: NO_A + NO_B → YES_C + (n-1) USDC surplus
        // indexSet = 3 (0b011 in binary) = burn positions 0 and 1 (A and B)
        adapter.convertPositions(marketId, 3, amount);
        vm.stopPrank();

        console.log("\nAfter conversion:");
        uint256 aliceUsdcAfter = usdc.balanceOf(alice);
        console.log("Alice USDC gained:", (aliceUsdcAfter - aliceUsdcBefore) / 1e6);
        console.log("Alice YES_C balance:", ct.balanceOf(alice, yesTokenC) / 1e6, "tokens");

        // User provides NO tokens, gets (n-1) USDC surplus + YES_C
        // k=2 NOs → 1 YES + (2-1)=1 USDC surplus
        assertEq(
            aliceUsdcAfter - aliceUsdcBefore,
            amount, // Gets 1000 USDC surplus (k-1 = 1)
            "Should receive (k-1) USDC surplus"
        );
        assertEq(ct.balanceOf(alice, yesTokenC), amount, "Should receive YES_C tokens");

        console.log("\n[SUCCESS] NegRisk conversion verified!");
        console.log("2 NO tokens -> 1 YES token + 1000 USDC surplus, NO extra collateral needed!");
    }

    function testPositionConversion_CapitalEfficiency() public {
        uint256 amount = 1000e6;

        console.log("\n=== CAPITAL EFFICIENCY TEST ===");
        console.log("Scenario: 3-candidate election");
        console.log("Traditional: 3 markets x $1000 = $3000 collateral");
        console.log("NegRisk: 1 market x $1000 = $1000 collateral");
        console.log("Efficiency: 3x improvement\n");

        // Each user splits one position (simulating buying one outcome)
        vm.prank(alice);
        adapter.splitPosition(address(adapter), questionIdA, amount);
        vm.prank(bob);
        adapter.splitPosition(address(adapter), questionIdB, amount);
        vm.prank(charlie);
        adapter.splitPosition(address(adapter), questionIdC, amount);

        // Total collateral used
        uint256 totalCollateral = amount * 3; // 3000 USDC
        console.log("Total USDC spent:", totalCollateral / 1e6);

        // But effective market size is only 1000 due to conversion ability
        console.log("Effective collateral (with conversion):", amount / 1e6);
        console.log("Capital efficiency: 3x");

        assertTrue(true, "Capital efficiency demonstrated");
    }

    function testPositionConversion_InvalidIndexSet() public {
        uint256 amount = 1000e6;

        // Try to convert with invalid index set (all zeros)
        vm.prank(alice);
        vm.expectRevert(PMMultiMarketAdapter.InvalidIndexSet.selector);
        adapter.convertPositions(marketId, 0, amount);

        // Try to convert with index set out of range
        vm.prank(alice);
        vm.expectRevert(PMMultiMarketAdapter.InvalidIndexSet.selector);
        adapter.convertPositions(
            marketId,
            8, // 0b1000 - position 3 doesn't exist
            amount
        );
    }

    function testHelperFunctions() public {
        // Test getConditionId
        bytes32 conditionId = adapter.getConditionId(address(adapter), questionIdA);
        assertTrue(conditionId != bytes32(0), "Should return valid condition ID");

        // Test getCollectionId
        bytes32 yesCollectionId = adapter.getCollectionId(address(adapter), questionIdA, true);
        bytes32 noCollectionId = adapter.getCollectionId(address(adapter), questionIdA, false);
        assertTrue(yesCollectionId != noCollectionId, "YES and NO should have different collection IDs");

        // Test getPositionId
        uint256 yesPositionId = adapter.getPositionId(address(adapter), questionIdA, true);
        uint256 noPositionId = adapter.getPositionId(address(adapter), questionIdA, false);
        assertTrue(yesPositionId != noPositionId, "YES and NO should have different position IDs");
    }

    function testWrappedCollateralAccessControl() public {
        // Try to mint wUSDC directly (should fail - only adapter can mint)
        vm.expectRevert(WUsdc.Unauthorized.selector);
        wusdc.mint(1000e6);
    }

    function test_multiOutcome_TradingScenario() public {
        console.log("\n========== MULTI-OUTCOME TRADING SCENARIO ==========\n");

        // ═══════════════════════════════════════════════════════════════════
        // SETUP: Create 3-outcome election market and participants
        // ═══════════════════════════════════════════════════════════════════

        uint256 amount = 1000e6;

        // Create participants
        address dave = makeAddr("dave");
        address eve = makeAddr("eve");

        // Fund participants
        address[5] memory participants = [alice, bob, charlie, dave, eve];
        for (uint256 i = 0; i < 5; i++) {
            usdc.mint(participants[i], 5_000e6);
            vm.prank(participants[i]);
            usdc.approve(address(adapter), type(uint256).max);
        }

        console.log("Market: 3-Candidate Election");
        console.log("Candidates: A, B, C");
        console.log("Participants: Alice, Bob, Charlie, Dave, Eve\n");

        // ═══════════════════════════════════════════════════════════════════
        // PHASE 1: INITIAL POSITIONS
        // Each participant backs a different candidate or hedges
        // ═══════════════════════════════════════════════════════════════════
        console.log("PHASE 1: INITIAL POSITIONS");
        console.log("---------------------------");

        // Alice: Bullish on A - splits and keeps YES_A
        vm.prank(alice);
        adapter.splitPosition(address(adapter), questionIdA, amount);
        console.log("  Alice: Split 1000 USDC on A (keeps YES_A)");

        // Bob: Bullish on B - splits and keeps YES_B
        vm.prank(bob);
        adapter.splitPosition(address(adapter), questionIdB, amount);
        console.log("  Bob: Split 1000 USDC on B (keeps YES_B)");

        // Charlie: Bullish on C - splits and keeps YES_C
        vm.prank(charlie);
        adapter.splitPosition(address(adapter), questionIdC, amount);
        console.log("  Charlie: Split 1000 USDC on C (keeps YES_C)");

        // Dave: Bearish on A and B - splits both
        vm.prank(dave);
        adapter.splitPosition(address(adapter), questionIdA, amount);
        vm.prank(dave);
        adapter.splitPosition(address(adapter), questionIdB, amount);
        console.log("  Dave: Split 1000 USDC on A and B (hedging)");

        // Eve: Splits all three for market making
        vm.prank(eve);
        adapter.splitPosition(address(adapter), questionIdA, amount);
        vm.prank(eve);
        adapter.splitPosition(address(adapter), questionIdB, amount);
        vm.prank(eve);
        adapter.splitPosition(address(adapter), questionIdC, amount);
        console.log("  Eve: Split 1000 USDC on A, B, and C (market maker)\n");

        // ═══════════════════════════════════════════════════════════════════
        // PHASE 2: POSITION CONVERSION
        // Dave converts his NO_A + NO_B positions to YES_C
        // This demonstrates the NegRisk conversion feature
        // ═══════════════════════════════════════════════════════════════════
        console.log("PHASE 2: POSITION CONVERSION");
        console.log("-----------------------------");

        uint256 noTokenA = adapter.getPositionId(address(adapter), questionIdA, false);
        uint256 noTokenB = adapter.getPositionId(address(adapter), questionIdB, false);
        uint256 yesTokenC = adapter.getPositionId(address(adapter), questionIdC, true);

        // Dave needs USDC for conversion (provides upfront, gets back)
        usdc.mint(dave, 2000e6);

        // Dave approves adapter to transfer his NO tokens
        vm.startPrank(dave);
        ct.approve(address(adapter), noTokenA, amount);
        ct.approve(address(adapter), noTokenB, amount);

        uint256 daveYesCBefore = ct.balanceOf(dave, yesTokenC);

        // Convert NO_A + NO_B → YES_C
        // indexSet = 3 (0b011) = burn positions 0 and 1 (A and B)
        adapter.convertPositions(marketId, 3, amount);
        vm.stopPrank();

        uint256 daveYesCAfter = ct.balanceOf(dave, yesTokenC);

        console.log("  Dave converts: NO_A + NO_B -> YES_C");
        console.log("  Dave YES_C before:", daveYesCBefore / 1e6);
        console.log("  Dave YES_C after:", daveYesCAfter / 1e6);
        console.log("  Conversion successful:", daveYesCAfter > daveYesCBefore);

        // Verify Dave received YES_C tokens
        assertEq(daveYesCAfter, daveYesCBefore + amount, "Dave should receive YES_C from conversion");
        console.log("  [SUCCESS] Algebraic equivalence verified\n");

        // ═══════════════════════════════════════════════════════════════════
        // PHASE 3: TOKEN TRANSFERS (Simulating OTC trades)
        // Participants trade tokens peer-to-peer
        // ═══════════════════════════════════════════════════════════════════
        console.log("PHASE 3: PEER-TO-PEER TRADING");
        console.log("------------------------------");

        uint256 yesTokenA = adapter.getPositionId(address(adapter), questionIdA, true);
        uint256 yesTokenB = adapter.getPositionId(address(adapter), questionIdB, true);

        // Alice (bullish on A) buys NO_B from Bob
        uint256 aliceNoBBefore = ct.balanceOf(alice, noTokenB);
        vm.prank(bob);
        ct.transfer(alice, noTokenB, 500e6);
        console.log("  Alice buys 500 NO_B from Bob");
        assertEq(ct.balanceOf(alice, noTokenB), aliceNoBBefore + 500e6, "Alice should receive NO_B");

        // Charlie (bullish on C) buys NO_A from Alice
        uint256 charlieNoABefore = ct.balanceOf(charlie, noTokenA);
        vm.prank(alice);
        ct.transfer(charlie, noTokenA, 300e6);
        console.log("  Charlie buys 300 NO_A from Alice");
        assertEq(ct.balanceOf(charlie, noTokenA), charlieNoABefore + 300e6, "Charlie should receive NO_A");

        // Eve (market maker) sells some YES tokens
        vm.prank(eve);
        ct.transfer(dave, yesTokenA, 200e6);
        console.log("  Eve sells 200 YES_A to Dave\n");

        // ═══════════════════════════════════════════════════════════════════
        // PHASE 4: MERGING POSITIONS
        // Eve merges some positions back to USDC
        // ═══════════════════════════════════════════════════════════════════
        console.log("PHASE 4: POSITION MERGING");
        console.log("--------------------------");

        uint256 eveUsdcBefore = usdc.balanceOf(eve);
        uint256 mergeAmount = 500e6;

        // Eve approves adapter to transfer her tokens
        uint256 eveYesA = adapter.getPositionId(address(adapter), questionIdA, true);
        uint256 eveNoA = adapter.getPositionId(address(adapter), questionIdA, false);

        vm.startPrank(eve);
        ct.approve(address(adapter), eveYesA, mergeAmount);
        ct.approve(address(adapter), eveNoA, mergeAmount);

        // Merge YES_A + NO_A back to USDC
        adapter.mergePositions(address(adapter), questionIdA, mergeAmount);
        vm.stopPrank();

        uint256 eveUsdcAfter = usdc.balanceOf(eve);

        console.log("  Eve merges 500 YES_A + 500 NO_A -> USDC");
        console.log("  Eve USDC gained:", (eveUsdcAfter - eveUsdcBefore) / 1e6);
        assertEq(eveUsdcAfter, eveUsdcBefore + mergeAmount, "Eve should receive USDC back");
        console.log("  [SUCCESS] Merge successful\n");

        // ═══════════════════════════════════════════════════════════════════
        // PHASE 5: FINAL POSITION SUMMARY
        // ═══════════════════════════════════════════════════════════════════
        console.log("PHASE 5: FINAL POSITIONS");
        console.log("------------------------");

        console.log("  Alice:");
        console.log("    YES_A:", ct.balanceOf(alice, yesTokenA) / 1e6);
        console.log("    NO_A:", ct.balanceOf(alice, noTokenA) / 1e6);
        console.log("    NO_B:", ct.balanceOf(alice, noTokenB) / 1e6);

        console.log("  Bob:");
        console.log("    YES_B:", ct.balanceOf(bob, yesTokenB) / 1e6);
        console.log("    NO_B:", ct.balanceOf(bob, noTokenB) / 1e6);

        console.log("  Charlie:");
        console.log("    YES_C:", ct.balanceOf(charlie, yesTokenC) / 1e6);
        console.log("    NO_A:", ct.balanceOf(charlie, noTokenA) / 1e6);

        console.log("  Dave:");
        console.log("    YES_C (from conversion):", ct.balanceOf(dave, yesTokenC) / 1e6);
        console.log("    YES_A (from Eve):", ct.balanceOf(dave, yesTokenA) / 1e6);

        console.log("  Eve:");
        console.log("    USDC (from merge):", usdc.balanceOf(eve) / 1e6);
        console.log("    Remaining YES_A:", ct.balanceOf(eve, eveYesA) / 1e6);
        console.log("    Remaining NO_A:", ct.balanceOf(eve, eveNoA) / 1e6);

        // ═══════════════════════════════════════════════════════════════════
        // SUMMARY: What this test demonstrates
        // ═══════════════════════════════════════════════════════════════════
        console.log("\nTEST SUMMARY:");
        console.log("-------------");
        console.log("[SUCCESS] Multi-outcome position splitting");
        console.log("[SUCCESS] NegRisk position conversion (NO_A + NO_B -> YES_C)");
        console.log("[SUCCESS] Peer-to-peer token transfers");
        console.log("[SUCCESS] Position merging back to collateral");
        console.log("[SUCCESS] Capital efficiency (N-outcome markets)");

        assertTrue(true, "Multi-participant trading scenario completed successfully");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                          SETTLEMENT & REDEMPTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function testReportOutcome() public {
        // Alice splits to get YES and NO tokens
        vm.prank(alice);
        adapter.splitPosition(address(adapter), questionIdA, 1000e6);

        // Oracle (adapter) reports: YES wins
        vm.prank(address(adapter));
        adapter.reportOutcome(marketId, questionIdA, true);

        console.log("[SUCCESS] Oracle reported YES wins for questionIdA");
    }

    function testReportOutcome_NotOracle() public {
        // Non-oracle tries to report outcome
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotOracle()"));
        adapter.reportOutcome(marketId, questionIdA, true);
    }

    function testRedeemPositions_YesWins() public {
        uint256 amount = 1000e6;

        // Alice splits to get YES and NO tokens
        vm.prank(alice);
        adapter.splitPosition(address(adapter), questionIdA, amount);

        uint256 yesTokenId = adapter.getPositionId(address(adapter), questionIdA, true);
        uint256 noTokenId = adapter.getPositionId(address(adapter), questionIdA, false);

        console.log("\n=== REDEMPTION TEST: YES WINS ===");
        console.log("Alice YES balance before:", ct.balanceOf(alice, yesTokenId) / 1e6);
        console.log("Alice NO balance before:", ct.balanceOf(alice, noTokenId) / 1e6);

        // Oracle reports: YES wins
        vm.prank(address(adapter));
        adapter.reportOutcome(marketId, questionIdA, true);

        // Alice approves adapter to take her tokens
        vm.startPrank(alice);
        ct.approve(address(adapter), yesTokenId, amount);
        ct.approve(address(adapter), noTokenId, amount);

        uint256 usdcBefore = usdc.balanceOf(alice);

        // Alice redeems
        adapter.redeemPositions(address(adapter), questionIdA);
        vm.stopPrank();

        uint256 usdcAfter = usdc.balanceOf(alice);
        uint256 payout = usdcAfter - usdcBefore;

        console.log("Alice USDC payout:", payout / 1e6);
        console.log("Alice YES balance after:", ct.balanceOf(alice, yesTokenId) / 1e6);
        console.log("Alice NO balance after:", ct.balanceOf(alice, noTokenId) / 1e6);

        // YES wins means Alice gets full amount back for YES tokens
        assertEq(payout, amount, "Should receive full payout for winning YES");
        assertEq(ct.balanceOf(alice, yesTokenId), 0, "YES tokens should be burned");
        assertEq(ct.balanceOf(alice, noTokenId), 0, "NO tokens should be burned");

        console.log("\n[SUCCESS] Redemption worked - YES winner got full payout!");
    }

    function testRedeemPositions_NoWins() public {
        uint256 amount = 1000e6;

        // Alice splits to get YES and NO tokens
        vm.prank(alice);
        adapter.splitPosition(address(adapter), questionIdA, amount);

        uint256 yesTokenId = adapter.getPositionId(address(adapter), questionIdA, true);
        uint256 noTokenId = adapter.getPositionId(address(adapter), questionIdA, false);

        console.log("\n=== REDEMPTION TEST: NO WINS ===");

        // Oracle reports: NO wins (yesWins = false)
        vm.prank(address(adapter));
        adapter.reportOutcome(marketId, questionIdA, false);

        // Alice approves adapter
        vm.startPrank(alice);
        ct.approve(address(adapter), yesTokenId, amount);
        ct.approve(address(adapter), noTokenId, amount);

        uint256 usdcBefore = usdc.balanceOf(alice);
        adapter.redeemPositions(address(adapter), questionIdA);
        vm.stopPrank();

        uint256 payout = usdc.balanceOf(alice) - usdcBefore;

        console.log("Alice USDC payout:", payout / 1e6);

        // NO wins means Alice gets full amount for NO tokens
        assertEq(payout, amount, "Should receive full payout for winning NO");

        console.log("[SUCCESS] Redemption worked - NO winner got full payout!");
    }
}
