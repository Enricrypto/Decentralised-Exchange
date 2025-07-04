// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Script.sol";
import {Factory} from "../../src/core/Factory.sol";

contract DeployFactory is Script {
    function run() external {
        // Load deployer private key from environment variable
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Start broadcasting transactions using deployer key
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the Factory contract
        Factory factory = new Factory();

        // Log the deployed contract address
        console2.log("Factory deployed at:", address(factory));

        vm.stopBroadcast();
    }
}
