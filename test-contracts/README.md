# Monad Testnet Smart Contract Deployment

Test contracts for deploying to Monad testnet and verifying via Blockscout API.

## Setup

1. Install dependencies:
```bash
npm install
```

2. Configure environment:
```bash
cp .env.example .env
# Edit .env and add your PRIVATE_KEY
```

3. Make sure you have testnet MON tokens in your wallet

## Deploy

```bash
npm run deploy
```

This will:
- Deploy SimpleStorage contract to Monad testnet
- Save deployment info to `deployment-info.json`
- Display contract address and transaction details

## Contract: SimpleStorage

A simple storage contract with the following features:
- Store and retrieve a uint256 value
- Increment the stored value
- Emit events on value changes
- Track the owner address

Constructor parameter: `uint256 initialValue` (set to 42 in deployment script)

## After Deployment

Use the contract address from `deployment-info.json` to verify the contract using the Blockscout verification API.
