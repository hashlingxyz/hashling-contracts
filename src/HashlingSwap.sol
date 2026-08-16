// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// Minimal SwapRouter02 surface. exactInputSingle on SwapRouter02 has NO
/// deadline field (unlike SwapRouter v1); the deadline is enforced here.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    /// Sends the router's WETH balance to `recipient` as ETH (multicall helper).
    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}

interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// Buy / sell any token against its Uniswap v3 pool, with a flat fee to
/// Hashling. Exists because Robinhood Chain has pools (Noxa launched ~60k
/// tokens straight into them; Hashling curves graduate into them) and no
/// front end that reaches them.
///
/// Custody: none. ETH and tokens pass through within one call; nothing is
/// held between transactions and there is no owner, pause, or upgrade. The
/// fee rate and recipient are fixed at deploy — the same posture as the
/// factory. Slippage is the caller's `minOut`; the deadline is checked here
/// because SwapRouter02 does not.
contract HashlingSwap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable router;
    IWETH9 public immutable weth;
    address public immutable feeRecipient;
    /// Basis points of ETH in (buy) or ETH out (sell). 100 = 1%.
    uint16 public immutable feeBps;
    uint16 public constant MAX_FEE_BPS = 500;

    error ZeroAddress();
    error FeeTooHigh();
    error Expired();
    error ZeroAmount();
    error EthTransferFailed();

    event Bought(address indexed token, address indexed buyer, uint256 ethIn, uint256 fee, uint256 tokensOut);
    event Sold(address indexed token, address indexed seller, uint256 tokensIn, uint256 fee, uint256 ethOut);

    constructor(address router_, address weth_, address feeRecipient_, uint16 feeBps_) {
        if (router_ == address(0) || weth_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        router = ISwapRouter02(router_);
        weth = IWETH9(weth_);
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    /// ETH -> token. Fee is taken from msg.value first; the rest is swapped
    /// and tokens go straight to the caller (the router pays the recipient).
    function buy(address token, uint24 poolFee, uint256 minOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (msg.value == 0) revert ZeroAmount();
        uint256 fee = (msg.value * feeBps) / 10_000;
        uint256 amountIn = msg.value - fee;
        _payEth(feeRecipient, fee);
        tokensOut = router.exactInputSingle{value: amountIn}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: token,
                fee: poolFee,
                recipient: msg.sender,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        emit Bought(token, msg.sender, msg.value, fee, tokensOut);
    }

    /// token -> ETH. Caller approves this contract; tokens are pulled, swapped
    /// to WETH held briefly here, unwrapped, fee taken from the ETH out, rest
    /// paid to the caller. `minOut` is ETH after fee.
    function sell(address token, uint24 poolFee, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(token).forceApprove(address(router), amountIn);
        uint256 wethOut = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(weth),
                fee: poolFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0, // enforced on ethOut below, after fee
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(token).forceApprove(address(router), 0);
        weth.withdraw(wethOut);
        uint256 fee = (wethOut * feeBps) / 10_000;
        ethOut = wethOut - fee;
        // Slippage in the units the caller sees: ETH after fee.
        require(ethOut >= minOut, "slippage");
        _payEth(feeRecipient, fee);
        _payEth(msg.sender, ethOut);
        emit Sold(token, msg.sender, amountIn, fee, ethOut);
    }

    function _payEth(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// Only WETH may push ETH here (on withdraw). Anything else is refused so
    /// no ETH can ever be stranded in this contract.
    receive() external payable {
        require(msg.sender == address(weth), "no direct eth");
    }
}
