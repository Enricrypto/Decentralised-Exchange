// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../../src/router/Router.sol"; 
import "../../src/core/Factory.sol"; 

contract DeployRouterScript is Script {
    function run() external {
        // Replace with your deployed Factory contract address
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");

        // Start broadcasting transaction
        vm.startBroadcast();

        // Deploy Router with Factory address
        Router router = new Router(factoryAddress);

        vm.stopBroadcast();

        console.log("Router deployed to:", address(router));
    }
}
