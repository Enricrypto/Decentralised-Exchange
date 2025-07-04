// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../core/Pair.sol";

contract Factory {
    // Maps tokenA => tokenB => pair address
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint
    );

    // Only one unique pool per token pair is allowed.
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair) {
        require(tokenA != tokenB, "Factory: IDENTICAL_ADDRESSES");
        // Sort tokens to avoid duplicates
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "Factory: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "Factory: PAIR_EXISTS");

        // Deploy new Pair contract with create2
        // type(Pair).creationCode gets the raw compiled bytecode of the Pair contract.
        bytes memory bytecode = abi.encodePacked(
            type(Pair).creationCode,
            abi.encode(address(this)) // Pass factory as constructor argument
        );
        // salt is computed by hashing the token addresses (sorted) — this ensures the salt is unique for each token pair.
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        // assembly calls the create2 opcode:
        assembly {
            // create2 allows deterministic contract deployment, meaning the address of the Pair contract will always be the same for a
            // given input (in this case: token0 and token1)
            // - 0 is the amount of ETH sent (none here)
            // - add(bytecode, 32) is the location of the actual code in memory (skipping the first 32 bytes which is the length prefix of the bytecode bytes array)
            // - mload(bytecode) loads the size of the bytecode
            // - salt is the salt used to deterministically generate the address
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        Pair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping both ways
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }
}
