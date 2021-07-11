//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestToken is ERC20 {
  constructor() ERC20("TEST", "TEST") {
    _mint(msg.sender, 10000e18);
  }
}
