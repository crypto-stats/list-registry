const { expect } = require("chai");

async function mineBlocks(numBlocks) {
  for (let i = 0; i < numBlocks; i += 1) {
    await ethers.provider.send("evm_mine");
  }
}

describe("WETH Adapter", function() {
  let auction;
  let weth;
  let owner;
  let sponsor1;
  let user;
  let adapter;
  const feeCampaignId = ethers.utils.formatBytes32String('fees').substr(0, 34);

  before(async () => {
    ([owner, sponsor1, user] = await ethers.getSigners());
  })

  beforeEach(async () => {
    const WETH = await ethers.getContractFactory("WETH");
    weth = await WETH.deploy();

    const SingleTokenOracle = await ethers.getContractFactory("SingleTokenOracle");
    const oracle = await SingleTokenOracle.deploy(weth.address);

    const SponsorAuction = await ethers.getContractFactory("SponsorAuction");
    auction = await SponsorAuction.deploy(oracle.address);
    
    const WETHAdapter = await ethers.getContractFactory('WETHAdapter');
    adapter = await WETHAdapter.deploy(auction.address, weth.address);
  })

  it('should let a sponsor submit a bid with ETH', async () => {
    const tx = await adapter.connect(sponsor1).createSponsor(feeCampaignId, 100, 'Test', { value: 200 });
    const { logs } = await tx.wait();

    expect(logs.length).to.equal(6);
    const newSponsorEvent = auction.interface.parseLog(logs[3]);
    expect(newSponsorEvent.name).to.equal('NewSponsor');
    expect(newSponsorEvent.args.campaign).to.equal(feeCampaignId);
    expect(newSponsorEvent.args.owner).to.equal(adapter.address);
    expect(newSponsorEvent.args.token).to.equal(weth.address);
    expect(newSponsorEvent.args.paymentPerSecond).to.equal(100);
    expect(newSponsorEvent.args.metadata).to.equal('Test');
    const { sponsor: id } = newSponsorEvent.args;

    const depositEvent = auction.interface.parseLog(logs[4]);
    expect(depositEvent.name).to.equal('Deposit');
    expect(depositEvent.args.sponsor).to.equal(id);
    expect(depositEvent.args.token).to.equal(weth.address);
    expect(depositEvent.args.amount).to.equal(200);await sponsor1.getAddress()

    const ownerXferEvent = auction.interface.parseLog(logs[5]);
    expect(ownerXferEvent.name).to.equal('SponsorOwnerTransferred');
    expect(ownerXferEvent.args.sponsor).to.equal(id);
    expect(ownerXferEvent.args.newOwner).to.equal(await sponsor1.getAddress());

    const sponsor = await auction.getSponsor(id);

    expect(sponsor.owner).to.equal(await sponsor1.getAddress());
    expect(sponsor.approved).to.equal(false);
    expect(sponsor.active).to.equal(false);
    expect(sponsor.token).to.equal(weth.address);
    expect(sponsor.paymentPerSecond).to.equal(100);
    expect(sponsor.campaign).to.equal(feeCampaignId);
    expect(sponsor.metadata).to.equal('Test');

    const balance = await auction.sponsorBalance(id);

    expect(balance.storedBalance).to.equal(200);
  });

  describe('with a sponsor created', function() {
    let sponsorId;

    beforeEach(async () => {
      const tx = await auction.connect(sponsor1).createSponsor(weth.address, feeCampaignId, 0, 100, 'Test');
      const { events } = await tx.wait();
      sponsorId = events[0].args.sponsor;
    });
    
    it('should deposit and withdraw funds from a sponsor', async () => {
      await expect(adapter.connect(sponsor1).deposit(sponsorId, { value: 200 }))
        .to.emit(auction, 'Deposit')
        .withArgs(sponsorId, weth.address, 200);

      const balance = await auction.sponsorBalance(sponsorId);

      expect(balance.storedBalance).to.equal(200);
    });
  });
});
