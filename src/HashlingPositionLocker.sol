// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from
    "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from
    "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {
    INonfungiblePositionManagerV2
} from "./interfaces/IHashlingV3.sol";

/// Holds every registered V3 position permanently. There is deliberately no
/// transfer, decrease-liquidity, rescue, owner, pause, or upgrade function.
contract HashlingPositionLocker is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant CREATOR_SHARE_BPS = 8_000;
    uint256 private constant BPS = 10_000;

    INonfungiblePositionManagerV2 public immutable positionManager;
    address public immutable protocolFeeRecipient;
    address public immutable migrator;

    struct PositionInfo {
        address creator;
        address token0;
        address token1;
        bool registered;
    }

    mapping(uint256 => PositionInfo) public positionInfo;
    mapping(address => mapping(address => uint256)) public claimable;

    error ZeroAddress();
    error WrongNftContract();
    error PositionNotHeld();
    error PositionAlreadyRegistered();
    error PositionNotRegistered();
    error InvalidPositionData();
    error NothingToClaim();
    error NotMigrator();
    error InvalidMint();

    event LiquidityLocked(
        uint256 indexed tokenId,
        address indexed creator,
        address token0,
        address token1
    );
    event FeesCollected(
        uint256 indexed tokenId,
        address indexed asset,
        uint256 amount,
        uint256 creatorShare,
        uint256 protocolShare
    );
    event FeesClaimed(
        address indexed recipient,
        address indexed asset,
        uint256 amount,
        address indexed caller
    );

    constructor(
        address positionManager_,
        address protocolFeeRecipient_,
        address migrator_
    ) {
        if (
            positionManager_ == address(0)
                || protocolFeeRecipient_ == address(0)
                || migrator_ == address(0)
        ) revert ZeroAddress();

        positionManager =
            INonfungiblePositionManagerV2(positionManager_);
        protocolFeeRecipient = protocolFeeRecipient_;
        migrator = migrator_;
    }

    /// The position manager mints directly to this contract. Registration is
    /// performed in the same migration transaction, so nobody can interleave
    /// a conflicting registration.
    function registerPosition(uint256 tokenId, address creator) external {
        if (msg.sender != migrator) revert NotMigrator();
        if (creator == address(0)) revert ZeroAddress();
        if (positionInfo[tokenId].registered) {
            revert PositionAlreadyRegistered();
        }
        if (positionManager.ownerOf(tokenId) != address(this)) {
            revert PositionNotHeld();
        }

        (address token0, address token1) =
            _positionTokens(tokenId);

        positionInfo[tokenId] = PositionInfo({
            creator: creator,
            token0: token0,
            token1: token1,
            registered: true
        });

        emit LiquidityLocked(tokenId, creator, token0, token1);
    }

    /// The canonical positions() response contains 12 fixed-size ABI words.
    /// Reading only words three and four avoids generating a 12-value Solidity
    /// decoder while keeping the target and selector permanently fixed.
    function _positionTokens(uint256 tokenId)
        private
        view
        returns (address token0, address token1)
    {
        (bool ok, bytes memory data) =
            address(positionManager).staticcall(
                abi.encodeWithSelector(
                    INonfungiblePositionManagerV2.positions.selector,
                    tokenId
                )
            );
        if (!ok || data.length < 12 * 32) {
            revert InvalidPositionData();
        }

        assembly ("memory-safe") {
            token0 := mload(add(data, 0x60))
            token1 := mload(add(data, 0x80))
        }

        if (token0 == address(0) || token1 == address(0)) {
            revert InvalidPositionData();
        }
    }

    function collectFees(uint256 tokenId)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        PositionInfo memory info = positionInfo[tokenId];
        if (!info.registered) revert PositionNotRegistered();

        uint256 before0 = IERC20(info.token0).balanceOf(address(this));
        uint256 before1 = IERC20(info.token1).balanceOf(address(this));

        positionManager.collect(
            INonfungiblePositionManagerV2.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        amount0 =
            IERC20(info.token0).balanceOf(address(this)) - before0;
        amount1 =
            IERC20(info.token1).balanceOf(address(this)) - before1;

        _credit(tokenId, info.creator, info.token0, amount0);
        _credit(tokenId, info.creator, info.token1, amount1);
    }

    /// Anyone may trigger a claim, but the funds always go to the recorded
    /// recipient. The caller cannot redirect them.
    function claim(address recipient, address asset)
        external
        nonReentrant
        returns (uint256 amount)
    {
        amount = claimable[recipient][asset];
        if (amount == 0) revert NothingToClaim();

        claimable[recipient][asset] = 0;
        IERC20(asset).safeTransfer(recipient, amount);

        emit FeesClaimed(recipient, asset, amount, msg.sender);
    }

    function _credit(
        uint256 tokenId,
        address creator,
        address asset,
        uint256 amount
    ) private {
        if (amount == 0) return;

        uint256 creatorShare =
            (amount * CREATOR_SHARE_BPS) / BPS;
        uint256 protocolShare = amount - creatorShare;

        claimable[creator][asset] += creatorShare;
        claimable[protocolFeeRecipient][asset] += protocolShare;

        emit FeesCollected(
            tokenId,
            asset,
            amount,
            creatorShare,
            protocolShare
        );
    }

    function onERC721Received(
        address operator,
        address from,
        uint256,
        bytes calldata
    ) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) {
            revert WrongNftContract();
        }
        if (operator != migrator || from != address(0)) {
            revert InvalidMint();
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}
