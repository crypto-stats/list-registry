//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./SponsorAuction.sol";

interface IWETH {
  function deposit() external payable;
  function approve(address recipient, uint256 amount) external;
}

contract WETHAdapter {
  SponsorAuction public immutable auction;
  IWETH public immutable weth;

  constructor(address _auction, address _weth) {
    auction = SponsorAuction(_auction);
    weth = IWETH(_weth);
  }

  function createSponsor(
    bytes16 campaign,
    uint128 paymentPerSecond,
    string calldata metadata
  ) external payable returns (bytes32 id) {
    weth.deposit{ value: msg.value }();
    weth.approve(address(auction), msg.value);

    id = auction.createSponsor(address(weth), campaign, uint128(msg.value), paymentPerSecond, metadata);
    auction.transferSponsorOwnership(id, msg.sender);
  }

  function deposit(bytes32 sponsorId) external payable {
    weth.deposit{ value: msg.value }();
    weth.approve(address(auction), msg.value);

    auction.deposit(sponsorId, msg.value);
  }
}
