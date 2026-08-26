// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from
    "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HashlingFactoryV2} from "../src/HashlingFactoryV2.sol";
import {HashlingTokenV2} from "../src/HashlingTokenV2.sol";
import {
    IHashlingMigratorV2
} from "../src/interfaces/IHashlingV3.sol";

contract InvariantMigratorV2 is IHashlingMigratorV2 {
    address internal constant POOL = address(0xBEEF);
    uint256 internal nextPositionId = 1;

    function factory() external pure returns (address) {
        return address(0);
    }

    function poolWithinTolerance(address, uint256, uint256)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function preparePool(address, uint256, uint256)
        external
        pure
        returns (address, uint24, uint160)
    {
        return (POOL, 10_000, 1);
    }

    function migrate(
        address token,
        address,
        uint256,
        uint256,
        uint256 tokenAmountDesired
    )
        external
        payable
        returns (address, uint24, uint256, uint256, uint256)
    {
        require(
            IERC20(token).transferFrom(
                msg.sender,
                address(this),
                tokenAmountDesired
            )
        );

        uint256 tokenUsed = tokenAmountDesired / 2;
        require(
            IERC20(token).transfer(
                msg.sender,
                tokenAmountDesired - tokenUsed
            )
        );

        return (
            POOL,
            10_000,
            nextPositionId++,
            msg.value,
            tokenUsed
        );
    }

    function correctPool(
        address,
        address,
        uint256,
        uint256,
        uint256
    ) external payable returns (uint256, uint256) {
        return (0, 0);
    }
}

contract FactoryV2Handler is Test {
    HashlingFactoryV2 public immutable factory;
    address public immutable token;
    address public immutable creator;
    address public immutable protocol;
    address[] public actors;

    uint256 public ethDeposited;
    uint256 public ethWithdrawn;
    uint256 public successfulGraduations;
    uint256 public successfulTradesAfterReady;
    uint256 public stateRegressions;
    uint256 public highestState;
    bool public readyObserved;
    uint256 public readyRealEth;
    uint256 public readyTokenReserve;

    constructor(
        HashlingFactoryV2 factory_,
        address token_,
        address creator_,
        address protocol_
    ) {
        factory = factory_;
        token = token_;
        creator = creator_;
        protocol = protocol_;

        for (uint256 i; i < 5; ++i) {
            address actor =
                address(uint160(uint256(0xA11CE) + i));
            actors.push(actor);
            vm.deal(actor, 100 ether);
        }
    }

    function buy(uint256 actorSeed, uint256 ethAmount) external {
        address actor = actors[actorSeed % actors.length];
        ethAmount = bound(ethAmount, 1 gwei, 2 ether);
        if (actor.balance < ethAmount) return;

        HashlingFactoryV2.State beforeState =
            factory.stateOf(token);
        uint256 beforeBalance = actor.balance;
        vm.prank(actor);
        try factory.buy{value: ethAmount}(token, 0) {
            ethDeposited += beforeBalance - actor.balance;
            if (beforeState != HashlingFactoryV2.State.Bonding) {
                successfulTradesAfterReady++;
            }
        } catch {}
        _observeState();
    }

    function sell(uint256 actorSeed, uint256 tokenPct) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = IERC20(token).balanceOf(actor);
        if (balance == 0) return;

        uint256 amount = (
            balance * bound(tokenPct, 1, 10_000)
        ) / 10_000;
        if (amount == 0) return;

        HashlingFactoryV2.State beforeState =
            factory.stateOf(token);
        uint256 beforeBalance = actor.balance;
        vm.startPrank(actor);
        IERC20(token).approve(address(factory), amount);
        try factory.sell(token, amount, 0) {
            ethWithdrawn += actor.balance - beforeBalance;
            if (beforeState != HashlingFactoryV2.State.Bonding) {
                successfulTradesAfterReady++;
            }
        } catch {}
        vm.stopPrank();
        _observeState();
    }

    function graduate() external {
        try factory.graduate(token) returns (bool graduated) {
            if (graduated) successfulGraduations++;
        } catch {}
        _observeState();
    }

    function claimCreator() external {
        uint256 beforeBalance = creator.balance;
        try factory.claimCreatorFees(creator) {
            ethWithdrawn += creator.balance - beforeBalance;
        } catch {}
        _observeState();
    }

    function claimProtocol() external {
        uint256 beforeBalance = protocol.balance;
        try factory.claimProtocolFees() {
            ethWithdrawn += protocol.balance - beforeBalance;
        } catch {}
        _observeState();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _observeState() private {
        uint256 current = uint256(factory.stateOf(token));
        if (current < highestState) stateRegressions++;
        if (current > highestState) highestState = current;

        if (
            current
                == uint256(
                    HashlingFactoryV2.State.GraduationReady
                ) && !readyObserved
        ) {
            (,, uint128 realEth, uint128 reserve,,) =
                factory.curves(token);
            readyObserved = true;
            readyRealEth = realEth;
            readyTokenReserve = reserve;
        }
    }
}

