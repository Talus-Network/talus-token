#!/bin/bash
SUI="sui"
TOTAL_AMOUNT="10^19"

# Helper function for large number calculations
_calculate() {
    echo "scale=0; $1" | bc
}

DEFAULT_INIT=$(_calculate "$TOTAL_AMOUNT/2")

# Add user input for RPC and alias
read -p "Enter RPC URL (default: http://127.0.0.1:9000): " RPC_URL
read -p "Enter environment alias (default: local): " ENV_ALIAS
read -p "Enter faucet source size (default: $DEFAULT_INIT (half)): " INIT_AMOUNT
read -p "Enter exhcnage rate Talus/Sui (default: 10): " EXCHANGE_RATE
read -p "Enter max withdrawal ratio every time (default: 50 (0~100)): " WITHDRAWAL_PCT
read -p "Deploy and initialize faucet? (y/N): " DEPLOY_FAUCET


# Set default values if no input provided
RPC_URL=${RPC_URL:-"http://127.0.0.1:9000"}
ENV_ALIAS=${ENV_ALIAS:-"local"}
EXCHANGE_RATE=${EXCHANGE_RATE:-10}
WITHDRAWAL_PCT=${WITHDRAWAL_PCT:-50}
DEPLOY_FAUCET=${DEPLOY_FAUCET:-"n"}

SPLIT_AMOUNT=0

# Setup client if needed
if ! $SUI client active-env | grep -q "$ENV_ALIAS"; then
    echo "Setting up client with RPC: $RPC_URL and alias: $ENV_ALIAS"
    $SUI client new-env --alias "$ENV_ALIAS" --rpc "$RPC_URL"
    $SUI client switch --env "$ENV_ALIAS"
fi

# Helper functions for idempotency
_checkProcess() {
    pgrep -f "$1" >/dev/null
    return $?
}

# Run a command in the background.
_evalBg() {
    eval "$@" &>/dev/null & disown;
}


# Get faucet coins if needed with retry
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

# Start node if not running
if ! _checkProcess "$SUI start"; then
    echo "Starting Node"
    start_node="RUST_LOG=\"off,sui_node=error\" $SUI start --with-faucet --force-regenesis"
    _evalBg "${start_node}"
    echo "Waiting for the node to start"
    sleep 15
else
    echo "Node already running"
fi

echo "get address"
USER=$($SUI client active-address)
echo "Active address: \"$USER\""

# Get faucet coins if needed
if ! $SUI client gas | grep -q "0x"; then
    _getFaucetCoins
fi

echo "Publishing Token contract:"
TokenContractID=$($SUI client publish --gas-budget 300000000 ./talus --json| jq -r ".objectChanges[] | select(.packageId) | .packageId")
TalusCoin=$($SUI client balance --with-coins --json | jq -r '.[0][][1][] | select(.coinType | contains("::us::US")) | .coinObjectId')
sleep 3
echo "Token Contract at: \"$TokenContractID\""
echo "Talus coin at : \"$TalusCoin\""


# Only deploy faucet if requested
if [[ "${DEPLOY_FAUCET,,}" =~ ^(y|yes)$ ]]; then
    
    if [ -z "$INIT_AMOUNT" ]; then
        SPLIT_AMOUNT=$DEFAULT_INIT
    else
        SPLIT_AMOUNT=$(_calculate "$TOTAL_AMOUNT-$INIT_AMOUNT")
    fi

    echo "Split coin"
    $SUI client split-coin --coin-id $TalusCoin --amounts $SPLIT_AMOUNT --gas-budget 10000000
    
    echo "Publishing Faucet Contract:"
    FaucetContractID=$($SUI client publish --gas-budget 30000000 ./faucet --json | jq -r ".objectChanges[] | select(.packageId) | .packageId")
    sleep 3
    echo "Faucet contract at: \"$FaucetContractID\""

    echo "Initiate faucet"
    FaucetID=$($SUI client call --package $FaucetContractID --module faucet --function initiate \
        --type-args $TokenContractID::us::US --type-args 0x2::sui::SUI \
        --args $TalusCoin --args $EXCHANGE_RATE --args $WITHDRAWAL_PCT \
        --json | jq -r '.objectChanges[] | select(.type == "created") |.objectId')
    echo "faucet at: $FaucetID"
else
    echo "Skipping faucet deployment"
fi


echo "Split coin for reward program"
TalusCoin=$($SUI client balance --with-coins --json | jq -r '.[0][][1][] | select(.coinType | contains("::us::US")) | .coinObjectId')
RESERVE_SIZE=$(_calculate "($TOTAL_AMOUNT*85/100)-$SPLIT_AMOUNT")
$SUI client split-coin --coin-id $TalusCoin --amounts $RESERVE_SIZE --gas-budget 10000000


echo "Deploy Reward Program and Deposit Pool"
LoyaltyProgramContractID=$($SUI client publish --gas-budget 30000000 ./deposit_pool --json | jq -r ".objectChanges[] | select(.packageId) | .packageId")
sleep 3
echo "Loyalty Program Contract at: \"$LoyaltyProgramContractID\""

echo "Deploy RLoyalty Token Contract"
LoyaltyTokenContractID=$($SUI client publish --gas-budget 30000000 ./loyalty --json | jq -r '.objectChanges[] | select(.packageId) | .packageId')
sleep 3
echo "Loyalty Token Contract at: \"$LoyaltyProgramContractID\""

echo "Init Reward Program and Deposit Pool"
# TODO

# echo "test mint"
# $SUI client call --package $FaucetContractID --module faucet --function mint \
#         --type-args $TokenContractID::us::US --type-args 0x2::sui::SUI \
#         --args $FaucetID --args <sui coin id> \
#         --dry-run
# echo "test refund"
# $SUI client call --package $FaucetContractID --module faucet --function refund \
#         --type-args $TokenContractID::us::US --type-args 0x2::sui::SUI \
#         --args $FaucetID --args <talus coin id> \
#         --dry-run