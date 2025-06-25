// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/Factory.sol";
import "../core/Pair.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract Router is ReentrancyGuard {
    using SafeERC20 for IERC20;

    Factory public factory;

    constructor(address _factory) {
        require(_factory != address(0), "Invalid factory");
        factory = Factory(_factory);
    }

    // Helper to get pair address from factory for tokens
    function getPair(
        address tokenA,
        address tokenB
    ) public view returns (address) {
        return factory.getPair(tokenA, tokenB);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired, // How much the user wants to add of tokenA
        uint amountBDesired, // How much the user wants to add of tokenB
        uint amountAMin, // Minimum tokenA accepted (slippage protection)
        uint amountBMin, // Minimum tokenB accepted (slippage protection)
        address to
    )
        external
        nonReentrant
        returns (uint amountA, uint amountB, uint liquidity)
    {
        // get/create pair
        address pairAddress = factory.getPair(tokenA, tokenB);
        if (pairAddress == address(0)) {
            pairAddress = factory.createPair(tokenA, tokenB);
        }

        Pair pair = Pair(pairAddress);

        // Fetch reserves in pool
        (uint reserve0, uint reserve1) = pair.getReserves();

        // Map reserves correctly to tokenA/tokenB
        (uint reserveA, uint reserveB) = tokenA == pair.token0()
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        // Compute optimal amounts to add
        if (reserveA == 0 && reserveB == 0) {
            // Pool is empty (first liquidity provider)
            // No ratio yet, so accept user's desired amounts as is
            amountA = amountADesired;
            amountB = amountBDesired;
        } else {
            // Pool exists and has reserves, so maintain the ratio
            // Calculate optimal amount of token B given amountADesired
            // If you want to add amountADesired of token A, the correct matching amount of token B — to maintain pool ratio — is amountBOptimal.
            uint amountBOptimal = quote(amountADesired, reserveA, reserveB);

            // Is the amount of token B you’re willing to provide (amountBDesired) at least as much as
            // what’s needed to match token A (amountBOptimal).
            if (amountBOptimal <= amountBDesired) {
                // The optimal amount of B needed is less than or equal to what user wants to provide

                // Check if optimal B amount satisfies minimum required (slippage protection)
                require(amountBOptimal >= amountBMin, "Insufficient B amount");

                // We use all of amountADesired and we reduce token B to amountBOptimal (to match the correct ratio).
                amountA = amountADesired;
                amountB = amountBOptimal;
            } else {
                // Optimal B amount is greater than what user wants to provide
                // User isn’t willing to provide enough token B for the amount of token A they want to add, so we based the ratio
                // off the user's amountBDesired and we check the optimal amount of token A instead.

                // Calculate optimal amount of A given amountBDesired
                uint amountAOptimal = quote(amountBDesired, reserveB, reserveA);

                // Check that optimal A is not more than what user wants to provide (should be true)
                require(amountAOptimal <= amountADesired, "A optimal too high");

                // Check if optimal A amount meets minimum amount required (slippage protection)
                require(amountAOptimal >= amountAMin, "Insufficient A amount");

                // Use user's full amountBDesired and optimal amountAOptimal to maintain ratio
                amountA = amountAOptimal;
                amountB = amountBDesired;
            }
        }

        // Transfer tokens from the user to the pair contract
        IERC20(tokenA).safeTransferFrom(msg.sender, pairAddress, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pairAddress, amountB);

        uint liquidity = pair.mint(msg.sender);

        return (amountA, amountB, liquidity);
    }

    // User can remove partial or all liquidity
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity, // Amount of LP tokens to burn
        uint amountAMin, // Min tokenA to receive
        uint amountBMin, // Min tokenB to receive
        address to
    ) external nonReentrant returns (uint amountA, uint amountB) {
        address pairAddress = factory.getPair(tokenA, tokenB);
        require(pairAddress != address(0), "Pair doesn't exist");

        Pair pair = Pair(pairAddress);

        // Transfer LP tokens from user to pair contract
        IERC20(pairAddress).safeTransferFrom(
            msg.sender,
            pairAddress,
            liquidity
        );

        // Burn LP tokens and return tokens to `to`
        (uint amount0, uint amount1) = pair.burn(to);

        // Map token0/token1 to tokenA/tokenB
        (address token0, ) = sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);

        // Slippage protection
        require(amountA >= amountAMin, "Insufficient A amount");
        require(amountB >= amountBMin, "Insufficient B amount");
    }

    // Swap tokenIn -> tokenOut for exact amountIn
    // Acts as the user-facing interface to perform a swap
    // amountOut is how many tokens the user will receive from the swap in exchange for the amountIn tokens they are giving
    function swapTokenForToken(
        address tokenIn,
        address tokenOut,
        uint amountIn
    ) external returns (uint amountOut) {
        address pairAddr = getPair(tokenIn, tokenOut);
        require(pairAddr != address(0), "Pair does not exist");

        Pair pair = Pair(pairAddr);

        // Get reserves from pair
        (uint reserve0, uint reserve1) = pair.getReserves();

        // Determine input/output reserves order based on token order in pair
        (uint reserveIn, uint reserveOut) = tokenIn == pair.token0()
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        // Calculate output amount using helper function (including platform fee)
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut > 0, "Insufficient output amount");

        // Transfer amountIn tokens from user to pair contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, pairAddr, amountIn);

        // Call pair.swap() - SPECIFY AMOUNT OUT DEPENDING ON TOKEN ORDER
        if (tokenIn == pair.token0()) {
            // Output tokens are token1, so amount0Out = 0, amount1Out = amountOut
            pair.swap(0, amountOut, msg.sender);
        } else {
            // Output tokens are token0, so amount0Out = amountOut, amount1Out = 0
            pair.swap(amountOut, 0, msg.sender);
        }
    }

    // HELPER FUNCTIONS
    // Function called by the UX (frontend) to get the correct amount of tokenB. You pass the amount of tokenA, to know
    // the value on tokenB required to provide liquidity
    function quote(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) public pure returns (uint amountB) {
        require(amountA > 0, "Insufficient amount");
        require(reserveA > 0 && reserveB > 0, "Insufficient Liquidity");
        amountB = (amountA * reserveB) / reserveA;
    }

    // Calculates output amount based on reserves and amountIn (using constant product formula with 0.3% fee)
    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) public pure returns (uint amountOut) {
        require(amountIn > 0, "AmountIn must be > 0");
        require(reserveIn > 0 && reserveOut > 0, "Invalid reserves");

        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }
}
