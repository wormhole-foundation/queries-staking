# Wormhole Query Type Staking System

## About

The Wormhole Query Staking System is a decentralized staking infrastructure that creates isolated staking pools for different types of Wormhole query bundles .i.e. all EVM query types or all Solana query types. Each pool implements a decay mechanism where staked tokens gradually become claimable as fees over time, compensating for the query access granted.

## Architecture

### Components

The staking system consists of two core contracts a query type factory contract that acts as the deployment and configuration hub and a query type pool contract that manages stake.

#### Query Type Staking Pool

The `QueryTypeStakingPool` contract manages the actual staking operations for a specific query type. When users stake their tokens, they commit them for a defined period consisting of two phases: a lockup period where tokens cannot be withdrawn, followed by an access period where the stake gradually decays according to a pre-set rate. This decay mechanism creates a predictable fee stream that compensates the protocol for providing query access.

Each pool maintains comprehensive state about every staker, including their stake amount, when they staked, and how much decay has been claimed. The contract enforces minimum stake amounts and maximum pool capacity to ensure healthy pool economics. It also tracks conversion rates between staked tokens and query credits through a historical conversion table, allowing the system to adjust economics over time without affecting existing stakes.

The decay calculation happens continuously in the background, with the contract automatically processing any accrued decay whenever a user interacts with their stake. The decay rate, set at pool creation and immutable thereafter, determines what percentage of the time-based decay becomes fees. For example, with a 50% decay rate and a 60-day access period, a stake would lose 25% of its value as fees after 30 days.

Beyond basic staking, the pool supports advanced features like signer delegation, where stakers can authorize another address to perform signing operations on their behalf while retaining ownership of the staked tokens. This separation of concerns is particularly useful for seperating the staking address from the address whose signature is used in api requests. The contract has the ability to block addresses from staking that violate terms of services.

#### Query Type Staking Pool Factory

The `QueryTypeStakingPoolFactory` contract serves as the system's control center, responsible for deploying new pools and maintaining global configuration that affects all pools. When deploying a new pool, the factory ensures that each bundle query types has exactly one pool, preventing fragmentation and confusion. It maintains a registry mapping query types to their pool addresses, making it easy for users and integrators to find the correct pool for their needs.

The factory holds configuration, most notably the fee recipient address that receives decay fees from all pools. This fee management system ensures consistent handling of protocol revenues while allowing the flexibility to update the recipient as needed. Only the factory owner can create new pools or update the fee recipient, providing controlled expansion of the system while preventing unauthorized pool creation.

During pool deployment, the factory sets several immutable parameters that define the pool's economic model. These include the decay rate that determines fee extraction, the initial conversion rate between stakes and query credits, and the pool owner who will manage the pool's configurable parameters. The factory also ensures all pools use the same staking token (the W token), maintaining consistency across the ecosystem.

## Development

### Build and test

This project uses [Foundry](https://github.com/foundry-rs/foundry). Follow [these instructions](https://github.com/foundry-rs/foundry#installation) to install it.

Clone the repo.

Install dependencies & run tests.

```bash
forge install
forge build
forge test
```

### Spec and lint

This project uses [scopelint](https://github.com/ScopeLift/scopelint) for linting and spec generation. Follow [these instructions](https://github.com/ScopeLift/scopelint?tab=readme-ov-file#installation) to install it.

To use scopelint's linting functionality, run:

```bash
scopelint check # check formatting
scopelint fmt # apply formatting changes
```

To use scopelint's spec generation functionality, run:

```bash
scopelint spec
```

<<<<<<< HEAD
### Deployment

```bash
# Deploy to network
forge script script/Deploy.s.sol \
  --rpc-url <RPC_URL> \
  --broadcast \
  --verify

# Required environment variables:
# PRIVATE_KEY - Deployer's private key
# W_TOKEN_ADDRESS - Wormhole token contract address
```

## Integration Guide

### Setting Up a Staking Pool

=======
1. **Deploy Pool via Factory**:
```solidity
address pool = factory.createStakingPool(
    0x0001000000000000000000000000000000000000000000000000000000000000, // Query type
    msg.sender,                                                            // Pool owner
    0x0000000000000000000000000000000000000000000000000000000000000001, // Initial entry
    50                                                                     // 50% decay rate
);
```

2. **Configure Pool Parameters**:
```solidity
pool.setLockupPeriod(30 days);
pool.setAccessPeriod(60 days);
pool.setMinimumStake(100 * 10**18);
pool.setStakingTokenCapacity(1000000 * 10**18);
```

### Staking Operations

```solidity
// Approve tokens first
token.approve(poolAddress, stakeAmount);

// Stake tokens
pool.stake(stakeAmount);

// Delegate signing authority
pool.setSigner(hotWalletAddress);

// Check stake balance (accounting for decay)
uint256 currentBalance = pool.stakeBalances(myAddress);

// Unstake (after lockup period)
pool.unstake(unstakeAmount);
```

## Security Considerations

- **Decay Timing**: Claims are processed atomically with stake/unstake operations to prevent gaming
- **Reentrancy Protection**: Uses checks-effects-interactions pattern
- **Safe Token Handling**: OpenZeppelin's SafeERC20 for all token transfers
- **Access Controls**: Owner-only functions for critical parameters
- **Capacity Limits**: Global and per-staker limits to prevent excessive concentration
- **Blocklisting**: Compliance mechanism that jails stakes while preventing unstaking
- **Immutable Decay Rate**: Cannot be changed after pool deployment to ensure predictability

## Configuration Profiles

| Profile | Optimizer | Runs | Fuzz Runs | Use Case |
|---------|-----------|------|-----------|----------|
| default | Enabled | 10,000,000 | 256 | Production deployment |
| ci | Enabled | 10,000,000 | 5,000 | Continuous integration |
| lite | Disabled | - | 32 | Development |
=======
This command will use the names of the contract's unit tests to generate a human readable spec. It will list each contract, its constituent functions, and the human readable description of functionality each unit test aims to assert.
>>>>>>> 46ff45f (Another pass)

## License

Apache-2.0

⚠ This software is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License. Or plainly spoken - this is a very complex piece of software which targets a bleeding-edge, experimental smart contract runtime. Mistakes happen, and no matter how hard you try and whether you pay someone to audit it, it may eat your tokens, set your printer on fire or startle your cat. Cryptocurrencies are a high-risk investment, no matter how fancy.
