// SPDX-License-Identifier: Apache-2.0
// slither-disable-start reentrancy-benign

pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {QueryTypeStakerFactory} from "src/QueryTypeStakerFactory.sol";

contract Deploy is Script {
  QueryTypeStakerFactory public factory;

  function run() public {
    // Get the deployer's private key and W token address from environment
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address wTokenAddress = vm.envAddress("W_TOKEN_ADDRESS");

    // Start broadcasting transactions
    vm.startBroadcast(deployerPrivateKey);
    address deployer = vm.addr(deployerPrivateKey);

    // Deploy the factory
    factory = new QueryTypeStakerFactory(deployer, wTokenAddress);

    vm.stopBroadcast();
  }
}
