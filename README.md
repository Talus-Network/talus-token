# Talus Token Project

This repository contains the smart contracts for the Talus Token project on Sui blockchain, featuring a custom token, a decentralized faucet for token distribution, a deposit pool for yield generation, and a reward pool for loyalty incentives.

## Prerequisites

- Sui CLI installed
- jq for JSON processing
- bc for calculations
- Basic understanding of Sui smart contracts

## Project Structure

```
talus-token/
├── talus/             # US token (Coin) 
├── faucet/            # Bi-directional faucet contract
├── loyalty/           # Loyalty token
├── deposit_pool/      # Deposit pool and reward pool contracts
└── deploy.sh          # Deployment script
```

## Contracts

### Talus Token
A custom token implementation on the Sui blockchain.

### Faucet Module
The faucet module implements a faucet that enables exchanging between target token (e.g. TALUS) and base token (e.g. SUI) at a configurable exchange rate. Key features include:

- Configurable exchange rate between two tokens for test net so the Sybil attack resistance is based on supply of base token
- Percentage-based withdrawal limits to prevent draining
- Ability to inject additional liquidity
- Simple interface for minting and refunding

### Deposit Pool Module

The deposit pool module allows users to deposit base tokens and earn loyalty tokens as rewards. Users can lock their tokens for different time periods with varying APY rates. Key features include:

- Multiple lock terms with configurable APY
- Early withdrawal support (configurable)
- Pending withdrawal period (optional)
- Admin-controlled reward pool integration
- Receipts for each deposit, enabling precise reward calculation

#### Usage

```move
// Initialize a deposit pool
let treasury_cap = // ... obtain Loyalty token treasury cap
let base_apy = 5; // APY
let rate_decimal = Some(2); // unit of 1% 
let early_withdrawal = true;
let withdrawal_pending_days = 2;
deposit_pool::deposit_pool::new<Base, Loyalty>(
    treasury_cap, base_apy, base_decimal, early_withdrawal, withdrawal_pending_days, ctx
);

// Deposit base tokens
deposit_pool::deposit_pool::deposit(pool, base_coin, term_days, clock, recipient, ctx);

// Withdraw and claim rewards
deposit_pool::deposit_pool::withdrawal(pool, receipt, clock, ctx);
```

### Reward Pool Module

The reward pool module manages reward pools and allows users to claim rewards by spending loyalty tokens. Pools can be refreshed with more rewards, and events are emitted for transparency.

#### Usage

```move
// Create a new reward pool
let reward_coin = 100// ... obtain reward tokens
let loyalty_per_unit = 10; 
let reward_per_unit = 1; // 10 Loyalty tokens per reward token
let minimum_expected_reward = 10; 
deposit_pool::reward_program::new_reward_pool<Loyalty, Reward>(reward_coin, loyalty_rate, reward_rate, ctx);

// Add more rewards to the pool
deposit_pool::reward_program::reward_fresh(pool, additional_reward_coin);

// Claim rewards by spending loyalty tokens
deposit_pool::reward_program::claim(pool, loyalty_token, policy, Some(minimum_expected_reward), ctx);
```

## Deployment

The project includes an automated deployment script that:
1. Starts a local Sui node if remote RPC is not provided
2. Sets up the environment
3. Publishes all contracts
4. Initializes the faucet and deposit pool with initial liquidity

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

## Security Features

The contracts include several security measures:
- Withdrawal limits (configurable percentage) prevent large withdrawals
- Fixed exchange rates prevent manipulation
- Shared object model ensures equal access
- Idempotent deployment process
- Retry mechanisms for faucet operations
- Admin controls for deposit pool and reward pool configuration

## Configuration

Default values in deployment:
- Total Supply: 10^19 tokens
- Initial Faucet Amount: 50% of total supply
- Exchange Rate: 10 TALUS/SUI
- Withdrawal Limit: 50% per transaction

These values can be customized during deployment through the interactive prompts.
