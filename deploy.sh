#!/bin/bash

set -euo pipefail

###########################################
# Configuration Variables
###########################################
SUI="sui"
TOTAL_SUPPLY="10^19"
INITIAL_SPLIT_AMOUNT=0 
BASE_APY=2
APY_DECIMAL="2" # an Option<u8> value, "2" means 1%, "3" means 0.1%, "4" means 0.01%, etc

###########################################
# Helper Functions
###########################################

# Calculate large numbers using bc
_calculate_amount() {  # Changed from _calculate
    echo "scale=0; $1" | bc
}

# Helper functions for idempotency
_checkProcess() {
    pgrep -f "$1" >/dev/null
    return $?
}

# Run a command in the background
_evalBg() {
    eval "$@" &>/dev/null & disown;
}

# Get faucet coins with retry mechanism
_getFaucetCoins() {
    local max_attempts=5
    local attempt=1
    local wait_time=5

    while ! $SUI client gas | grep -q "0x"; do
        if [ $attempt -gt $max_attempts ]; then
            echo "Failed to get faucet coins after $max_attempts attempts"
            exit 1
        fi
        
        echo "Attempt $attempt: Getting faucet coins..."
        if $SUI client faucet; then
            echo "Faucet request successful, waiting for coins..."
            sleep $wait_time
            if $SUI client gas | grep -q "0x"; then
                echo "Coins received successfully"
                break
            fi
        else
            echo "Faucet request failed, retrying in $wait_time seconds..."
        fi
        
        attempt=$((attempt + 1))
        wait_time=$((wait_time + 5))
        sleep $wait_time
    done
}

###########################################
# User Input Configuration
###########################################

# Calculate default initialization amount
DEFAULT_INIT=$(_calculate_amount "$TOTAL_SUPPLY/2")

# Collect user inputs with descriptive prompts
read -p "Enter RPC URL (default: http://127.0.0.1:9000): " RPC_URL
read -p "Enter environment alias (default: local): " ENV_ALIAS
read -p "Enter faucet source size (default: $DEFAULT_INIT (half)): " INIT_AMOUNT
read -p "Enter exchange rate Talus/Sui (default: 10): " EXCHANGE_RATE
read -p "Enter max withdrawal ratio every time (default: 50 (0~100)): " WITHDRAWAL_PCT
read -p "Deploy and initialize faucet? (y/N): " DEPLOY_FAUCET

# Set default values for configuration
RPC_URL=${RPC_URL:-"http://127.0.0.1:9000"}
ENV_ALIAS=${ENV_ALIAS:-"local"}
EXCHANGE_RATE=${EXCHANGE_RATE:-10}
WITHDRAWAL_PCT=${WITHDRAWAL_PCT:-50}
DEPLOY_FAUCET=${DEPLOY_FAUCET:-"n"}

###########################################
# Environment Setup
###########################################

# Configure Sui client environment if not already set
if ! $SUI client active-env | grep -q "$ENV_ALIAS"; then
    echo "Setting up client with RPC: $RPC_URL and alias: $ENV_ALIAS"
    $SUI client new-env --alias "$ENV_ALIAS" --rpc "$RPC_URL"
    $SUI client switch --env "$ENV_ALIAS"
fi

# Start local node if not running
if ! _checkProcess "$SUI start"; then
    echo "Starting Node"
    start_node="RUST_LOG=\"off,sui_node=error\" $SUI start --with-faucet --force-regenesis"
    _evalBg "${start_node}"
    echo "Waiting for the node to start"
    sleep 15
else
    echo "Node already running"
fi

###########################################
# Token Deployment
###########################################

# Get active address
echo "get address"
USER=$($SUI client active-address)
echo "Active address: \"$USER\""

# Ensure we have gas
if ! $SUI client gas | grep -q "0x"; then
    _getFaucetCoins
fi

# Deploy main token contract
echo "Publishing Token contract:"
TOKEN_CONTRACT_ID=$($SUI client publish ./talus --json| jq -er ".objectChanges[] | select(.packageId) | .packageId")
TALUS_COIN=$($SUI client balance --with-coins --json | jq -er '.[0][][1][] | select(.coinType | contains("::us::US")) | .coinObjectId')
sleep 3
echo "Token Contract at: \"$TOKEN_CONTRACT_ID\""
echo "Talus coin at : \"$TALUS_COIN\""

