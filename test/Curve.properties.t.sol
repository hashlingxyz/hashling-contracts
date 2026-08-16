// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HashlingFactory} from "../src/HashlingFactory.sol";
import {HashlingToken} from "../src/HashlingToken.sol";

/// A contract that tries to re-enter the factory whenever it is paid ETH.
/// Every re-entry attempt must fail; if one ever succeeds the attack flag
/// trips and the test fails.
contract ReentrantActor {
    HashlingFactory immutable factory;
    address immutable token;
    bool public reentrySucceeded;

    constructor(HashlingFactory factory_, address token_) {
        factory = factory_;
        token = token_;
    }

    function doBuy(uint256 amount) external {
        factory.buy{value: amount}(token, 0);
    }

    function doSell(uint256 amount) external {
        HashlingToken(token).approve(address(factory), amount);
        factory.sell(token, amount, 0);
    }

    receive() external payable {
        // Attack from inside the payout: try to sell again mid-sell.
        uint256 balance = HashlingToken(token).balanceOf(address(this));
        if (balance > 0) {
            HashlingToken(token).approve(address(factory), balance);
            try factory.sell(token, balance, 0) {
                reentrySucceeded = true;
            } catch {}
        }
    }
}

contract CurveProperties is Test {
    HashlingFactory factory;
    address token;
    uint256 constant SUPPLY = 1e9 ether;

    function setUp() public {
        factory = new HashlingFactory(address(0xFEE));
        token = factory.launch("Prop", "PROP", SUPPLY, "");
    }

    /// A buy followed by selling everything back never returns more ETH than
    /// was paid — for any buy size and any prior curve state the fuzzer can
    /// set up with an earlier whale buy.
    function testFuzz_roundTripNeverProfits(uint256 priorBuy, uint256 buyAmount) public {
        priorBuy = bound(priorBuy, 0, 20 ether);
        buyAmount = bound(buyAmount, 1 gwei, 10 ether);

        if (priorBuy > 0) {
            address whale = address(0xBEEF);
            vm.deal(whale, priorBuy);
            vm.prank(whale);
            factory.buy{value: priorBuy}(token, 0);
        }

        address trader = address(0xCAFE);
        vm.deal(trader, buyAmount);
        vm.startPrank(trader);
        uint256 tokensOut;
        try factory.buy{value: buyAmount}(token, 0) returns (uint256 out) {
            tokensOut = out;
        } catch {
            vm.stopPrank();
            return; // dust buy rejected — fine
        }
        HashlingToken(token).approve(address(factory), tokensOut);
        try factory.sell(token, tokensOut, 0) {} catch {}
        vm.stopPrank();

        assertLe(trader.balance, buyAmount, "round trip profited");
    }

    /// Selling in many small chunks must never beat what was paid in either —
    /// rounding has to stay in the curve's favor across any split.
    function testFuzz_chunkedExitNeverProfits(uint256 buyAmount, uint256 chunks) public {
        buyAmount = bound(buyAmount, 0.001 ether, 10 ether);
        chunks = bound(chunks, 2, 20);

        address trader = address(0xCAFE);
        vm.deal(trader, buyAmount);
        vm.startPrank(trader);
        uint256 tokensOut = factory.buy{value: buyAmount}(token, 0);
        HashlingToken(token).approve(address(factory), tokensOut);
        uint256 chunk = tokensOut / chunks;
        for (uint256 i = 0; i < chunks && chunk > 0; i++) {
            try factory.sell(token, chunk, 0) {} catch {}
        }
        vm.stopPrank();

        assertLe(trader.balance, buyAmount, "chunked exit profited");
    }

    /// Reentrancy from the sell payout must never succeed.
    function testFuzz_sellPayoutReentrancyBlocked(uint256 buyAmount) public {
        buyAmount = bound(buyAmount, 0.001 ether, 5 ether);
        ReentrantActor attacker = new ReentrantActor(factory, token);
        vm.deal(address(attacker), buyAmount);

        attacker.doBuy(buyAmount);
        uint256 tokens = HashlingToken(token).balanceOf(address(attacker));
        // Sell half so the receive() hook still holds tokens to attack with.
        attacker.doSell(tokens / 2);

        assertFalse(attacker.reentrySucceeded(), "reentrancy succeeded");
        assertLe(address(attacker).balance, buyAmount, "attacker profited");
    }

    /// The scaled seed/target arithmetic holds across the allowed supply
    /// range: launches never revert for in-range supplies and the reference
    /// supply reproduces the whitepaper constants exactly.
    function testFuzz_launchScaling(uint256 supply) public {
        supply = bound(supply, 1e6 ether, 1e12 ether);
        address t = factory.launch("Scale", "SCL", supply, "");
        (, uint128 vEth, , uint128 reserve, uint128 target, ) = factory.curves(t);
        assertEq(uint256(reserve), (supply * 8000) / 10_000, "curve allocation");
        assertEq(uint256(vEth), (2.81 ether * supply) / 1e9 ether, "seed scaling");
        assertEq(uint256(target), (6.5 ether * supply) / 1e9 ether, "target scaling");
    }

    function test_referenceSupplyMatchesWhitepaper() public {
        (, uint128 vEth, , , uint128 target, ) = factory.curves(token);
        assertEq(uint256(vEth), 2.81 ether);
        assertEq(uint256(target), 6.5 ether);
    }

    /// Graduation is blocked until the migrator exists — no fund-holding path.
    function test_graduateBlocked() public {
        address whale = address(0xBEEF);
        vm.deal(whale, 10 ether);
        vm.prank(whale);
        factory.buy{value: 10 ether}(token, 0);
        vm.expectRevert("migrator not yet implemented");
        factory.graduate(token);
    }
}
