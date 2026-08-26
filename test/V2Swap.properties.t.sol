// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    HashlingV2Swap,
    IUniswapV2Factory,
    IUniswapV2Router02
} from "../src/HashlingV2Swap.sol";

contract MockV2TaxToken is ERC20 {
    address public pair;
    address public immutable taxSink;
    uint16 public buyTaxBps = 300;
    uint16 public sellTaxBps = 300;

    constructor(address taxSink_) ERC20("Mock V2 Tax", "MV2") {
        taxSink = taxSink_;
    }

    function setPair(address pair_) external { pair = pair_; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function _update(address from, address to, uint256 value) internal override {
        uint256 tax;
        if (from != address(0) && to != address(0)) {
            if (from == pair) tax = (value * buyTaxBps) / 10_000;
            else if (to == pair) tax = (value * sellTaxBps) / 10_000;
        }
        if (tax != 0) super._update(from, taxSink, tax);
        super._update(from, to, value - tax);
    }
}

contract MockV2Pair {
    IERC20 public immutable token;
    constructor(IERC20 token_) { token = token_; }
    function pay(address to, uint256 amount) external { token.transfer(to, amount); }
}

contract MockV2Factory is IUniswapV2Factory {
    address public pair;
    function setPair(address pair_) external { pair = pair_; }
    function getPair(address, address) external view returns (address) { return pair; }
}

contract MockV2Router is IUniswapV2Router02 {
    uint256 public constant RATE = 1_000;
    address public immutable override factory;
    address public immutable override WETH;
    MockV2TaxToken public immutable token;
    MockV2Pair public immutable pair;
    address public lastBuyRecipient;

    constructor(
        address factory_,
        address weth_,
        MockV2TaxToken token_,
        MockV2Pair pair_
    ) {
        factory = factory_;
        WETH = weth_;
        token = token_;
        pair = pair_;
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable {
        require(block.timestamp <= deadline, "expired");
        require(path[0] == WETH && path[1] == address(token), "path");
        lastBuyRecipient = to;
        pair.pay(to, msg.value * RATE);
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, "expired");
        require(path[0] == address(token) && path[1] == WETH, "path");
        uint256 pairBefore = token.balanceOf(address(pair));
        token.transferFrom(msg.sender, address(pair), amountIn);
        uint256 netToPair = token.balanceOf(address(pair)) - pairBefore;
        (bool ok,) = to.call{value: netToPair / RATE}("");
        require(ok, "eth");
    }

    receive() external payable {}
}

contract RejectV2Eth {}

contract V2SwapProperties is Test {
    address constant WETH = address(0xBEEF);
    address constant FEE_TO = address(0xFEE);
    address constant TAX_SINK = address(0x7A7);
    address constant ALICE = address(0xA11CE);
    uint16 constant FEE_BPS = 100;

    MockV2TaxToken token;
    MockV2Pair pair;
    MockV2Factory factory;
    MockV2Router router;
    HashlingV2Swap swap;

    function setUp() public {
        token = new MockV2TaxToken(TAX_SINK);
        pair = new MockV2Pair(token);
        factory = new MockV2Factory();
        router = new MockV2Router(address(factory), WETH, token, pair);
        token.setPair(address(pair));
        factory.setPair(address(pair));
        token.mint(address(pair), 1_000_000_000 ether);
        vm.deal(address(router), 1_000_000 ether);
        vm.deal(ALICE, 1_000_000 ether);
        swap = new HashlingV2Swap(address(router), FEE_TO, FEE_BPS);
    }

    function test_constructorBindsRouterFactoryAndWeth() public view {
        assertEq(address(swap.router()), address(router));
        assertEq(address(swap.factory()), address(factory));
        assertEq(swap.weth(), WETH);
        assertEq(swap.feeRecipient(), FEE_TO);
        assertEq(swap.feeBps(), FEE_BPS);
    }

    function test_constructorGuards() public {
        vm.expectRevert(HashlingV2Swap.ZeroAddress.selector);
        new HashlingV2Swap(address(0), FEE_TO, FEE_BPS);
        vm.expectRevert(HashlingV2Swap.FeeTooHigh.selector);
        new HashlingV2Swap(address(router), FEE_TO, 501);
    }

    function testFuzz_buyChargesOnePercentAndOnePoolTax(uint96 rawValue) public {
        uint256 value = bound(uint256(rawValue), 10_000, 100 ether);
        uint256 hashlingFee = (value * FEE_BPS) / 10_000;
        uint256 routerInput = value - hashlingFee;
        uint256 grossTokens = routerInput * router.RATE();
        uint256 v2Tax = (grossTokens * 300) / 10_000;
        uint256 expected = grossTokens - v2Tax;

        vm.prank(ALICE);
        uint256 out = swap.buy{value: value}(
            address(token), expected, block.timestamp + 60
        );

        assertEq(out, expected, "post-tax tokens");
        assertEq(token.balanceOf(ALICE), expected, "buyer receives output");
        assertEq(router.lastBuyRecipient(), ALICE, "pair pays buyer directly");
        assertEq(token.balanceOf(TAX_SINK), v2Tax, "pool tax occurs once");
        assertEq(FEE_TO.balance, hashlingFee, "1% Hashling fee");
        assertEq(token.balanceOf(address(swap)), 0, "no token residue");
        assertEq(address(swap).balance, 0, "no ETH residue");
    }

    function testFuzz_sellChargesOnePoolTaxThenOnePercent(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 100_000, 100_000_000 ether);
        token.mint(ALICE, amount);
        uint256 v2Tax = (amount * 300) / 10_000;
        uint256 grossEth = (amount - v2Tax) / router.RATE();
        uint256 hashlingFee = (grossEth * FEE_BPS) / 10_000;
        uint256 expected = grossEth - hashlingFee;

        vm.startPrank(ALICE);
        token.approve(address(swap), amount);
        uint256 beforeEth = ALICE.balance;
        uint256 out = swap.sell(
            address(token), amount, expected, block.timestamp + 60
        );
        vm.stopPrank();

        assertEq(out, expected, "post-fee ETH");
        assertEq(ALICE.balance - beforeEth, expected, "seller receives ETH");
        assertEq(FEE_TO.balance, hashlingFee, "1% Hashling fee");
        assertEq(token.balanceOf(TAX_SINK), v2Tax, "pool tax occurs once");
        assertEq(token.balanceOf(address(swap)), 0, "no token residue");
        assertEq(address(swap).balance, 0, "no ETH residue");
        assertEq(token.allowance(address(swap), address(router)), 0, "router approval reset");
    }

    function test_slippageIsAtUserBoundary() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("slippage"));
        swap.buy{value: 1 ether}(
            address(token), type(uint256).max, block.timestamp + 60
        );
    }

    function test_expiredZeroAndMissingPairFailClosed() public {
        vm.prank(ALICE);
        vm.expectRevert(HashlingV2Swap.Expired.selector);
        swap.buy{value: 1 ether}(address(token), 0, block.timestamp - 1);

        vm.prank(ALICE);
        vm.expectRevert(HashlingV2Swap.ZeroAmount.selector);
        swap.buy{value: 0}(address(token), 0, block.timestamp + 60);

        factory.setPair(address(0));
        vm.prank(ALICE);
        vm.expectRevert(HashlingV2Swap.PairMissing.selector);
        swap.buy{value: 1 ether}(address(token), 0, block.timestamp + 60);
    }

    function test_directEthRefused() public {
        vm.prank(ALICE);
        (bool ok,) = address(swap).call{value: 1 ether}("");
        assertFalse(ok, "direct ETH must be refused");
    }

    function test_feeRecipientRevertRollsBackTrade() public {
        HashlingV2Swap rejecting = new HashlingV2Swap(
            address(router), address(new RejectV2Eth()), FEE_BPS
        );
        vm.prank(ALICE);
        vm.expectRevert(HashlingV2Swap.EthTransferFailed.selector);
        rejecting.buy{value: 1 ether}(
            address(token), 0, block.timestamp + 60
        );
        assertEq(token.balanceOf(ALICE), 0, "whole trade rolled back");
    }
}
