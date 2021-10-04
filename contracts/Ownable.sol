//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

error MustBeCalledByOwner();

contract Ownable {
  address public owner;

  event OwnershipTransferred(address indexed newOwner);

  constructor() {
    owner = msg.sender;
  }

  modifier onlyOwner {
    if (msg.sender != owner) {
      revert MustBeCalledByOwner();
    }
    _;
  }

  function transferOwnership(address newOwner) external onlyOwner {
    owner = newOwner;
    emit OwnershipTransferred(newOwner);
  }
}
