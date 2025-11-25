## Dependency Test Contract
This package contains a test contract designed to verify dependencies between the talus package and this package.

### Test Procedure
1. Configure Client Environment
Set up your Sui client for the desired network.

Devnet Configuration:

RPC: `https://rpc.ssfn.devnet.production.taluslabs.dev`

Faucet: `https://faucet.devnet.production.taluslabs.dev/gas`

Explorer: `https://explorer.devnet.taluslabs.dev/`

2. Fund Wallet
Acquire at least two native SUI gas objects (coins) using the faucet link provided above or the Discord faucet.

3. Mint US Tokens
Retrieve the required Object IDs (Faucet ID, Token IDs) from the registry files below:

Devnet: [objects.devnet.json](https://storage.googleapis.com/production-talus-tge-objects/v1.1.2/objects.devnet.json)

Testnet: [objects.testnet.json](https://storage.googleapis.com/production-talus-tge-objects/v1.1.2/objects.testnet.json)

Mainnet: [objects.mainnet.json](https://storage.googleapis.com/production-talus-tge-objects/v1.1.2/objects.mainnet.json)

Mint Command: Replace variables (starting with $) with the actual IDs found in the JSON files above.

```Bash
sui client call --package <faucet package id> --module faucet --function mint \
    --type-args <token package id>::us::US \
    --type-args 0x2::sui::SUI \
    --args <faucet object id> \
    --args <sui coin id> \
    --dry-run
```

Important: After minting, record your US Token Object ID. Ensure the `<token package id>` used matches the address defined in ../../talus/Move.lock under the corresponding environment and the faucet is under the same deployment sequence.

4. Publish and Test
Publish the package and execute the dependency test function.

```Bash
# 1. Publish the package
sui client publish . --dry-run

# 2. Call the test function
# Replace <dependency package id> with the ID generated from the publish step
# Replace <US token id> with the ID obtained in Step 3
sui client call --package <dependency package id> --module test --function half --arg

```
