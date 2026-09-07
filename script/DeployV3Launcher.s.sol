// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {HashlingV3Launcher} from "../src/HashlingV3Launcher.sol";
import {HashlingSwap} from "../src/HashlingSwap.sol";
import {
    HashlingPositionLocker
} from "../src/HashlingPositionLocker.sol";
import {
    INonfungiblePositionManagerV2
} from "../src/interfaces/IHashlingV3.sol";

contract DeployV3Launcher is Script {
    uint256 private constant ROBINHOOD_CHAIN_ID = 4_663;

    address private constant V3_FACTORY =
        0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address private constant POSITION_MANAGER =
        0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address private constant SWAP_ROUTER =
        0xCaf681a66D020601342297493863E78C959E5cb2;
    address private constant WETH =
        0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    struct Predictions {
        address locker;
        address launcher;
        address zeroFeeSwap;
    }

    error WrongChain(uint256 actualChainId);
    error ZeroAddress();
    error MissingDependency(address dependency);
    error DependencyMismatch();

    function run()
        external
        returns (
            HashlingPositionLocker locker,
            HashlingV3Launcher launcher,
            HashlingSwap zeroFeeSwap
        )
    {
        if (block.chainid != ROBINHOOD_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }

        address protocolFeeRecipient =
            vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        address deployer = vm.envAddress("DEPLOYER");

        _assertDependencies(protocolFeeRecipient, deployer);
        Predictions memory predicted = _predict(deployer);

        vm.startBroadcast(deployer);

        locker = new HashlingPositionLocker(
            POSITION_MANAGER,
            protocolFeeRecipient,
            predicted.launcher
        );

        launcher = new HashlingV3Launcher(
            V3_FACTORY,
            POSITION_MANAGER,
            SWAP_ROUTER,
            WETH,
            address(locker),
            protocolFeeRecipient
        );

        zeroFeeSwap = new HashlingSwap(
            SWAP_ROUTER,
            WETH,
            protocolFeeRecipient,
            0
        );

        vm.stopBroadcast();

        _assertDeployment(
            protocolFeeRecipient,
            predicted,
            locker,
            launcher,
            zeroFeeSwap
        );
    }

    function _assertDependencies(
        address protocolFeeRecipient,
        address deployer
    ) private view {
        if (
            protocolFeeRecipient == address(0)
                || deployer == address(0)
        ) revert ZeroAddress();

        _requireContract(V3_FACTORY);
        _requireContract(POSITION_MANAGER);
        _requireContract(SWAP_ROUTER);
        _requireContract(WETH);

        INonfungiblePositionManagerV2 positionManager =
            INonfungiblePositionManagerV2(POSITION_MANAGER);

        if (
            positionManager.factory() != V3_FACTORY
                || positionManager.WETH9() != WETH
        ) revert DependencyMismatch();
    }

    function _requireContract(address dependency) private view {
        if (dependency.code.length == 0) {
            revert MissingDependency(dependency);
        }
    }

    function _predict(address deployer)
        private
        view
        returns (Predictions memory predicted)
    {
        uint64 nonce = vm.getNonce(deployer);

        predicted.locker =
            vm.computeCreateAddress(deployer, nonce);
        predicted.launcher =
            vm.computeCreateAddress(deployer, nonce + 1);
        predicted.zeroFeeSwap =
            vm.computeCreateAddress(deployer, nonce + 2);
    }

    function _assertDeployment(
        address protocolFeeRecipient,
        Predictions memory predicted,
        HashlingPositionLocker locker,
        HashlingV3Launcher launcher,
        HashlingSwap zeroFeeSwap
    ) private view {
        if (
            address(locker) != predicted.locker
                || address(launcher) != predicted.launcher
                || address(zeroFeeSwap) != predicted.zeroFeeSwap
        ) revert DependencyMismatch();

        if (
            address(locker.positionManager()) != POSITION_MANAGER
                || locker.protocolFeeRecipient()
                    != protocolFeeRecipient
                || locker.migrator() != address(launcher)
        ) revert DependencyMismatch();

        if (
            address(launcher.uniswapFactory()) != V3_FACTORY
                || address(launcher.positionManager())
                    != POSITION_MANAGER
                || address(launcher.swapRouter()) != SWAP_ROUTER
                || address(launcher.weth()) != WETH
                || address(launcher.locker()) != address(locker)
                || launcher.protocolFeeRecipient()
                    != protocolFeeRecipient
        ) revert DependencyMismatch();

        if (
            address(zeroFeeSwap.router()) != SWAP_ROUTER
                || address(zeroFeeSwap.weth()) != WETH
                || zeroFeeSwap.feeRecipient()
                    != protocolFeeRecipient
                || zeroFeeSwap.feeBps() != 0
        ) revert DependencyMismatch();
    }
}
