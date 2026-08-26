// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HashlingV2Swap} from "../src/HashlingV2Swap.sol";

interface IFlapPortalFork {
    struct ExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 minOutputAmount;
        bytes permitData;
    }

    function swapExactInput(ExactInputParams calldata params)
        external
        payable
        returns (uint256 outputAmount);
}

contract V2SwapFork is Test {
    address constant ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address constant PORTAL = 0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09;
    address constant OWNERCOIN = 0x796A6422Cc3EF4000B82c62bc1d913Ba74b67777;
    // Graduated at block 7,789,386; older non-tax 8888 template.
    address constant OLDER_8888 = 0x10B90dd1D5A999c2Ff9c034D13BE55a7ba788888;
    address constant FEE_TO = address(0xFEE);
    address constant ALICE = address(0xA11CE);

    IFlapPortalFork portal = IFlapPortalFork(PORTAL);
    HashlingV2Swap swap;

    function setUp() public {
        // Deliberately no envOr/skip: this contract must fail when FORK_RPC is
        // absent so a green result proves that live Portal integration ran.
        vm.createSelectFork(vm.envString("FORK_RPC"));
        swap = new HashlingV2Swap(ROUTER, FEE_TO, 100);
        vm.deal(ALICE, 10 ether);
    }

    function test_ownerCoinMatchesDirectPortalWithOnlyOnePercentAdded() public {
        _assertPortalParity(OWNERCOIN);
    }

    function test_older8888MatchesDirectPortalWithOnlyOnePercentAdded() public {
        _assertPortalParity(OLDER_8888);
    }

    function _assertPortalParity(address token) private {
        uint256 grossBuy = 0.001 ether;
        uint256 buyFee = grossBuy / 100;
        uint256 netBuy = grossBuy - buyFee;

        uint256 buySnapshot = vm.snapshot();
        uint256 directTokens = _portalBuy(token, netBuy);
        assertTrue(vm.revertTo(buySnapshot), "buy snapshot restore");

        uint256 feeBeforeBuy = FEE_TO.balance;
        uint256 wrappedTokens = _wrapperBuy(token, grossBuy);
        assertEq(
            wrappedTokens,
            directTokens,
            "wrapper must add only the 1% input fee"
        );
        assertEq(FEE_TO.balance - feeBeforeBuy, buyFee, "exact buy fee");
        assertEq(IERC20(token).balanceOf(address(swap)), 0, "no token residue");

        // Both sell branches start with the same wallet balance and the same
        // pool reserves: snapshot after the parity-proven wrapper buy.
        uint256 sellSnapshot = vm.snapshot();
        uint256 directEth = _portalSell(token, wrappedTokens);
        assertTrue(vm.revertTo(sellSnapshot), "sell snapshot restore");

        uint256 feeBefore = FEE_TO.balance;
        uint256 wrappedEth = _wrapperSell(token, wrappedTokens);
        uint256 expectedFee = directEth / 100;
        assertEq(
            wrappedEth,
            directEth - expectedFee,
            "wrapper must add only the 1% output fee"
        );
        assertEq(FEE_TO.balance - feeBefore, expectedFee, "exact sell fee");
        assertEq(address(swap).balance, 0, "no ETH residue");
        assertEq(IERC20(token).balanceOf(address(swap)), 0, "no token residue");
        assertEq(IERC20(token).allowance(address(swap), ROUTER), 0, "approval reset");
    }

    function _portalBuy(address token, uint256 ethIn)
        private
        returns (uint256 tokensOut)
    {
        uint256 beforeBalance = IERC20(token).balanceOf(ALICE);
        vm.prank(ALICE);
        portal.swapExactInput{value: ethIn}(
            IFlapPortalFork.ExactInputParams({
                inputToken: address(0),
                outputToken: token,
                inputAmount: ethIn,
                minOutputAmount: 0,
                permitData: ""
            })
        );
        tokensOut = IERC20(token).balanceOf(ALICE) - beforeBalance;
    }

    function _wrapperBuy(address token, uint256 ethIn)
        private
        returns (uint256 tokensOut)
    {
        uint256 beforeBalance = IERC20(token).balanceOf(ALICE);
        vm.prank(ALICE);
        tokensOut = swap.buy{value: ethIn}(
            token,
            0,
            block.timestamp + 60
        );
        assertEq(IERC20(token).balanceOf(ALICE) - beforeBalance, tokensOut, "tokens landed");
    }

    function _portalSell(address token, uint256 amountIn)
        private
        returns (uint256 ethOut)
    {
        vm.startPrank(ALICE);
        IERC20(token).approve(PORTAL, amountIn);
        uint256 beforeBalance = ALICE.balance;
        portal.swapExactInput(
            IFlapPortalFork.ExactInputParams({
                inputToken: token,
                outputToken: address(0),
                inputAmount: amountIn,
                minOutputAmount: 0,
                permitData: ""
            })
        );
        ethOut = ALICE.balance - beforeBalance;
        vm.stopPrank();
    }

    function _wrapperSell(address token, uint256 amountIn)
        private
        returns (uint256 ethOut)
    {
        vm.startPrank(ALICE);
        IERC20(token).approve(address(swap), amountIn);
        ethOut = swap.sell(
            token,
            amountIn,
            0,
            block.timestamp + 60
        );
        vm.stopPrank();
    }
}
