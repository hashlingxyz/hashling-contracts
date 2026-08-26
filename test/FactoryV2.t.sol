// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {HashlingFactoryV2} from "../src/HashlingFactoryV2.sol";
import {HashlingTokenV2} from "../src/HashlingTokenV2.sol";
import {
    IHashlingMigratorV2
} from "../src/interfaces/IHashlingV3.sol";

contract MockMigratorV2 is IHashlingMigratorV2 {
    using SafeERC20 for IERC20;

    address public constant POOL = address(0xBEEF);
    uint256 public nextPositionId = 1;
    bool public failMigration;
    bool public poolAvailable = true;
    bool public failCorrection;

    function factory() external pure returns (address) {
        return address(0);
    }

    function setFailMigration(bool fail_) external {
        failMigration = fail_;
    }

    function setFailCorrection(bool fail_) external {
        failCorrection = fail_;
    }

    function setPoolAvailable(bool available_) external {
        poolAvailable = available_;
    }

    function poolWithinTolerance(address, uint256, uint256)
        external
        view
        returns (bool)
    {
        return poolAvailable;
    }

    function preparePool(address, uint256, uint256)
        external
        pure
        returns (
            address pool,
            uint24 poolFee,
            uint160 sqrtPriceX96
        )
    {
        return (POOL, 10_000, uint160(1 << 96));
    }

    function migrate(
        address token,
        address,
        uint256,
        uint256,
        uint256 tokenAmountDesired
    )
        external
        payable
        returns (
            address pool,
            uint24 poolFee,
            uint256 positionId,
            uint256 ethUsed,
            uint256 tokenUsed
        )
    {
        require(!failMigration, "mock migration failure");

        IERC20(token).safeTransferFrom(
            msg.sender,
            address(this),
            tokenAmountDesired
        );

        tokenUsed = tokenAmountDesired / 2;
        uint256 tokenDust = tokenAmountDesired - tokenUsed;
        if (tokenDust != 0) {
            IERC20(token).safeTransfer(msg.sender, tokenDust);
        }

        return (
            POOL,
            10_000,
            nextPositionId++,
            msg.value,
            tokenUsed
        );
    }

    function correctPool(
        address,
        address,
        uint256,
        uint256,
        uint256
    ) external payable returns (uint256, uint256) {
        require(!failCorrection, "mock correction failure");
        poolAvailable = true;
        return (0, 0);
    }
}

