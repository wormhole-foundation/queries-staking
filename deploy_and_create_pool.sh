#!/bin/bash

# Deploy and Create Staking Pool Script
# This script deploys the QueryTypeStakerFactory and creates a staking pool
# Uses devnet configuration from ../wormhole/scripts/devnet-consts.json

set -e  # Exit on error

echo "=== Query Staking Pool Deployment Script ==="

# Devnet configuration from devnet-consts.json (Ethereum chain 2)
RPC_URL="http://localhost:8545"
PRIVATE_KEY="0x4f3edf983ac636a65a842ce7c78d9aa706d3b113bce9c46f30d7d21715b23b1d"
W_TOKEN_ADDRESS="0x2D8BE6BF0baA74e0A907016679CaE9190e80dD0A"

echo "Using RPC URL: $RPC_URL"
echo "Using W_TOKEN_ADDRESS: $W_TOKEN_ADDRESS"
echo "Using devnet test wallet (0x90F8bf6A479f320ead074411a4B0e7944Ea8c9C1)"

# Export variables for the forge scripts
export PRIVATE_KEY
export W_TOKEN_ADDRESS

# Pool creation parameters with defaults
QUERY_TYPE=${QUERY_TYPE:-"0x0000000000000000000000000000000000000000000000000000000000000001"}
INITIAL_ENTRY=${INITIAL_ENTRY:-"0x0000000000000000000000000000000000000000000000000000000000000001"}
DECAY_RATE=${DECAY_RATE:-"10"}

echo "Pool parameters:"
echo "  QUERY_TYPE: $QUERY_TYPE"
echo "  INITIAL_ENTRY: $INITIAL_ENTRY"
echo "  DECAY_RATE: $DECAY_RATE"

# Step 1: Deploy the factory
echo ""
echo "Step 1: Deploying QueryTypeStakerFactory..."
forge script script/Deploy.s.sol:Deploy \
    --rpc-url "$RPC_URL" \
    --broadcast

# Extract the factory address from the broadcast JSON file
BROADCAST_FILE="broadcast/Deploy.s.sol/1337/run-latest.json"

if [ ! -f "$BROADCAST_FILE" ]; then
    echo "Error: Broadcast file not found at $BROADCAST_FILE"
    exit 1
fi

# Extract the contractAddress from the first transaction (the factory deployment)
FACTORY_ADDRESS=$(jq -r '.transactions[0].contractAddress' "$BROADCAST_FILE")

if [ -z "$FACTORY_ADDRESS" ] || [ "$FACTORY_ADDRESS" == "null" ]; then
    echo "Warning: Could not automatically extract factory address"
    echo "Please check the deployment output above and set FACTORY_ADDRESS manually"
    exit 1
fi

echo "Factory deployed at: $FACTORY_ADDRESS"

# Step 2: Create a staking pool
echo ""
echo "Step 2: Creating staking pool..."

export FACTORY_ADDRESS
export QUERY_TYPE
export INITIAL_ENTRY
export DECAY_RATE

forge script script/CreateStakingPool.s.sol:CreateStakingPool \
    --rpc-url "$RPC_URL" \
    --broadcast

# Extract the pool address from the broadcast JSON file
POOL_BROADCAST_FILE="broadcast/CreateStakingPool.s.sol/1337/run-latest.json"

if [ ! -f "$POOL_BROADCAST_FILE" ]; then
    echo "Warning: Pool broadcast file not found at $POOL_BROADCAST_FILE"
else
    # The pool address is in topics[2] of the CreateQueryTypeStakingPool event
    # Event signature: CreateQueryTypeStakingPool(bytes32 indexed queryType, address indexed poolAddress)
    POOL_ADDRESS=$(jq -r '.receipts[0].logs[] | select(.topics[0] == "0x34d4b91c04bf254b71c435c46e26f1c0b6ec05b426b3bbebb5a80d3e71c030db") | .topics[2]' "$POOL_BROADCAST_FILE" | sed 's/0x000000000000000000000000/0x/')

    if [ -n "$POOL_ADDRESS" ] && [ "$POOL_ADDRESS" != "null" ]; then
        echo "Staking pool created at: $POOL_ADDRESS"
    fi
fi

echo ""
echo "=== Deployment Complete ==="
echo "Factory Address: $FACTORY_ADDRESS"
if [ -n "$POOL_ADDRESS" ]; then
    echo "Pool Address: $POOL_ADDRESS"
fi
