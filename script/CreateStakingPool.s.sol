// SPDX-License-Identifier: Apache-2.0
// slither-disable-start reentrancy-benign

pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {QueryTypeStakerFactory} from "src/QueryTypeStakerFactory.sol";

contract CreateStakingPool is Script {
  function run() public {
    // Get the deployer's private key and factory address from environment
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address factoryAddress = vm.envAddress("FACTORY_ADDRESS");

    // Get pool parameters from environment
    bytes32 queryType = vm.envBytes32("QUERY_TYPE");
    bytes32 initialEntry = vm.envBytes32("INITIAL_ENTRY");
    uint8 decayRate = uint8(vm.envUint("DECAY_RATE"));

    // Start broadcasting transactions
    vm.startBroadcast(deployerPrivateKey);

    // Pool owner is the same as deployer
    address poolOwner = vm.addr(deployerPrivateKey);

    // Create the staking pool
    QueryTypeStakerFactory factory = QueryTypeStakerFactory(factoryAddress);
    address poolAddress = factory.createStakingPool(queryType, poolOwner, initialEntry, decayRate);

    vm.stopBroadcast();

    // Log the pool address
    console.log("Staking pool created at:", poolAddress);
  }
}
