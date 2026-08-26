// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// Fixed-supply V2 token. The complete supply is minted once to Factory V2.
/// The factory may only burn tokens still held by the factory itself.
contract HashlingTokenV2 is ERC20 {
    address public immutable factory;
    uint256 public immutable initialSupply;

    error NotFactory();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        address factory_
    ) ERC20(name_, symbol_) {
        factory = factory_;
        initialSupply = supply_;
        _mint(factory_, supply_);
    }

    function burnFactoryBalance(uint256 amount) external {
        if (msg.sender != factory) revert NotFactory();
        _burn(factory, amount);
    }
}
