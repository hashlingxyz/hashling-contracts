// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from
    "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {HashlingFactoryV2} from "../src/HashlingFactoryV2.sol";
import {
    IHashlingMigratorV2
} from "../src/interfaces/IHashlingV3.sol";

contract DriftMigratorV2 is IHashlingMigratorV2 {
    uint256 private constant Q192 = uint256(1) << 192;
    address internal constant WETH =
        0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    mapping(address => uint160) public preparedPrice;

    function factory() external pure returns (address) {
        return address(0);
    }

    function preparePool(
        address token,
        uint256 effectiveEthReserve,
        uint256 tokenReserve
    ) external returns (address, uint24, uint160 sqrtPriceX96) {
        sqrtPriceX96 = expectedSqrtPriceX96(
            token,
            effectiveEthReserve,
            tokenReserve
        );
        preparedPrice[token] = sqrtPriceX96;
        return (address(0xBEEF), 10_000, sqrtPriceX96);
    }

    function expectedSqrtPriceX96(
        address token,
        uint256 effectiveEthReserve,
        uint256 tokenReserve
    ) public pure returns (uint160) {
        uint256 numerator = token < WETH
            ? effectiveEthReserve
            : tokenReserve;
        uint256 denominator = token < WETH
            ? tokenReserve
            : effectiveEthReserve;
        return uint160(
            Math.sqrt(Math.mulDiv(numerator, Q192, denominator))
        );
    }

    function poolWithinTolerance(address, uint256, uint256)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function migrate(address, address, uint256, uint256, uint256)
        external
        payable
        returns (address, uint24, uint256, uint256, uint256)
    {
        revert();
    }

    function correctPool(address, address, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256)
    {
        revert();
    }
}

contract FactoryV2DriftTest is Test {
    uint256 private constant PPB = 1_000_000_000;
    uint256 private constant TOLERANCE_PPB = 50_000;
    address private constant BUYER = address(0xB0B);

    DriftMigratorV2 private migrator;
    HashlingFactoryV2 private factory;

    function setUp() public {
        migrator = new DriftMigratorV2();
        factory = new HashlingFactoryV2(
            address(migrator),
            address(0xFEE)
        );
        vm.deal(BUYER, 1_000_000 ether);
    }

    function testClosingPriceDriftAtDepth() public {
        uint256[6] memory chunkCounts = [
            uint256(1),
            2,
            3,
            7,
            31,
            127
        ];
        uint256 maxDriftPpb;
        uint256 maxRawDeviation;
        uint256 casesRun;

        for (uint256 supplyIndex; supplyIndex < 12; ++supplyIndex) {
            uint256 supply = factory.MIN_SUPPLY()
                + Math.mulDiv(
                    factory.MAX_SUPPLY() - factory.MIN_SUPPLY(),
                    supplyIndex * supplyIndex,
                    121
                );

            for (uint256 j; j < chunkCounts.length; ++j) {
                address token = factory.launch(
                    "Drift",
                    "DRIFT",
                    supply,
                    ""
                );
                _fill(token, chunkCounts[j]);

                (
                    ,
                    uint128 finalEffectiveEth,
                    uint128 finalTokenReserve,
                    ,
                    ,
                    ,

                ) = factory.graduation(token);
                uint160 prepared = migrator.preparedPrice(token);
                uint160 closing = migrator.expectedSqrtPriceX96(
                    token,
                    finalEffectiveEth,
                    finalTokenReserve
                );
                uint256 deviation = prepared > closing
                    ? prepared - closing
                    : closing - prepared;
                uint256 driftPpb = Math.ceilDiv(
                    deviation * PPB,
                    closing
                );

                if (deviation > maxRawDeviation) {
                    maxRawDeviation = deviation;
                }
                if (driftPpb > maxDriftPpb) {
                    maxDriftPpb = driftPpb;
                }
                ++casesRun;
            }
        }

        uint256 toleranceConsumedBps = Math.ceilDiv(
            maxDriftPpb * 10_000,
            TOLERANCE_PPB
        );
        emit log_named_uint("drift cases", casesRun);
        emit log_named_uint(
            "max sqrtPriceX96 deviation",
            maxRawDeviation
        );
        emit log_named_uint("max drift PPB", maxDriftPpb);
        emit log_named_uint(
            "tolerance consumed BPS (100 = 1%)",
            toleranceConsumedBps
        );

        assertLe(maxDriftPpb, TOLERANCE_PPB);
    }

    function _fill(address token, uint256 chunks) private {
        (,,,, uint128 target,) = factory.curves(token);
        uint256 netChunk = uint256(target) / chunks;
        uint256 grossChunk = Math.ceilDiv(netChunk * 10_000, 9_900);

        vm.startPrank(BUYER);
        for (uint256 i; i + 1 < chunks; ++i) {
            if (
                factory.stateOf(token)
                    != HashlingFactoryV2.State.Bonding
            ) break;
            factory.buy{value: grossChunk}(token, 0);
        }
        if (
            factory.stateOf(token)
                == HashlingFactoryV2.State.Bonding
        ) {
            factory.buy{value: 10_000 ether}(token, 0);
        }
        vm.stopPrank();
    }
}
