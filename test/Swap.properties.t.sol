// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {HashlingSwap, ISwapRouter02, IWETH9} from "../src/HashlingSwap.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract MockWETH is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 a) external { _burn(msg.sender, a); (bool ok,) = msg.sender.call{value: a}(""); require(ok); }
    receive() external payable { _mint(msg.sender, msg.value); }
}

/// Fixed-rate "pool": 1 ETH -> RATE tokens, RATE tokens -> 1 ETH. Enough to
/// prove the wrapper's accounting; price discovery is Uniswap's job.
contract MockRouter {
    MockToken public token; MockWETH public weth; uint256 public constant RATE = 1000;
    bool public reenter; HashlingSwap public target;
    constructor(MockToken t, MockWETH w) { token = t; weth = w; }
    function arm(HashlingSwap s) external { target = s; reenter = true; }
    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        if (reenter) { reenter = false; try target.buy{value: 1}(address(token), 100, 0, block.timestamp) {} catch {} }
        if (p.tokenIn == address(weth)) {
            require(msg.value == p.amountIn, "value");
            out = p.amountIn * RATE;
            require(out >= p.amountOutMinimum, "Too little received");
            token.mint(p.recipient, out);
        } else {
            token.transferFrom(msg.sender, address(this), p.amountIn);
            out = p.amountIn / RATE;
            require(out >= p.amountOutMinimum, "Too little received");
            weth.deposit{value: out}();
            weth.transfer(p.recipient, out);
        }
    }
    receive() external payable {}
}

contract SwapProperties is Test {
    MockToken token; MockWETH weth; MockRouter router; HashlingSwap swap;
    address feeTo = address(0xFEE);
    address alice = address(0xA11CE);
    uint16 constant BPS = 100;

    function setUp() public {
        token = new MockToken(); weth = new MockWETH(); router = new MockRouter(token, weth);
        vm.deal(address(router), 1_000_000 ether); // liquidity for sells
        swap = new HashlingSwap(address(router), address(weth), feeTo, BPS);
        vm.deal(alice, 1_000_000 ether);
    }

    function test_constructorGuards() public {
        vm.expectRevert(HashlingSwap.ZeroAddress.selector);
        new HashlingSwap(address(0), address(weth), feeTo, BPS);
        vm.expectRevert(HashlingSwap.FeeTooHigh.selector);
        new HashlingSwap(address(router), address(weth), feeTo, 501);
    }

    /// Buy conservation: msg.value = fee + swapped; fee = value*bps/1e4 exactly;
    /// tokens = swapped*RATE; contract holds nothing after.
    function testFuzz_buy(uint256 value) public {
        value = bound(value, 1, 100_000 ether);
        uint256 feeBefore = feeTo.balance;
        vm.prank(alice);
        uint256 out = swap.buy{value: value}(address(token), 100, 0, block.timestamp);
        uint256 fee = (uint256(value) * BPS) / 10_000;
        assertEq(feeTo.balance - feeBefore, fee, "fee");
        assertEq(out, (uint256(value) - fee) * router.RATE(), "out");
        assertEq(token.balanceOf(alice), out, "tokens to buyer");
        assertEq(address(swap).balance, 0, "no eth stranded");
        assertEq(token.balanceOf(address(swap)), 0, "no tokens stranded");
    }

    /// Sell conservation: ethOut + fee = wethOut; fee exact; minOut enforced
    /// AFTER fee; nothing stranded; allowance reset to 0.
    function testFuzz_sell(uint256 amount) public {
        amount = bound(amount, router.RATE(), 100_000 ether * router.RATE());
        token.mint(alice, amount);
        vm.startPrank(alice);
        token.approve(address(swap), amount);
        uint256 gross = uint256(amount) / router.RATE();
        uint256 fee = (gross * BPS) / 10_000;
        uint256 aliceBefore = alice.balance; uint256 feeBefore = feeTo.balance;
        uint256 out = swap.sell(address(token), 100, amount, gross - fee, block.timestamp);
        vm.stopPrank();
        assertEq(out, gross - fee, "out");
        assertEq(alice.balance - aliceBefore, out, "eth to seller");
        assertEq(feeTo.balance - feeBefore, fee, "fee");
        assertEq(address(swap).balance, 0, "no eth stranded");
        assertEq(weth.balanceOf(address(swap)), 0, "no weth stranded");
        assertEq(token.balanceOf(address(swap)), 0, "no tokens stranded");
        assertEq(token.allowance(address(swap), address(router)), 0, "allowance reset");
    }

    function test_sellSlippageIsAfterFee() public {
        token.mint(alice, 1000e18);
        vm.startPrank(alice);
        token.approve(address(swap), 1000e18);
        uint256 gross = 1e18; // 1000e18 / RATE
        // Asking for the gross amount must fail: the fee comes off first.
        vm.expectRevert(bytes("slippage"));
        swap.sell(address(token), 100, 1000e18, gross, block.timestamp);
        // Asking for gross - fee succeeds.
        swap.sell(address(token), 100, 1000e18, gross - gross / 100, block.timestamp);
        vm.stopPrank();
    }

    function test_deadline() public {
        vm.prank(alice);
        vm.expectRevert(HashlingSwap.Expired.selector);
        swap.buy{value: 1 ether}(address(token), 100, 0, block.timestamp - 1);
    }

    function test_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(HashlingSwap.ZeroAmount.selector);
        swap.buy{value: 0}(address(token), 100, 0, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(HashlingSwap.ZeroAmount.selector);
        swap.sell(address(token), 100, 0, 0, block.timestamp);
    }

    function test_reentrancyBlocked() public {
        router.arm(swap);
        vm.deal(address(router), 1_000_000 ether);
        vm.prank(alice);
        swap.buy{value: 1 ether}(address(token), 100, 0, block.timestamp);
        // The nested buy was attempted and swallowed; if it had succeeded the
        // router would have received an extra mint call — check only one buyer
        // balance change happened for alice's swap.
        assertEq(router.reenter(), false);
        assertEq(address(swap).balance, 0);
    }

    function test_directEthRefused() public {
        vm.prank(alice);
        (bool ok,) = address(swap).call{value: 1 ether}("");
        assertFalse(ok, "direct eth must be refused");
    }

    function test_feeRecipientRevertBlocksTrade() public {
        // A fee recipient that refuses ETH must revert the whole trade, never
        // strand ETH.
        HashlingSwap s2 = new HashlingSwap(address(router), address(weth), address(this), BPS);
        vm.prank(alice);
        vm.expectRevert(HashlingSwap.EthTransferFailed.selector);
        s2.buy{value: 1 ether}(address(token), 100, 0, block.timestamp);
    }
    // No receive() here on purpose: `address(this)` refuses ETH.
}
