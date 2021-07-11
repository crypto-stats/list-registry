//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../interfaces/IOracle.sol";

contract TestOracle is IOracle {
  function getPrice(address token, uint256 amount) external view override returns (uint256) {
    return amount;
  }
}
