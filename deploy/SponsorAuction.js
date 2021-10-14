// const WETH_ADDRESS = '0xB47e6A5f8b33b3F17603C83a0535A9dcD7E32681';
const WETH_ADDRESS = '0xd0a1e359811322d97991e03f863a0c30c2cf029c'; //kovan

const owner = '0x3431c5139Bb6F5ba16E4d55EF2420ba8E0E127F6';

const func = async function ({ deployments, getNamedAccounts, getChainId }) {
  const { deploy, execute, read } = deployments;
  const { deployer } = await getNamedAccounts();

  const oracle = await deploy('SingleTokenOracle', {
    args: [WETH_ADDRESS],
    from: deployer,
    deterministicDeployment: true,
  });
  console.log(`Deployed SingleTokenOracle to ${oracle.address}`);

  const auction = await deploy('SponsorAuction', {
    args: [oracle.address],
    from: deployer,
  });
  console.log(`Deployed SponsorAuction to ${auction.address}`);
  await execute('SponsorAuction', { from: deployer }, 'setNumSlots', '0x6c6973636f6e00000000000000000000', 1)
  await execute('SponsorAuction', { from: deployer }, 'transferOwnership', owner);

  const factory = await deploy('WETHAdapter', {
    args: [auction.address, WETH_ADDRESS],
    from: deployer,
    deterministicDeployment: true,
  });
  console.log(`Deployed WETHAdapter to ${factory.address}`);
};

module.exports = func;
