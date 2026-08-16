// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HashlingSwap} from "../src/HashlingSwap.sol";

/// Against a Robinhood Chain mainnet fork: buy then sell CASHCAT (a Noxa
/// launch) through the real SwapRouter02. Skipped when no fork RPC is set.
contract SwapFork is Test {
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant CASHCAT = 0x020bfC650A365f8BB26819deAAbF3E21291018b4;
    uint24 constant POOL_FEE = 3000;
    address feeTo = address(0xFEE);
    address alice = address(0xA11CE);

    function test_forkBuySell() public {
        string memory url = vm.envOr("FORK_RPC", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        HashlingSwap swap = new HashlingSwap(ROUTER, WETH, feeTo, 100);
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        uint256 out = swap.buy{value: 0.001 ether}(CASHCAT, POOL_FEE, 0, block.timestamp + 60);
        assertGt(out, 0, "bought nothing");
        assertEq(IERC20(CASHCAT).balanceOf(alice), out, "tokens landed");
        assertEq(feeTo.balance, 0.00001 ether, "1% fee");
        assertEq(address(swap).balance, 0, "no eth stranded");

        IERC20(CASHCAT).approve(address(swap), out);
        uint256 ethBefore = alice.balance;
        uint256 got = swap.sell(CASHCAT, POOL_FEE, out, 0, block.timestamp + 60);
        vm.stopPrank();
        assertGt(got, 0, "sold for nothing");
        assertEq(alice.balance - ethBefore, got, "eth landed");
        assertEq(address(swap).balance, 0, "no eth stranded after sell");
        assertEq(IERC20(WETH).balanceOf(address(swap)), 0, "no weth stranded");
        emit log_named_uint("tokens for 0.001 ETH", out);
        emit log_named_uint("eth back (wei)", got);
    }
}
