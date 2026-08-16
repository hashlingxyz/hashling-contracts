// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// Fixed-supply ERC20 minted in full to the launch factory at creation.
/// Deliberately has no owner, no mint, no pause, no admin of any kind:
/// once deployed, nobody — including Hashling — holds any power over it.
contract HashlingToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        address curve_
    ) ERC20(name_, symbol_) {
        _mint(curve_, supply_);
    }
}
