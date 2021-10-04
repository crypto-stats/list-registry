const { expect } = require("chai");

async function mineBlocks(numBlocks) {
  for (let i = 0; i < numBlocks; i += 1) {
    await ethers.provider.send("evm_mine");
  }
}

describe("SponsorAuction", function() {
  let auction;
  let token;
  let owner;
  let sponsor1;
  let user;
  const feeCampaignId = ethers.utils.formatBytes32String('fees').substr(0, 34);

  before(async () => {
    ([owner, sponsor1, user] = await ethers.getSigners());
  })

  beforeEach(async () => {
    const TestOracle = await ethers.getContractFactory("TestOracle");
    const testOracle = await TestOracle.deploy();

    const SponsorAuction = await ethers.getContractFactory("SponsorAuction");
    auction = await SponsorAuction.deploy(testOracle.address);
    
    const TestToken = await ethers.getContractFactory("TestToken");
    token = await TestToken.connect(sponsor1).deploy();

    await token.approve(auction.address, '0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff');
  })

  it('should let the owner adjust campaign slots', async () => {
    await expect(auction.setNumSlots(feeCampaignId, 2))
      .to.emit(auction, 'NumberOfSlotsChanged')
      .withArgs(feeCampaignId, 2);

    let campaign = await auction.getCampaign(feeCampaignId);
    expect(campaign.slots).to.equal(2);
    expect(campaign.activeSlots).to.equal(0);

    await expect(auction.setNumSlots(feeCampaignId, 3))
      .to.emit(auction, 'NumberOfSlotsChanged')
      .withArgs(feeCampaignId, 3);

    campaign = await auction.getCampaign(feeCampaignId);
    expect(campaign.slots).to.equal(3);
    expect(campaign.activeSlots).to.equal(0);
  });

  it('should not let another user adjust campaign slots', async () => {
    await expect(auction.connect(user).setNumSlots(feeCampaignId, 2))
      .to.be.revertedWith('MustBeCalledByOwner');
  });

  describe('with a campaign created', function() {
    beforeEach(async () => {
      await auction.setNumSlots(feeCampaignId, 2);
    });

    it('should let a sponsor submit a bid without tokens', async () => {
      const tx = await auction.connect(sponsor1).createSponsor(token.address, feeCampaignId, 0, 100, 'Test');
      const { events } = await tx.wait();

      expect(events.length).to.equal(1);
      expect(events[0].event).to.equal('NewSponsor');
      expect(events[0].args.campaign).to.equal(feeCampaignId);
      expect(events[0].args.owner).to.equal(await sponsor1.getAddress());
      expect(events[0].args.token).to.equal(token.address);
      expect(events[0].args.paymentPerSecond).to.equal(100);
      expect(events[0].args.metadata).to.equal('Test');
      const { sponsor: id } = events[0].args;

      const sponsor = await auction.getSponsor(id);

      expect(sponsor.owner).to.equal(await sponsor1.getAddress());
      expect(sponsor.approved).to.equal(false);
      expect(sponsor.active).to.equal(false);
      expect(sponsor.token).to.equal(token.address);
      expect(sponsor.paymentPerSecond).to.equal(100);
      expect(sponsor.campaign).to.equal(feeCampaignId);
      expect(sponsor.metadata).to.equal('Test');
    });

    it('should let a sponsor submit a bid with tokens', async () => {
      const tx = await auction.connect(sponsor1).createSponsor(token.address, feeCampaignId, 1000, 100, 'Test');
      const { events } = await tx.wait();

      expect(events.length).to.equal(4);
      expect(events[2].event).to.equal('NewSponsor');
      expect(events[2].args.campaign).to.equal(feeCampaignId);
      expect(events[2].args.owner).to.equal(await sponsor1.getAddress());
      expect(events[2].args.token).to.equal(token.address);
      expect(events[2].args.paymentPerSecond).to.equal(100);
      expect(events[2].args.metadata).to.equal('Test');
      const { sponsor: id } = events[2].args;
      
      expect(events[3].event).to.equal('Deposit');
      expect(events[3].args.sponsor).to.equal(id);
      expect(events[3].args.token).to.equal(token.address);
      expect(events[3].args.amount).to.equal(1000);

      const sponsor = await auction.getSponsor(id);

      expect(sponsor.owner).to.equal(await sponsor1.getAddress());
      expect(sponsor.approved).to.equal(false);
      expect(sponsor.active).to.equal(false);
      expect(sponsor.token).to.equal(token.address);
      expect(sponsor.paymentPerSecond).to.equal(100);
      expect(sponsor.campaign).to.equal(feeCampaignId);
      expect(sponsor.metadata).to.equal('Test');

      const balance = await auction.sponsorBalance(id);
      expect(balance.balance).to.equal(1000);
      expect(balance.storedBalance).to.equal(1000);
      expect(balance.pendingPayment).to.equal(0);
    });

    it('should fail when creating a bid with invalid data');

    describe('with a sponsor created', function() {
      let sponsorId;

      beforeEach(async () => {
        const tx = await auction.connect(sponsor1).createSponsor(token.address, feeCampaignId, 1000, 100, 'Test');
        const { events } = await tx.wait();
        sponsorId = events[3].args.sponsor;
      });

      it('should let the owner approve the sponsor', async () => {
        await expect(auction.setApproved(sponsorId, true))
          .to.emit(auction, 'ApprovalSet')
          .withArgs(sponsorId, true);

        const sponsor = await auction.getSponsor(sponsorId);
        expect(sponsor.approved).to.equal(true);
      });

      it('should not let normal users approve sponsors');

      it('should deposit and withdraw funds from a sponsor');

      it('should change a sponsor bid');
      
      it('should change a sponsor metadata');

      it('should not let unapproved sponsors be lifted to a slot');

      describe('with a sponsor approved', function() {
        beforeEach(async () => {
          await auction.setApproved(sponsorId, true);
        });

        it('should lift sponsor to slot', async () => {
          await expect(auction.lift(sponsorId))
            .to.emit(auction, 'SponsorActivated')
            .withArgs(feeCampaignId, sponsorId);

          const campaign = await auction.getCampaign(feeCampaignId);
          expect(campaign.slots).to.equal(2);
          expect(campaign.activeSlots).to.equal(1);

          const sponsor = await auction.getSponsor(sponsorId);
          expect(sponsor.active).to.equal(true);

          const activeSponsors = await auction.getActiveSponsors(feeCampaignId);
          expect(activeSponsors).to.deep.equal([sponsorId]);
        });

        it('should not allow processing payment');

        describe('with a sponsor active', function() {
          beforeEach(async () => {
            await auction.lift(sponsorId);
          });

          it('should accrue payment over time, and let anyone settle the payment', async () => {            
            let balance = await auction.sponsorBalance(sponsorId);
            expect(balance.balance).to.equal(1000);
            expect(balance.storedBalance).to.equal(1000);
            expect(balance.pendingPayment).to.equal(0);

            await mineBlocks(3);

            balance = await auction.sponsorBalance(sponsorId);
            expect(balance.balance).to.equal(700);
            expect(balance.storedBalance).to.equal(1000);
            expect(balance.pendingPayment).to.equal(300);

            // Payment will increase by 100, since processPayment will be in a subsequent block
            await expect(auction.connect(user).processPayment(sponsorId))
              .to.emit(auction, 'PaymentProcessed')
              .withArgs(feeCampaignId, sponsorId, token.address, 400);

            balance = await auction.sponsorBalance(sponsorId);
            expect(balance.balance).to.equal(600);
            expect(balance.storedBalance).to.equal(600);
            expect(balance.pendingPayment).to.equal(0);

            const amountCollected = await auction.paymentCollected(token.address);
            expect(amountCollected).to.equal(400);
          });

          it('should accrue payment over time, and let the sponsor withdraw the remainder', async () => {
            let balance = await auction.sponsorBalance(sponsorId);
            expect(balance.balance).to.equal(1000);
            expect(balance.storedBalance).to.equal(1000);
            expect(balance.pendingPayment).to.equal(0);

            await mineBlocks(3);

            balance = await auction.sponsorBalance(sponsorId);
            expect(balance.balance).to.equal(700);
            expect(balance.storedBalance).to.equal(1000);
            expect(balance.pendingPayment).to.equal(300);

            // Payment will increase by 100, since processPayment will be in a subsequent block
            await expect(auction.connect(sponsor1).withdraw(sponsorId, 1000, await user.getAddress()))
              .to.emit(auction, 'PaymentProcessed')
              .withArgs(feeCampaignId, sponsorId, token.address, 400)
              .to.emit(auction, 'SponsorDeactivated')
              .withArgs(feeCampaignId, sponsorId)
              .to.emit(auction, 'Withdrawal')
              .withArgs(sponsorId, token.address, 600);

            balance = await auction.sponsorBalance(sponsorId);
            expect(balance.balance).to.equal(0);
            expect(balance.storedBalance).to.equal(0);
            expect(balance.pendingPayment).to.equal(0);

            const withdrawBalance = await token.balanceOf(await user.getAddress());
            expect(withdrawBalance).to.equal(600);

            const amountCollected = await auction.paymentCollected(token.address);
            expect(amountCollected).to.equal(400);
          });

          it('should let any user deactivate after all funds spent', async () => {
            let balance = await auction.sponsorBalance(sponsorId);
            expect(balance.balance).to.equal(1000);
            expect(balance.storedBalance).to.equal(1000);
            expect(balance.pendingPayment).to.equal(0);

            await mineBlocks(11);

            balance = await auction.sponsorBalance(sponsorId);
            expect(balance.balance).to.equal(0);
            expect(balance.storedBalance).to.equal(1000);
            expect(balance.pendingPayment).to.equal(1000);

            await expect(auction.connect(user).processPayment(sponsorId))
              .to.emit(auction, 'PaymentProcessed')
              .withArgs(feeCampaignId, sponsorId, token.address, 1000)
              .to.emit(auction, 'SponsorDeactivated')
              .withArgs(feeCampaignId, sponsorId);

            balance = await auction.sponsorBalance(sponsorId);
            expect(balance.balance).to.equal(0);
            expect(balance.storedBalance).to.equal(0);
            expect(balance.pendingPayment).to.equal(0);

            const sponsor = await auction.getSponsor(sponsorId);
            expect(sponsor.active).to.equal(false);

            const activeSponsors = await auction.getActiveSponsors(feeCampaignId);
            expect(activeSponsors).to.deep.equal([]);

            const amountCollected = await auction.paymentCollected(token.address);
            expect(amountCollected).to.equal(1000);
          });

          it('should not let an active sponsor be "lifted"');

          describe('with more sponsors than slots', function() {
            let sponsorId2;
            let sponsorId3;

            beforeEach(async () => {
              const tx1 = await auction.connect(sponsor1).createSponsor(token.address, feeCampaignId, 1000, 120, 'Test');
              const { events: events1 } = await tx1.wait();
              sponsorId2 = events1[3].args.sponsor;
              await auction.setApproved(sponsorId2, true);

              const tx2 = await auction.connect(sponsor1).createSponsor(token.address, feeCampaignId, 1000, 140, 'Test');
              const { events: events2 } = await tx2.wait();
              sponsorId3 = events2[3].args.sponsor;
              await auction.setApproved(sponsorId3, true);
            });

            it('should allow lifting & swapping the sponsors into order', async () => {
              await auction.lift(sponsorId2);

              let campaign = await auction.getCampaign(feeCampaignId);
              expect(campaign.slots).to.equal(2);
              expect(campaign.activeSlots).to.equal(2);

              let sponsor2 = await auction.getSponsor(sponsorId2);
              expect(sponsor2.active).to.equal(true);

              let activeSponsors = await auction.getActiveSponsors(feeCampaignId);
              expect(activeSponsors).to.deep.equal([sponsorId, sponsorId2]);


              await expect(auction.swap(sponsorId3, sponsorId2))
                .to.emit(auction, 'PaymentProcessed') // TODO args
                .to.emit(auction, 'SponsorDeactivated')
                .withArgs(feeCampaignId, sponsorId2)
                .to.emit(auction, 'SponsorActivated')
                .withArgs(feeCampaignId, sponsorId3)
                .to.emit(auction, 'SponsorSwapped')
                .withArgs(feeCampaignId, sponsorId2, sponsorId3);


              sponsor2 = await auction.getSponsor(sponsorId2);
              expect(sponsor2.active).to.equal(false);
              let sponsor3 = await auction.getSponsor(sponsorId3);
              expect(sponsor3.active).to.equal(true);

              activeSponsors = await auction.getActiveSponsors(feeCampaignId);
              expect(activeSponsors).to.deep.equal([sponsorId, sponsorId3]);


              await expect(auction.swap(sponsorId2, sponsorId))
                .to.emit(auction, 'PaymentProcessed') // TODO args
                .to.emit(auction, 'SponsorDeactivated')
                .withArgs(feeCampaignId, sponsorId)
                .to.emit(auction, 'SponsorActivated')
                .withArgs(feeCampaignId, sponsorId2)
                .to.emit(auction, 'SponsorSwapped')
                .withArgs(feeCampaignId, sponsorId, sponsorId2);


              sponsor2 = await auction.getSponsor(sponsorId2);
              expect(sponsor2.active).to.equal(true);
              let sponsor1 = await auction.getSponsor(sponsorId);
              expect(sponsor1.active).to.equal(false);

              activeSponsors = await auction.getActiveSponsors(feeCampaignId);
              expect(activeSponsors).to.deep.equal([sponsorId2, sponsorId3]);
            });
          });
        });
      });
    });
  })
});
