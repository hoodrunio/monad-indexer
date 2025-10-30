const hre = require("hardhat");
const dotenv = require('dotenv');
dotenv.config();
async function main() {
  console.log("Deploying SimpleStorage contract to Monad testnet...");

  // Get the deployer account
  const signers = await hre.ethers.getSigners();

  if (!signers || signers.length === 0) {
    throw new Error("No signers found. Make sure PRIVATE_KEY is set in .env file");
  }

  const deployer = signers[0];
  const deployerAddress = await deployer.getAddress();
  console.log("Deploying with account:", deployerAddress);

  // Get account balance
  const balance = await hre.ethers.provider.getBalance(deployerAddress);
  console.log("Account balance:", hre.ethers.formatEther(balance), "MON");

  // Deploy the contract with an initial value of 42
  const initialValue = 42;
  const SimpleStorage = await hre.ethers.getContractFactory("SimpleStorage");
  const simpleStorage = await SimpleStorage.deploy(initialValue);

  await simpleStorage.waitForDeployment();

  const address = await simpleStorage.getAddress();
  console.log("\n✅ SimpleStorage deployed to:", address);
  console.log("Initial value:", initialValue);

  // Verify the initial value
  const storedValue = await simpleStorage.get();
  console.log("Stored value (verified):", storedValue.toString());

  console.log("\n📋 Contract Info:");
  console.log("- Address:", address);
  console.log("- Network: Monad Testnet");
  console.log("- Deployer:", deployerAddress);
  console.log("\n🔗 You can now verify this contract using the verification API");

  // Save deployment info
  const fs = require('fs');
  const deploymentInfo = {
    network: "monad-testnet",
    contractName: "SimpleStorage",
    contractAddress: address,
    deployer: deployerAddress,
    constructorArgs: [initialValue],
    timestamp: new Date().toISOString(),
    transactionHash: simpleStorage.deploymentTransaction().hash
  };

  fs.writeFileSync(
    './deployment-info.json',
    JSON.stringify(deploymentInfo, null, 2)
  );

  console.log("\n💾 Deployment info saved to deployment-info.json");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
