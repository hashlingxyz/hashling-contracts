// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HashlingFactory} from "../src/HashlingFactory.sol";
import {HashlingToken} from "../src/HashlingToken.sol";

/// Random buys, sells and fee claims against one live curve. The invariants
/// below must hold after every sequence the fuzzer can construct — the rung-1
/// bar is that the fuzzer loses.
contract CurveHandler is Test {
    HashlingFactory public factory;
    address public token;
    address[] public actors;

    uint256 public ethDeposited; // gross ETH sent into buys
    uint256 public ethWithdrawn; // ETH paid out by sells + fee claims

    constructor(HashlingFactory factory_, address token_) {
        factory = factory_;
        token = token_;
        for (uint256 i = 0; i < 5; i++) {
            address a = address(uint160(0xA11CE + i));
            actors.push(a);
            vm.deal(a, 100 ether);
        }
    }

    function buy(uint256 actorSeed, uint256 ethAmount) external {
        address actor = actors[actorSeed % actors.length];
        ethAmount = bound(ethAmount, 0.0001 ether, 5 ether);
        if (actor.balance < ethAmount) return;
        vm.prank(actor);
        try factory.buy{value: ethAmount}(token, 0) {
            ethDeposited += ethAmount;
        } catch {}
    }

    function sell(uint256 actorSeed, uint256 tokenPct) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = HashlingToken(token).balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = (balance * bound(tokenPct, 1, 10_000)) / 10_000;
        if (amount == 0) return;
        uint256 before = actor.balance;
        vm.startPrank(actor);
        HashlingToken(token).approve(address(factory), amount);
        try factory.sell(token, amount, 0) {
            ethWithdrawn += actor.balance - before;
        } catch {}
        vm.stopPrank();
    }

    function claimCreator(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 before = actor.balance;
        vm.prank(actor);
        try factory.claimCreatorFees() {
            ethWithdrawn += actor.balance - before;
        } catch {}
    }
}

contract CurveInvariants is Test {
    HashlingFactory factory;
    address token;
    CurveHandler handler;

    uint256 constant SUPPLY = 1e9 ether;

    function setUp() public {
        factory = new HashlingFactory(address(0xFEE));
        // Creator is one of the handler's actors so creator-fee claims are
        // exercised by the same fuzz sequences as trades.
        vm.prank(address(uint160(0xA11CE)));
        token = factory.launch("Fuzz", "FUZZ", SUPPLY, "");
        handler = new CurveHandler(factory, token);
        targetContract(address(handler));
    }

    /// The factory can always pay everyone: real reserves + accrued fees
    /// never exceed the ETH it actually holds.
    function invariant_solvent() public view {
        (, , uint128 realEth, , , ) = factory.curves(token);
        uint256 owed = uint256(realEth) + factory.protocolFees();
        for (uint256 i = 0; i < 5; i++) {
            owed += factory.creatorFees(address(uint160(0xA11CE + i)));
        }
        assertGe(address(factory).balance, owed, "insolvent");
    }

    /// Tokens are conserved: curve reserve + reserved pool allocation +
    /// everything traders hold always equals total supply.
    function invariant_tokenConservation() public view {
        (, , , uint128 tokenReserve, , ) = factory.curves(token);
        uint256 reservedForPool = SUPPLY - (SUPPLY * factory.CURVE_SUPPLY_BPS()) / 10_000;
        assertEq(
            HashlingToken(token).balanceOf(address(factory)),
            uint256(tokenReserve) + reservedForPool,
            "token leak"
        );
    }

    /// The curve never pays out more ETH than was put in: the virtual seed
    /// is unextractable no matter the trade sequence.
    function invariant_noEthCreation() public view {
        assertGe(handler.ethDeposited(), handler.ethWithdrawn(), "eth minted");
    }

    /// Real reserve never exceeds what buys deposited net of fees.
    function invariant_realReserveBounded() public view {
        (, , uint128 realEth, , , ) = factory.curves(token);
        assertLe(uint256(realEth), handler.ethDeposited(), "reserve inflated");
    }
}
