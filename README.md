# Wormhole Query Type Staking System

## About

The Wormhole Query Staking System is a decentralized staking infrastructure that creates isolated staking pools for different types of Wormhole query bundles, e.g., all EVM query types or all Solana query types. Each pool implements a decay mechanism where staked tokens gradually become claimable as fees over time, compensating for the query access granted.

## Architecture

### Components

The staking system consists of two core contracts: a query-type factory contract that acts as the deployment and configuration hub, and a query-type pool contract that manages stake.

#### Query Type Staking Pool

The `QueryTypeStakingPool` contract manages the actual staking operations for a specific query type. When users stake their tokens, they commit them for a defined period consisting of two phases: a lockup period during which tokens cannot be withdrawn, followed by an access period during which staking provides access to queries but can be withdrawn at any time. Stake decays gradually according to a preset rate. This decay mechanism creates a predictable fee stream that compensates the protocol for providing query access.

Each pool maintains a comprehensive state about every staker, including their stake amount, when they staked, and how much decay has been claimed. The contract enforces minimum stake amounts and maximum pool capacity to ensure healthy pool economics. It also tracks conversion rates between staked tokens and query credits through a historical conversion table, allowing the system to adjust economics over time without affecting existing stakes.

The decay calculation happens continuously in the background, with the contract automatically processing any accrued decay whenever a user interacts with their stake. The decay rate, set at pool creation and immutable thereafter, determines what percentage of the time-based decay becomes fees. For example, with a 50% decay rate and a 60-day access period, a stake would lose 25% of its value as fees after 30 days.

Beyond basic staking, the pool supports advanced features like signer delegation, where stakers can authorize another address to perform signing operations on their behalf while retaining ownership of the staked tokens. This separation of concerns is particularly useful for separating the staking address from the address whose signature is used in api requests. The contract has the ability to block addresses from staking that violate the terms of service.

#### Query Type Staking Pool Factory

The `QueryTypeStakingPoolFactory` contract serves as the system's control center, responsible for deploying new pools and maintaining global configuration that affects all pools. When deploying a new pool, the factory ensures that each bundle of query types has exactly one pool, preventing fragmentation and confusion. It maintains a registry mapping query types to their pool addresses, making it easy for users and integrators to find the correct pool for their needs.

The factory holds configuration, most notably the fee recipient address that receives decay fees from all pools. Only the factory owner can create new pools or update the fee recipient, providing controlled expansion of the system while preventing unauthorized pool creation.

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

## License

Apache-2.0

⚠ This software is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License. Or plainly spoken - this is a very complex piece of software which targets a bleeding-edge, experimental smart contract runtime. Mistakes happen, and no matter how hard you try and whether you pay someone to audit it, it may eat your tokens, set your printer on fire or startle your cat. Cryptocurrencies are a high-risk investment, no matter how fancy.
