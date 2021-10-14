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
error MustWithdrawBalanceToChangeToken(bytes32 sponsorId);
error InsufficentBidToSwap(uint256 currentBid, uint256 attemptedSwapBid);

contract SponsorAuction is Ownable {
  // This his struct is packed to take up 4 storage slots, plus variable slots for the metadata string
  struct Sponsor {
    uint128 balance;         // 16 bytes -- slot 1
    bool approved;           // 1 byte
    bool active;             // 1 byte
    uint8 slot;              // 1 byte
    uint32 lastUpdated;      // 4 bytes
    address owner;           // 20 bytes -- slot 2
    IERC20 token;            // 20 bytes -- slot 3
    uint128 paymentPerSecond; // 16 bytes -- slot 4
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
    uint128 paymentPerSecond,
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
  event BidUpdated(bytes32 indexed sponsor, address indexed token, uint256 paymentPerSecond);

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

  /// @notice Returns details about a given sponsor
  /// @param sponsorId The ID of a sponsor
  /// @return owner The owner of the sponsorship
  /// @return approved Whether the sponsorship is approved by the auction owner
  /// @return active Whether the sponsorship holds an active slot
  /// @return token The payment token
  /// @return paymentPerSecond The amount of tokens-per-second to pay when the sponsorship is active
  /// @return campaign The campaign the sponsorship is part of
  /// @return lastUpdated Timestamp of the last time the sponsor was activated/disactivated
  /// @return metadata Any metadata (such as an IPFS CID)
  function getSponsor(bytes32 sponsorId) external view returns (
    address owner,
    bool approved,
    bool active,
    IERC20 token,
    uint128 paymentPerSecond,
    bytes16 campaign,
    uint32 lastUpdated,
    string memory metadata
  ) {
    Sponsor memory sponsor = sponsors[sponsorId];
    owner = sponsor.owner;
    approved = sponsor.approved;
    active = sponsor.active;
    token = sponsor.token;
    paymentPerSecond = sponsor.paymentPerSecond;
    campaign = sponsor.campaign;
    lastUpdated = sponsor.lastUpdated;
    metadata = sponsor.metadata;
  }

  /// @notice Returns details about a given campaign
  /// @param campaignId The ID of a campaign (often a short string)
  /// @return slots The maximum simultaneous active sponsorships in this campaign
  /// @return activeSlots The number of sponsors in this campaign that are currently active
  function getCampaign(bytes16 campaignId) external view returns (uint8 slots, uint8 activeSlots) {
    Campaign memory campaign = campaigns[campaignId];
    slots = campaign.slots;
    activeSlots = campaign.activeSlots;
  }

  /// @notice The current balance of a sponsorship, which may change per-second when active
  /// @param sponsorId The ID of a sponsor
  /// @return balance The current balance, factoring any pending payment
  /// @return storedBalance The balance of the sponsorship on the last update
  /// @return pendingPayment Any payments that have accrued since the last update (increases every second when active)
  function sponsorBalance(bytes32 sponsorId) external view returns (
    uint128 balance,
    uint128 storedBalance,
    uint128 pendingPayment
  ) {
    Sponsor memory sponsor = sponsors[sponsorId];

    uint256 timeElapsed = block.timestamp - sponsor.lastUpdated;
    pendingPayment = uint128(timeElapsed) * sponsor.paymentPerSecond;

    if (pendingPayment > sponsor.balance) {
      // If their balance is too small, we just zero the balance
      pendingPayment = sponsor.balance;
    }

    storedBalance = sponsor.balance;
    balance = storedBalance - pendingPayment;
  }

  /// @notice Returns the IDs of all active sponsors in a campaign. Due to the unbounded loop, should only be called by frontend
  /// @param campaignId The ID of a campaign (often a short string)
  /// @return activeSponsors ID of all active sponsors
  function getActiveSponsors(bytes16 campaignId) external view returns (bytes32[] memory activeSponsors) {
    Campaign memory campaign = campaigns[campaignId];
    activeSponsors = new bytes32[](campaign.activeSlots);

    for(uint256 i = 0; i < campaign.activeSlots; i += 1) {
      activeSponsors[i] = campaignActiveSponsors[campaignId][i];
    }
  }

  /// @notice The current payment-per-second of a sponsorship bid
  /// @param sponsorId The ID of a sponsor
  /// @return paymentPerSecond The payment-per-second in the payment token
  /// @return paymentPerSecondInETH The payment-per-second, converted to ETH using the oracle
  function paymentRate(bytes32 sponsorId) external view returns (
    uint128 paymentPerSecond,
    uint128 paymentPerSecondInETH
  ) {
    Sponsor memory sponsor = sponsors[sponsorId];
    paymentPerSecond = sponsor.paymentPerSecond;
    uint256 paymentPerSecondInETH256 = oracle.getPrice(address(sponsor.token), paymentPerSecond);
    // In the unlikely case of a 128-bit overflow, use MAX_INT for uint128
    paymentPerSecondInETH = paymentPerSecondInETH256 > type(uint128).max
      ? type(uint128).max
      : uint128(paymentPerSecondInETH256);
  }

  // Sponsor functions

  /// @notice Create a new unapproved sponsorship
  /// @param _token The ERC20 token to denominate payment in
  /// @param campaign The ID of the campaign to submit the sponsorship to
  /// @param paymentPerSecond The payment-per-second in the payment token
  /// @param metadata Any data to attach to the sponsorship (such as an IPFS CID)
  /// @return id The psuedo-randomly generated ID for the new sponsorship
  function createSponsor(
    address _token,
    bytes16 campaign,
    uint256 initialDeposit,
    uint128 paymentPerSecond,
    string calldata metadata
  ) external returns (bytes32 id) {
    if (campaign == bytes16(0) || _token == address(0)) {
      revert InvalidValue();
    }

    // Prevent overflow attacks
    if (uint256(paymentPerSecond) * 365 days > type(uint128).max) {
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
      paymentPerSecond: paymentPerSecond,
      lastUpdated: uint32(block.timestamp),
      approved: false,
      active: false,
      slot: 0,
      metadata: metadata
    });

    emit NewSponsor(id, campaign, msg.sender, _token, paymentPerSecond, metadata);

    if (balance > 0) {
      emit Deposit(id, _token, balance);
    }
  }

  /// @notice Deposit tokens into the balance of an existing sponsorship (may be called by anyone)
  /// @param sponsorId The ID of a sponsor
  /// @param amount Amount of tokens to deposit (must be ERC20-approved)
  function deposit(bytes32 sponsorId, uint256 amount) external {
    Sponsor memory sponsor = sponsors[sponsorId];
    if (sponsor.owner == address(0)) {
      revert InvalidSponsor(sponsorId);
    }

    uint128 depositReceived = _deposit(IERC20(sponsor.token), amount);

    sponsors[sponsorId].balance = sponsor.balance + depositReceived;

    emit Deposit(sponsorId, address(sponsor.token), depositReceived);

    if (sponsor.active) {
      updateSponsor(sponsorId, sponsor, false, false);
    }
  }

  /// @notice Update the token or payment-per-second of a sponsorship (only called by sponsorship owner)
  /// @param sponsorId The ID of a sponsorship to update
  /// @param token The new token to associate with the bid. If different, balance must be 0
  /// @param paymentPerSecond The payment-per-second bid
  function updateBid(bytes32 sponsorId, address token, uint128 paymentPerSecond) external {
    Sponsor memory sponsor = sponsors[sponsorId];
    if (sponsor.owner != msg.sender) {
      revert MustBeCalledBySponsorOwner(sponsor.owner);
    }

    uint256 currentBalance = sponsor.balance;
    if (sponsor.active) {
      (, currentBalance) = updateSponsor(sponsorId, sponsor, false, false);
    }

    if (address(sponsor.token) != token && currentBalance > 0) {
      revert MustWithdrawBalanceToChangeToken(sponsorId);
    }

    sponsors[sponsorId].token = IERC20(token);
    sponsors[sponsorId].paymentPerSecond = paymentPerSecond;

    emit BidUpdated(sponsorId, token, paymentPerSecond);
  }

  /// @notice Update the metadata of a sponsor (only called by sponsorship owner, will deactivate/unapprove sponsorship)
  /// @param sponsorId The ID of a sponsorship to update
  /// @param metadata New metadata value
  function updateMetadata(bytes32 sponsorId, string calldata metadata) external {
    Sponsor memory sponsor = sponsors[sponsorId];
    address _owner = sponsor.owner;
    if (sponsors[sponsorId].owner != msg.sender) {
      revert MustBeCalledBySponsorOwner(_owner);
    }

    if (sponsor.active) {
      updateSponsor(sponsorId, sponsor, false, false);
    }

    sponsors[sponsorId].metadata = metadata;

    if (sponsor.approved || sponsor.active) {
      sponsors[sponsorId].approved = false;
      sponsors[sponsorId].active = false;
    }

    emit MetadataUpdated(sponsorId, metadata);

    if (sponsor.active) {
      emit SponsorDeactivated(sponsor.campaign, sponsorId);
    }
    if (sponsor.approved) {
      emit ApprovalSet(sponsorId, false);
    }
  }

  /// @notice Withdraw funds from a sponsorship (only called by sponsorship owner)
  /// @param sponsorId The ID of a sponsorship to update
  /// @param amountRequested The amount of tokens to withdraw. If 0 or greater than the current balance, will withdraw current balance
  /// @param recipient Address to receive tokens
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
      (active, balance) = updateSponsor(sponsorId, sponsor, false, false);
    }

    if (balance == 0) {
      return 0;
    }

    withdrawAmount = uint128(amountRequested) > balance || amountRequested == 0
      ? balance
      : uint128(amountRequested);

    if (active && withdrawAmount == balance) {
      clearSlot(sponsor.campaign, sponsor.slot);
      sponsors[sponsorId].active = false;
      // sponsor.slot doesn't need to be changed, since it's never read while deactivated

      emit SponsorDeactivated(sponsor.campaign, sponsorId);
    }

    sponsors[sponsorId].balance = balance - uint128(withdrawAmount);

    SafeERC20.safeTransfer(sponsor.token, recipient, withdrawAmount);

    emit Withdrawal(sponsorId, address(sponsor.token), withdrawAmount);
  }

  /// @notice Transfer ownership of sponsor to a new address (only called by current owner)
  /// @param sponsorId The ID of a sponsorship to update
  /// @param newOwner Address of new owner account
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

  /// @notice Deactive a sponsor if the balance reaches 0 or the number of slots is reduced
  /// @param sponsorId The ID of a sponsor
  function drop(bytes32 sponsorId) external {
    Sponsor memory sponsor = sponsors[sponsorId];
    if (!sponsor.active) {
      revert SponsorInactive(sponsorId);
    }

    Campaign memory campaign = campaigns[sponsor.campaign];

    (, uint256 newBalance) = updateSponsor(sponsorId, sponsor, true, false);

    if (newBalance > 0 && campaign.activeSlots <= campaign.slots) {
      revert SponsorListNotOversized(sponsor.campaign);
    }
  }

  /// @notice Swaps an active sponsor for an inactive sponsor with higher bid (called by anyone)
  /// @param inactiveSponsorId The ID of a sponsor that is approved but inactive
  /// @param activeSponsorId The ID of a sponsor with an empty balance, or a lower bid
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

    if (!activeSponsor.active) {
      revert SponsorInactive(activeSponsorId);
    }

    (, uint256 newBalance) = updateSponsor(activeSponsorId, activeSponsor, true, true);

    // If the active sponsor has an empty balance, we can swap in any approved sponsor
    // If the balance isn't empty, then we compare bids
    if (newBalance != 0) {
      uint256 inactiveBidInETH = oracle.getPrice(address(inactiveSponsor.token), inactiveSponsor.paymentPerSecond);
      uint256 activeBidInETH = oracle.getPrice(address(activeSponsor.token), activeSponsor.paymentPerSecond);

      if (inactiveBidInETH <= activeBidInETH) {
        revert InsufficentBidToSwap(activeBidInETH, inactiveBidInETH);
      }
    }

    activateSponsor(inactiveSponsorId, inactiveSponsor.campaign, activeSponsor.slot);

    emit SponsorSwapped(
      inactiveSponsor.campaign,
      activeSponsorId,
      inactiveSponsorId
    );
  }

  /// @notice Process the payment of an active sponsor, deactivating if balance reaches 0. (Called by anyone)
  /// @param sponsorId The ID of a sponsor
  function processPayment(bytes32 sponsorId) external {
    Sponsor memory sponsor = sponsors[sponsorId];
    if (!sponsor.active) {
      revert SponsorInactive(sponsorId);
    }

    updateSponsor(sponsorId, sponsor, false, false);
  }

  // Owner actions

  /// @notice Approves or unapproves a sponsor. (Called by auction owner)
  /// @param sponsorId The ID of a sponsor
  /// @param approved New approval value
  function setApproved(bytes32 sponsorId, bool approved) external onlyOwner {
    sponsors[sponsorId].approved = approved;
    emit ApprovalSet(sponsorId, approved);
  }

  /// @notice Set the number of potential active sponsors of a campaign. (Called by auction owner)
  /// @param campaign The ID of a campaign
  /// @param newNumSlots Number of potential active sponsors
  function setNumSlots(bytes16 campaign, uint8 newNumSlots) external onlyOwner {
    campaigns[campaign].slots = newNumSlots;
    emit NumberOfSlotsChanged(campaign, newNumSlots);
  }

  /// @notice Withdraw tokens collected from sponsors. (Called by auction owner)
  /// @param token Token to withdraw
  /// @param recipient Address to receive payment
  function withdrawTreasury(address token, address recipient) external onlyOwner returns (uint256 amount) {
    amount = paymentCollected[token];
    if (amount > 0) {
      SafeERC20.safeTransfer(IERC20(token), recipient, amount);
      paymentCollected[token] = 0;
      emit TreasuryWithdrawal(token, recipient, amount);
    }
  }

  // Private functions

  /// @notice Calling function must ensure sponsor is currently inactive
  function activateSponsor(bytes32 sponsorId, bytes16 campaign, uint8 slot) private {
    sponsors[sponsorId].lastUpdated = uint32(block.timestamp);
    sponsors[sponsorId].active = true;
    sponsors[sponsorId].slot = slot;

    campaignActiveSponsors[campaign][slot] = sponsorId;

    emit SponsorActivated(campaign, sponsorId);
  }

  /// @notice For a given sponsor, it will process pending payments and deactivate if necessary
  /// @param sponsorId The ID of a sponsor
  /// @param sponsor The current sponsor state
  /// @param forceDeactivate Deactivate the sponsor, even if there is sufficent balance (used in swap/drop)
  /// @param skipClearingSlot Leave the campaign slot enabled (used in swap)
  function updateSponsor(
    bytes32 sponsorId,
    Sponsor memory sponsor,
    bool forceDeactivate,
    bool skipClearingSlot
  ) private returns (bool newActiveState, uint128 newBalance) {
    newActiveState = !forceDeactivate;

    uint256 timeElapsed = block.timestamp - sponsor.lastUpdated;
    uint128 pendingPayment = uint128(timeElapsed) * sponsor.paymentPerSecond;

    if (pendingPayment > sponsor.balance) {
      // If their balance is too small, we just zero the balance
      pendingPayment = sponsor.balance;
      newActiveState = false;
    }

    paymentCollected[address(sponsor.token)] += pendingPayment;

    newBalance = sponsor.balance - pendingPayment;
    sponsors[sponsorId].balance = newBalance;
    sponsors[sponsorId].lastUpdated = uint32(block.timestamp);
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
      if (!skipClearingSlot) {
        clearSlot(sponsor.campaign, sponsor.slot);
        // sponsor.slot doesn't need to be changed, since it's never read while deactivated
      }

      emit SponsorDeactivated(sponsor.campaign, sponsorId);
    }
  }

  /// @notice Remove a sponsor from a campaign's list of active sponsors
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

  /// @notice Transfer an approved token from the sender to the contract
  function _deposit(IERC20 token, uint256 amount) private returns (uint128) {
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
