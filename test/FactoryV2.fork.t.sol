// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HashlingFactoryV2} from "../src/HashlingFactoryV2.sol";
import {HashlingMigrator} from "../src/HashlingMigrator.sol";
import {
    HashlingPositionLocker
} from "../src/HashlingPositionLocker.sol";
import {HashlingSwap} from "../src/HashlingSwap.sol";
import {HashlingTokenV2} from "../src/HashlingTokenV2.sol";
import {
    IUniswapV3PoolV2,
    IUniswapV3SwapCallbackV2,
    IWETH9V2,
    INonfungiblePositionManagerV2
} from "../src/interfaces/IHashlingV3.sol";

contract ZeroLiquidityPriceMover is IUniswapV3SwapCallbackV2 {
    function move(address pool, uint160 priceLimit) external {
        IUniswapV3PoolV2(pool).swap(
            address(this),
            false,
            1,
            priceLimit,
            ""
        );
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata
    ) external pure {
        require(amount0Delta == 0 && amount1Delta == 0);
    }
}

interface IForkPositionManager is INonfungiblePositionManagerV2 {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function getApproved(uint256 tokenId)
        external
        view
        returns (address);

    function isApprovedForAll(address owner, address operator)
        external
        view
        returns (bool);

    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);
}

contract FactoryV2Fork is Test {
    address internal constant MAINNET_V3_FACTORY =
        0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant MAINNET_ROUTER =
        0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant MAINNET_POSITION_MANAGER =
        0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address internal constant MAINNET_WETH =
        0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant BUYER = address(0xB0B);
    address internal constant TRADER = address(0xA11CE);
    address internal constant CALLER = address(0xCA11);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant PROTOCOL = address(0xFEE);

    HashlingFactoryV2 internal factory;
    HashlingMigrator internal migrator;
    HashlingPositionLocker internal locker;
    address internal v3Factory;
    address internal router;
    address internal positionManager;
    address internal weth;
    address internal token;
    address internal pool;
    uint24 internal poolFee;
    uint256 internal positionId;
    uint256 internal closingEffectiveEth;
    uint256 internal closingTokenReserve;

    function testForkCompleteGraduationLifecycle() public {
        string memory url = vm.envOr("FORK_RPC", string(""));
        if (bytes(url).length == 0) return;
        v3Factory = vm.envOr(
            "FORK_V3_FACTORY",
            MAINNET_V3_FACTORY
        );
        router = vm.envOr("FORK_ROUTER", MAINNET_ROUTER);
        positionManager = vm.envOr(
            "FORK_POSITION_MANAGER",
            MAINNET_POSITION_MANAGER
        );
        weth = vm.envOr("FORK_WETH", MAINNET_WETH);
        vm.createSelectFork(url);

        _assertDependencies();
        _deployAndLaunchPinnedPool();
        _fillCurveAndAssertRefund();
        _graduateAndAssertPermanentLock();
        _tradeAndAssertFeeDistribution();
    }

    function _assertDependencies() private view {
        assertGt(v3Factory.code.length, 0);
        assertGt(router.code.length, 0);
        assertGt(positionManager.code.length, 0);
        assertGt(weth.code.length, 0);

        IForkPositionManager npm =
            IForkPositionManager(positionManager);
        assertEq(npm.factory(), v3Factory);
        assertEq(npm.WETH9(), weth);
    }

    function _deployAndLaunchPinnedPool() private {
        uint64 nonce = vm.getNonce(address(this));
        address predictedMigrator =
            vm.computeCreateAddress(address(this), nonce + 2);
        factory = new HashlingFactoryV2(
            predictedMigrator,
            PROTOCOL
        );
        locker = new HashlingPositionLocker(
            positionManager,
            PROTOCOL,
            predictedMigrator
        );
        migrator = new HashlingMigrator(
            v3Factory,
            positionManager,
            weth,
            address(locker),
            address(factory)
        );
        assertEq(address(migrator), predictedMigrator);
        _assertRestrictedEntryPoints();

        uint256 supply = factory.MIN_SUPPLY();
        vm.prank(CREATOR);
        token = factory.launch(
            "Hashling V2 Fork",
            "HV2F",
            supply,
            ""
        );

        (,,,, pool, poolFee,) = factory.graduation(token);
        assertEq(poolFee, 10_000);
        assertGt(pool.code.length, 0);
    }

    function _assertRestrictedEntryPoints() private {
        vm.startPrank(ATTACKER);
        vm.expectRevert(HashlingMigrator.NotFactory.selector);
        migrator.preparePool(address(1), 1, 1);

        vm.expectRevert(HashlingPositionLocker.NotMigrator.selector);
        locker.registerPosition(1, ATTACKER);

        vm.expectRevert(
            HashlingMigrator.UnauthorizedCallback.selector
        );
        migrator.uniswapV3SwapCallback(
            1,
            -1,
            abi.encode(ATTACKER)
        );
        vm.stopPrank();
    }

    function _fillCurveAndAssertRefund() private {
        vm.deal(BUYER, 2 ether);
        (
            uint256 expectedTokens,
            uint256 grossUsed,
            ,
            uint256 refund
        ) = factory.quoteBuy(token, 1 ether);

        uint256 beforeBalance = BUYER.balance;
        vm.prank(BUYER);
        uint256 actualTokens =
            factory.buy{value: 1 ether}(token, expectedTokens);

        assertEq(actualTokens, expectedTokens);
        assertEq(beforeBalance - BUYER.balance, grossUsed);
        assertEq(refund, 1 ether - grossUsed);
        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.GraduationReady)
        );

        (
            ,
            uint128 frozenEffectiveEth,
            uint128 frozenTokenReserve,
            ,
            ,
            ,

        ) = factory.graduation(token);
        closingEffectiveEth = frozenEffectiveEth;
        closingTokenReserve = frozenTokenReserve;
    }

    function _graduateAndAssertPermanentLock() private {
        uint160 expectedPrice = migrator.expectedSqrtPriceX96(
            token,
            closingEffectiveEth,
            closingTokenReserve
        );

        ZeroLiquidityPriceMover mover =
            new ZeroLiquidityPriceMover();
        uint160 movedPrice =
            expectedPrice + uint160(uint256(expectedPrice) / 100);
        mover.move(pool, movedPrice);
        assertFalse(
            migrator.poolWithinTolerance(
                token,
                closingEffectiveEth,
                closingTokenReserve
            )
        );

        _addBlockingLiquidity();

        address inputToken = IUniswapV3PoolV2(pool).token0();
        uint256 largeCap;
        vm.startPrank(BUYER);
        if (inputToken == token) {
            largeCap = IERC20(token).balanceOf(BUYER) / 10;
            IERC20(token).approve(address(migrator), largeCap);
            vm.expectRevert();
            factory.correctAndGraduate(token, 1);
        } else {
            largeCap = 0.1 ether;
            vm.expectRevert();
            factory.correctAndGraduate{value: 1}(token, 1);
        }
        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.GraduationReady)
        );

        if (inputToken == token) {
            factory.correctAndGraduate(token, largeCap);
        } else {
            factory.correctAndGraduate{value: largeCap}(
                token,
                largeCap
            );
        }
        vm.stopPrank();

        uint128 burnedTokens;
        (
            ,
            ,
            ,
            burnedTokens,
            pool,
            poolFee,
            positionId
        ) = factory.graduation(token);

        assertEq(
            uint256(factory.stateOf(token)),
            uint256(HashlingFactoryV2.State.Graduated)
        );
        assertGt(pool.code.length, 0);

        (uint160 actualPrice,,,,,,) =
            IUniswapV3PoolV2(pool).slot0();
        assertEq(actualPrice, expectedPrice);

        IForkPositionManager npm =
            IForkPositionManager(positionManager);
        assertEq(npm.ownerOf(positionId), address(locker));
        assertEq(npm.getApproved(positionId), address(0));
        assertFalse(
            npm.isApprovedForAll(address(locker), ATTACKER)
        );

        (
            address recordedCreator,
            ,
            ,
            bool registered
        ) = locker.positionInfo(positionId);
        assertEq(recordedCreator, CREATOR);
        assertTrue(registered);

        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertEq(IERC20(token).balanceOf(address(migrator)), 0);
        assertEq(IERC20(weth).balanceOf(address(migrator)), 0);
        assertEq(address(migrator).balance, 0);
        assertEq(
            address(factory).balance,
            factory.creatorFees(CREATOR) + factory.protocolFees()
        );

        HashlingTokenV2 launched = HashlingTokenV2(token);
        assertEq(
            launched.initialSupply(),
            launched.totalSupply() + burnedTokens
        );

        vm.prank(ATTACKER);
        vm.expectRevert();
        npm.decreaseLiquidity(
            IForkPositionManager.DecreaseLiquidityParams({
                tokenId: positionId,
                liquidity: 1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    function _addBlockingLiquidity() private {
        IUniswapV3PoolV2 v3Pool = IUniswapV3PoolV2(pool);
        address token0 = v3Pool.token0();
        int24 spacing = v3Pool.tickSpacing();
        uint256 projectAmount =
            IERC20(token).balanceOf(BUYER) / 1_000;
        uint256 wethAmount = 0.001 ether;

        vm.startPrank(BUYER);
        IWETH9V2(weth).deposit{value: wethAmount}();
        IERC20(token).approve(positionManager, projectAmount);
        IERC20(weth).approve(positionManager, wethAmount);

        INonfungiblePositionManagerV2.MintParams memory p;
        p.token0 = token0;
        p.token1 = v3Pool.token1();
        p.fee = 10_000;
        p.tickLower = (-887_272 / spacing) * spacing;
        p.tickUpper = (887_272 / spacing) * spacing;
        p.amount0Desired =
            token0 == token ? projectAmount : wethAmount;
        p.amount1Desired =
            token0 == token ? wethAmount : projectAmount;
        p.recipient = BUYER;
        p.deadline = block.timestamp;
        (uint256 hostilePosition, uint128 liquidity,,) =
            INonfungiblePositionManagerV2(positionManager).mint(p);
        vm.stopPrank();

        assertGt(hostilePosition, 0);
        assertGt(liquidity, 0);
    }

    function _tradeAndAssertFeeDistribution() private {
        HashlingSwap swap =
            new HashlingSwap(router, weth, PROTOCOL, 0);
        vm.deal(TRADER, 1 ether);

        vm.prank(TRADER);
        uint256 bought = swap.buy{value: 0.0002 ether}(
            token,
            poolFee,
            0,
            block.timestamp
        );
        assertGt(bought, 0);

        vm.startPrank(TRADER);
        IERC20(token).approve(address(swap), bought / 2);
        uint256 sold = swap.sell(
            token,
            poolFee,
            bought / 2,
            0,
            block.timestamp
        );
        vm.stopPrank();
        assertGt(sold, 0);

        (uint256 amount0, uint256 amount1) =
            locker.collectFees(positionId);
        assertTrue(amount0 != 0 || amount1 != 0);

        (
            ,
            address token0,
            address token1,

        ) = locker.positionInfo(positionId);
        _assertFeeSplit(token0, amount0);
        _assertFeeSplit(token1, amount1);
        _claimAndAssertPayment(token0);
        _claimAndAssertPayment(token1);
    }

    function _assertFeeSplit(address asset, uint256 amount)
        private
        view
    {
        uint256 creatorShare = (amount * 8_000) / 10_000;
        assertEq(
            locker.claimable(CREATOR, asset),
            creatorShare
        );
        assertEq(
            locker.claimable(PROTOCOL, asset),
            amount - creatorShare
        );
    }

    function _claimAndAssertPayment(address asset) private {
        uint256 creatorAmount =
            locker.claimable(CREATOR, asset);
        uint256 protocolAmount =
            locker.claimable(PROTOCOL, asset);
        uint256 creatorBefore =
            IERC20(asset).balanceOf(CREATOR);
        uint256 protocolBefore =
            IERC20(asset).balanceOf(PROTOCOL);

        if (creatorAmount != 0) {
            vm.prank(CALLER);
            locker.claim(CREATOR, asset);
        }
        if (protocolAmount != 0) {
            vm.prank(CALLER);
            locker.claim(PROTOCOL, asset);
        }

        assertEq(
            IERC20(asset).balanceOf(CREATOR) - creatorBefore,
            creatorAmount
        );
        assertEq(
            IERC20(asset).balanceOf(PROTOCOL) - protocolBefore,
            protocolAmount
        );
    }
}
