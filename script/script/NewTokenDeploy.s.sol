// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {Token} from "../../src/tokens/Token.sol"; 

contract DeployNewTokens is Script {
    function run() external {
        // Load deployer private key and token params from .env
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        // Token D
        Token tokenD = new Token("Token D", "TKND", 1_000_000 ether);
        console2.log("Token D deployed to:", address(tokenD));

        // Token E
        Token tokenE = new Token("Token E", "TKNE", 2_000_000 ether);
        console2.log("Token E deployed to:", address(tokenE));

        // Token F
        Token tokenF = new Token("Token F", "TKNF", 3_000_000 ether);
        console2.log("Token F deployed to:", address(tokenF));

        vm.stopBroadcast();
    }
}
