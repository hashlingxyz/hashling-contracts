// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HashlingFactoryV2} from "../src/HashlingFactoryV2.sol";
import {
    IHashlingMigratorV2
} from "../src/interfaces/IHashlingV3.sol";

contract PropertyMigratorV2 is IHashlingMigratorV2 {
    address internal constant POOL = address(0xBEEF);

    function factory() external pure returns (address) {
        return address(0);
    }

    function poolWithinTolerance(address, uint256, uint256)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function preparePool(address, uint256, uint256)
        external
        pure
        returns (address, uint24, uint160)
    {
        return (POOL, 10_000, 1);
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
        returns (address, uint24, uint256, uint256, uint256)
    {
        require(
            IERC20(token).transferFrom(
                msg.sender,
                address(this),
                tokenAmountDesired
            )
        );
        return (
            POOL,
            10_000,
            1,
            msg.value,
            tokenAmountDesired
        );
    }

    function correctPool(
        address,
        address,
        uint256,
        uint256,
        uint256
    ) external payable returns (uint256, uint256) {
        return (0, 0);
    }
}

contract ReentrantActorV2 {
    HashlingFactoryV2 internal immutable factory;
    address internal immutable token;
    bool public reentrySucceeded;

    constructor(HashlingFactoryV2 factory_, address token_) {
        factory = factory_;
        token = token_;
    }

    function buy(uint256 amount) external {
        factory.buy{value: amount}(token, 0);
    }

    function sell(uint256 amount) external {
        IERC20(token).approve(address(factory), amount);
        factory.sell(token, amount, 0);
    }

    receive() external payable {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;

        IERC20(token).approve(address(factory), balance);
        try factory.sell(token, balance, 0) {
            reentrySucceeded = true;
        } catch {}
    }
}

contract FactoryV2Properties is Test {
    uint256 internal constant SUPPLY = 1e9 ether;
    address internal constant TRADER = address(0xCAFE);
    address internal constant WHALE = address(0xBEEF);

    PropertyMigratorV2 internal migrator;
    HashlingFactoryV2 internal factory;
    address internal token;

    function setUp() public {
        migrator = new PropertyMigratorV2();
        factory = new HashlingFactoryV2(
            address(migrator),
            address(0xFEE)
        );
        token = factory.launch("V2 Property", "V2P", SUPPLY, "");
    }

    function testFuzzRoundTripNeverProfits(
        uint256 priorBuy,
        uint256 buyAmount
    ) public {
        priorBuy = bound(priorBuy, 0, 1 ether);
        buyAmount = bound(buyAmount, 1 gwei, 4 ether);

        if (priorBuy != 0) {
            priorBuy = bound(priorBuy, 100, 1 ether);
            vm.deal(WHALE, priorBuy);
            vm.prank(WHALE);
            factory.buy{value: priorBuy}(token, 0);
        }

        vm.deal(TRADER, buyAmount);
        vm.startPrank(TRADER);
        uint256 tokensOut =
            factory.buy{value: buyAmount}(token, 0);
        IERC20(token).approve(address(factory), tokensOut);
        factory.sell(token, tokensOut, 0);
        vm.stopPrank();

        assertLe(TRADER.balance, buyAmount);
    }

    function testFuzzChunkedExitNeverProfits(
        uint256 buyAmount,
        uint256 chunks
    ) public {
        buyAmount = bound(buyAmount, 0.001 ether, 5 ether);
        chunks = bound(chunks, 2, 50);

        vm.deal(TRADER, buyAmount);
        vm.startPrank(TRADER);
        uint256 tokensOut =
            factory.buy{value: buyAmount}(token, 0);
        IERC20(token).approve(address(factory), tokensOut);

        uint256 chunk = tokensOut / chunks;
        for (uint256 i; i < chunks && chunk != 0; ++i) {
            try factory.sell(token, chunk, 0) {} catch {
                break;
            }
        }
        vm.stopPrank();

        assertLe(TRADER.balance, buyAmount);
    }

    function testFuzzTargetCrossingRefundsExactly(
        uint256 priorBuy,
        uint256 excess
    ) public {
        priorBuy = bound(priorBuy, 0, 5 ether);
        excess = bound(excess, 0, 10 ether);

        if (priorBuy != 0) {
            priorBuy = bound(priorBuy, 100, 5 ether);
            vm.deal(WHALE, priorBuy);
            vm.prank(WHALE);
            factory.buy{value: priorBuy}(token, 0);
        }

        (
            uint256 expectedTokens,
            uint256 grossNeeded,
            ,

        ) = factory.quoteBuy(token, 100 ether);
        uint256 offered = grossNeeded + excess;
        vm.deal(TRADER, offered);
        uint256 beforeBalance = TRADER.balance;

        vm.prank(TRADER);
        uint256 actualTokens = factory.buy{value: offered}(
            token,
            expectedTokens
        );

        assertEq(actualTokens, expectedTokens);
        assertEq(beforeBalance - TRADER.balance, grossNeeded);
        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.GraduationReady)
        );

        (,, uint128 realEth,, uint128 target,) =
            factory.curves(token);
        assertEq(realEth, target);
    }

    function testFuzzLaunchScaling(uint256 supply) public {
        supply = bound(
            supply,
            factory.MIN_SUPPLY(),
            factory.MAX_SUPPLY()
        );
        address launched =
            factory.launch("Scale", "SCL", supply, "");
        (
            ,
            uint128 virtualEth,
            ,
            uint128 reserve,
            uint128 target,

        ) = factory.curves(launched);

        assertEq(
            reserve,
            (supply * factory.CURVE_SUPPLY_BPS())
                / factory.BPS()
        );
        assertEq(
            virtualEth,
            (factory.REF_VIRTUAL_ETH() * supply)
                / factory.REF_SUPPLY()
        );
        assertEq(
            target,
            (factory.REF_RAISE_TARGET() * supply)
                / factory.REF_SUPPLY()
        );
    }

    function testFuzzSellPayoutReentrancyBlocked(
        uint256 buyAmount
    ) public {
        buyAmount = bound(buyAmount, 0.001 ether, 4 ether);
        ReentrantActorV2 attacker =
            new ReentrantActorV2(factory, token);
        vm.deal(address(attacker), buyAmount);

        attacker.buy(buyAmount);
        uint256 balance =
            IERC20(token).balanceOf(address(attacker));
        attacker.sell(balance / 2);

        assertFalse(attacker.reentrySucceeded());
        assertLe(address(attacker).balance, buyAmount);
    }
}
