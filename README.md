# Talus Token Project

This repository contains the smart contracts for the Talus Token project on Sui blockchain, featuring a custom token and a decentralized faucet for token distribution.

## Prerequisites

- Sui CLI installed
- jq for JSON processing
- bc for calculations
- Basic understanding of Sui smart contracts

## Project Structure

```
talus-token/
├── talus/             # Talus token implementation
├── faucet/            # Bi-directional faucet contract
└── deploy.sh          # Deployment script
```

## Contracts

### Talus Token
A custom token implementation on the Sui blockchain.

### Faucet Module
The faucet module implements a faucet that enables exchanging between target token (e.g. TALUS) and base token (e.g. SUI) at a configurable exchange rate. Key features include:

- Configurable exchange rate between two token for test net so the Sybil attack resistance is based on supply of base token
- Percentage-based withdrawal limits to prevent draining
- Ability to inject additional liquidity
- Simple interface for minting and refunding

## Deployment

The project includes an automated deployment script that:
1. Starts a local Sui node if remote rpc is not provided
2. Sets up the environment
3. Publishes both contracts
4. Initializes the faucet with initial liquidity

To deploy:
```bash
./deploy.sh

# You will be prompted for:
- RPC URL (default: http://127.0.0.1:9000)
- Environment alias (default: local)
- Initial amount (default: 50% of total supply)
- Exchange rate (default: 10 TALUS/SUI)
- Max withdrawal ratio (default: 50%)
```

## Faucet Module

The faucet module implements a faucet that enables exchanging two types of coins at a fixed exchange rate. Key features include:

- Fixed exchange rate between two coin types
- Withdrawal limits to prevent draining
- Ability to inject additional liquidity
- Simple interface for minting and refunding

### Usage

```move
// Create a new faucet
let talus_coin = // ... obtain TALUS tokens
let exchange_rate = 10; // 1 SUI = 10 TALUS
let withdrawal_pct = 50; // 50% max withdrawal per tx
faucet::initiate<TALUS, SUI>(talus_coin, exchange_rate, withdrawal_pct, ctx);

// Mint TALUS using SUI
faucet::mint(faucet, sui_coin, ctx);

// Refund SUI by returning TALUS
faucet::refund(faucet, talus_coin, ctx);

// Add more liquidity
faucet::inject(faucet, additional_talus, ctx);
```

### Security Features

The faucet includes several security measures:
- Withdrawal limits (configurable percentage) prevent large withdrawals
- Fixed exchange rates prevent manipulation
- Shared object model ensures equal access
- Idempotent deployment process
- Retry mechanisms for faucet operations

### Configuration

Default values in deployment:
- Total Supply: 10^19 tokens
- Initial Faucet Amount: 50% of total supply
- Exchange Rate: 10 TALUS/SUI
- Withdrawal Limit: 50% per transaction

These values can be customized during deployment through the interactive prompts.
