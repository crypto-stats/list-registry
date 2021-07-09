const { expect } = require("chai");

describe("ListRegistry", function() {
  let listRegistry;
  const feesId = ethers.utils.formatBytes32String('fees');

  beforeEach(async () => {
    const ListRegistry = await ethers.getContractFactory("ListRegistry");
    listRegistry = await ListRegistry.deploy();
  })

  it("Should add elements to a list", async function() {
    let listData = await listRegistry.getList(feesId);
    expect(listData.first).to.equal('0x00000000000000000000000000000000');
    expect(listData.last).to.equal('0x00000000000000000000000000000000');
    let listElements = await listRegistry.getFullList(feesId);
    expect(listElements).to.deep.equal([]);

    const addTxPromise = listRegistry.addElement(feesId, 'Element1');
    await expect(addTxPromise).to.emit(listRegistry, 'ElementAdded');
    const addTx = await addTxPromise;
    const { events } = await addTx.wait();
    const { index: index1 } = events[0].args;
    const element = await listRegistry.getElement(feesId, index1);
    expect(element.value).to.equal('Element1');
    expect(element.previous).to.equal('0x00000000000000000000000000000000');
    expect(element.next).to.equal('0x00000000000000000000000000000000');

    listData = await listRegistry.getList(feesId);
    expect(listData.first).to.equal(index1);
    expect(listData.last).to.equal(index1);
    listElements = await listRegistry.getFullList(feesId);
    expect(listElements).to.deep.equal(['Element1']);

    const addTx2 = await listRegistry.addElement(feesId, 'Element2');
    const { events: events2 } = await addTx2.wait();
    const { index: index2 } = events2[0].args;

    listData = await listRegistry.getList(feesId);
    expect(listData.first).to.equal(index1);
    expect(listData.last).to.equal(index2);
    listElements = await listRegistry.getFullList(feesId);
    expect(listElements).to.deep.equal(['Element1', 'Element2']);

    const addTx3 = await listRegistry.addElement(feesId, 'Element3');
    const { events: events3 } = await addTx3.wait();
    const { index: index3 } = events3[0].args;

    listData = await listRegistry.getList(feesId);
    expect(listData.first).to.equal(index1);
    expect(listData.last).to.equal(index3);
    listElements = await listRegistry.getFullList(feesId);
    expect(listElements).to.deep.equal(['Element1', 'Element2', 'Element3']);
  });

  it("shouldn't let a non-owner add elements", async () => {
    const [user1, user2] = await ethers.getSigners();

    await expect(listRegistry.connect(user2).addElement(feesId, 'Element'))
      .to.be.revertedWith('MustBeCalledByOwner');
  });

  describe('with a full list', function() {
    let index1;
    let index2;
    let index3;

    beforeEach(async () => {
      await listRegistry.addElement(feesId, 'Element1');
      ({ last: index1 } = await listRegistry.getList(feesId));
      await listRegistry.addElement(feesId, 'Element2');
      ({ last: index2 } = await listRegistry.getList(feesId));
      await listRegistry.addElement(feesId, 'Element3');
      ({ last: index3 } = await listRegistry.getList(feesId));
    });

    it('should remove the first element', async () => {
      await expect(listRegistry.removeElement(feesId, index1))
        .to.emit(listRegistry, 'ElementRemoved')
        .withArgs(feesId, index1, 'Element1');

      const listData = await listRegistry.getList(feesId);
      expect(listData.first).to.equal(index2);
      expect(listData.last).to.equal(index3);
      const listElements = await listRegistry.getFullList(feesId);
      expect(listElements).to.deep.equal(['Element2', 'Element3']);
    });

    it('should remove the middle element', async () => {
      await expect(listRegistry.removeElement(feesId, index2))
        .to.emit(listRegistry, 'ElementRemoved')
        .withArgs(feesId, index2, 'Element2');

      const listData = await listRegistry.getList(feesId);
      expect(listData.first).to.equal(index1);
      expect(listData.last).to.equal(index3);
      const listElements = await listRegistry.getFullList(feesId);
      expect(listElements).to.deep.equal(['Element1', 'Element3']);
    });

    it('should remove the first element', async () => {
      await expect(listRegistry.removeElement(feesId, index3))
        .to.emit(listRegistry, 'ElementRemoved')
        .withArgs(feesId, index3, 'Element3');

      const listData = await listRegistry.getList(feesId);
      expect(listData.first).to.equal(index1);
      expect(listData.last).to.equal(index2);
      const listElements = await listRegistry.getFullList(feesId);
      expect(listElements).to.deep.equal(['Element1', 'Element2']);
    });

    it("shouldn't let a non-owner remove elements", async () => {
      const [user1, user2] = await ethers.getSigners();

      await expect(listRegistry.connect(user2).removeElement(feesId, index1))
        .to.be.revertedWith('MustBeCalledByOwner');
    });
  });
});
