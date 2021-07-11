//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

interface IOracle {
  function getPrice(address token, uint256 amount) external view returns (uint256);
}
