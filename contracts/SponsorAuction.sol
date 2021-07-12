//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IOracle.sol";
import "./Ownable.sol";

error Overflow();
error InvalidValue();
error ElementNotFound();
error MustBeCalledBySponsorOwner(address owner);
error SponsorListFull(bytes16 campaign);
error SponsorListNotOversized(bytes16 campaign);
error InvalidSponsor(bytes32 sponsorId);
error UnapprovedSponsor(bytes32 sponsorId);
error SponsorAlreadyActive(bytes32 sponsorId);
error SponsorInactive(bytes32 sponsorId);
error SponsorBalanceEmpty(bytes32 sponsorId);
error InsufficentBidToSwap(uint256 currentBid, uint256 attemptedSwapBid);

contract SponsorAuction is Ownable {
  struct Sponsor {
    uint128 balance;         // 16 bytes -- slot 1
    bool approved;           // 1 byte
    bool active;             // 1 byte
    uint8 slot;              // 1 byte
    uint32 lastUpdated;      // 4 bytes
    address owner;           // 20 bytes -- slot 2
    IERC20 token;            // 20 bytes -- slot 3
    uint128 paymentPerBlock; // 16 bytes -- slot 4
    bytes16 campaign;        // 16 bytes
    string metadata;
  }

  struct Campaign {
    uint8 slots;
    uint8 activeSlots;
  }

  mapping(bytes32 => Sponsor) private sponsors;

  mapping(bytes16 => Campaign) private campaigns;

  mapping(bytes16 => mapping(uint256 => bytes32)) private campaignActiveSponsors;

  mapping(address => uint256) public paymentCollected;

  IOracle public oracle;

  event NewSponsor(
    bytes32 indexed sponsor,
    bytes16 indexed campaign,
    address indexed owner,
    address token,
    uint128 paymentPerBlock,
    string metadata
  );
  event PaymentProcessed(
    bytes16 indexed campaign,
    bytes32 indexed sponsor,
    address indexed paymentToken,
    uint256 paymentAmount
  );
  event SponsorActivated(bytes16 indexed campaign, bytes32 indexed sponsor);
  event SponsorDeactivated(bytes16 indexed campaign, bytes32 indexed sponsor);
  event SponsorSwapped(
    bytes16 campaign,
    bytes32 sponsorDeactivated,
    bytes32 sponsorActivated
  );
  event MetadataUpdated(bytes32 indexed sponsor, string metadata);
  event SponsorOwnerTransferred(bytes32 indexed sponsor, address newOwner);
  event BidUpdated(bytes32 indexed sponsor, address indexed token, uint256 paymentPerBlock);

  event Deposit(bytes32 indexed sponsor, address indexed token, uint256 amount);
  event Withdrawal(bytes32 indexed sponsor, address indexed token, uint256 amount);

  event ApprovalSet(bytes32 indexed sponsor, bool approved);
  event NumberOfSlotsChanged(bytes16 indexed campaign, uint8 newNumSlots);
  event TreasuryWithdrawal(address indexed token, address indexed recipient, uint256 amount);

  // Constructor

  constructor(IOracle _oracle) {
    oracle = _oracle;
  }

  // View functions

  function getSponsor(bytes32 sponsorId) external view returns (
    address owner,
    bool approved,
    bool active,
    IERC20 token,
    uint128 paymentPerBlock,
    bytes16 campaign,
    uint32 lastUpdated,
    string memory metadata
  ) {
    Sponsor memory sponsor = sponsors[sponsorId];
    owner = sponsor.owner;
    approved = sponsor.approved;
    active = sponsor.active;
    token = sponsor.token;
    paymentPerBlock = sponsor.paymentPerBlock;
    campaign = sponsor.campaign;
    lastUpdated = sponsor.lastUpdated;
    metadata = sponsor.metadata;
  }

  function getCampaign(bytes16 campaignId) external view returns (uint8 slots, uint8 activeSlots) {
    Campaign memory campaign = campaigns[campaignId];
    slots = campaign.slots;
    activeSlots = campaign.activeSlots;
  }

  function sponsorBalance(bytes32 sponsorId) external view returns (
    uint128 balance,
    uint128 storedBalance,
    uint128 pendingPayment
  ) {
    Sponsor memory sponsor = sponsors[sponsorId];

    uint256 blocksElapsed = block.number - sponsor.lastUpdated;
    pendingPayment = uint128(blocksElapsed) * sponsor.paymentPerBlock;

    if (pendingPayment > sponsor.balance) {
      // If their balance is too small, we just zero the balance
      pendingPayment = sponsor.balance;
    }

    storedBalance = sponsor.balance;
    balance = storedBalance - pendingPayment;
  }

  function getActiveSponsors(bytes16 campaignId) external view returns (bytes32[] memory activeSponsors) {
    Campaign memory campaign = campaigns[campaignId];
    activeSponsors = new bytes32[](campaign.activeSlots);

    for(uint256 i = 0; i < campaign.activeSlots; i += 1) {
      activeSponsors[i] = campaignActiveSponsors[campaignId][i];
    }
  }

  function paymentRate(bytes32 sponsorId) external view returns (
    uint128 paymentPerBlock,
    uint128 paymentPerBlockInETH
  ) {
    Sponsor memory sponsor = sponsors[sponsorId];
    paymentPerBlock = sponsor.paymentPerBlock;
    uint256 paymentPerBlockInETH256 = oracle.getPrice(address(sponsor.token), paymentPerBlock);
    // In the unlikely case of a 128-bit overflow, use MAX_INT for uint128
    paymentPerBlockInETH = paymentPerBlockInETH256 > type(uint128).max
      ? type(uint128).max
      : uint128(paymentPerBlockInETH256);
  }

  // Sponsor functions

  function createSponsor(
    address _token,
    bytes16 campaign,
    uint256 initialDeposit,
    uint128 paymentPerBlock,
    string calldata metadata
  ) external returns (bytes32 id) {
    if (campaign == bytes16(0) || _token == address(0)) {
      // TODO: ensure paymentPerBlock is small enough that the payment always fits into uint128
      revert InvalidValue();
    }

    uint128 balance = 0;
    if (initialDeposit > 0) {
      balance = _deposit(IERC20(_token), initialDeposit);
    }

    id = psuedoRandomID(msg.sender, metadata);

    sponsors[id] = Sponsor({
      campaign: campaign,
      owner: msg.sender,
      token: IERC20(_token),
      balance: balance,
      paymentPerBlock: paymentPerBlock,
      lastUpdated: uint32(block.number),
      approved: false,
      active: false,
      slot: 0,
      metadata: metadata
    });

    emit NewSponsor(id, campaign, msg.sender, _token, paymentPerBlock, metadata);

    if (balance > 0) {
      emit Deposit(id, _token, balance);
    }
  }

  function deposit(bytes32 sponsorId, uint256 amount) external {
    Sponsor memory sponsor = sponsors[sponsorId];
    if (sponsor.owner == address(0)) {
      revert InvalidSponsor(sponsorId);
    }

    uint128 depositReceived = _deposit(IERC20(sponsor.token), amount);

    sponsors[sponsorId].balance = sponsor.balance + depositReceived;

    emit Deposit(sponsorId, address(sponsor.token), depositReceived);

    if (sponsor.active) {
      updateSponsor(sponsorId, sponsor, false);
    }
  }

  function updateBid(bytes32 sponsorId, address token, uint128 paymentPerBlock) external {
    Sponsor memory sponsor = sponsors[sponsorId];
    if (sponsor.owner != msg.sender) {
      revert MustBeCalledBySponsorOwner(sponsor.owner);
    }

    if (sponsor.active) {
      updateSponsor(sponsorId, sponsor, false);
    }

    sponsors[sponsorId].token = IERC20(token);
    sponsors[sponsorId].paymentPerBlock = paymentPerBlock;

    emit BidUpdated(sponsorId, token, paymentPerBlock);
  }

  function updateMetadata(bytes32 sponsorId, string calldata metadata) external {
    address _owner = sponsors[sponsorId].owner;
    if (_owner != msg.sender) {
      revert MustBeCalledBySponsorOwner(_owner);
    }

    sponsors[sponsorId].metadata = metadata;

    emit MetadataUpdated(sponsorId, metadata);
  }

  function withdraw(
    bytes32 sponsorId,
    uint256 amountRequested,
    address recipient
  ) external returns (uint256 withdrawAmount) {
    Sponsor memory sponsor = sponsors[sponsorId];
    if (sponsor.owner != msg.sender) {
      revert MustBeCalledBySponsorOwner(sponsor.owner);
    }

    uint128 balance = sponsor.balance;
    bool active = sponsor.active;
    if (active) {
      (active, balance) = updateSponsor(sponsorId, sponsor, false);
    }

    if (balance == 0) {
      return 0;
    }

    uint128 _withdrawAmount = uint128(amountRequested) > balance ? balance : uint128(amountRequested);
    withdrawAmount = _withdrawAmount;

    if (active && withdrawAmount == balance) {
      clearSlot(sponsor.campaign, sponsor.slot);
      sponsors[sponsorId].active = false;
      // sponsor.slot doesn't need to be changed, since it's never read while deactivated

      emit SponsorDeactivated(sponsor.campaign, sponsorId);
    }

    sponsors[sponsorId].balance = balance - _withdrawAmount;

    SafeERC20.safeTransfer(sponsor.token, recipient, withdrawAmount);

    emit Withdrawal(sponsorId, address(sponsor.token), withdrawAmount);
  }

  function transferSponsorOwnership(bytes32 sponsorId, address newOwner) external {
    address _owner = sponsors[sponsorId].owner;
    if (_owner != msg.sender) {
      revert MustBeCalledBySponsorOwner(_owner);
    }

    sponsors[sponsorId].owner = newOwner;

    emit SponsorOwnerTransferred(sponsorId, newOwner);
  }

  // List adjustments

  /// @notice Activates an inactive sponsor on a campaign that has not filled all active slots
  /// @param sponsorId The ID of a sponsor that is approved but inactive
  function lift(bytes32 sponsorId) external {
    Sponsor memory sponsor = sponsors[sponsorId];
    if (!sponsor.approved) {
      revert UnapprovedSponsor(sponsorId);
    }
    if (sponsor.active) {
      revert SponsorAlreadyActive(sponsorId);
    }

    Campaign memory campaign = campaigns[sponsor.campaign];

    if (campaign.activeSlots >= campaign.slots) {
      revert SponsorListFull(sponsor.campaign);
    }

    activateSponsor(sponsorId, sponsor.campaign, campaign.activeSlots);

    campaigns[sponsor.campaign].activeSlots = campaign.activeSlots + 1;
  }

  function drop(bytes32 sponsorId) external {
    Sponsor memory sponsor = sponsors[sponsorId];
    if (!sponsor.active) {
      revert SponsorInactive(sponsorId);
    }

    Campaign memory campaign = campaigns[sponsor.campaign];

    if (campaign.activeSlots <= campaign.slots) {
      revert SponsorListNotOversized(sponsor.campaign);
    }

    updateSponsor(sponsorId, sponsor, true);
    campaigns[sponsor.campaign].activeSlots = campaign.activeSlots - 1;
  }

  function swap(bytes32 inactiveSponsorId, bytes32 activeSponsorId) external {
    Sponsor memory inactiveSponsor = sponsors[inactiveSponsorId];
    Sponsor memory activeSponsor = sponsors[activeSponsorId];
    
    if (inactiveSponsor.campaign == bytes16(0)) {
      revert InvalidValue(); // Inactive sponsor doesn't exist
    }
    if (!inactiveSponsor.approved) {
      revert UnapprovedSponsor(inactiveSponsorId);
    }
    if (inactiveSponsor.active) {
      revert SponsorAlreadyActive(inactiveSponsorId);
    }
    if (inactiveSponsor.balance == 0) {
      revert SponsorBalanceEmpty(inactiveSponsorId);
    }

    if (activeSponsorId == bytes32(0)) {
      revert InvalidValue(); // Active sponsor doesn't exist
    }
    if (!activeSponsor.active) {
      revert SponsorInactive(activeSponsorId);
    }

    uint256 inactiveBidInETH = oracle.getPrice(address(inactiveSponsor.token), inactiveSponsor.paymentPerBlock);
    uint256 activeBidInETH = oracle.getPrice(address(activeSponsor.token), activeSponsor.paymentPerBlock);

    if (inactiveBidInETH <= activeBidInETH) {
      revert InsufficentBidToSwap(activeBidInETH, inactiveBidInETH);
    }

    updateSponsor(activeSponsorId, activeSponsor, true);

    activateSponsor(inactiveSponsorId, inactiveSponsor.campaign, activeSponsor.slot);

    emit SponsorSwapped(
      inactiveSponsor.campaign,
      activeSponsorId,
      inactiveSponsorId
    );
  }

  function processPayment(bytes32 sponsorId) external {
    Sponsor memory sponsor = sponsors[sponsorId];
    if (!sponsor.active) {
      revert SponsorInactive(sponsorId);
    }

    updateSponsor(sponsorId, sponsor, false);
  }

  // Owner actions

  function setApproved(bytes32 sponsorId, bool approved) external onlyOwner {
    sponsors[sponsorId].approved = approved;
    emit ApprovalSet(sponsorId, approved);
  }

  function setNumSlots(bytes16 campaign, uint8 newNumSlots) external onlyOwner {
    campaigns[campaign].slots = newNumSlots;
    emit NumberOfSlotsChanged(campaign, newNumSlots);
  }

  function withdrawTreasury(address token, address recipient) external onlyOwner returns (uint256 amount) {
    amount = paymentCollected[token];
    if (amount > 0) {
      SafeERC20.safeTransfer(IERC20(token), recipient, amount);
      paymentCollected[token] = 0;
      emit TreasuryWithdrawal(token, recipient, amount);
    }
  }

  // Private functions

  function activateSponsor(bytes32 sponsorId, bytes16 campaign, uint8 slot) private {
    sponsors[sponsorId].lastUpdated = uint32(block.number);
    sponsors[sponsorId].active = true;
    sponsors[sponsorId].slot = slot;

    campaignActiveSponsors[campaign][slot] = sponsorId;

    emit SponsorActivated(campaign, sponsorId);
  }

  function updateSponsor(
    bytes32 sponsorId,
    Sponsor memory sponsor,
    bool forceDeactivate
  ) private returns (bool newActiveState, uint128 newBalance) {
    newActiveState = !forceDeactivate;

    uint256 blocksElapsed = block.number - sponsor.lastUpdated;
    uint128 pendingPayment = uint128(blocksElapsed) * sponsor.paymentPerBlock;

    if (pendingPayment > sponsor.balance) {
      // If their balance is too small, we just zero the balance
      pendingPayment = sponsor.balance;
      newActiveState = false;
    }

    paymentCollected[address(sponsor.token)] += pendingPayment;

    newBalance = sponsor.balance - pendingPayment;
    sponsors[sponsorId].balance = newBalance;
    sponsors[sponsorId].lastUpdated = uint32(block.number);
    sponsors[sponsorId].active = newActiveState;

    if (pendingPayment > 0) {
      emit PaymentProcessed(
        sponsor.campaign,
        sponsorId,
        address(sponsor.token),
        pendingPayment
      );
    }
    if (!newActiveState) {
      clearSlot(sponsor.campaign, sponsor.slot);
      // sponsor.slot doesn't need to be changed, since it's never read while deactivated

      emit SponsorDeactivated(sponsor.campaign, sponsorId);
    }
  }

  function clearSlot(bytes16 campaignId, uint256 slot) private {
    Campaign memory campaign = campaigns[campaignId];

    uint256 lastActiveSpot = uint256(campaign.activeSlots) - 1;
    if (slot == lastActiveSpot) {
      campaignActiveSponsors[campaignId][slot] = bytes32(0);
    } else {
      campaignActiveSponsors[campaignId][slot] = campaignActiveSponsors[campaignId][lastActiveSpot];
      campaignActiveSponsors[campaignId][lastActiveSpot] = bytes32(0);
    }
    campaigns[campaignId].activeSlots = campaign.activeSlots - 1;
  }

  function _deposit(IERC20 token, uint256 amount) private returns (uint128) {
    IERC20 token = IERC20(token);

    uint256 startingBalance = token.balanceOf(address(this));
    SafeERC20.safeTransferFrom(token, msg.sender, address(this), amount);
    uint256 endBalance = token.balanceOf(address(this));

    if (endBalance - startingBalance > type(uint128).max) {
      revert Overflow();
    }

    return uint128(endBalance - startingBalance);
  }

  function psuedoRandomID(address sender, string memory value) private view returns (bytes32) {
    return keccak256(abi.encodePacked(block.difficulty, block.timestamp, sender, value));        
  }
}
