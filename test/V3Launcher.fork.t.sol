// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HashlingV3Launcher} from
    "../src/HashlingV3Launcher.sol";
import {HashlingTokenV2} from "../src/HashlingTokenV2.sol";
import {HashlingSwap} from "../src/HashlingSwap.sol";
import {
    HashlingPositionLocker
} from "../src/HashlingPositionLocker.sol";
import {
    IUniswapV3FactoryV2,
    IUniswapV3PoolV2,
    INonfungiblePositionManagerV2
} from "../src/interfaces/IHashlingV3.sol";

interface IV3LauncherForkPositionManager is
    INonfungiblePositionManagerV2
{
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

    function isApprovedForAll(
        address owner,
        address operator
    ) external view returns (bool);

    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    ) external payable returns (uint256, uint256);
}

contract V3LauncherFork is Test {
    address internal constant V3_FACTORY =
        0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant SWAP_ROUTER =
        0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant POSITION_MANAGER =
        0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address internal constant WETH =
        0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TRADER = address(0xA11CE);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant PROTOCOL = address(0xFEE);

    IV3LauncherForkPositionManager private npm;
    HashlingPositionLocker private locker;
    HashlingV3Launcher private launcher;
    HashlingSwap private zeroFeeSwap;

    address private token;
    address private pool;
    uint256 private positionId;
    uint256 private tokensBought;
    uint256 private devBuy;

    function testForkLaunchAndZeroFeeTrading() public {
        string memory url = vm.envOr(
            "FORK_RPC",
            string("")
        );
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        assertEq(block.chainid, 4663, "wrong fork chain");

        _assertDependencies();
        _deployStack();
        _launchToken();
        _assertTokenState();
        _assertLaunchRecord();
        _assertPoolConfiguration();
        _assertPermanentLock();
        _tradeThroughZeroFeeWrapper();
        _collectAndAssertFees();
    }

    function _assertDependencies() private {
        assertGt(V3_FACTORY.code.length, 0);
        assertGt(SWAP_ROUTER.code.length, 0);
        assertGt(POSITION_MANAGER.code.length, 0);
        assertGt(WETH.code.length, 0);

        npm =
            IV3LauncherForkPositionManager(POSITION_MANAGER);
        assertEq(npm.factory(), V3_FACTORY);
        assertEq(npm.WETH9(), WETH);
    }

    function _deployStack() private {
        uint64 nonce = vm.getNonce(address(this));
        address predictedLauncher = vm.computeCreateAddress(
            address(this),
            nonce + 1
        );
        address predictedZeroFeeSwap = vm.computeCreateAddress(
            address(this),
            nonce + 2
        );

        locker = new HashlingPositionLocker(
            POSITION_MANAGER,
            PROTOCOL,
            predictedLauncher
        );
        launcher = new HashlingV3Launcher(
            V3_FACTORY,
            POSITION_MANAGER,
            SWAP_ROUTER,
            WETH,
            address(locker),
            PROTOCOL
        );
        zeroFeeSwap = new HashlingSwap(
            SWAP_ROUTER,
            WETH,
            PROTOCOL,
            0
        );

        assertEq(address(launcher), predictedLauncher);
        assertEq(address(zeroFeeSwap), predictedZeroFeeSwap);
        assertEq(zeroFeeSwap.feeBps(), 0);
        assertEq(zeroFeeSwap.feeRecipient(), PROTOCOL);
    }

    function _launchToken() private {
        devBuy = launcher.MIN_DEV_BUY();
        vm.deal(CREATOR, devBuy);
        vm.prank(CREATOR);
        (
            token,
            pool,
            positionId,
            tokensBought
        ) = launcher.launch{value: devBuy}(
            "Hashling Direct V3 Fork",
            "HV3F",
            "ipfs://hashling-v3-fork",
            0,
            block.timestamp + 60
        );
    }

    function _assertTokenState() private view {
        assertGt(tokensBought, 0);
        assertGt(pool.code.length, 0);
        assertGt(positionId, 0);
        assertEq(address(launcher).balance, 0);
        assertEq(IERC20(token).balanceOf(address(launcher)), 0);
        assertEq(IERC20(WETH).balanceOf(address(launcher)), 0);

        HashlingTokenV2 launched = HashlingTokenV2(token);
        assertEq(
            launched.initialSupply(),
            launcher.TOKEN_SUPPLY()
        );
        assertEq(launched.balanceOf(CREATOR), tokensBought);
        assertEq(
            launched.balanceOf(pool)
                + launched.balanceOf(CREATOR),
            launched.totalSupply()
        );
    }

    function _assertLaunchRecord() private view {
        (
            address creator,
            address recordedPool,
            uint256 recordedPositionId,
            uint256 tokenLiquidity,
            uint256 recordedDevBuy,
            uint256 recordedTokensBought,
            int24 tickLower,
            int24 tickUpper
        ) = launcher.launches(token);

        assertEq(creator, CREATOR);
        assertEq(recordedPool, pool);
        assertEq(recordedPositionId, positionId);
        assertEq(recordedDevBuy, devBuy);
        assertEq(recordedTokensBought, tokensBought);
        assertEq(
            tokenLiquidity,
            IERC20(token).totalSupply()
        );
        assertEq(launcher.tokenCount(), 1);
        assertEq(launcher.allTokens(0), token);
    }

    function _assertPoolConfiguration() private view {
        (,,,,,, int24 tickLower, int24 tickUpper) =
            launcher.launches(token);
        IUniswapV3PoolV2 candidate =
            IUniswapV3PoolV2(pool);
        address token0 = candidate.token0();
        address token1 = candidate.token1();
        int24 spacing = candidate.tickSpacing();

        assertEq(
            IUniswapV3FactoryV2(V3_FACTORY).getPool(
                token0,
                token1,
                launcher.POOL_FEE()
            ),
            pool
        );
        assertEq(candidate.fee(), launcher.POOL_FEE());
        assertEq(spacing, 200);
        assertEq(int256(tickLower % spacing), 0);
        assertEq(int256(tickUpper % spacing), 0);

        (, int24 currentTick,,,,,) = candidate.slot0();
        if (token0 == token) {
            assertGe(int256(currentTick), int256(tickLower));
        } else {
            assertEq(token1, token);
            assertLe(int256(currentTick), int256(tickUpper));
        }
    }

    function _assertPermanentLock() private {
        IUniswapV3PoolV2 candidate =
            IUniswapV3PoolV2(pool);
        address token0 = candidate.token0();
        address token1 = candidate.token1();

        assertEq(npm.ownerOf(positionId), address(locker));
        assertEq(npm.getApproved(positionId), address(0));
        assertFalse(
            npm.isApprovedForAll(address(locker), ATTACKER)
        );

        (
            address recordedCreator,
            address positionToken0,
            address positionToken1,
            bool registered
        ) = locker.positionInfo(positionId);
        assertEq(recordedCreator, CREATOR);
        assertEq(positionToken0, token0);
        assertEq(positionToken1, token1);
        assertTrue(registered);

        vm.startPrank(ATTACKER);
        vm.expectRevert();
        npm.decreaseLiquidity(
            IV3LauncherForkPositionManager
                .DecreaseLiquidityParams({
                    tokenId: positionId,
                    liquidity: 1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
        );
        vm.stopPrank();
    }

    function _tradeThroughZeroFeeWrapper() private {
        uint256 wrapperBuy = 0.0002 ether;
        uint256 protocolBalanceBefore = PROTOCOL.balance;
        uint24 poolFee = launcher.POOL_FEE();
        vm.deal(TRADER, 1 ether);

        vm.prank(TRADER);
        uint256 wrapperTokens = zeroFeeSwap.buy{
            value: wrapperBuy
        }(
            token,
            poolFee,
            0,
            block.timestamp + 60
        );
        assertGt(wrapperTokens, 0);
        assertEq(
            IERC20(token).balanceOf(TRADER),
            wrapperTokens
        );
        assertEq(PROTOCOL.balance, protocolBalanceBefore);

        uint256 sellAmount = wrapperTokens / 2;
        vm.startPrank(TRADER);
        IERC20(token).approve(address(zeroFeeSwap), sellAmount);
        uint256 traderBalanceBefore = TRADER.balance;
        uint256 ethOut = zeroFeeSwap.sell(
            token,
            poolFee,
            sellAmount,
            0,
            block.timestamp + 60
        );
        vm.stopPrank();

        assertGt(ethOut, 0);
        assertEq(TRADER.balance - traderBalanceBefore, ethOut);
        assertEq(PROTOCOL.balance, protocolBalanceBefore);
        assertEq(address(zeroFeeSwap).balance, 0);
        assertEq(IERC20(token).balanceOf(address(zeroFeeSwap)), 0);
        assertEq(IERC20(WETH).balanceOf(address(zeroFeeSwap)), 0);
        assertEq(
            IERC20(token).allowance(
                address(zeroFeeSwap),
                SWAP_ROUTER
            ),
            0
        );
    }

    function _collectAndAssertFees() private {
        IUniswapV3PoolV2 candidate =
            IUniswapV3PoolV2(pool);
        address token0 = candidate.token0();
        address token1 = candidate.token1();
        (uint256 amount0, uint256 amount1) =
            locker.collectFees(positionId);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        _assertFeeSplit(token0, amount0);
        _assertFeeSplit(token1, amount1);
    }

    function _assertFeeSplit(
        address asset,
        uint256 amount
    ) private view {
        uint256 creatorShare =
            (amount * locker.CREATOR_SHARE_BPS()) / 10_000;

        assertEq(
            locker.claimable(CREATOR, asset),
            creatorShare
        );
        assertEq(
            locker.claimable(PROTOCOL, asset),
            amount - creatorShare
        );
    }
}
