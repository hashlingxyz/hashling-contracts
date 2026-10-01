// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from
    "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// 1% fee wrapper over Uniswap V4 pools that carry one fixed hook.
///
/// Built for graduated Pons V2 tokens: every canonical graduation pool is
/// (token, quote, fee 0, tickSpacing 200, Pons hook). The pool key is rebuilt
/// here from immutable parameters, so only that pool can ever be traded;
/// third-party pools on the same pair are unreachable by construction.
///
/// Quotes may be native ETH (address(0)) or any ERC-20. The Hashling fee is
/// taken in the quote currency: on the input for buys, on the output for
/// sells. Native output is accepted only from the PoolManager. No owner,
/// pause, upgrade, or sweep exists. Nothing is held between calls: a swap the
/// pool cannot fill in full (its price limit stops it before the input is
/// spent) reverts with PartialFill rather than leaving the remainder here.
contract HashlingV4Swap is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    address public immutable hooks;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    address public immutable feeRecipient;
    uint16 public immutable feeBps;

    uint16 public constant MAX_FEE_BPS = 500;
    address public constant NATIVE = address(0);
    uint160 private constant MIN_SQRT_PRICE = 4_295_128_739;
    uint160 private constant MAX_SQRT_PRICE =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    bool private unlocking;

    struct Callback {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
    }

    error ZeroAddress();
    error FeeTooHigh();
    error ZeroAmount();
    error SameCurrency();
    error ValueMismatch();
    error Slippage();
    error PartialFill();
    error NotPoolManager();
    error NotUnlocking();
    error EthTransferFailed();

    event Bought(
        address indexed token,
        address indexed quote,
        address indexed buyer,
        uint256 quoteIn,
        uint256 fee,
        uint256 tokensOut
    );
    event Sold(
        address indexed token,
        address indexed quote,
        address indexed seller,
        uint256 tokensIn,
        uint256 fee,
        uint256 quoteOut
    );

    constructor(
        address poolManager_,
        address hooks_,
        uint24 poolFee_,
        int24 tickSpacing_,
        address feeRecipient_,
        uint16 feeBps_
    ) {
        if (poolManager_ == address(0) || hooks_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        poolManager = IPoolManager(poolManager_);
        hooks = hooks_;
        poolFee = poolFee_;
        tickSpacing = tickSpacing_;
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    /// Buy `token` with `quoteAmount` of `quote`. For a native quote send
    /// exactly `quoteAmount` as msg.value; for an ERC-20 quote approve this
    /// contract first and send no value. Fee-on-transfer quotes are charged
    /// on what actually arrives.
    function buy(address token, address quote, uint256 quoteAmount, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (token == address(0)) revert ZeroAddress();
        if (token == quote) revert SameCurrency();
        if (quoteAmount == 0) revert ZeroAmount();

        uint256 received;
        if (quote == NATIVE) {
            if (msg.value != quoteAmount) revert ValueMismatch();
            received = msg.value;
        } else {
            if (msg.value != 0) revert ValueMismatch();
            received = _pull(quote, quoteAmount);
        }

        uint256 fee = (received * feeBps) / 10_000;
        uint256 amountIn = received - fee;
        if (amountIn == 0) revert ZeroAmount();

        (PoolKey memory key, bool zeroForOne) = _key(token, quote, true);
        tokensOut = _swap(key, zeroForOne, amountIn);
        if (tokensOut < minTokensOut) revert Slippage();

        IERC20(token).safeTransfer(msg.sender, tokensOut);
        _pay(quote, feeRecipient, fee);
        emit Bought(token, quote, msg.sender, received, fee, tokensOut);
    }

    /// Sell `tokenAmount` of `token` for `quote`. Approve this contract
    /// first. The fee is taken from the quote received; the remainder is paid
    /// to the seller in the quote currency (ETH for native quotes).
    function sell(address token, address quote, uint256 tokenAmount, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (token == address(0)) revert ZeroAddress();
        if (token == quote) revert SameCurrency();
        if (tokenAmount == 0) revert ZeroAmount();

        uint256 received = _pull(token, tokenAmount);

        (PoolKey memory key, bool zeroForOne) = _key(token, quote, false);
        uint256 grossOut = _swap(key, zeroForOne, received);
        if (grossOut == 0) revert ZeroAmount();

        uint256 fee = (grossOut * feeBps) / 10_000;
        quoteOut = grossOut - fee;
        if (quoteOut < minQuoteOut) revert Slippage();

        _pay(quote, feeRecipient, fee);
        _pay(quote, msg.sender, quoteOut);
        emit Sold(token, quote, msg.sender, received, fee, quoteOut);
    }

    /// PoolManager re-enters here during `unlock`. Executes the swap, settles
    /// the input the pool consumed from this contract's balance, takes the
    /// output here, and reports both amounts back to `_swap`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!unlocking) revert NotUnlocking();

        Callback memory c = abi.decode(data, (Callback));
        int256 delta = poolManager.swap(
            c.key,
            SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: -int256(c.amountIn),
                sqrtPriceLimitX96: c.zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (uint256 owed, uint256 out) = _amounts(delta, c.zeroForOne);
        _settle(c.zeroForOne ? c.key.currency0 : c.key.currency1, owed);
        poolManager.take(c.zeroForOne ? c.key.currency1 : c.key.currency0, address(this), out);
        return abi.encode(owed, out);
    }

    /// Splits the swap delta into what we owe the pool and what it owes us.
    function _amounts(int256 delta, bool zeroForOne)
        private
        pure
        returns (uint256 owed, uint256 out)
    {
        (int128 d0, int128 d1) = _unpack(delta);
        (int128 dIn, int128 dOut) = zeroForOne ? (d0, d1) : (d1, d0);
        if (dIn >= 0 || dOut <= 0) revert ZeroAmount();
        owed = uint256(uint128(-dIn));
        out = uint256(uint128(dOut));
    }

    /// Pays the input currency into the PoolManager: value for native,
    /// sync/transfer/settle for ERC-20 (fee-on-transfer safe).
    function _settle(address currency, uint256 owed) private {
        if (currency == NATIVE) {
            poolManager.settle{value: owed}();
        } else {
            poolManager.sync(currency);
            IERC20(currency).safeTransfer(address(poolManager), owed);
            poolManager.settle();
        }
    }

    /// Native output is accepted only from the PoolManager during a swap.
    receive() external payable {
        if (msg.sender != address(poolManager) || !unlocking) revert EthTransferFailed();
    }

    /// One exact-input swap through `unlock`. The pool must consume the whole
    /// input: a partial fill would strand the remainder in this contract.
    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        private
        returns (uint256 out)
    {
        unlocking = true;
        bytes memory result = poolManager.unlock(
            abi.encode(Callback({key: key, zeroForOne: zeroForOne, amountIn: amountIn}))
        );
        unlocking = false;
        uint256 owed;
        (owed, out) = abi.decode(result, (uint256, uint256));
        if (owed < amountIn) revert PartialFill();
    }

    /// Rebuilds the only pool key this contract can trade: the canonical
    /// hooked pool for (token, quote). `buying` selects the swap direction.
    function _key(address token, address quote, bool buying)
        private
        view
        returns (PoolKey memory key, bool zeroForOne)
    {
        (address c0, address c1) = token < quote ? (token, quote) : (quote, token);
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
        address input = buying ? quote : token;
        zeroForOne = input == c0;
    }

    function _pull(address currency, uint256 amount) private returns (uint256 received) {
        IERC20 t = IERC20(currency);
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        received = t.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();
    }

    function _pay(address currency, address to, uint256 amount) private {
        if (amount == 0) return;
        if (currency == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(currency).safeTransfer(to, amount);
        }
    }

    function _unpack(int256 delta) private pure returns (int128 amount0, int128 amount1) {
        assembly {
            amount0 := sar(128, delta)
            amount1 := signextend(15, delta)
        }
    }
}
