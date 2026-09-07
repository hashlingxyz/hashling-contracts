// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from
    "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from
    "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {
    HashlingV3Launcher,
    IHashlingV3LaunchRouter
} from "../src/HashlingV3Launcher.sol";
import {HashlingTokenV2} from "../src/HashlingTokenV2.sol";
import {
    HashlingPositionLocker
} from "../src/HashlingPositionLocker.sol";
import {
    IUniswapV3FactoryV2,
    IUniswapV3PoolV2,
    INonfungiblePositionManagerV2
} from "../src/interfaces/IHashlingV3.sol";

contract LauncherMockWeth is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}
}

contract LauncherMockPool is IUniswapV3PoolV2 {
    address public immutable override token0;
    address public immutable override token1;
    uint24 public immutable override fee;
    int24 public immutable override tickSpacing;

    uint160 private immutable price;
    int24 private immutable currentTick;

    constructor(
        address token0_,
        address token1_,
        uint24 fee_,
        uint160 price_,
        int24 currentTick_,
        int24 tickSpacing_
    ) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        price = price_;
        currentTick = currentTick_;
        tickSpacing = tickSpacing_;
    }

    function slot0()
        external
        view
        override
        returns (
            uint160,
            int24,
            uint16,
            uint16,
            uint16,
            uint8,
            bool
        )
    {
        return (price, currentTick, 0, 0, 0, 0, true);
    }

    function swap(
        address,
        bool,
        int256,
        uint160,
        bytes calldata
    ) external pure override returns (int256, int256) {
        return (0, 0);
    }
}

contract LauncherMockFactory is IUniswapV3FactoryV2 {
    mapping(bytes32 => address) private pools;

    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view override returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    function createPool(
        address token0,
        address token1,
        uint24 fee,
        uint160 price
    ) external returns (address pool) {
        bytes32 key = _key(token0, token1, fee);
        require(pools[key] == address(0), "pool exists");

        pool = address(
            new LauncherMockPool(
                token0,
                token1,
                fee,
                price,
                -123,
                200
            )
        );
        pools[key] = pool;
    }

    function _key(
        address tokenA,
        address tokenB,
        uint24 fee
    ) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee));
    }
}

contract LauncherMockPositionManager is
    INonfungiblePositionManagerV2
{
    uint256 public constant DUST = 7;

    address public immutable override factory;
    address public immutable override WETH9;
    address public router;
    uint256 public nextTokenId = 1;

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    mapping(uint256 => address) public override ownerOf;
    mapping(uint256 => Position) private position;

    constructor(address factory_, address weth_) {
        factory = factory_;
        WETH9 = weth_;
    }

    function setRouter(address router_) external {
        require(router == address(0), "router set");
        router = router_;
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable override returns (address pool) {
        pool = IUniswapV3FactoryV2(factory).getPool(
            token0,
            token1,
            fee
        );
        if (pool == address(0)) {
            pool = LauncherMockFactory(factory).createPool(
                token0,
                token1,
                fee,
                sqrtPriceX96
            );
        }
    }

    function mint(MintParams calldata params)
        external
        payable
        override
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        require(router != address(0), "router missing");

        address projectToken = params.token0 == WETH9
            ? params.token1
            : params.token0;
        uint256 desired = projectToken == params.token0
            ? params.amount0Desired
            : params.amount1Desired;
        uint256 otherDesired = projectToken == params.token0
            ? params.amount1Desired
            : params.amount0Desired;

        require(desired > DUST, "insufficient desired");
        require(otherDesired == 0, "not one sided");

        uint256 tokenUsed = desired - DUST;
        require(
            IERC20(projectToken).transferFrom(
                msg.sender,
                address(this),
                tokenUsed
            ),
            "transfer"
        );

        tokenId = nextTokenId++;
        liquidity = uint128(tokenUsed);
        ownerOf[tokenId] = params.recipient;
        position[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity
        });

        bytes4 accepted = IERC721Receiver(params.recipient)
            .onERC721Received(
                msg.sender,
                address(0),
                tokenId,
                ""
            );
        require(
            accepted
                == IERC721Receiver.onERC721Received.selector,
            "unsafe recipient"
        );

        amount0 =
            projectToken == params.token0 ? tokenUsed : 0;
        amount1 =
            projectToken == params.token1 ? tokenUsed : 0;
    }

    function payout(
        address token,
        address recipient,
        uint256 amount
    ) external {
        require(msg.sender == router, "not router");
        require(
            IERC20(token).transfer(recipient, amount),
            "payout"
        );
    }

    function collect(CollectParams calldata)
        external
        payable
        override
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    function positions(uint256 tokenId)
        external
        view
        override
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        Position memory p = position[tokenId];
        return (
            0,
            address(0),
            p.token0,
            p.token1,
            p.fee,
            p.tickLower,
            p.tickUpper,
            p.liquidity,
            0,
            0,
            0,
            0
        );
    }
}