contract FactoryV2Test is Test {
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant PROTOCOL = address(0xFEE);

    MockMigratorV2 internal migrator;
    HashlingFactoryV2 internal factory;
    address internal token;

    function setUp() public {
        migrator = new MockMigratorV2();
        factory =
            new HashlingFactoryV2(address(migrator), PROTOCOL);

        vm.prank(CREATOR);
        token = factory.launch(
            "Hashling V2 Test",
            "HV2",
            1e9 ether,
            ""
        );

        vm.deal(BUYER, 100 ether);
    }

    function testLaunchMintsCompleteSupplyOnce() public view {
        HashlingTokenV2 launched = HashlingTokenV2(token);
        assertEq(launched.initialSupply(), 1e9 ether);
        assertEq(launched.totalSupply(), 1e9 ether);
        assertEq(
            launched.balanceOf(address(factory)),
            1e9 ether
        );
        assertEq(launched.factory(), address(factory));
    }

    function testRejectsSupplyOutsideRange() public {
        vm.startPrank(CREATOR);
        vm.expectRevert(
            HashlingFactoryV2.SupplyOutOfRange.selector
        );
        factory.launch("Small", "S", 1e6 ether - 1, "");

        vm.expectRevert(
            HashlingFactoryV2.SupplyOutOfRange.selector
        );
        factory.launch("Large", "L", 1e12 ether + 1, "");
        vm.stopPrank();
    }

    function testRejectsZeroFeeDustTrades() public {
        vm.expectRevert(HashlingFactoryV2.DustTrade.selector);
        factory.quoteBuy(token, 1);

        vm.prank(BUYER);
        factory.buy{value: 1 ether}(token, 0);
        vm.expectRevert(HashlingFactoryV2.DustTrade.selector);
        factory.quoteSell(token, 1);
    }

    function testSubFeeFinalRemainderCanCloseCurve() public {
        uint256 target = factory.REF_RAISE_TARGET();
        uint256 netBefore = target - 1;
        uint256 grossBefore =
            ((netBefore * 10_000) + 9_899) / 9_900;

        if (
            (grossBefore - 1)
                - (((grossBefore - 1) * 100) / 10_000)
                >= netBefore
        ) {
            grossBefore -= 1;
        }

        vm.prank(BUYER);
        factory.buy{value: grossBefore}(token, 0);

        (,, uint128 realEth,, uint128 raiseTarget,) =
            factory.curves(token);
        assertEq(uint256(raiseTarget) - realEth, 1);

        (, uint256 grossUsed, uint256 fee,) =
            factory.quoteBuy(token, 2);
        assertEq(grossUsed, 2);
        assertEq(fee, 1);

        vm.prank(BUYER);
        factory.buy{value: 2}(token, 0);
        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.GraduationReady)
        );
    }

    function testFinalPurchaseRefundsAndFreezes() public {
        (
            uint256 expectedTokens,
            uint256 grossUsed,
            ,
            uint256 refund
        ) = factory.quoteBuy(token, 10 ether);

        uint256 beforeBalance = BUYER.balance;
        vm.prank(BUYER);
        uint256 actualTokens =
            factory.buy{value: 10 ether}(token, expectedTokens);

        assertEq(actualTokens, expectedTokens);
        assertEq(beforeBalance - BUYER.balance, grossUsed);
        assertEq(refund, 10 ether - grossUsed);
        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.GraduationReady)
        );

        (,, uint128 realEth,, uint128 target,) =
            factory.curves(token);
        (
            uint128 migrationFee,
            uint128 finalEffectiveEth,
            uint128 finalTokenReserve,
            ,
            ,
            ,

        ) = factory.graduation(token);

        assertEq(realEth, target);
        assertEq(finalEffectiveEth, 2.81 ether + 6.5 ether);
        assertGt(finalTokenReserve, 0);
        assertEq(
            migrationFee,
            0.25 ether + ((6.5 ether * 300) / 10_000)
        );
    }

    function testCurveTradesStopAtReadiness() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);

        vm.prank(BUYER);
        vm.expectRevert(HashlingFactoryV2.WrongState.selector);
        factory.buy{value: 1 ether}(token, 0);

        vm.prank(BUYER);
        vm.expectRevert(HashlingFactoryV2.WrongState.selector);
        factory.sell(token, 1 ether, 0);
    }

    function testMigrationFailureRemainsRetryable() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);

        migrator.setFailMigration(true);
        assertFalse(factory.graduate(token));

        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.GraduationReady)
        );

        migrator.setFailMigration(false);
        assertTrue(factory.graduate(token));

        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.Graduated)
        );
    }

    function testMigrationFeeBookedOnlyAfterSuccess() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);

        uint256 feesBefore = factory.protocolFees();
        (uint128 migrationFee,,,,,,) = factory.graduation(token);

        migrator.setFailMigration(true);
        assertFalse(factory.graduate(token));
        assertEq(factory.protocolFees(), feesBefore);

        migrator.setFailMigration(false);
        factory.graduate(token);
        assertEq(
            factory.protocolFees(),
            feesBefore + migrationFee
        );
    }

    function testPersistentMigrationFailureUnlocksRefund() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        migrator.setFailMigration(true);

        assertFalse(factory.graduate(token));
        vm.warp(block.timestamp + factory.REFUND_DELAY());
        factory.activateRefund(token);

        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.Refunding)
        );
    }

    function testRecoveredMigrationWinsOverRefund() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        migrator.setFailMigration(true);

        assertFalse(factory.graduate(token));
        vm.warp(block.timestamp + factory.REFUND_DELAY());
        migrator.setFailMigration(false);
        factory.activateRefund(token);

        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.Graduated)
        );
    }

    function testRefundCannotActivateBeforeDelay() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        migrator.setPoolAvailable(false);
        factory.startRefundCountdown(token);

        vm.expectRevert(
            HashlingFactoryV2.RefundDelayActive.selector
        );
        factory.activateRefund(token);
    }

    function testRefundCannotActivateWhenMigrationAvailable() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        vm.expectRevert(
            HashlingFactoryV2.MigrationAvailable.selector
        );
        factory.startRefundCountdown(token);
    }

    function testRefundRequiresBlockedCountdown() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        migrator.setPoolAvailable(false);
        vm.warp(block.timestamp + factory.REFUND_DELAY());

        vm.expectRevert(
            HashlingFactoryV2.RefundCountdownNotStarted.selector
        );
        factory.activateRefund(token);
    }

    function testRefundActivationRechecksMigration() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        migrator.setPoolAvailable(false);
        factory.startRefundCountdown(token);
        vm.warp(block.timestamp + factory.REFUND_DELAY());
        migrator.setPoolAvailable(true);

        factory.activateRefund(token);
        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.Graduated)
        );
    }

    function testRefundBurnsFactoryTokensAndReturnsFullReserve() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        migrator.setPoolAvailable(false);
        factory.startRefundCountdown(token);
        vm.warp(block.timestamp + factory.REFUND_DELAY());
        factory.activateRefund(token);

        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.Refunding)
        );
        assertEq(IERC20(token).balanceOf(address(factory)), 0);

        uint256 buyerTokens = IERC20(token).balanceOf(BUYER);
        assertEq(IERC20(token).totalSupply(), buyerTokens);
        uint256 beforeBalance = BUYER.balance;

        vm.startPrank(BUYER);
        IERC20(token).approve(address(factory), buyerTokens);
        vm.expectRevert(HashlingFactoryV2.DustTrade.selector);
        factory.redeem(token, 1);
        uint256 payout = factory.redeem(token, buyerTokens);
        vm.stopPrank();

        assertEq(payout, 6.5 ether);
        assertEq(BUYER.balance - beforeBalance, 6.5 ether);
        assertEq(IERC20(token).totalSupply(), 0);
        (,,, uint128 remaining) = factory.refundStatus(token);
        assertEq(remaining, 0);
    }

    function testRefundIsProportionalAcrossHolders() public {
        address buyerTwo = address(0xB0B2);
        vm.deal(buyerTwo, 2 ether);
        vm.prank(buyerTwo);
        factory.buy{value: 1 ether}(token, 0);

        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        migrator.setPoolAvailable(false);
        factory.startRefundCountdown(token);
        vm.warp(block.timestamp + factory.REFUND_DELAY());
        factory.activateRefund(token);

        uint256 firstTokens = IERC20(token).balanceOf(buyerTwo);
        uint256 secondTokens = IERC20(token).balanceOf(BUYER);
        uint256 redeemable = firstTokens + secondTokens;
        uint256 expectedFirst =
            (6.5 ether * firstTokens) / redeemable;

        vm.startPrank(buyerTwo);
        IERC20(token).approve(address(factory), firstTokens);
        uint256 firstPayout = factory.redeem(token, firstTokens);
        vm.stopPrank();

        vm.startPrank(BUYER);
        IERC20(token).approve(address(factory), secondTokens);
        uint256 secondPayout = factory.redeem(token, secondTokens);
        vm.stopPrank();

        assertEq(firstPayout, expectedFirst);
        uint256 totalPayout = firstPayout + secondPayout;
        assertLe(totalPayout, 6.5 ether);
        assertLe(6.5 ether - totalPayout, 1);
        (,,, uint128 remaining) = factory.refundStatus(token);
        assertEq(remaining, 6.5 ether - totalPayout);
    }

    function testRefundStateRejectsTradingAndGraduation() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        migrator.setPoolAvailable(false);
        factory.startRefundCountdown(token);
        vm.warp(block.timestamp + factory.REFUND_DELAY());
        factory.activateRefund(token);

        vm.prank(BUYER);
        vm.expectRevert(HashlingFactoryV2.WrongState.selector);
        factory.buy{value: 1 ether}(token, 0);

        vm.expectRevert(HashlingFactoryV2.WrongState.selector);
        factory.graduate(token);
    }

    function testCannotGraduateTwice() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        factory.graduate(token);

        vm.expectRevert(HashlingFactoryV2.WrongState.selector);
        factory.graduate(token);
    }

    function testLaunchAddressIsNotNextCreateAddress() public view {
        address oldPredictableAddress =
            vm.computeCreateAddress(address(factory), 1);
        assertTrue(token != oldPredictableAddress);
    }

    function testCorrectionAndGraduationAreAtomic() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        migrator.setPoolAvailable(false);
        migrator.setFailCorrection(true);

        vm.expectRevert("mock correction failure");
        factory.correctAndGraduate(token, 1);
        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.GraduationReady)
        );

        migrator.setFailCorrection(false);
        factory.correctAndGraduate(token, 1);
        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.Graduated)
        );
    }

    function testGraduationConservesActiveSupply() public {
        vm.prank(BUYER);
        factory.buy{value: 10 ether}(token, 0);
        factory.graduate(token);

        HashlingTokenV2 launched = HashlingTokenV2(token);
        uint256 activeSupply = launched.totalSupply();

        assertEq(
            activeSupply,
            launched.balanceOf(BUYER)
                + launched.balanceOf(address(migrator))
        );

        (,,, uint128 burned,,,) = factory.graduation(token);

        assertEq(
            launched.initialSupply(),
            activeSupply + burned
        );
        assertEq(launched.balanceOf(address(factory)), 0);
    }

    function testPermissionlessProtocolClaimPaysProtocol() public {
        vm.prank(BUYER);
        factory.buy{value: 1 ether}(token, 0);

        uint256 claimable = factory.protocolFees();
        uint256 beforeBalance = PROTOCOL.balance;

        vm.prank(address(0xCA11));
        factory.claimProtocolFees();

        assertEq(PROTOCOL.balance - beforeBalance, claimable);
        assertEq(factory.protocolFees(), 0);
    }

    function testPermissionlessCreatorClaimPaysCreator() public {
        vm.prank(BUYER);
        factory.buy{value: 1 ether}(token, 0);

        uint256 claimable = factory.creatorFees(CREATOR);
        uint256 beforeBalance = CREATOR.balance;

        vm.prank(address(0xCA11));
        factory.claimCreatorFees(CREATOR);

        assertEq(CREATOR.balance - beforeBalance, claimable);
        assertEq(factory.creatorFees(CREATOR), 0);
    }

    function testMigrationFeeAtSupplyBoundaries() public {
        _assertScaledMigrationFee(1e6 ether);
        _assertScaledMigrationFee(1e9 ether);
        _assertScaledMigrationFee(1e12 ether);
    }

    function testFuzzScaledMigrationFee(uint256 supply) public {
        supply = bound(
            supply,
            factory.MIN_SUPPLY(),
            factory.MAX_SUPPLY()
        );

        vm.prank(CREATOR);
        address fuzzToken =
            factory.launch("Fuzz", "FZ", supply, "");

        (,,, uint128 tokenReserve, uint128 target,) =
            factory.curves(fuzzToken);

        uint256 gross =
            (uint256(target) * 10_000 + 9_899) / 9_900;
        vm.deal(BUYER, gross + 1 ether);
        vm.prank(BUYER);
        factory.buy{value: gross + 1}(fuzzToken, 0);

        (uint128 frozenFee,,,,,,) =
            factory.graduation(fuzzToken);

        uint256 expectedFlat =
            (0.25 ether * supply) / 1e9 ether;
        uint256 expectedFee =
            expectedFlat + ((uint256(target) * 300) / 10_000);

        assertEq(frozenFee, expectedFee);
        assertGt(tokenReserve, 0);
    }

    function _assertScaledMigrationFee(uint256 supply) private {
        vm.prank(CREATOR);
        address boundaryToken =
            factory.launch("Boundary", "BND", supply, "");

        (,,,, uint128 target,) = factory.curves(boundaryToken);

        uint256 gross =
            (uint256(target) * 10_000 + 9_899) / 9_900;
        vm.deal(BUYER, gross + 1 ether);
        vm.prank(BUYER);
        factory.buy{value: gross + 1}(boundaryToken, 0);

        (uint128 migrationFee,,,,,,) =
            factory.graduation(boundaryToken);

        uint256 expectedFlat =
            (0.25 ether * supply) / 1e9 ether;
        uint256 expectedFee =
            expectedFlat + ((uint256(target) * 300) / 10_000);

        assertEq(migrationFee, expectedFee);
        assertLt(migrationFee, target);
        assertGt(uint256(target) - migrationFee, 0);
    }
}
