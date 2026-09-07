// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from
    "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from
    "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {HashlingTokenV2} from "./HashlingTokenV2.sol";
import {
    IUniswapV3FactoryV2,
    IUniswapV3PoolV2,
    INonfungiblePositionManagerV2,
    IHashlingPositionLocker
} from "./interfaces/IHashlingV3.sol";

interface IHashlingV3LaunchRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

/// Launches fixed-supply tokens directly into canonical TOKEN/WETH Uniswap V3
/// pools. There is no bonding curve, migration phase, owner, pause, upgrade,
/// launch fee, creator allocation, mint authority, tax, or transfer limit.
///
/// The complete supply is deposited as one-sided liquidity. The resulting
/// position NFT is minted directly to a dedicated HashlingPositionLocker,
/// where its principal remains permanently locked. The creator's ETH is then
/// used for the first pool buy in the same transaction.
contract HashlingV3Launcher is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TOKEN_SUPPLY = 1_000_000_000 ether;
    uint256 public constant START_FDV = 3.5125 ether;
    uint256 public constant MIN_DEV_BUY = 0.001 ether;
    uint24 public constant POOL_FEE = 10_000;

    int24 private constant MIN_TICK = -887_272;
    int24 private constant MAX_TICK = 887_272;
    uint160 private constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 private constant MAX_SQRT_RATIO =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    uint256 private constant Q192 = uint256(1) << 192;

    IUniswapV3FactoryV2 public immutable uniswapFactory;
    INonfungiblePositionManagerV2 public immutable positionManager;
    IHashlingV3LaunchRouter public immutable swapRouter;
    IERC20 public immutable weth;
    IHashlingPositionLocker public immutable locker;
    address public immutable protocolFeeRecipient;

    struct Launch {
        address creator;
        address pool;
        uint256 positionId;
        uint256 tokenLiquidity;
        uint256 devBuyEth;
        uint256 devBuyTokens;
        int24 tickLower;
        int24 tickUpper;
    }

    struct SeedResult {
        address pool;
        uint256 positionId;
        uint256 tokenUsed;
        uint256 burnedTokens;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
    }

    mapping(address => Launch) public launches;
    address[] public allTokens;

    error ZeroAddress();
    error DependencyMismatch();
    error Expired();
    error DevBuyTooSmall();
    error InvalidPool();
    error InvalidPrice();
    error InvalidTickSpacing();
    error InsufficientLiquidity();
    error Slippage();

    /// Retains Factory V2's event shape so launch metadata remains recoverable
    /// by the existing Hashling decoder.
    event TokenCreated(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        uint256 supply,
        string artUri
    );

    event V3Launched(
        address indexed token,
        address indexed creator,
        address indexed pool,
        uint256 positionId,
        uint256 tokenLiquidity,
        uint256 burnedTokens,
        uint256 devBuyEth,
        uint256 devBuyTokens,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper
    );

    constructor(
        address uniswapFactory_,
        address positionManager_,
        address swapRouter_,
        address weth_,
        address locker_,
        address protocolFeeRecipient_
    ) {
        if (
            uniswapFactory_ == address(0)
                || positionManager_ == address(0)
                || swapRouter_ == address(0)
                || weth_ == address(0)
                || locker_ == address(0)
                || protocolFeeRecipient_ == address(0)
        ) revert ZeroAddress();

        if (
            uniswapFactory_.code.length == 0
                || positionManager_.code.length == 0
                || swapRouter_.code.length == 0
                || weth_.code.length == 0
                || locker_.code.length == 0
        ) revert DependencyMismatch();

        uniswapFactory = IUniswapV3FactoryV2(uniswapFactory_);
        positionManager =
            INonfungiblePositionManagerV2(positionManager_);
        swapRouter = IHashlingV3LaunchRouter(swapRouter_);
        weth = IERC20(weth_);
        locker = IHashlingPositionLocker(locker_);
        protocolFeeRecipient = protocolFeeRecipient_;

        if (
            positionManager.factory() != uniswapFactory_
                || positionManager.WETH9() != weth_
                || locker.positionManager() != positionManager_
                || locker.migrator() != address(this)
                || locker.protocolFeeRecipient()
                    != protocolFeeRecipient_
        ) revert DependencyMismatch();
    }

    function launch(
        string calldata name,
        string calldata symbol,
        string calldata artUri,
        uint256 minTokensOut,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        returns (
            address token,
            address pool,
            uint256 positionId,
            uint256 tokensBought
        )
    {
        if (block.timestamp > deadline) revert Expired();
        if (msg.value < MIN_DEV_BUY) revert DevBuyTooSmall();

        token = _deployToken(name, symbol, artUri);
        SeedResult memory seeded = _seedPool(token, msg.sender);

        tokensBought = swapRouter.exactInputSingle{value: msg.value}(
            IHashlingV3LaunchRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: token,
                fee: POOL_FEE,
                recipient: msg.sender,
                amountIn: msg.value,
                amountOutMinimum: minTokensOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (tokensBought < minTokensOut) revert Slippage();

        pool = seeded.pool;
        positionId = seeded.positionId;
        launches[token] = Launch({
            creator: msg.sender,
            pool: pool,
            positionId: positionId,
            tokenLiquidity: seeded.tokenUsed,
            devBuyEth: msg.value,
            devBuyTokens: tokensBought,
            tickLower: seeded.tickLower,
            tickUpper: seeded.tickUpper
        });
        allTokens.push(token);

        _emitTokenCreated(token, name, symbol, artUri);
        _emitV3Launched(token, seeded, tokensBought);
    }

    function _emitTokenCreated(
        address token,
        string calldata name,
        string calldata symbol,
        string calldata artUri
    ) internal {
        emit TokenCreated(
            token,
            msg.sender,
            name,
            symbol,
            TOKEN_SUPPLY,
            artUri
        );
    }

    function _emitV3Launched(
        address token,
        SeedResult memory seeded,
        uint256 tokensBought
    ) internal {
        emit V3Launched(
            token,
            msg.sender,
            seeded.pool,
            seeded.positionId,
            seeded.tokenUsed,
            seeded.burnedTokens,
            msg.value,
            tokensBought,
            seeded.sqrtPriceX96,
            seeded.tickLower,
            seeded.tickUpper
        );
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    /// The opening value matches Factory V2:
    /// 2.81 virtual ETH / 80% curve allocation = 3.5125 ETH FDV.
    function startingSqrtPriceX96(address token)
        public
        view
        returns (uint160 result)
    {
        if (token == address(0) || token == address(weth)) {
            revert ZeroAddress();
        }

        uint256 numerator =
            token < address(weth) ? START_FDV : TOKEN_SUPPLY;
        uint256 denominator =
            token < address(weth) ? TOKEN_SUPPLY : START_FDV;
        uint256 ratioX192 = Math.mulDiv(
            numerator,
            Q192,
            denominator
        );
        uint256 sqrtRatio = Math.sqrt(ratioX192);

        if (
            sqrtRatio < MIN_SQRT_RATIO
                || sqrtRatio >= MAX_SQRT_RATIO
                || sqrtRatio > type(uint160).max
        ) revert InvalidPrice();

        result = uint160(sqrtRatio);
    }

    function _deployToken(
        string calldata name,
        string calldata symbol,
        string calldata artUri
    ) private returns (address token) {
        bytes32 salt = keccak256(
            abi.encode(
                block.prevrandao,
                blockhash(block.number - 1),
                msg.sender,
                allTokens.length,
                name,
                symbol,
                artUri
            )
        );

        token = address(
            new HashlingTokenV2{salt: salt}(
                name,
                symbol,
                TOKEN_SUPPLY,
                address(this)
            )
        );
    }

    function _seedPool(address token, address creator)
        private
        returns (SeedResult memory result)
    {
        (address token0, address token1) =
            _sort(token, address(weth));
        result.sqrtPriceX96 = startingSqrtPriceX96(token);
        result.pool =
            positionManager.createAndInitializePoolIfNecessary(
                token0,
                token1,
                POOL_FEE,
                result.sqrtPriceX96
            );

        (int24 currentTick, int24 tickSpacing) = _validatePool(
            result.pool,
            token0,
            token1,
            result.sqrtPriceX96
        );
        (result.tickLower, result.tickUpper) =
            _oneSidedRange(
                token == token0,
                currentTick,
                tickSpacing
            );

        IERC20 projectToken = IERC20(token);
        projectToken.forceApprove(
            address(positionManager),
            TOKEN_SUPPLY
        );

        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        (
            result.positionId,
            liquidity,
            amount0,
            amount1
        ) = positionManager.mint(
            INonfungiblePositionManagerV2.MintParams({
                token0: token0,
                token1: token1,
                fee: POOL_FEE,
                tickLower: result.tickLower,
                tickUpper: result.tickUpper,
                amount0Desired: token == token0
                    ? TOKEN_SUPPLY
                    : 0,
                amount1Desired: token == token1
                    ? TOKEN_SUPPLY
                    : 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp
            })
        );
        projectToken.forceApprove(address(positionManager), 0);

        result.tokenUsed =
            token == token0 ? amount0 : amount1;
        if (
            liquidity == 0 || result.tokenUsed == 0
                || result.tokenUsed > TOKEN_SUPPLY
        ) revert InsufficientLiquidity();

        result.burnedTokens =
            TOKEN_SUPPLY - result.tokenUsed;
        if (
            projectToken.balanceOf(address(this))
                != result.burnedTokens
        ) revert InsufficientLiquidity();

        if (result.burnedTokens != 0) {
            HashlingTokenV2(token).burnFactoryBalance(
                result.burnedTokens
            );
        }

        locker.registerPosition(result.positionId, creator);
    }

    function _validatePool(
        address pool,
        address token0,
        address token1,
        uint160 expectedPrice
    )
        private
        view
        returns (int24 currentTick, int24 tickSpacing)
    {
        if (
            pool == address(0)
                || uniswapFactory.getPool(
                    token0,
                    token1,
                    POOL_FEE
                ) != pool
        ) revert InvalidPool();

        IUniswapV3PoolV2 candidate = IUniswapV3PoolV2(pool);
        if (
            candidate.token0() != token0
                || candidate.token1() != token1
                || candidate.fee() != POOL_FEE
        ) revert InvalidPool();

        uint160 actualPrice;
        (actualPrice, currentTick,,,,,) = candidate.slot0();
        if (actualPrice != expectedPrice) revert InvalidPrice();

        tickSpacing = candidate.tickSpacing();
        if (tickSpacing <= 0) revert InvalidTickSpacing();
    }

    /// Position liquidity starts entirely in the project token. A WETH→token
    /// buy crosses the nearest usable boundary and activates the position.
    function _oneSidedRange(
        bool tokenIsToken0,
        int24 currentTick,
        int24 tickSpacing
    ) private pure returns (int24 tickLower, int24 tickUpper) {
        int24 minUsableTick =
            (MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxUsableTick =
            (MAX_TICK / tickSpacing) * tickSpacing;

        if (tokenIsToken0) {
            tickLower =
                (currentTick / tickSpacing) * tickSpacing;
            if (tickLower < currentTick) {
                tickLower += tickSpacing;
            }
            tickUpper = maxUsableTick;
        } else {
            tickLower = minUsableTick;
            tickUpper =
                (currentTick / tickSpacing) * tickSpacing;
            if (tickUpper > currentTick) {
                tickUpper -= tickSpacing;
            }
        }

        if (
            tickLower < minUsableTick
                || tickUpper > maxUsableTick
                || tickLower >= tickUpper
        ) revert InvalidTickSpacing();
    }

    function _sort(address a, address b)
        private
        pure
        returns (address token0, address token1)
    {
        if (a == address(0) || b == address(0) || a == b) {
            revert ZeroAddress();
        }
        (token0, token1) = a < b ? (a, b) : (b, a);
    }
}
