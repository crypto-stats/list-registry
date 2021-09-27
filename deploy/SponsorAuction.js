const WETH_ADDRESS = '0xB47e6A5f8b33b3F17603C83a0535A9dcD7E32681';

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

  const factory = await deploy('WETHAdapter', {
    args: [auction.address, WETH_ADDRESS],
    from: deployer,
    deterministicDeployment: true,
  });
  console.log(`Deployed WETHAdapter to ${factory.address}`);
};

module.exports = func;
