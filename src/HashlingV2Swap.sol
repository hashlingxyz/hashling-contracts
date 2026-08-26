// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// Generic WETH-paired Uniswap V2 execution with Hashling's immutable ETH fee.
///
/// Flap is the first UI adapter, not a hard-coded contract dependency. The UI
/// is responsible for exposing this route only after Flap reports graduation
/// and its emitted pool matches this router's canonical factory. Future V2
/// adapters can reuse the same execution layer after their own venue checks.
///
/// No owner, pause, upgrade, or sweep exists. Assets introduced by a normal
/// trade leave again inside that call. Slippage is enforced on the amount the
/// user actually receives, after transfer tax and Hashling's fee.
contract HashlingV2Swap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV2Router02 public immutable router;
    IUniswapV2Factory public immutable factory;
    address public immutable weth;
    address public immutable feeRecipient;
    uint16 public immutable feeBps;

    uint16 public constant MAX_FEE_BPS = 500;

    bool private acceptingEth;

    error ZeroAddress();
    error FeeTooHigh();
    error Expired();
    error ZeroAmount();
    error PairMissing();
    error ResidualToken();
    error EthTransferFailed();
    error DirectEthRefused();

    event Bought(
        address indexed token,
        address indexed buyer,
        uint256 ethIn,
        uint256 fee,
        uint256 tokensOut
    );
    event Sold(
        address indexed token,
        address indexed seller,
        uint256 tokensIn,
        uint256 fee,
        uint256 ethOut
    );

    constructor(address router_, address feeRecipient_, uint16 feeBps_) {
        if (router_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();

        IUniswapV2Router02 routerRef = IUniswapV2Router02(router_);
        address factory_ = routerRef.factory();
        address weth_ = routerRef.WETH();
        if (factory_ == address(0) || weth_ == address(0)) revert ZeroAddress();

        router = routerRef;
        factory = IUniswapV2Factory(factory_);
        weth = weth_;
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    /// ETH -> token through the router's canonical token/WETH pair. Hashling's
    /// fee is taken from ETH input before the swap.
    function buy(address tokenAddress, uint256 minOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (msg.value == 0) revert ZeroAmount();
        _requirePair(tokenAddress);

        uint256 fee = (msg.value * feeBps) / 10_000;
        uint256 amountIn = msg.value - fee;
        IERC20 token = IERC20(tokenAddress);
        uint256 buyerBefore = token.balanceOf(msg.sender);

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = tokenAddress;
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(
            0,
            path,
            msg.sender,
            deadline
        );

        tokensOut = token.balanceOf(msg.sender) - buyerBefore;
        if (tokensOut == 0) revert ZeroAmount();
        require(tokensOut >= minOut, "slippage");

        _payEth(feeRecipient, fee);
        emit Bought(tokenAddress, msg.sender, msg.value, fee, tokensOut);
    }

    /// token -> ETH through the router's canonical token/WETH pair. The caller
    /// approves this contract; Hashling's fee is taken from gross ETH output.
    function sell(
        address tokenAddress,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 ethOut) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        _requirePair(tokenAddress);

        IERC20 token = IERC20(tokenAddress);
        uint256 wrapperBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = token.balanceOf(address(this)) - wrapperBefore;
        if (received == 0) revert ZeroAmount();

        token.forceApprove(address(router), received);
        uint256 ethBefore = address(this).balance;
        address[] memory path = new address[](2);
        path[0] = tokenAddress;
        path[1] = weth;
        acceptingEth = true;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            received,
            0,
            path,
            address(this),
            deadline
        );
        acceptingEth = false;
        token.forceApprove(address(router), 0);

        if (token.balanceOf(address(this)) != wrapperBefore) revert ResidualToken();
        uint256 grossOut = address(this).balance - ethBefore;
        if (grossOut == 0) revert ZeroAmount();
        uint256 fee = (grossOut * feeBps) / 10_000;
        ethOut = grossOut - fee;
        require(ethOut >= minOut, "slippage");

        _payEth(feeRecipient, fee);
        _payEth(msg.sender, ethOut);
        emit Sold(tokenAddress, msg.sender, received, fee, ethOut);
    }

    function _requirePair(address token) private view {
        if (token == address(0)) revert ZeroAddress();
        if (factory.getPair(token, weth) == address(0)) revert PairMissing();
    }

    function _payEth(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// Router02 sends native output to this contract during a sell. ETH from an
    /// ordinary direct transfer is refused so it cannot be stranded here.
    receive() external payable {
        if (!acceptingEth) revert DirectEthRefused();
    }
}
