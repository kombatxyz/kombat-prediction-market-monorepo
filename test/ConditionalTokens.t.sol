pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {ConditionalTokens} from "../src/ConditionalTokens.sol";
import {CTHelpers} from "../src/libraries/CTHelpers.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockCollateral is ERC20 {
    constructor() ERC20("Mock Collateral", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ConditionalTokensTest is Test {
    ConditionalTokens public ct;
    MockCollateral public collateral;

    address public oracle = makeAddr("oracle");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 public questionId = keccak256("Will BTC hit 100k?");
    uint256 public constant OUTCOME_COUNT = 2;

    function setUp() public {
        ct = new ConditionalTokens();
        collateral = new MockCollateral();

        collateral.mint(alice, 1000 ether);
        vm.prank(alice);
        collateral.approve(address(ct), type(uint256).max);
    }

    function test_prepareCondition() public {
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        assertEq(ct.getOutcomeSlotCount(conditionId), OUTCOME_COUNT);
    }

    function test_prepareCondition_emitsEvent() public {
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        vm.expectEmit(true, true, true, true);
        emit ConditionalTokens.ConditionPreparation(conditionId, oracle, questionId, OUTCOME_COUNT);

        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
    }

    function test_prepareCondition_revertsTooFewOutcomes() public {
        vm.expectRevert(ConditionalTokens.TooFewOutcomes.selector);
        ct.prepareCondition(oracle, questionId, 1);
    }

    function test_prepareCondition_revertsTooManyOutcomes() public {
        vm.expectRevert(ConditionalTokens.TooManyOutcomes.selector);
        ct.prepareCondition(oracle, questionId, 257);
    }

    function test_prepareCondition_revertsAlreadyPrepared() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        vm.expectRevert(ConditionalTokens.ConditionAlreadyPrepared.selector);
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
    }

    function test_reportPayouts_singleWinner() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        assertEq(ct.payoutDenominator(conditionId), 1);
        assertEq(ct.payoutNumerators(conditionId, 0), 1);
        assertEq(ct.payoutNumerators(conditionId, 1), 0);
    }

    function test_reportPayouts_splitPayouts() public {
        ct.prepareCondition(oracle, questionId, 3);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, 3);

        uint256[] memory payouts = new uint256[](3);
        payouts[0] = 1;
        payouts[1] = 2;
        payouts[2] = 1;

        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        assertEq(ct.payoutDenominator(conditionId), 4);
    }

    function test_reportPayouts_revertsNotOracle() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;

        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.ConditionNotPrepared.selector);
        ct.reportPayouts(questionId, payouts);
    }

    function test_reportPayouts_revertsAlreadyResolved() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;

        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        vm.prank(oracle);
        vm.expectRevert(ConditionalTokens.ConditionAlreadyResolved.selector);
        ct.reportPayouts(questionId, payouts);
    }

    function test_splitPosition_fromCollateral() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        uint256 amount = 100 ether;

        vm.prank(alice);
        ct.splitPosition(IERC20(address(collateral)), bytes32(0), conditionId, partition, amount);

        assertEq(collateral.balanceOf(address(ct)), amount);

        uint256 yesPositionId =
            ct.getPositionId(IERC20(address(collateral)), ct.getCollectionId(bytes32(0), conditionId, 1));
        uint256 noPositionId =
            ct.getPositionId(IERC20(address(collateral)), ct.getCollectionId(bytes32(0), conditionId, 2));

        assertEq(ct.balanceOf(alice, yesPositionId), amount);
        assertEq(ct.balanceOf(alice, noPositionId), amount);
    }

    function test_splitPosition_threeOutcomes() public {
        ct.prepareCondition(oracle, questionId, 3);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, 3);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 6;

        uint256 amount = 50 ether;

        vm.prank(alice);
        ct.splitPosition(IERC20(address(collateral)), bytes32(0), conditionId, partition, amount);

        uint256 pos0 = ct.getPositionId(IERC20(address(collateral)), ct.getCollectionId(bytes32(0), conditionId, 1));
        uint256 pos12 = ct.getPositionId(IERC20(address(collateral)), ct.getCollectionId(bytes32(0), conditionId, 6));

        assertEq(ct.balanceOf(alice, pos0), amount);
        assertEq(ct.balanceOf(alice, pos12), amount);
    }

    function test_splitPosition_revertsInvalidPartition() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory partition = new uint256[](1);
        partition[0] = 1;

        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.InvalidPartition.selector);
        ct.splitPosition(IERC20(address(collateral)), bytes32(0), conditionId, partition, 100);
    }

    function test_splitPosition_revertsNotDisjoint() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 3;

        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.PartitionNotDisjoint.selector);
        ct.splitPosition(IERC20(address(collateral)), bytes32(0), conditionId, partition, 100);
    }

    function test_mergePositions_toCollateral() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        uint256 amount = 100 ether;

        vm.prank(alice);
        ct.splitPosition(IERC20(address(collateral)), bytes32(0), conditionId, partition, amount);

        uint256 balanceBefore = collateral.balanceOf(alice);

        vm.prank(alice);
        ct.mergePositions(IERC20(address(collateral)), bytes32(0), conditionId, partition, amount);

        assertEq(collateral.balanceOf(alice), balanceBefore + amount);

        uint256 yesPositionId =
            ct.getPositionId(IERC20(address(collateral)), ct.getCollectionId(bytes32(0), conditionId, 1));
        uint256 noPositionId =
            ct.getPositionId(IERC20(address(collateral)), ct.getCollectionId(bytes32(0), conditionId, 2));

        assertEq(ct.balanceOf(alice, yesPositionId), 0);
        assertEq(ct.balanceOf(alice, noPositionId), 0);
    }

    function test_mergePositions_partialMerge() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        uint256 splitAmount = 100 ether;
        uint256 mergeAmount = 40 ether;

        vm.prank(alice);
        ct.splitPosition(IERC20(address(collateral)), bytes32(0), conditionId, partition, splitAmount);

        vm.prank(alice);
        ct.mergePositions(IERC20(address(collateral)), bytes32(0), conditionId, partition, mergeAmount);

        uint256 yesPositionId =
            ct.getPositionId(IERC20(address(collateral)), ct.getCollectionId(bytes32(0), conditionId, 1));

        assertEq(ct.balanceOf(alice, yesPositionId), splitAmount - mergeAmount);
    }

    function test_redeemPositions_singleWinner() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        uint256 amount = 100 ether;

        vm.prank(alice);
        ct.splitPosition(IERC20(address(collateral)), bytes32(0), conditionId, partition, amount);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        uint256 balanceBefore = collateral.balanceOf(alice);

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 1;

        vm.prank(alice);
        ct.redeemPositions(IERC20(address(collateral)), bytes32(0), conditionId, indexSets);

        assertEq(collateral.balanceOf(alice), balanceBefore + amount);
    }

    function test_redeemPositions_losingPosition() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        uint256 amount = 100 ether;

        vm.prank(alice);
        ct.splitPosition(IERC20(address(collateral)), bytes32(0), conditionId, partition, amount);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        uint256 balanceBefore = collateral.balanceOf(alice);

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 2;

        vm.prank(alice);
        ct.redeemPositions(IERC20(address(collateral)), bytes32(0), conditionId, indexSets);

        assertEq(collateral.balanceOf(alice), balanceBefore);
    }

    function test_redeemPositions_splitPayouts() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        uint256 amount = 100 ether;

        vm.prank(alice);
        ct.splitPosition(IERC20(address(collateral)), bytes32(0), conditionId, partition, amount);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 1;

        vm.prank(oracle);
        ct.reportPayouts(questionId, payouts);

        uint256 balanceBefore = collateral.balanceOf(alice);

        uint256[] memory indexSets = new uint256[](2);
        indexSets[0] = 1;
        indexSets[1] = 2;

        vm.prank(alice);
        ct.redeemPositions(IERC20(address(collateral)), bytes32(0), conditionId, indexSets);

        assertEq(collateral.balanceOf(alice), balanceBefore + amount);
    }

    function test_redeemPositions_revertsNotResolved() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 1;

        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.ConditionNotResolved.selector);
        ct.redeemPositions(IERC20(address(collateral)), bytes32(0), conditionId, indexSets);
    }

    function test_transfer() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.prank(alice);
        ct.splitPosition(IERC20(address(collateral)), bytes32(0), conditionId, partition, 100 ether);

        uint256 yesPositionId =
            ct.getPositionId(IERC20(address(collateral)), ct.getCollectionId(bytes32(0), conditionId, 1));

        vm.prank(alice);
        ct.transfer(bob, yesPositionId, 30 ether);

        assertEq(ct.balanceOf(alice, yesPositionId), 70 ether);
        assertEq(ct.balanceOf(bob, yesPositionId), 30 ether);
    }

    function test_transferFrom_withApproval() public {
        ct.prepareCondition(oracle, questionId, OUTCOME_COUNT);
        bytes32 conditionId = ct.getConditionId(oracle, questionId, OUTCOME_COUNT);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.prank(alice);
        ct.splitPosition(IERC20(address(collateral)), bytes32(0), conditionId, partition, 100 ether);

        uint256 yesPositionId =
            ct.getPositionId(IERC20(address(collateral)), ct.getCollectionId(bytes32(0), conditionId, 1));

        vm.prank(alice);
        ct.approve(bob, yesPositionId, 50 ether);

        vm.prank(bob);
        ct.transferFrom(alice, bob, yesPositionId, 30 ether);

        assertEq(ct.balanceOf(alice, yesPositionId), 70 ether);
        assertEq(ct.balanceOf(bob, yesPositionId), 30 ether);
        assertEq(ct.allowance(alice, bob, yesPositionId), 20 ether);
    }
}