contract LauncherMockRouter is IHashlingV3LaunchRouter {
    uint256 public constant OUTPUT = 5_000_000 ether;

    LauncherMockPositionManager public immutable
        positionManager;

    address public lastTokenIn;
    address public lastTokenOut;
    address public lastRecipient;
    uint24 public lastFee;
    uint256 public lastAmountIn;
    uint256 public lastMinimum;
    uint256 public lastValue;

    constructor(LauncherMockPositionManager positionManager_) {
        positionManager = positionManager_;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable override returns (uint256 amountOut) {
        require(msg.value == params.amountIn, "value");

        lastTokenIn = params.tokenIn;
        lastTokenOut = params.tokenOut;
        lastRecipient = params.recipient;
        lastFee = params.fee;
        lastAmountIn = params.amountIn;
        lastMinimum = params.amountOutMinimum;
        lastValue = msg.value;

        amountOut = OUTPUT;
        positionManager.payout(
            params.tokenOut,
            params.recipient,
            amountOut
        );
    }
}

contract V3LauncherProperties is Test {
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant PROTOCOL = address(0xFEE);

    LauncherMockWeth internal weth;
    LauncherMockFactory internal factory;
    LauncherMockPositionManager internal positionManager;
    LauncherMockRouter internal router;
    HashlingPositionLocker internal locker;
    HashlingV3Launcher internal launcher;

    address private launchedToken;
    address private launchedPool;
    uint256 private launchedPositionId;
    uint256 private launchedTokensBought;
    uint256 private launchedDevBuy;

    function setUp() public {
        weth = new LauncherMockWeth();
        factory = new LauncherMockFactory();
        positionManager = new LauncherMockPositionManager(
            address(factory),
            address(weth)
        );
        router = new LauncherMockRouter(positionManager);
        positionManager.setRouter(address(router));

        uint64 nonce = vm.getNonce(address(this));
        address predictedLauncher = vm.computeCreateAddress(
            address(this),
            nonce + 1
        );

        locker = new HashlingPositionLocker(
            address(positionManager),
            PROTOCOL,
            predictedLauncher
        );
        launcher = new HashlingV3Launcher(
            address(factory),
            address(positionManager),
            address(router),
            address(weth),
            address(locker),
            PROTOCOL
        );

        assertEq(address(launcher), predictedLauncher);
    }

    function testLaunchIsAtomicFixedSupplyAndOneSided()
        public
    {
        launchedDevBuy = launcher.MIN_DEV_BUY();
        uint256 expectedOutput = router.OUTPUT();
        vm.deal(CREATOR, launchedDevBuy);

        vm.prank(CREATOR);
        (
            launchedToken,
            launchedPool,
            launchedPositionId,
            launchedTokensBought
        ) = launcher.launch{value: launchedDevBuy}(
            "Direct V3",
            "DV3",
            "ipfs://art",
            expectedOutput,
            block.timestamp
        );

        _assertTokenState();
        _assertLaunchRecord();
        _assertLockerRegistration();
        _assertPoolConfiguration();
        _assertRouterForwarding();
    }

    function _assertTokenState() private view {
        HashlingTokenV2 launched =
            HashlingTokenV2(launchedToken);
        assertEq(launched.name(), "Direct V3");
        assertEq(launched.symbol(), "DV3");
        assertEq(
            launched.initialSupply(),
            launcher.TOKEN_SUPPLY()
        );
        assertEq(
            launched.totalSupply(),
            launcher.TOKEN_SUPPLY()
                - positionManager.DUST()
        );
        assertEq(launchedTokensBought, router.OUTPUT());
        assertEq(
            launched.balanceOf(CREATOR),
            launchedTokensBought
        );
        assertEq(launched.balanceOf(address(launcher)), 0);
        assertEq(launched.balanceOf(address(router)), 0);
        assertEq(
            launched.balanceOf(address(positionManager))
                + launched.balanceOf(CREATOR),
            launched.totalSupply()
        );
        assertEq(
            launched.allowance(
                address(launcher),
                address(positionManager)
            ),
            0
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
            ,

        ) = launcher.launches(launchedToken);

        assertEq(creator, CREATOR);
        assertEq(recordedPool, launchedPool);
        assertEq(recordedPositionId, launchedPositionId);
        assertEq(
            tokenLiquidity,
            IERC20(launchedToken).totalSupply()
        );
        assertEq(recordedDevBuy, launchedDevBuy);
        assertEq(
            recordedTokensBought,
            launchedTokensBought
        );
        assertEq(launcher.tokenCount(), 1);
        assertEq(launcher.allTokens(0), launchedToken);
    }

    function _assertLockerRegistration() private {
        (
            address lockedCreator,
            address lockedToken0,
            address lockedToken1,
            bool registered
        ) = locker.positionInfo(launchedPositionId);
        assertEq(lockedCreator, CREATOR);
        assertEq(
            lockedToken0,
            launchedToken < address(weth)
                ? launchedToken
                : address(weth)
        );
        assertEq(
            lockedToken1,
            launchedToken < address(weth)
                ? address(weth)
                : launchedToken
        );
        assertTrue(registered);
        assertEq(
            positionManager.ownerOf(launchedPositionId),
            address(locker)
        );

        vm.prank(address(0xBAD));
        vm.expectRevert(
            HashlingPositionLocker.NotMigrator.selector
        );
        locker.registerPosition(
            launchedPositionId,
            address(0xBAD)
        );

        vm.prank(address(launcher));
        vm.expectRevert(
            HashlingPositionLocker
                .PositionAlreadyRegistered.selector
        );
        locker.registerPosition(
            launchedPositionId,
            address(0xBAD)
        );
    }

    function _assertPoolConfiguration() private view {
        (,,,,,, int24 tickLower, int24 tickUpper) =
            launcher.launches(launchedToken);
        LauncherMockPool candidate =
            LauncherMockPool(launchedPool);
        assertEq(candidate.fee(), launcher.POOL_FEE());
        assertEq(candidate.tickSpacing(), 200);
        assertEq(
            candidate.token0(),
            launchedToken < address(weth)
                ? launchedToken
                : address(weth)
        );
        assertEq(
            candidate.token1(),
            launchedToken < address(weth)
                ? address(weth)
                : launchedToken
        );

        (uint160 price, int24 currentTick,,,,,) =
            candidate.slot0();
        assertEq(
            price,
            launcher.startingSqrtPriceX96(launchedToken)
        );
        assertEq(currentTick, -123);

        if (launchedToken < address(weth)) {
            assertEq(tickLower, 0);
            assertEq(tickUpper, 887_200);
        } else {
            assertEq(tickLower, -887_200);
            assertEq(tickUpper, -200);
        }
    }

    function _assertRouterForwarding() private view {
        assertEq(router.lastTokenIn(), address(weth));
        assertEq(router.lastTokenOut(), launchedToken);
        assertEq(router.lastRecipient(), CREATOR);
        assertEq(router.lastFee(), launcher.POOL_FEE());
        assertEq(router.lastAmountIn(), launchedDevBuy);
        assertEq(router.lastMinimum(), router.OUTPUT());
        assertEq(router.lastValue(), launchedDevBuy);
        assertEq(address(launcher).balance, 0);
    }

    function testRejectsExpiredAndSubminimumDevBuy() public {
        vm.warp(100);
        uint256 minDevBuy = launcher.MIN_DEV_BUY();
        vm.deal(CREATOR, 1 ether);
        vm.startPrank(CREATOR);

        vm.expectRevert(HashlingV3Launcher.Expired.selector);
        launcher.launch{value: minDevBuy}(
            "Expired",
            "EXP",
            "",
            0,
            99
        );

        vm.expectRevert(
            HashlingV3Launcher.DevBuyTooSmall.selector
        );
        launcher.launch{value: minDevBuy - 1}(
            "Small",
            "SML",
            "",
            0,
            block.timestamp
        );

        vm.stopPrank();
        assertEq(launcher.tokenCount(), 0);
    }

    function testSlippageRollsBackTheCompleteLaunch() public {
        uint256 devBuy = launcher.MIN_DEV_BUY();
        uint256 expectedOutput = router.OUTPUT();
        vm.deal(CREATOR, devBuy);

        vm.startPrank(CREATOR);
        vm.expectRevert(HashlingV3Launcher.Slippage.selector);
        launcher.launch{value: devBuy}(
            "Rollback",
            "RBK",
            "",
            expectedOutput + 1,
            block.timestamp
        );
        vm.stopPrank();

        assertEq(launcher.tokenCount(), 0);
        assertEq(positionManager.nextTokenId(), 1);
        assertEq(address(router).balance, 0);
    }

    function testConstructorRejectsMismatchedLocker()
        public
    {
        HashlingPositionLocker wrongLocker =
            new HashlingPositionLocker(
                address(positionManager),
                PROTOCOL,
                address(0xBAD)
            );

        vm.expectRevert(
            HashlingV3Launcher.DependencyMismatch.selector
        );
        new HashlingV3Launcher(
            address(factory),
            address(positionManager),
            address(router),
            address(weth),
            address(wrongLocker),
            PROTOCOL
        );
    }

    function testStartingPriceMatchesFixedFdvBothOrders()
        public
        view
    {
        uint160 wethNumber = uint160(address(weth));
        address lowerToken = address(wethNumber - 1);
        address higherToken = address(wethNumber + 1);
        uint256 q96 = uint256(1) << 96;

        uint160 lowerSqrt =
            launcher.startingSqrtPriceX96(lowerToken);
        uint256 lowerPriceX96 = Math.mulDiv(
            uint256(lowerSqrt),
            uint256(lowerSqrt),
            q96
        );
        uint256 lowerFdv = Math.mulDiv(
            lowerPriceX96,
            launcher.TOKEN_SUPPLY(),
            q96
        );

        uint160 higherSqrt =
            launcher.startingSqrtPriceX96(higherToken);
        uint256 higherPriceX96 = Math.mulDiv(
            uint256(higherSqrt),
            uint256(higherSqrt),
            q96
        );
        uint256 higherFdv = Math.mulDiv(
            launcher.TOKEN_SUPPLY(),
            q96,
            higherPriceX96
        );

        assertApproxEqAbs(
            lowerFdv,
            launcher.START_FDV(),
            1_000
        );
        assertApproxEqAbs(
            higherFdv,
            launcher.START_FDV(),
            1_000
        );
    }

    function testStartingPriceRejectsInvalidToken() public {
        vm.expectRevert(HashlingV3Launcher.ZeroAddress.selector);
        launcher.startingSqrtPriceX96(address(0));

        vm.expectRevert(HashlingV3Launcher.ZeroAddress.selector);
        launcher.startingSqrtPriceX96(address(weth));
    }

    function testFuzzEntireDevBuyIsForwarded(uint96 raw)
        public
    {
        uint256 devBuy = bound(
            uint256(raw),
            launcher.MIN_DEV_BUY(),
            100 ether
        );
        uint256 expectedOutput = router.OUTPUT();
        vm.deal(CREATOR, devBuy);

        vm.prank(CREATOR);
        (address token,,, uint256 tokensBought) =
            launcher.launch{value: devBuy}(
                "Forward",
                "FWD",
                "",
                expectedOutput,
                block.timestamp
            );

        assertEq(router.lastAmountIn(), devBuy);
        assertEq(router.lastValue(), devBuy);
        assertEq(address(router).balance, devBuy);
        assertEq(address(launcher).balance, 0);
        assertEq(
            IERC20(token).balanceOf(CREATOR),
            tokensBought
        );
    }
}
