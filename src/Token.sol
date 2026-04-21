// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract NLX is ERC20, Ownable {
    constructor(
        address initialOwner,
        string memory _name,
        string memory _symbol,
        uint8 _decimal,
        uint256 _totalSupply
    ) ERC20(_name, _symbol) Ownable(initialOwner) {
        _mint(initialOwner, _totalSupply * (10**_decimal));
    }
}
