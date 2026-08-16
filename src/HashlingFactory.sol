// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {HashlingToken} from "./HashlingToken.sol";

/// Hashling launch factory: constant-product bonding curves with virtual ETH
/// reserves, matching the incumbent's mechanics so a creator comparing venues
/// has exactly one number to read (migration cost).
///
/// Spec (whitepaper fee table):
///   - launch: gas only
///   - trade fee: 1% flat, split 80% creator / 20% protocol
///   - curve allocation: 80% of supply; 20% reserved for the Uniswap pool
///   - virtual ETH seed: 2.81 ETH at 1B supply, scales linearly with supply
///   - graduation raise target: ~6.5 ETH at 1B supply, scales linearly
///   - migration: 0.25 ETH flat + 3% of raise, taken at graduation
///
/// Deliberately NO Ownable. The protocol fee recipient is fixed at
/// construction and can only be changed by that recipient itself.
/// Uniswap migration is performed by anyone calling graduate(); the pool
/// step is isolated behind an immutable migrator so this contract holds no
/// upgrade or admin surface.
contract HashlingFactory is ReentrancyGuard {
    // ---------------------------------------------------------------- config

    uint256 public constant FEE_BPS = 100; // 1% trade fee
    uint256 public constant CREATOR_FEE_SHARE_BPS = 8000; // 80% of the fee
    uint256 public constant CURVE_SUPPLY_BPS = 8000; // 80% of supply on curve
    uint256 public constant MIGRATION_FLAT_WEI = 0.25 ether;
    uint256 public constant MIGRATION_RAISE_BPS = 300; // 3% of raise

    /// Virtual seed / raise target at the reference 1B (1e9 * 1e18) supply.
    uint256 public constant REF_SUPPLY = 1e9 ether;
    uint256 public constant REF_VIRTUAL_ETH = 2.81 ether;
    uint256 public constant REF_RAISE_TARGET = 6.5 ether;

    address public protocolFeeRecipient;

    // ----------------------------------------------------------------- state

    struct Curve {
        address creator;
        uint128 virtualEth; // virtual ETH reserve (constant for the curve)
        uint128 realEth; // real ETH held by the curve (the raise so far)
        uint128 tokenReserve; // tokens remaining on the curve
        uint128 raiseTarget; // real ETH at which the curve may graduate
        bool graduated;
    }

    mapping(address => Curve) public curves;
    mapping(address => uint256) public creatorFees; // accrued, pull-based
    uint256 public protocolFees; // accrued, pull-based
    address[] public allTokens;

    // ---------------------------------------------------------------- events

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
    event Graduated(address indexed token, uint256 raise, uint256 migrationFee);
    event FeesClaimed(address indexed claimant, uint256 amount);

    constructor(address protocolFeeRecipient_) {
        require(protocolFeeRecipient_ != address(0), "zero recipient");
        protocolFeeRecipient = protocolFeeRecipient_;
    }

    /// Only the current recipient may hand the role on. Not an owner: the
    /// role controls nothing but where the protocol's own fees go.
    function setProtocolFeeRecipient(address next) external {
        require(msg.sender == protocolFeeRecipient, "not recipient");
        require(next != address(0), "zero recipient");
        protocolFeeRecipient = next;
    }

    // ---------------------------------------------------------------- launch

    function launch(
        string calldata name,
        string calldata symbol,
        uint256 supply,
        string calldata artUri
    ) external returns (address token) {
        require(supply >= 1e6 ether && supply <= 1e12 ether, "supply range");

        uint256 curveTokens = (supply * CURVE_SUPPLY_BPS) / 10_000;
        uint256 vEth = (REF_VIRTUAL_ETH * supply) / REF_SUPPLY;
        uint256 target = (REF_RAISE_TARGET * supply) / REF_SUPPLY;
        require(vEth > 0 && target > 0, "supply too small");

        token = address(new HashlingToken(name, symbol, supply, address(this)));
        curves[token] = Curve({
            creator: msg.sender,
            virtualEth: uint128(vEth),
            realEth: 0,
            tokenReserve: uint128(curveTokens),
            raiseTarget: uint128(target),
            graduated: false
        });
        allTokens.push(token);
        emit TokenCreated(token, msg.sender, name, symbol, supply, artUri);
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    // ----------------------------------------------------------------- trade

    /// Buy tokens with ETH along x*y=k, where x = virtualEth + realEth.
    /// The 1% fee is taken from the ETH in, before it hits the reserve.
    function buy(address token, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        Curve storage c = curves[token];
        require(c.creator != address(0), "unknown token");
        require(!c.graduated, "graduated");
        require(msg.value > 0, "zero eth");

        uint256 fee = (msg.value * FEE_BPS) / 10_000;
        uint256 ethIn = msg.value - fee;
        _accrueFee(c.creator, fee);

        uint256 x = uint256(c.virtualEth) + c.realEth;
        uint256 y = c.tokenReserve;
        // tokensOut = y - k/(x + ethIn); rounds down, in the curve's favor.
        tokensOut = y - (x * y) / (x + ethIn);
        require(tokensOut >= minTokensOut, "slippage");
        require(tokensOut > 0, "dust buy");

        c.realEth += uint128(ethIn);
        c.tokenReserve -= uint128(tokensOut);
        HashlingToken(token).transfer(msg.sender, tokensOut);
        emit Trade(token, msg.sender, true, msg.value, tokensOut, c.realEth);
    }

    /// Sell tokens back to the curve. The 1% fee is taken from the ETH out.
    function sell(address token, uint256 tokensIn, uint256 minEthOut)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        Curve storage c = curves[token];
        require(c.creator != address(0), "unknown token");
        require(!c.graduated, "graduated");
        require(tokensIn > 0, "zero tokens");

        uint256 x = uint256(c.virtualEth) + c.realEth;
        uint256 y = c.tokenReserve;
        // ethOut = x - k/(y + tokensIn); rounds down, in the curve's favor.
        uint256 gross = x - (x * y) / (y + tokensIn);
        // The virtual seed is not withdrawable: a sell can only pay out of
        // the real reserve. Cap defensively; the invariant suite proves the
        // cap is never the binding constraint under honest arithmetic.
        require(gross <= c.realEth, "exceeds real reserve");

        uint256 fee = (gross * FEE_BPS) / 10_000;
        ethOut = gross - fee;
        require(ethOut >= minEthOut, "slippage");

        c.realEth -= uint128(gross);
        c.tokenReserve += uint128(tokensIn);
        _accrueFee(c.creator, fee);

        HashlingToken(token).transferFrom(msg.sender, address(this), tokensIn);
        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "eth send failed");
        emit Trade(token, msg.sender, false, ethOut, tokensIn, c.realEth);
    }

    // ------------------------------------------------------------ graduation

    /// Anyone may graduate a curve that has met its raise target. The
    /// migration fee (0.25 ETH flat + 3% of raise) accrues to the protocol;
    /// the remaining ETH and the reserved 20% supply are handed to the
    /// migrator for the Uniswap v3 pool + locked position (next pass — until
    /// the migrator lands, graduation is blocked rather than custodial).
    function graduate(address token) external nonReentrant {
        Curve storage c = curves[token];
        require(c.creator != address(0), "unknown token");
        require(!c.graduated, "graduated");
        require(c.realEth >= c.raiseTarget, "target not met");

        uint256 raise = c.realEth;
        uint256 migrationFee = MIGRATION_FLAT_WEI + (raise * MIGRATION_RAISE_BPS) / 10_000;
        require(raise > migrationFee, "fee exceeds raise");

        c.graduated = true;
        c.realEth = 0;
        protocolFees += migrationFee;

        // TODO(next pass): mint the Uniswap v3 position with
        // (raise - migrationFee) ETH + the reserved supply, locked forever.
        // Blocked until then so no path exists where the factory keeps funds.
        revert("migrator not yet implemented");

        // emit Graduated(token, raise, migrationFee);
    }

    // ------------------------------------------------------------------ fees

    function _accrueFee(address creator, uint256 fee) internal {
        uint256 toCreator = (fee * CREATOR_FEE_SHARE_BPS) / 10_000;
        creatorFees[creator] += toCreator;
        protocolFees += fee - toCreator;
    }

    function claimCreatorFees() external nonReentrant {
        uint256 amount = creatorFees[msg.sender];
        require(amount > 0, "nothing accrued");
        creatorFees[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth send failed");
        emit FeesClaimed(msg.sender, amount);
    }

    function claimProtocolFees() external nonReentrant {
        require(msg.sender == protocolFeeRecipient, "not recipient");
        uint256 amount = protocolFees;
        require(amount > 0, "nothing accrued");
        protocolFees = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth send failed");
        emit FeesClaimed(msg.sender, amount);
    }
}