###########################################
# Faucet Deployment (Optional)
###########################################
# Calculate split amounts for faucet
if [ -z "$INIT_AMOUNT" ]; then
    SPLIT_AMOUNT=$DEFAULT_INIT
else
    SPLIT_AMOUNT=$(_calculate_amount "$TOTAL_SUPPLY-$INIT_AMOUNT")
fi

if [[ "${DEPLOY_FAUCET,,}" =~ ^(y|yes)$ ]]; then

    echo "Split coin"
    _spliter=$($SUI client split-coin --coin-id $TALUS_COIN --amounts $SPLIT_AMOUNT)
    
    # Deploy and initialize faucet
    echo "Publishing Faucet Contract:"
    FaucetContractID=$($SUI client publish ./faucet --json | jq -er ".objectChanges[] | select(.packageId) | .packageId")
    sleep 3
    echo "Faucet contract at: \"$FaucetContractID\""

    echo "Initiate faucet"
    FaucetID=$($SUI client call --package $FaucetContractID --module faucet --function new \
        --type-args $TOKEN_CONTRACT_ID::us::US --type-args 0x2::sui::SUI \
        --args $TALUS_COIN --args $EXCHANGE_RATE --args $WITHDRAWAL_PCT \
        --json | jq -er '.objectChanges[] | select(.type == "created") |.objectId')
    echo "faucet at: $FaucetID"
else
    echo "Skipping faucet deployment"
fi

###########################################
# Loyalty Program Setup
###########################################

# Prepare coins for reward pool
sleep 3
echo "Split coin for reward pool"
TALUS_COIN=$($SUI client balance --with-coins --json | jq -er '.[0][][1][] | select(.coinType | contains("::us::US")) | .coinObjectId')
RESERVE_SIZE=$(_calculate_amount "($TOTAL_SUPPLY*85/100)-$SPLIT_AMOUNT")
_spliter=$($SUI client split-coin --coin-id $TALUS_COIN --amounts $RESERVE_SIZE)

# Deploy Loyalty Token Contract
echo "Deploy Loyalty Token Contract"
script=$($SUI client publish ./loyalty --json) 
LoyaltyTokenContractID=$(echo $script | jq -er '.objectChanges[] | select(.packageId) | .packageId')
LoyaltyTreasuryCap=$(echo $script | jq -er '.objectChanges[] | select(.objectType!= null and(.objectType | contains("TreasuryCap<"))) | .objectId')

# Deploy reward pool and Deposit Pool
sleep 3
echo "Deploy reward pool and Deposit Pool"
LoyaltyProgramContractID=$($SUI client publish ./deposit_pool --json | jq -er ".objectChanges[] | select(.packageId) | .packageId")
sleep 3
echo "Loyalty Program Contract at: \"$LoyaltyProgramContractID\""
echo "Loyalty Token Contract at: \"$LoyaltyTokenContractID\""
echo "Loyalty Token Cap at: \"$LoyaltyTreasuryCap\""

# Initialize deposit pool
echo "Init Deposit pool"
script=$($SUI client call --package $LoyaltyProgramContractID --module deposit_pool --function new \
        --type-args $TOKEN_CONTRACT_ID::us::US --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \
        --args $LoyaltyTreasuryCap --args $BASE_APY --args [] --args false --args 0 \
        --json)
ADMIN_CAP=$(echo $script| jq -er '.objectChanges[] | select(.objectType!= null and(.objectType | contains("AdminCap"))) | .objectId')
DEPOSIT_POOL=$(echo $script| jq -er '.objectChanges[] | select(.objectType!= null and(.objectType | contains("DepositPool"))) | .objectId')
echo "Pool at: $DEPOSIT_POOL"
echo "admin cap at $ADMIN_CAP"

# Setup Reward Pool
sleep 3
echo "initiate reward pool"
REWARD_POOL=$($SUI client call --package $LoyaltyProgramContractID --module reward_pool --function new \
        --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \
        --type-args $TOKEN_CONTRACT_ID::us::US  \
        --args $TALUS_COIN --args 1 --args 1 --json | jq -er '.objectChanges[] | select(.objectType!= null and(.objectType | contains("RewardPool"))) | .objectId')

sleep 3
echo "reward pool at $REWARD_POOL"
echo "register reward pool"

