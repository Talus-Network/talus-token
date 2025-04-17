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
read -p "Enter initial amount (default: $DEFAULT_INIT (half)): " INIT_AMOUNT
read -p "Enter exhcnage rate Talus/Sui (default: 10): " EXCHANGE_RATE
read -p "Enter max withdrawal ratio every time (default: 50 (0~100)): " WITHDRAWAL_PCT


# Set default values if no input provided
RPC_URL=${RPC_URL:-"http://127.0.0.1:9000"}
ENV_ALIAS=${ENV_ALIAS:-"local"}
EXCHANGE_RATE=${EXCHANGE_RATE:-10}
WITHDRAWAL_PCT=${WITHDRAWAL_PCT:-50}

if [ -z "$INIT_AMOUNT" ]; then
    SPLIT_AMOUNT=$DEFAULT_INIT
else
    SPLIT_AMOUNT=$(_calculate "$TOTAL_AMOUNT-$INIT_AMOUNT")
fi

# ...existing code until setup client section...

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

_getCoins() {
    data=$($SUI client gas | awk -F '│' '/0x/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')

    counter=1

    # Loop through each line
    while IFS= read -r line; do
        eval "coinId_$counter=\"$line\""
        counter=$((counter + 1))
    done <<< "$data"

    # Print variables to verify
    for i in $(seq 1 $((counter - 1))); do
        eval "echo Coin ID \$i: \$coinId_$i"
    done

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
if ! _checkProcess "sui start"; then
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

_getCoins

echo "Publishing Token contract:"
TokenContractID=$($SUI client publish --gas-budget 300000000 ./talus --json| jq -r ".objectChanges[] | select(.packageId) | .packageId")
TalusCoin=$($SUI client balance --with-coins --json | jq -r '.[0][][1][] | select(.coinType | contains("::talus::TALUS")) | .coinObjectId')
sleep 3
echo "Token Contract at: \"$TokenContractID\""
echo "Talus coin at : \"$TalusCoin\""

echo "Split coin"
splitres=$($SUI client split-coin --coin-id $TalusCoin --amounts $SPLIT_AMOUNT --gas-budget 10000000)

echo "Publishing Faucet Contract:"
FaucetContractID=$($SUI client publish --gas-budget 30000000 ./faucet --json | jq -r ".objectChanges[] | select(.packageId) | .packageId")
sleep 3
echo "Faucet contract at: \"$FaucetContractID\""

echo "Initiate faucet"
FaucetID=$($SUI client call --package $FaucetContractID --module faucet --function initiate --type-args $TokenContractID::talus::TALUS --type-args 0x2::sui::SUI --args $TalusCoin --args $EXCHANGE_RATE --args $WITHDRAWAL_PCT --json | jq -r '.objectChanges[] | select(.type == "created") |.objectId')
echo "faucet at: $FaucetID"
# Initiate Faucet between $SUI and $Talus NPC if needed
# if [ -z "$NPCID" ]; then
#     echo "Initiating NPC:"
#     NPCID=$($SUI client call --package $PlayerContractID --module player --function initiate --args $coinId_3 --json | jq -r ".effects.created.[] | select(.owner.Shared) |.reference.objectId")
#     sleep 10
#     NPCEntity=$($SUI client dynamic-field $NPCID --json | jq -r '.data[] | select(.objectType | contains("entity::Entity")) | .objectId')
#     echo "NPC at: \"$NPCID\""
#     echo "NPC with entity: \"$NPCEntity\""
# fi
