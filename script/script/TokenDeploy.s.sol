// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {Token} from "../../src/tokens/Token.sol";

contract TokenDeploy is Script {
    function run() external {
        // Load deployer private key and token params from .env
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        // Token A
        Token tokenA = new Token("Token A", "TKNA", 1_000_000 ether);
        console2.log("Token A deployed to:", address(tokenA));

        // Token B
        Token tokenB = new Token("Token B", "TKNB", 2_000_000 ether);
        console2.log("Token B deployed to:", address(tokenB));

        // Token C
        Token tokenC = new Token("Token C", "TKNC", 3_000_000 ether);
        console2.log("Token C deployed to:", address(tokenC));

        vm.stopBroadcast();
    }
}