# Register reward pool
PolicyID=$($SUI client call --package $LoyaltyProgramContractID --module deposit_pool --function add_reward_program \
        --type-args $LoyaltyProgramContractID::reward_pool::RewardProgram \
        --type-args $TOKEN_CONTRACT_ID::us::US \
        --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \
        --args $DEPOSIT_POOL --args $ADMIN_CAP \
        --gas-budget 30000000 --json| jq -er '.objectChanges[] | select(.objectType!= null and(.objectType | contains("TokenPolicy"))) | .objectId' )
        
echo "Policy at $PolicyID"

###########################################
# Test Commands (Commented Out)
###########################################

# Test mint
# $SUI client call --package $FaucetContractID --module faucet --function mint \
#         --type-args $TOKEN_CONTRACT_ID::us::US --type-args 0x2::sui::SUI \
#         --args $FaucetID --args <sui coin>\
#         --dry-run

# echo "test refund"
# $SUI client call --package $FaucetContractID --module faucet --function refund \
#         --type-args $TOKEN_CONTRACT_ID::us::US --type-args 0x2::sui::SUI \
#         --args $FaucetID --args <us coin> \
#         --dry-run

# echo "Test deposit to pool"
#  $SUI client call --package $LoyaltyProgramContractID --module deposit_pool \
#          --function deposit \
#          --type-args $TOKEN_CONTRACT_ID::us::US \
#          --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \
#          --args $DEPOSIT_POOL \
#          --args <us coin id> \
#          --args 0 --args $USER \
#          --args [] --args 0x6 --dry-run

# echo "Test withdrawal from pool"
# $SUI client call --package $LoyaltyProgramContractID --module deposit_pool --function withdraw \
#         --type-args $TOKEN_CONTRACT_ID::us::US --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \
#         --args $DEPOSIT_POOL --args <receipt id>\
#         --args 0x6 --gas-budget 10000000

# echo "Test claim reward"
# $SUI client call --package $LoyaltyProgramContractID --module reward_pool \
#         --function claim \
#         --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \ 
#         --type-args $TOKEN_CONTRACT_ID::us::US 
#         --args $DEPOSIT_POOL --args <token id> --args $PolicyID --args [] \

# echo "Test add term"
# $SUI client call --package $LoyaltyProgramContractID --module deposit_pool \
#         --function upsert_lock_term \
#         --type-args $TOKEN_CONTRACT_ID::us::US \
#         --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \
#         --args $DEPOSIT_POOL --args $ADMIN_CAP --args 30 --args 10 --dry-run 

# $SUI client call --package $LoyaltyProgramContractID --module deposit_pool \
#         --function upsert_lock_term \
#         --type-args $TOKEN_CONTRACT_ID::us::US \
#         --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \
#         --args $DEPOSIT_POOL --args $ADMIN_CAP --args 60 --args 20 --dry-run 


# echo "Test deposit to pool"
#  $SUI client call --package $LoyaltyProgramContractID --module deposit_pool \
#          --function deposit \
#          --type-args $TOKEN_CONTRACT_ID::us::US \
#          --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \
#          --args $DEPOSIT_POOL \
#          --args <us coin id> \
#          --args 30 --args $USER \
#          --args [] --args 0x6 --dry-run

# should error now
# $SUI client call --package $LoyaltyProgramContractID --module deposit_pool \
#         --function upgrade_term \
#         --type-args $TOKEN_CONTRACT_ID::us::US \
#         --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \
#         --args $DEPOSIT_POOL --args <receipt id> --args 60 \
#         --args [20] --args 0x6 --dry-run 

# $SUI client call --package $LoyaltyProgramContractID --module deposit_pool \
#         --function enable_extending_terms \
#         --type-args $TOKEN_CONTRACT_ID::us::US \
#         --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \
#         --args $DEPOSIT_POOL --args $ADMIN_CAP --dry-run 

# $SUI client call --package $LoyaltyProgramContractID --module deposit_pool \
#         --function upgrade_term \
#         --type-args $TOKEN_CONTRACT_ID::us::US \
#         --type-args $LoyaltyTokenContractID::loyalty::LOYALTY \
#         --args $DEPOSIT_POOL --args <receipt id> --args 60 \
#         --args [20] --args 0x6 --dry-run 