contract FactoryV2Invariants is Test {
    uint256 internal constant SUPPLY = 1e9 ether;
    address internal constant CREATOR = address(0xA11CE);
    address internal constant PROTOCOL = address(0xFEE);

    InvariantMigratorV2 internal migrator;
    HashlingFactoryV2 internal factory;
    FactoryV2Handler internal handler;
    address internal token;

    function setUp() public {
        migrator = new InvariantMigratorV2();
        factory = new HashlingFactoryV2(
            address(migrator),
            PROTOCOL
        );
        vm.prank(CREATOR);
        token = factory.launch(
            "V2 Invariant",
            "V2I",
            SUPPLY,
            ""
        );
        handler = new FactoryV2Handler(
            factory,
            token,
            CREATOR,
            PROTOCOL
        );

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.graduate.selector;
        selectors[3] = handler.claimCreator.selector;
        selectors[4] = handler.claimProtocol.selector;
        targetContract(address(handler));
        targetSelector(
            FuzzSelector({
                addr: address(handler),
                selectors: selectors
            })
        );
    }

    function invariantFactoryIsExactlySolvent() public view {
        (
            ,
            ,
            uint128 realEth,
            ,
            ,

        ) = factory.curves(token);

        uint256 reserveOwed = realEth;

        uint256 totalOwed = reserveOwed
            + factory.creatorFees(CREATOR)
            + factory.protocolFees();
        assertEq(address(factory).balance, totalOwed);
    }

    function invariantTokenSupplyIsConserved() public view {
        HashlingTokenV2 launched = HashlingTokenV2(token);
        uint256 accounted =
            launched.balanceOf(address(factory))
                + launched.balanceOf(address(migrator));

        uint256 count = handler.actorCount();
        for (uint256 i; i < count; ++i) {
            accounted += launched.balanceOf(handler.actors(i));
        }

        assertEq(launched.totalSupply(), accounted);
        (,,, uint128 burnedTokens,,,) =
            factory.graduation(token);
        assertEq(
            launched.initialSupply(),
            launched.totalSupply() + burnedTokens
        );
    }

    function invariantVirtualEthCannotBeExtracted() public view {
        assertGe(
            handler.ethDeposited(),
            handler.ethWithdrawn()
        );
    }

    function invariantStateNeverRegresses() public view {
        assertEq(handler.stateRegressions(), 0);
        assertLe(handler.successfulGraduations(), 1);
        assertEq(handler.successfulTradesAfterReady(), 0);
    }

    function invariantReadyStateIsFrozen() public view {
        HashlingFactoryV2.State state = factory.stateOf(token);
        if (
            state != HashlingFactoryV2.State.GraduationReady
        ) return;

        (,, uint128 realEth, uint128 reserve, uint128 target,) =
            factory.curves(token);
        assertTrue(handler.readyObserved());
        assertEq(realEth, target);
        assertEq(realEth, handler.readyRealEth());
        assertEq(reserve, handler.readyTokenReserve());
        assertEq(handler.successfulGraduations(), 0);
    }

    function invariantGraduatedFactoryRetainsNoLiquidity()
        public
        view
    {
        if (
            factory.stateOf(token)
                != HashlingFactoryV2.State.Graduated
        ) return;

        (,, uint128 realEth, uint128 reserve,,) =
            factory.curves(token);
        assertEq(realEth, 0);
        assertEq(reserve, 0);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertEq(handler.successfulGraduations(), 1);
    }

    function invariantMigrationFeeRemainsFrozen() public view {
        HashlingFactoryV2.State state = factory.stateOf(token);
        if (state == HashlingFactoryV2.State.Bonding) return;

        (uint128 migrationFee,,,,,,) =
            factory.graduation(token);
        uint256 expected =
            factory.MIGRATION_FLAT_AT_REFERENCE()
                + (
                    factory.REF_RAISE_TARGET()
                        * factory.MIGRATION_RAISE_BPS()
                ) / factory.BPS();
        assertEq(migrationFee, expected);
    }
}
