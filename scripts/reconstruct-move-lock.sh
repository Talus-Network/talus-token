#!/usr/bin/env bash
#
# Reconstruct Move.lock for a deployed Sui Move package
#
# Usage:
#   ./reconstruct-move-lock.sh --package-id <id> --sui-version <tag> --repo-tag <tag> --package-dir <dir>
#
# Example:
#   ./reconstruct-move-lock.sh \
#     --package-id 0xee962a61432231c2ede6946515beb02290cb516ad087bb06a731e922b2a5f57a \
#     --sui-version mainnet-v1.59.1 \
#     --repo-tag v1.1.2 \
#     --package-dir talus \
#     --network mainnet

set -euo pipefail

# Default values
NETWORK="mainnet"
REPO_URL="https://github.com/Talus-Network/talus-token.git"
OUTPUT_DIR=""
DRY_RUN=false

# RPC endpoints
declare -A RPC_ENDPOINTS=(
    ["mainnet"]="https://fullnode.mainnet.sui.io:443"
    ["testnet"]="https://fullnode.testnet.sui.io:443"
    ["devnet"]="https://rpc.ssfn.devnet.production.taluslabs.dev:443"
)

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Reconstruct Move.lock for a deployed Sui Move package.

Required Options:
    --package-id ID       The deployed package ID (0x...)
    --sui-version TAG     Sui tools docker image tag (e.g., mainnet-v1.59.1)
    --repo-tag TAG        Git tag of the source code that was deployed
    --package-dir DIR     Directory containing Move.toml (e.g., talus, faucet)

Optional:
    --network NAME        Network: mainnet, testnet, devnet (default: mainnet)
    --repo-url URL        Git repository URL (default: Talus-Network/talus-token)
    --output-dir DIR      Output directory for Move.lock (default: current dir)
    --dry-run             Show what would be done without executing
    -h, --help            Show this help message

Example:
    $(basename "$0") \\
        --package-id 0xee962a61432231c2ede6946515beb02290cb516ad087bb06a731e922b2a5f57a \\
        --sui-version mainnet-v1.59.1 \\
        --repo-tag v1.1.2 \\
        --package-dir talus \\
        --network mainnet
EOF
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# Parse arguments
PACKAGE_ID=""
SUI_VERSION=""
REPO_TAG=""
PACKAGE_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --package-id)
            PACKAGE_ID="$2"
            shift 2
            ;;
        --sui-version)
            SUI_VERSION="$2"
            shift 2
            ;;
        --repo-tag)
            REPO_TAG="$2"
            shift 2
            ;;
        --package-dir)
            PACKAGE_DIR="$2"
            shift 2
            ;;
        --network)
            NETWORK="$2"
            shift 2
            ;;
        --repo-url)
            REPO_URL="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Validate required arguments
[[ -z "$PACKAGE_ID" ]] && error "Missing required argument: --package-id"
[[ -z "$SUI_VERSION" ]] && error "Missing required argument: --sui-version"
[[ -z "$REPO_TAG" ]] && error "Missing required argument: --repo-tag"
[[ -z "$PACKAGE_DIR" ]] && error "Missing required argument: --package-dir"

# Validate network
[[ -z "${RPC_ENDPOINTS[$NETWORK]:-}" ]] && error "Invalid network: $NETWORK. Use mainnet, testnet, or devnet"

RPC_URL="${RPC_ENDPOINTS[$NETWORK]}"
DOCKER_IMAGE="mysten/sui-tools:$SUI_VERSION"

log "Configuration:"
log "  Package ID:    $PACKAGE_ID"
log "  Sui Version:   $SUI_VERSION"
log "  Repo Tag:      $REPO_TAG"
log "  Package Dir:   $PACKAGE_DIR"
log "  Network:       $NETWORK"
log "  RPC URL:       $RPC_URL"
log "  Docker Image:  $DOCKER_IMAGE"

if $DRY_RUN; then
    log "DRY RUN - No changes will be made"
fi

# Step 1: Get chain ID from RPC
log "Fetching chain ID from $NETWORK..."
CHAIN_ID=$(curl -s "$RPC_URL" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"sui_getChainIdentifier","params":[]}' \
    | jq -r '.result')

[[ -z "$CHAIN_ID" || "$CHAIN_ID" == "null" ]] && error "Failed to fetch chain ID"
log "Chain ID: $CHAIN_ID"

# Step 2: Create temp directory and clone repo
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

log "Cloning $REPO_URL @ $REPO_TAG..."
if ! $DRY_RUN; then
    git clone --depth 1 --branch "$REPO_TAG" "$REPO_URL" "$TEMP_DIR/repo" 2>&1 | while read -r line; do
        log "  git: $line"
    done
fi

# Step 3: Verify package directory exists
PACKAGE_PATH="$TEMP_DIR/repo/$PACKAGE_DIR"
if ! $DRY_RUN && [[ ! -f "$PACKAGE_PATH/Move.toml" ]]; then
    error "Move.toml not found in $PACKAGE_DIR"
fi

# Step 4: Pull docker image
log "Pulling docker image $DOCKER_IMAGE..."
if ! $DRY_RUN; then
    docker pull "$DOCKER_IMAGE" 2>&1 | tail -3 | while read -r line; do
        log "  docker: $line"
    done
fi

# Step 5: Build the package to generate Move.lock
log "Building Move package..."
if ! $DRY_RUN; then
    docker run --rm \
        -v "$TEMP_DIR/repo:/workspace" \
        -w "/workspace/$PACKAGE_DIR" \
        "$DOCKER_IMAGE" \
        sui move build 2>&1 | while read -r line; do
        log "  build: $line"
    done
fi

# Step 6: Verify Move.lock was generated
MOVE_LOCK="$PACKAGE_PATH/Move.lock"
if ! $DRY_RUN && [[ ! -f "$MOVE_LOCK" ]]; then
    error "Move.lock was not generated"
fi

# Step 7: Add environment section
log "Adding [$NETWORK] environment section..."
if ! $DRY_RUN; then
    cat >> "$MOVE_LOCK" <<EOF

[env]

[env.$NETWORK]
chain-id = "$CHAIN_ID"
original-published-id = "$PACKAGE_ID"
latest-published-id = "$PACKAGE_ID"
published-version = "1"
EOF
fi

# Step 8: Output the result
if [[ -n "$OUTPUT_DIR" ]]; then
    OUTPUT_FILE="$OUTPUT_DIR/Move.lock"
else
    OUTPUT_FILE="./Move.lock"
fi

if ! $DRY_RUN; then
    cp "$MOVE_LOCK" "$OUTPUT_FILE"
    log "Move.lock written to: $OUTPUT_FILE"
    log ""
    log "=== Generated Move.lock ==="
    cat "$OUTPUT_FILE"
else
    log ""
    log "Would write Move.lock to: $OUTPUT_FILE"
    log "With env section:"
    cat <<EOF
[env.$NETWORK]
chain-id = "$CHAIN_ID"
original-published-id = "$PACKAGE_ID"
latest-published-id = "$PACKAGE_ID"
published-version = "1"
EOF
fi

log ""
log "Done!"
