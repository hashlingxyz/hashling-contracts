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
import {
    IWETH9V2,
    IUniswapV3FactoryV2,
    IUniswapV3PoolV2,
    IUniswapV3SwapCallbackV2,
    INonfungiblePositionManagerV2,
    IHashlingPositionLocker,
    IHashlingFactoryV2Config
} from "./interfaces/IHashlingV3.sol";

contract HashlingMigrator is ReentrancyGuard, IUniswapV3SwapCallbackV2 {
    using SafeERC20 for IERC20;

    struct MigrationParams {
        address token;
        address creator;
        address pool;
        uint24 poolFee;
        uint256 tokenAmountDesired;
        uint256 ethAmount;
    }

    struct CorrectionParams {
        address token;
        address payer;
        address pool;
        address token0;
        address token1;
        address inputToken;
        uint160 expected;
        uint256 maxInput;
        bool zeroForOne;
    }

    uint24 public constant POOL_FEE = 10_000;
    int24 private constant MIN_TICK = -887_272;
    int24 private constant MAX_TICK = 887_272;
    uint160 private constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 private constant MAX_SQRT_RATIO =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    /// One Uniswap tick is approximately one basis point in price. Since
    /// sqrtPrice moves by roughly half the price move, permit 50 ppm.
    uint256 public constant SQRT_PRICE_TOLERANCE_PPM = 50;
    uint256 private constant PPM = 1_000_000;
    uint256 private constant Q192 = uint256(1) << 192;

    IUniswapV3FactoryV2 public immutable uniswapFactory;
    INonfungiblePositionManagerV2 public immutable positionManager;
    IHashlingPositionLocker public immutable locker;
    IWETH9V2 public immutable weth;
    address public immutable factory;

    address private _activePool;
    address private _activePayer;
    address private _activeInputToken;

    error ZeroAddress();
    error DependencyMismatch();
    error InvalidReserves();
    error InvalidPrice();
    error NoValidPool();
    error InsufficientProjectTokens();
    error EthRefundFailed();
    error NotFactory();
    error UnauthorizedCallback();
    error InvalidInputCap();
    error IncorrectEthValue();

    event PoolPrepared(
        address indexed token,
        address indexed pool,
        uint24 fee,
        uint160 sqrtPriceX96
    );
    event Migrated(
        address indexed token,
        address indexed pool,
        uint256 indexed positionId,
        uint24 fee,
        uint256 ethUsed,
        uint256 tokenUsed,
        uint256 tokenDust,
        uint256 ethDust
    );
    event PoolCorrected(
        address indexed token,
        address indexed payer,
        address indexed inputToken,
        uint256 inputUsed,
        uint256 outputReceived
    );

    constructor(
        address uniswapFactory_,
        address positionManager_,
        address weth_,
        address locker_,
        address factory_
    ) {
        if (
            uniswapFactory_ == address(0)
                || positionManager_ == address(0)
                || weth_ == address(0)
                || locker_ == address(0) || factory_ == address(0)
        ) revert ZeroAddress();

        uniswapFactory = IUniswapV3FactoryV2(uniswapFactory_);
        positionManager =
            INonfungiblePositionManagerV2(positionManager_);
        weth = IWETH9V2(weth_);
        locker = IHashlingPositionLocker(locker_);
        factory = factory_;

        if (
            positionManager.factory() != uniswapFactory_
                || positionManager.WETH9() != weth_
                || locker.migrator() != address(this)
                || locker.positionManager() != positionManager_
                || IHashlingFactoryV2Config(factory_).migrator()
                    != address(this)
                || locker.protocolFeeRecipient()
                    != IHashlingFactoryV2Config(factory_)
                        .protocolFeeRecipient()
        ) revert DependencyMismatch();
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    /// Called during launch. Initializing the empty pool before the curve can
    /// fill prevents an ordinary third party from choosing its initial price
    /// immediately before graduation.
    function preparePool(
        address token,
        uint256 effectiveEthReserve,
        uint256 tokenReserve
    )
        external
        onlyFactory
        returns (
            address pool,
            uint24 poolFee,
            uint160 sqrtPriceX96
        )
    {
        (pool, poolFee, sqrtPriceX96) =
            _selectValidPool(
                token,
                effectiveEthReserve,
                tokenReserve
            );
    }

    function migrate(
        address token,
        address creator,
        uint256 effectiveEthReserve,
        uint256 tokenReserve,
        uint256 tokenAmountDesired
    )
        external
        payable
        onlyFactory
        nonReentrant
        returns (
            address pool,
            uint24 poolFee,
            uint256 positionId,
            uint256 ethUsed,
            uint256 tokenUsed
        )
    {
        if (creator == address(0)) revert ZeroAddress();
        if (
            msg.value == 0 || tokenAmountDesired == 0
                || effectiveEthReserve == 0 || tokenReserve == 0
        ) revert InvalidReserves();

        (pool, poolFee,) =
            _selectValidPool(
                token,
                effectiveEthReserve,
                tokenReserve
            );

        (positionId, ethUsed, tokenUsed) = _mintAndLock(
            MigrationParams({
                token: token,
                creator: creator,
                pool: pool,
                poolFee: poolFee,
                tokenAmountDesired: tokenAmountDesired,
                ethAmount: msg.value
            })
        );
    }

    function poolWithinTolerance(
        address token,
        uint256 effectiveEthReserve,
        uint256 tokenReserve
    ) external view returns (bool) {
        (address token0, address token1) =
            _sort(token, address(weth));
        uint160 expected = expectedSqrtPriceX96(
            token,
            effectiveEthReserve,
            tokenReserve
        );

        address pool =
            uniswapFactory.getPool(token0, token1, POOL_FEE);
        return _poolIsValid(
            pool,
            token0,
            token1,
            POOL_FEE,
            expected
        );
    }

    function correctPool(
        address token,
        address payer,
        uint256 effectiveEthReserve,
        uint256 tokenReserve,
        uint256 maxInput
    )
        external
        payable
        onlyFactory
        nonReentrant
        returns (uint256 inputUsed, uint256 outputReceived)
    {
        if (payer == address(0)) revert ZeroAddress();
        if (maxInput == 0 || maxInput > uint256(type(int256).max)) {
            revert InvalidInputCap();
        }

        CorrectionParams memory p;
        p.token = token;
        p.payer = payer;
        p.maxInput = maxInput;
        (p.token0, p.token1) = _sort(token, address(weth));
        p.expected = expectedSqrtPriceX96(
            token,
            effectiveEthReserve,
            tokenReserve
        );
        p.pool = uniswapFactory.getPool(
            p.token0,
            p.token1,
            POOL_FEE
        );
        (uint160 current,,,,,,) =
            IUniswapV3PoolV2(p.pool).slot0();
        if (current == 0) revert InvalidPrice();

        p.zeroForOne = current > p.expected;
        p.inputToken = p.zeroForOne ? p.token0 : p.token1;
        return _correct(p);
    }

    function _correct(CorrectionParams memory p)
        private
        returns (uint256 inputUsed, uint256 outputReceived)
    {
        if (p.inputToken == address(weth)) {
            if (msg.value != p.maxInput) revert IncorrectEthValue();
        } else if (msg.value != 0) {
            revert IncorrectEthValue();
        }

        uint256 tokenBefore = IERC20(p.token).balanceOf(address(this));
        uint256 wethBefore = weth.balanceOf(address(this));
        if (p.inputToken == address(weth)) {
            weth.deposit{value: p.maxInput}();
        }

        _activePool = p.pool;
        _activePayer = p.payer;
        _activeInputToken = p.inputToken;
        (int256 amount0, int256 amount1) = IUniswapV3PoolV2(p.pool)
            .swap(
                address(this),
                p.zeroForOne,
                int256(p.maxInput),
                p.expected,
                abi.encode(p.payer)
            );
        _activePool = address(0);
        _activePayer = address(0);
        _activeInputToken = address(0);

        if (
            !_poolIsValid(
                p.pool,
                p.token0,
                p.token1,
                POOL_FEE,
                p.expected
            )
        ) revert InvalidPrice();

        int256 inputDelta = p.zeroForOne ? amount0 : amount1;
        int256 outputDelta = p.zeroForOne ? amount1 : amount0;
        if (inputDelta < 0 || outputDelta > 0) revert InvalidPrice();
        inputUsed = uint256(inputDelta);
        outputReceived = uint256(-outputDelta);
        if (inputUsed > p.maxInput) revert InvalidInputCap();

        if (p.inputToken == address(weth)) {
            uint256 tokenOut =
                IERC20(p.token).balanceOf(address(this)) - tokenBefore;
            if (tokenOut != 0) {
                IERC20(p.token).safeTransfer(p.payer, tokenOut);
            }
            uint256 refund = weth.balanceOf(address(this)) - wethBefore;
            if (refund != 0) {
                weth.withdraw(refund);
                _payEth(p.payer, refund);
            }
        } else {
            uint256 wethOut = weth.balanceOf(address(this)) - wethBefore;
            if (wethOut != 0) {
                weth.withdraw(wethOut);
                _payEth(p.payer, wethOut);
            }
        }

        emit PoolCorrected(
            p.token,
            p.payer,
            p.inputToken,
            inputUsed,
            outputReceived
        );
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        address payer = abi.decode(data, (address));
        if (
            msg.sender != _activePool || payer != _activePayer
                || _activeInputToken == address(0)
        ) revert UnauthorizedCallback();

        if (amount0Delta == 0 && amount1Delta == 0) return;

        IUniswapV3PoolV2 pool = IUniswapV3PoolV2(msg.sender);
        address token0 = pool.token0();
        address token1 = pool.token1();
        uint256 amountOwed;
        if (_activeInputToken == token0 && amount0Delta > 0) {
            amountOwed = uint256(amount0Delta);
        } else if (
            _activeInputToken == token1 && amount1Delta > 0
        ) {
            amountOwed = uint256(amount1Delta);
        } else {
            revert UnauthorizedCallback();
        }

        if (_activeInputToken == address(weth)) {
            IERC20(_activeInputToken).safeTransfer(
                msg.sender,
                amountOwed
            );
        } else {
            IERC20(_activeInputToken).safeTransferFrom(
                payer,
                msg.sender,
                amountOwed
            );
        }
    }

    function _mintAndLock(MigrationParams memory p)
        private
        returns (
            uint256 positionId,
            uint256 ethUsed,
            uint256 tokenUsed
        )
    {
        IERC20 projectToken = IERC20(p.token);
        projectToken.safeTransferFrom(
            msg.sender,
            address(this),
            p.tokenAmountDesired
        );
        weth.deposit{value: p.ethAmount}();

        (address token0, address token1) =
            _sort(p.token, address(weth));

        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        (positionId, liquidity, amount0, amount1) =
            _mintPosition(p, token0, token1);

        if (liquidity == 0) revert InsufficientProjectTokens();

        tokenUsed = token0 == p.token ? amount0 : amount1;
        ethUsed = token0 == address(weth) ? amount0 : amount1;

        /// At most one wei may remain because of integer rounding. A larger
        /// WETH remainder means the project-token side was insufficient.
        if (ethUsed + 1 < p.ethAmount) {
            revert InsufficientProjectTokens();
        }

        locker.registerPosition(positionId, p.creator);

        IERC20(token0).forceApprove(address(positionManager), 0);
        IERC20(token1).forceApprove(address(positionManager), 0);

        uint256 tokenDust = p.tokenAmountDesired - tokenUsed;
        uint256 ethDust = p.ethAmount - ethUsed;

        if (tokenDust != 0) {
            projectToken.safeTransfer(msg.sender, tokenDust);
        }

        if (ethDust != 0) {
            weth.withdraw(ethDust);
            (bool ok,) = msg.sender.call{value: ethDust}("");
            if (!ok) revert EthRefundFailed();
        }

        emit Migrated(
            p.token,
            p.pool,
            positionId,
            p.poolFee,
            ethUsed,
            tokenUsed,
            tokenDust,
            ethDust
        );
    }

    function _mintPosition(
        MigrationParams memory p,
        address token0,
        address token1
    )
        private
        returns (
            uint256,
            uint128,
            uint256,
            uint256
        )
    {
        int24 tickSpacing =
            IUniswapV3PoolV2(p.pool).tickSpacing();
        int24 tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;
        uint256 amount0Desired =
            token0 == p.token ? p.tokenAmountDesired : p.ethAmount;
        uint256 amount1Desired =
            token1 == p.token ? p.tokenAmountDesired : p.ethAmount;

        IERC20(token0).forceApprove(
            address(positionManager),
            amount0Desired
        );
        IERC20(token1).forceApprove(
            address(positionManager),
            amount1Desired
        );

        INonfungiblePositionManagerV2.MintParams memory mintParams;
        mintParams.token0 = token0;
        mintParams.token1 = token1;
        mintParams.fee = p.poolFee;
        mintParams.tickLower = tickLower;
        mintParams.tickUpper = tickUpper;
        mintParams.amount0Desired = amount0Desired;
        mintParams.amount1Desired = amount1Desired;
        mintParams.amount0Min = 0;
        mintParams.amount1Min = 0;
        mintParams.recipient = address(locker);
        mintParams.deadline = block.timestamp;

        return positionManager.mint(mintParams);
    }

    function expectedSqrtPriceX96(
        address token,
        uint256 effectiveEthReserve,
        uint256 tokenReserve
    ) public view returns (uint160 result) {
        if (
            token == address(0) || token == address(weth)
                || effectiveEthReserve == 0 || tokenReserve == 0
        ) revert InvalidReserves();

        uint256 numerator =
            token < address(weth) ? effectiveEthReserve : tokenReserve;
        uint256 denominator =
            token < address(weth) ? tokenReserve : effectiveEthReserve;
        uint256 ratioX192 = Math.mulDiv(numerator, Q192, denominator);
        uint256 sqrtRatio = Math.sqrt(ratioX192);

        if (
            sqrtRatio < MIN_SQRT_RATIO
                || sqrtRatio >= MAX_SQRT_RATIO
                || sqrtRatio > type(uint160).max
        ) revert InvalidPrice();

        result = uint160(sqrtRatio);
    }

    /// V2 pins every project to the 1% tier created during launch.
    function _selectValidPool(
        address token,
        uint256 effectiveEthReserve,
        uint256 tokenReserve
    )
        private
        returns (
            address pool,
            uint24 poolFee,
            uint160 sqrtPriceX96
        )
    {
        (address token0, address token1) = _sort(token, address(weth));
        sqrtPriceX96 = expectedSqrtPriceX96(
            token,
            effectiveEthReserve,
            tokenReserve
        );
        poolFee = POOL_FEE;
        pool = positionManager.createAndInitializePoolIfNecessary(
            token0,
            token1,
            poolFee,
            sqrtPriceX96
        );

        if (
            !_poolIsValid(
                pool,
                token0,
                token1,
                poolFee,
                sqrtPriceX96
            )
        ) revert NoValidPool();

        emit PoolPrepared(token, pool, poolFee, sqrtPriceX96);
    }

    function _poolIsValid(
        address pool,
        address token0,
        address token1,
        uint24 poolFee,
        uint160 expectedPrice
    ) private view returns (bool) {
        if (
            pool == address(0)
                || uniswapFactory.getPool(
                    token0,
                    token1,
                    poolFee
                ) != pool
        ) return false;

        IUniswapV3PoolV2 candidate = IUniswapV3PoolV2(pool);
        if (
            candidate.token0() != token0
                || candidate.token1() != token1
                || candidate.fee() != poolFee
        ) return false;

        (uint160 actualSqrtPriceX96,,,,,,) = candidate.slot0();
        uint256 difference = actualSqrtPriceX96 > expectedPrice
            ? actualSqrtPriceX96 - expectedPrice
            : expectedPrice - actualSqrtPriceX96;

        return actualSqrtPriceX96 != 0
            && Math.mulDiv(
                difference,
                PPM,
                expectedPrice
            ) <= SQRT_PRICE_TOLERANCE_PPM;
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

    function _payEth(address recipient, uint256 amount) private {
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert EthRefundFailed();
    }

    receive() external payable {
        if (msg.sender != address(weth)) revert EthRefundFailed();
    }
}
