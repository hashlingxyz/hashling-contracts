// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IWETH9V2 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IUniswapV3FactoryV2 {
    function getPool(address tokenA, address tokenB, uint24 fee)
        external
        view
        returns (address pool);
}

interface IUniswapV3PoolV2 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IUniswapV3SwapCallbackV2 {
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}

interface INonfungiblePositionManagerV2 {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function factory() external view returns (address);
    function WETH9() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IHashlingPositionLocker {
    function migrator() external view returns (address);
    function protocolFeeRecipient() external view returns (address);
    function positionManager() external view returns (address);
    function registerPosition(uint256 tokenId, address creator) external;
}

interface IHashlingFactoryV2Config {
    function migrator() external view returns (address);
    function protocolFeeRecipient() external view returns (address);
}

interface IHashlingMigratorV2 {
    function factory() external view returns (address);

    function poolWithinTolerance(
        address token,
        uint256 effectiveEthReserve,
        uint256 tokenReserve
    ) external view returns (bool);

    function preparePool(
        address token,
        uint256 effectiveEthReserve,
        uint256 tokenReserve
    )
        external
        returns (
            address pool,
            uint24 poolFee,
            uint160 sqrtPriceX96
        );

    function migrate(
        address token,
        address creator,
        uint256 effectiveEthReserve,
        uint256 tokenReserve,
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
        );

    function correctPool(
        address token,
        address payer,
        uint256 effectiveEthReserve,
        uint256 tokenReserve,
        uint256 maxInput
    )
        external
        payable
        returns (uint256 inputUsed, uint256 outputReceived);
}
