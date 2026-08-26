// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from
    "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from
    "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {HashlingTokenV2} from "./HashlingTokenV2.sol";
import {
    IHashlingMigratorV2
} from "./interfaces/IHashlingV3.sol";

contract HashlingFactoryV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant CREATOR_FEE_SHARE_BPS = 8_000;
    uint256 public constant CURVE_SUPPLY_BPS = 8_000;
    uint256 public constant MIGRATION_FLAT_AT_REFERENCE = 0.25 ether;
    uint256 public constant MIGRATION_RAISE_BPS = 300;
    uint256 public constant REFUND_DELAY = 7 days;

    uint256 public constant MIN_SUPPLY = 1e6 ether;
    uint256 public constant REF_SUPPLY = 1e9 ether;
    uint256 public constant MAX_SUPPLY = 1e12 ether;
    uint256 public constant REF_VIRTUAL_ETH = 2.81 ether;
    uint256 public constant REF_RAISE_TARGET = 6.5 ether;

    enum State {
        Bonding,
        GraduationReady,
        Graduated,
        Refunding
    }

    struct Curve {
        address creator;
        uint128 virtualEth;
        uint128 realEth;
        uint128 tokenReserve;
        uint128 raiseTarget;
        uint128 migrationFee;
        uint128 finalEffectiveEthReserve;
        uint128 finalTokenReserve;
        uint128 burnedTokens;
        uint128 refundSupply;
        uint128 redeemedTokens;
        uint64 readyAt;
        uint64 blockedAt;
        bool migrationFailureReported;
        State state;
        address pool;
        uint24 poolFee;
        uint256 positionId;
    }

    struct GraduationResult {
        address pool;
        uint24 poolFee;
        uint256 positionId;
        uint256 ethUsed;
        uint256 tokenUsed;
        uint256 migrationEth;
    }

    IHashlingMigratorV2 public immutable migrator;
    address public immutable protocolFeeRecipient;

    mapping(address => Curve) private _curves;
    mapping(address => uint256) public creatorFees;
    uint256 public protocolFees;
    address[] public allTokens;

    error ZeroAddress();
    error SupplyOutOfRange();
    error UnknownToken();
    error WrongState();
    error ZeroAmount();
    error Slippage();
    error DustTrade();
    error ExceedsRealReserve();
    error TransferFailed();
    error NothingToClaim();
    error RefundDelayActive();
    error MigrationAvailable();
    error RefundCountdownNotStarted();
    error RefundCountdownAlreadyStarted();

    event TokenCreated(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        uint256 supply,
        string artUri
    );
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 realEthAfter
    );
    event PurchaseRefunded(
        address indexed token,
        address indexed buyer,
        uint256 amount
    );
    event GraduationReady(
        address indexed token,
        uint256 finalEffectiveEthReserve,
        uint256 finalTokenReserve,
        uint256 migrationFee
    );
    event Graduated(
        address indexed token,
        address indexed pool,
        uint256 indexed positionId,
        uint24 poolFee,
        uint256 ethUsed,
        uint256 tokenUsed,
        uint256 burnedTokens
    );
    event GraduationAttemptFailed(
        address indexed token,
        bytes32 indexed reasonHash,
        uint256 refundAvailableAt
    );
    event RefundingActivated(
        address indexed token,
        uint256 reserve,
        uint256 redeemableSupply,
        uint256 burnedTokens
    );
    event RefundCountdownStarted(
        address indexed token,
        uint256 blockedAt,
        uint256 refundAvailableAt
    );
    event Redeemed(
        address indexed token,
        address indexed holder,
        uint256 tokenAmount,
        uint256 ethAmount
    );
    event FeesClaimed(
        address indexed recipient,
        uint256 amount,
        address indexed caller
    );

    constructor(address migrator_, address protocolFeeRecipient_) {
        if (
            migrator_ == address(0)
                || protocolFeeRecipient_ == address(0)
        ) revert ZeroAddress();

        migrator = IHashlingMigratorV2(migrator_);
        protocolFeeRecipient = protocolFeeRecipient_;
    }

    function launch(
        string calldata name,
        string calldata symbol,
        uint256 supply,
        string calldata artUri
    ) external nonReentrant returns (address token) {
        if (supply < MIN_SUPPLY || supply > MAX_SUPPLY) {
            revert SupplyOutOfRange();
        }

        bytes32 salt = keccak256(
            abi.encode(
                block.prevrandao,
                blockhash(block.number - 1),
                msg.sender,
                allTokens.length,
                name,
                symbol,
                supply,
                artUri
            )
        );
        token = address(
            new HashlingTokenV2{salt: salt}(
                name,
                symbol,
                supply,
                address(this)
            )
        );
        _configureCurve(token, supply, msg.sender);
        allTokens.push(token);

        emit TokenCreated(
            token,
            msg.sender,
            name,
            symbol,
            supply,
            artUri
        );
    }

    function _configureCurve(
        address token,
        uint256 supply,
        address creator
    ) private {
        uint256 curveTokens =
            Math.mulDiv(supply, CURVE_SUPPLY_BPS, BPS);
        uint256 virtualEth =
            Math.mulDiv(REF_VIRTUAL_ETH, supply, REF_SUPPLY);
        uint256 raiseTarget =
            Math.mulDiv(REF_RAISE_TARGET, supply, REF_SUPPLY);

        /// At the exact target, the ideal constant-product reserve is
        /// deterministic. Initializing the empty V3 pool now prevents the
        /// ordinary pre-graduation initialization race.
        uint256 idealFinalTokenReserve = Math.mulDiv(
            virtualEth,
            curveTokens,
            virtualEth + raiseTarget
        );
        (address pool, uint24 poolFee,) = migrator.preparePool(
            token,
            virtualEth + raiseTarget,
            idealFinalTokenReserve
        );

        _curves[token] = Curve({
            creator: creator,
            virtualEth: uint128(virtualEth),
            realEth: 0,
            tokenReserve: uint128(curveTokens),
            raiseTarget: uint128(raiseTarget),
            migrationFee: 0,
            finalEffectiveEthReserve: 0,
            finalTokenReserve: 0,
            burnedTokens: 0,
            refundSupply: 0,
            redeemedTokens: 0,
            readyAt: 0,
            blockedAt: 0,
            migrationFailureReported: false,
            state: State.Bonding,
            pool: pool,
            poolFee: poolFee,
            positionId: 0
        });
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function stateOf(address token) external view returns (State) {
        _requireKnown(token);
        return _curves[token].state;
    }

    /// Compact curve state used by trading clients and the indexer.
    function curves(address token)
        external
        view
        returns (
            address creator,
            uint128 virtualEth,
            uint128 realEth,
            uint128 tokenReserve,
            uint128 raiseTarget,
            State state
        )
    {
        Curve storage c = _curves[token];
        return (
            c.creator,
            c.virtualEth,
            c.realEth,
            c.tokenReserve,
            c.raiseTarget,
            c.state
        );
    }

    /// Graduation-only fields are separated to keep ABI encoding bounded.
    function graduation(address token)
        external
        view
        returns (
            uint128 migrationFee,
            uint128 finalEffectiveEthReserve,
            uint128 finalTokenReserve,
            uint128 burnedTokens,
            address pool,
            uint24 poolFee,
            uint256 positionId
        )
    {
        Curve storage c = _curves[token];
        return (
            c.migrationFee,
            c.finalEffectiveEthReserve,
            c.finalTokenReserve,
            c.burnedTokens,
            c.pool,
            c.poolFee,
            c.positionId
        );
    }

    function refundStatus(address token)
        external
        view
        returns (
            uint64 readyAt,
            uint128 refundSupply,
            uint128 redeemedTokens,
            uint128 reserveRemaining
        )
    {
        Curve storage c = _curves[token];
        _requireKnown(token);
        return (
            c.readyAt,
            c.refundSupply,
            c.redeemedTokens,
            c.realEth
        );
    }

    function refundBlockedAt(address token)
        external
        view
        returns (uint64)
    {
        _requireKnown(token);
        return _curves[token].blockedAt;
    }

    function quoteBuy(address token, uint256 grossOffered)
        public
        view
        returns (
            uint256 tokensOut,
            uint256 grossUsed,
            uint256 fee,
            uint256 refund
        )
    {
        Curve storage c = _curves[token];
        _requireKnown(token);
        if (c.state != State.Bonding) revert WrongState();
        if (grossOffered == 0) revert ZeroAmount();

        uint256 standardFee = (grossOffered * FEE_BPS) / BPS;
        uint256 standardNet = grossOffered - standardFee;
        uint256 remaining = uint256(c.raiseTarget) - c.realEth;
        uint256 netEth;

        if (standardNet >= remaining) {
            grossUsed = _grossForExactNet(remaining);
            if (grossUsed == remaining) {
                grossUsed += 1;
            }
            if (grossOffered < grossUsed) revert ZeroAmount();
            fee = grossUsed - remaining;
            netEth = remaining;
            refund = grossOffered - grossUsed;
        } else {
            grossUsed = grossOffered;
            fee = standardFee;
            netEth = standardNet;
        }
        if (fee == 0) revert DustTrade();

        uint256 effectiveEth = uint256(c.virtualEth) + c.realEth;
        tokensOut = uint256(c.tokenReserve)
            - Math.mulDiv(
                effectiveEth,
                c.tokenReserve,
                effectiveEth + netEth
            );
    }

    function buy(address token, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        Curve storage c = _curves[token];
        uint256 grossUsed;
        uint256 fee;
        uint256 refund;
        (tokensOut, grossUsed, fee, refund) =
            quoteBuy(token, msg.value);

        if (tokensOut == 0) revert DustTrade();
        if (tokensOut < minTokensOut) revert Slippage();

        uint256 netEth = grossUsed - fee;
        c.realEth += uint128(netEth);
        c.tokenReserve -= uint128(tokensOut);
        _accrueTradeFee(c.creator, fee);

        if (c.realEth == c.raiseTarget) {
            _freeze(token, c);
        }

        IERC20(token).safeTransfer(msg.sender, tokensOut);

        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert TransferFailed();
            emit PurchaseRefunded(token, msg.sender, refund);
        }

        emit Trade(
            token,
            msg.sender,
            true,
            grossUsed,
            tokensOut,
            c.realEth
        );
    }

    function quoteSell(address token, uint256 tokensIn)
        public
        view
        returns (uint256 ethOut, uint256 fee, uint256 gross)
    {
        Curve storage c = _curves[token];
        _requireKnown(token);
        if (c.state != State.Bonding) revert WrongState();
        if (tokensIn == 0) revert ZeroAmount();

        uint256 effectiveEth = uint256(c.virtualEth) + c.realEth;
        gross = effectiveEth
            - Math.mulDiv(
                effectiveEth,
                c.tokenReserve,
                uint256(c.tokenReserve) + tokensIn
            );
        if (gross > c.realEth) {
            /// Reversing a valid buy can round one wei above the real reserve
            /// because both reserve divisions round down. Cap only that
            /// unavoidable final wei; a larger excess is not curve-backed.
            if (gross - c.realEth > 1) revert ExceedsRealReserve();
            gross = c.realEth;
        }
        if (gross == 0) revert DustTrade();

        fee = (gross * FEE_BPS) / BPS;
        if (fee == 0) revert DustTrade();
        ethOut = gross - fee;
    }

    function sell(
        address token,
        uint256 tokensIn,
        uint256 minEthOut
    ) external nonReentrant returns (uint256 ethOut) {
        Curve storage c = _curves[token];
        uint256 fee;
        uint256 gross;
        (ethOut, fee, gross) = quoteSell(token, tokensIn);
        if (ethOut < minEthOut) revert Slippage();

        c.realEth -= uint128(gross);
        c.tokenReserve += uint128(tokensIn);
        _accrueTradeFee(c.creator, fee);

        IERC20(token).safeTransferFrom(
            msg.sender,
            address(this),
            tokensIn
        );
        _payEth(msg.sender, ethOut);

        emit Trade(
            token,
            msg.sender,
            false,
            ethOut,
            tokensIn,
            c.realEth
        );
    }

    /// Permissionless and retryable. A failed real migration attempt leaves
    /// the project frozen and starts the delayed liveness fail-safe.
    function graduate(address token)
        external
        nonReentrant
        returns (bool graduated)
    {
        Curve storage c = _curves[token];
        _requireKnown(token);
        if (c.state != State.GraduationReady) revert WrongState();

        bytes32 reasonHash;
        (graduated, reasonHash) = _tryGraduate(token, c);
        if (!graduated) {
            _recordMigrationFailure(token, c, reasonHash);
        }
    }

    /// A caller may fund a bounded correction of the pinned pool. Correction
    /// and migration share one transaction, so either both complete or neither
    /// changes state.
    function correctAndGraduate(address token, uint256 maxInput)
        external
        payable
        nonReentrant
    {
        Curve storage c = _curves[token];
        _requireKnown(token);
        if (c.state != State.GraduationReady) revert WrongState();

        bool available = migrator.poolWithinTolerance(
            token,
            c.finalEffectiveEthReserve,
            c.finalTokenReserve
        );
        if (available) {
            if (msg.value != 0) revert ZeroAmount();
        } else {
            migrator.correctPool{value: msg.value}(
                token,
                msg.sender,
                c.finalEffectiveEthReserve,
                c.finalTokenReserve,
                maxInput
            );
        }

        _graduate(token, c);
    }

    function _graduate(address token, Curve storage c) private {
        GraduationResult memory r;
        r.migrationEth =
            uint256(c.realEth) - c.migrationFee;
        uint256 tokenAmountDesired =
            IERC20(token).balanceOf(address(this));

        IERC20(token).forceApprove(
            address(migrator),
            tokenAmountDesired
        );

        (
            r.pool,
            r.poolFee,
            r.positionId,
            r.ethUsed,
            r.tokenUsed
        ) = migrator.migrate{value: r.migrationEth}(
            token,
            c.creator,
            c.finalEffectiveEthReserve,
            c.finalTokenReserve,
            tokenAmountDesired
        );

        IERC20(token).forceApprove(address(migrator), 0);
        _finishGraduation(token, c, r);
    }

    function _tryGraduate(address token, Curve storage c)
        private
        returns (bool graduated, bytes32 reasonHash)
    {
        GraduationResult memory r;
        r.migrationEth = uint256(c.realEth) - c.migrationFee;
        uint256 tokenAmountDesired =
            IERC20(token).balanceOf(address(this));

        IERC20(token).forceApprove(
            address(migrator),
            tokenAmountDesired
        );

        try migrator.migrate{value: r.migrationEth}(
            token,
            c.creator,
            c.finalEffectiveEthReserve,
            c.finalTokenReserve,
            tokenAmountDesired
        ) returns (
            address pool,
            uint24 poolFee,
            uint256 positionId,
            uint256 ethUsed,
            uint256 tokenUsed
        ) {
            r.pool = pool;
            r.poolFee = poolFee;
            r.positionId = positionId;
            r.ethUsed = ethUsed;
            r.tokenUsed = tokenUsed;
            IERC20(token).forceApprove(address(migrator), 0);
            _finishGraduation(token, c, r);
            graduated = true;
        } catch (bytes memory reason) {
            IERC20(token).forceApprove(address(migrator), 0);
            reasonHash = keccak256(reason);
        }
    }

    function _finishGraduation(
        address token,
        Curve storage c,
        GraduationResult memory r
    ) private {

        uint256 ethDust = r.migrationEth - r.ethUsed;
        protocolFees += uint256(c.migrationFee) + ethDust;

        uint256 tokenDust = IERC20(token).balanceOf(address(this));
        if (tokenDust != 0) {
            HashlingTokenV2(token).burnFactoryBalance(tokenDust);
        }

        c.realEth = 0;
        c.tokenReserve = 0;
        c.burnedTokens = uint128(tokenDust);
        c.pool = r.pool;
        c.poolFee = r.poolFee;
        c.positionId = r.positionId;
        c.state = State.Graduated;

        emit Graduated(
            token,
            r.pool,
            r.positionId,
            r.poolFee,
            r.ethUsed,
            r.tokenUsed,
            tokenDust
        );
    }

    function _recordMigrationFailure(
        address token,
        Curve storage c,
        bytes32 reasonHash
    ) private {
        c.migrationFailureReported = true;
        if (c.blockedAt == 0) {
            c.blockedAt = uint64(block.timestamp);
            emit RefundCountdownStarted(
                token,
                block.timestamp,
                block.timestamp + REFUND_DELAY
            );
        }
        emit GraduationAttemptFailed(
            token,
            reasonHash,
            uint256(c.blockedAt) + REFUND_DELAY
        );
    }

    function startRefundCountdown(address token) external nonReentrant {
        Curve storage c = _curves[token];
        _requireKnown(token);
        if (c.state != State.GraduationReady) revert WrongState();
        if (c.blockedAt != 0) revert RefundCountdownAlreadyStarted();
        if (_migrationAvailable(token, c)) revert MigrationAvailable();

        c.blockedAt = uint64(block.timestamp);
        emit RefundCountdownStarted(
            token,
            block.timestamp,
            block.timestamp + REFUND_DELAY
        );
    }

    /// After seven days from a reported migration blockage, anyone may switch
    /// the frozen project to proportional reserve redemption. This is terminal.
    function activateRefund(address token) external nonReentrant {
        Curve storage c = _curves[token];
        _requireKnown(token);
        if (c.state != State.GraduationReady) revert WrongState();
        if (c.blockedAt == 0) revert RefundCountdownNotStarted();
        if (block.timestamp < uint256(c.blockedAt) + REFUND_DELAY) {
            revert RefundDelayActive();
        }
        bool available = _migrationAvailable(token, c);
        if (available) {
            (bool graduated, bytes32 reasonHash) =
                _tryGraduate(token, c);
            if (graduated) return;
            _recordMigrationFailure(token, c, reasonHash);
        }

        uint256 factoryBalance = IERC20(token).balanceOf(address(this));
        uint256 redeemableSupply =
            IERC20(token).totalSupply() - factoryBalance;
        if (redeemableSupply == 0) revert ZeroAmount();

        if (factoryBalance != 0) {
            HashlingTokenV2(token).burnFactoryBalance(factoryBalance);
        }

        c.tokenReserve = 0;
        c.burnedTokens = uint128(factoryBalance);
        c.refundSupply = uint128(redeemableSupply);
        c.state = State.Refunding;

        emit RefundingActivated(
            token,
            c.realEth,
            redeemableSupply,
            factoryBalance
        );
    }

    /// Claims never expire. There is deliberately no sweep or recovery path.
    function redeem(address token, uint256 tokenAmount)
        external
        nonReentrant
        returns (uint256 ethAmount)
    {
        Curve storage c = _curves[token];
        _requireKnown(token);
        if (c.state != State.Refunding) revert WrongState();
        if (tokenAmount == 0) revert ZeroAmount();

        uint256 redeemedAfter = uint256(c.redeemedTokens) + tokenAmount;
        if (redeemedAfter > c.refundSupply) revert Slippage();

        ethAmount = Math.mulDiv(
            c.raiseTarget,
            tokenAmount,
            c.refundSupply
        );
        if (ethAmount == 0) revert DustTrade();

        c.redeemedTokens = uint128(redeemedAfter);
        c.realEth -= uint128(ethAmount);

        IERC20(token).safeTransferFrom(
            msg.sender,
            address(this),
            tokenAmount
        );
        HashlingTokenV2(token).burnFactoryBalance(tokenAmount);
        _payEth(msg.sender, ethAmount);

        emit Redeemed(token, msg.sender, tokenAmount, ethAmount);
    }

    function claimCreatorFees(address creator)
        public
        nonReentrant
        returns (uint256 amount)
    {
        amount = creatorFees[creator];
        if (amount == 0) revert NothingToClaim();

        creatorFees[creator] = 0;
        _payEth(creator, amount);
        emit FeesClaimed(creator, amount, msg.sender);
    }

    function claimCreatorFees() external returns (uint256 amount) {
        amount = claimCreatorFees(msg.sender);
    }

    /// Permissionless trigger; payment is always sent to the immutable
    /// protocol recipient and can never be redirected by the caller.
    function claimProtocolFees()
        external
        nonReentrant
        returns (uint256 amount)
    {
        amount = protocolFees;
        if (amount == 0) revert NothingToClaim();

        protocolFees = 0;
        _payEth(protocolFeeRecipient, amount);
        emit FeesClaimed(
            protocolFeeRecipient,
            amount,
            msg.sender
        );
    }

    function _freeze(address token, Curve storage c) private {
        c.state = State.GraduationReady;
        c.readyAt = uint64(block.timestamp);
        c.finalEffectiveEthReserve =
            c.virtualEth + c.realEth;
        c.finalTokenReserve = c.tokenReserve;

        uint256 scaledFlatFee = Math.mulDiv(
            MIGRATION_FLAT_AT_REFERENCE,
            HashlingTokenV2(token).initialSupply(),
            REF_SUPPLY
        );
        uint256 migrationFee = scaledFlatFee
            + Math.mulDiv(
                c.realEth,
                MIGRATION_RAISE_BPS,
                BPS
        );
        c.migrationFee = uint128(migrationFee);

        emit GraduationReady(
            token,
            c.finalEffectiveEthReserve,
            c.finalTokenReserve,
            migrationFee
        );
    }

    function _grossForExactNet(uint256 net)
        private
        pure
        returns (uint256 gross)
    {
        gross = Math.ceilDiv(net * BPS, BPS - FEE_BPS);

        /// Fee rounding can make the preceding wei sufficient.
        if (
            gross > net
                && (gross - 1)
                    - (((gross - 1) * FEE_BPS) / BPS)
                    >= net
        ) {
            gross -= 1;
        }
    }

    function _migrationAvailable(address token, Curve storage c)
        private
        view
        returns (bool available)
    {
        try migrator.poolWithinTolerance(
            token,
            c.finalEffectiveEthReserve,
            c.finalTokenReserve
        ) returns (bool result) {
            available = result;
        } catch {
            available = false;
        }
    }

    function _accrueTradeFee(address creator, uint256 fee) private {
        uint256 creatorShare =
            Math.mulDiv(fee, CREATOR_FEE_SHARE_BPS, BPS);
        creatorFees[creator] += creatorShare;
        protocolFees += fee - creatorShare;
    }

    function _requireKnown(address token) private view {
        if (_curves[token].creator == address(0)) revert UnknownToken();
    }

    function _payEth(address recipient, uint256 amount) private {
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {
        if (msg.sender != address(migrator)) revert TransferFailed();
    }
}
