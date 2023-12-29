import { ethers, network, run } from "hardhat";
import config from "../config";

const main = async () => {
  // Compile contracts
  await run("compile");
  console.log("Compiled contracts.");

  const networkName = network.name;

  // Sanity checks
  if (networkName === "mainnet") {
    if (!process.env.KEY_MAINNET) {
      throw new Error("Missing private key, refer to README 'Deployment' section");
    }
  } else if (networkName === "testnet") {
    if (!process.env.KEY_TESTNET) {
      throw new Error("Missing private key, refer to README 'Deployment' section");
    }
  }

  if (!config.ZodiacRouter[networkName] || config.ZodiacRouter[networkName] === ethers.constants.AddressZero) {
    throw new Error("Missing router address, refer to README 'Deployment' section");
  }

  if (!config.WVIC[networkName] || config.WVIC[networkName] === ethers.constants.AddressZero) {
    throw new Error("Missing WVIC address, refer to README 'Deployment' section");
  }

  console.log("Deploying to network:", networkName);

  // Deploy ZodiacZapV1
  console.log("Deploying ZodiacZap V1..");

  const ZodiacZapV1 = await ethers.getContractFactory("ZodiacZapV1");

  const zodiacZap = await ZodiacZapV1.deploy(
    config.WVIC[networkName],
    config.ZodiacRouter[networkName],
    config.MaxZapReverseRatio[networkName]
  );

  await zodiacZap.deployed();

  console.log("ZodiacZap V1 deployed to:", zodiacZap.address);
};

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
