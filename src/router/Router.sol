// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/Factory.sol";
import "../core/Pair.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract Router is ReentrancyGuard {
    using SafeERC20 for IERC20;

    Factory public factory;

    event LiquidityAdded(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        uint amountA,
        uint amountB,
        uint liquidity
    );

    event LiquidityRemoved(
        address indexed user,
        address indexed tokenA,
        address indexed tokenB,
        uint liquidity,
        uint amountA,
        uint amountB,
        address to
    );

    event SwapExecuted(
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint amountIn,
        uint amountOut
    );

    event MultiSwap(
        address indexed user,
        address[] path,
        uint amountIn,
        uint amountOut
    );

    constructor(address _factory) {
        require(_factory != address(0), "Invalid factory");
        factory = Factory(_factory);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to
    )
        external
        nonReentrant
        returns (uint amountA, uint amountB, uint liquidity)
    {
        require(to != address(0), "Invalid LP recipient");

        // Get or create the pair
        address pairAddress = factory.getPair(tokenA, tokenB);
        if (pairAddress == address(0)) {
            pairAddress = factory.createPair(tokenA, tokenB);
        }

        // Determine optimal amounts based on reserves
        (amountA, amountB) = _calculateLiquidityAmounts(
            pairAddress,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );

        // Transfer tokens and mint LP
        liquidity = _transferAndMint(
            tokenA,
            tokenB,
            pairAddress,
            amountA,
            amountB,
            to
        );

        emit LiquidityAdded(
            msg.sender,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity
        );
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
        require(to != address(0), "Invalid recipient");

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
        // Ensure the output matches the order of the tokens as provided by the user
        (address token0, ) = sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);

        // Prevents "dust" or rounding errors from allowing a meaningless removeLiquidity call
        require(amountA > 0 && amountB > 0, "Zero output");
        // Slippage protection
        require(amountA >= amountAMin, "Insufficient A amount");
        require(amountB >= amountBMin, "Insufficient B amount");

        emit LiquidityRemoved(
            msg.sender,
            tokenA,
            tokenB,
            liquidity,
            amountA,
            amountB,
            to
        );
    }

    // Swap tokenIn -> tokenOut for exact amountIn
    // Acts as the user-facing interface to perform a swap
    // amountOut is how many tokens the user will receive from the swap in exchange for the amountIn tokens they are giving
    function swapTokenForToken(
        address tokenIn,
        address tokenOut,
        uint amountIn,
        uint minAmountOut
    ) external returns (uint amountOut) {
        require(
            tokenIn != address(0) && tokenOut != address(0),
            "Invalid token address"
        );
        require(tokenIn != tokenOut, "Tokens must differ");

        address pairAddr = getPair(tokenIn, tokenOut);
        require(pairAddr != address(0), "Pair does not exist");

        Pair pair = Pair(pairAddr);

        // Get reserves from pair
        (uint reserve0, uint reserve1) = pair.getReserves();
        address token0 = pair.token0();

        // Determine input/output reserve order
        (uint reserveIn, uint reserveOut) = tokenIn == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        // Calculate output amount
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        require(amountOut >= minAmountOut, "Insufficient output amount");

        // Transfer input tokens to the pair contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, pairAddr, amountIn);

        // Determine swap output amounts
        (uint amount0Out, uint amount1Out) = tokenIn == token0
            ? (uint(0), amountOut)
            : (amountOut, uint(0));

        // Execute swap
        pair.swap(amount0Out, amount1Out, msg.sender);

        // Emit event
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    function multiHopSwap(
        address[] calldata path, // array of token addresses
        uint amountIn,
        uint minAmountOut
    ) external returns (uint amountOut) {
        require(path.length >= 2, "Path too short");
        require(amountIn > 0, "Zero input");
        require(minAmountOut > 0, "Zero min output");

        // Transfer the first token from sender to the first pair
        // path[0] = input token, path[1] = first intermediate token, path[2] = final output token
        IERC20(path[0]).safeTransferFrom(
            msg.sender,
            getPair(path[0], path[1]), // first pair in the swap path
            amountIn
        );

        uint currentAmountIn = amountIn;

        // Loop through each hop in the path, updating currentAmountIn for next hop
        for (uint i = 0; i < path.length - 1; i++) {
            address input = path[i];
            address output = path[i + 1];

            address to = i < path.length - 2
                ? getPair(output, path[i + 2])
                : msg.sender;

            currentAmountIn = _executeSwap(input, output, to, currentAmountIn);
        }

        // Final output check
        require(currentAmountIn >= minAmountOut, "Slippage: Output too low");
        amountOut = currentAmountIn;

        emit MultiSwap(msg.sender, path, amountIn, amountOut);
    }

    // HELPER FUNCTIONS

    // Helper function to get pair address from factory for tokens
    function getPair(
        address tokenA,
        address tokenB
    ) public view returns (address) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        return factory.getPair(token0, token1);
    }

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

    function sortTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "Identical addresses");
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "Zero address");
    }

    // Private helper function to perform a single hop swap
    function _executeSwap(
        address input,
        address output,
        address to,
        uint amountIn
    ) private returns (uint amountOut) {
        address pairAddr = getPair(input, output);
        require(pairAddr != address(0), "Pair does not exist");

        Pair pair = Pair(pairAddr);

        (uint reserve0, uint reserve1) = pair.getReserves();

        (uint reserveIn, uint reserveOut) = input == pair.token0()
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);

        (uint amount0Out, uint amount1Out) = input == pair.token0()
            ? (uint(0), amountOut)
            : (amountOut, uint(0));

        pair.swap(amount0Out, amount1Out, to);
    }

    /// @dev Calculates optimal amounts of tokens A and B to add as liquidity,
    // respecting reserve ratios and slippage constraints
    function _calculateLiquidityAmounts(
        address pairAddress,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) private view returns (uint amountA, uint amountB) {
        Pair pair = Pair(pairAddress);
        (uint reserveA, uint reserveB) = pair.getReserves();

        // If no reserves, accept desired amounts
        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }

        // Calculate optimal B amount for given A
        uint amountBOptimal = quote(amountADesired, reserveA, reserveB);
        if (amountBOptimal <= amountBDesired) {
            require(amountBOptimal >= amountBMin, "Insufficient B amount");
            return (amountADesired, amountBOptimal);
        }

        // Otherwise calculate optimal A amount for given B
        uint amountAOptimal = quote(amountBDesired, reserveB, reserveA);
        require(amountAOptimal <= amountADesired, "A optimal too high");
        require(amountAOptimal >= amountAMin, "Insufficient A amount");
        return (amountAOptimal, amountBDesired);
    }

    /// @dev Transfers tokens to the pair and mints LP tokens to the recipient
    function _transferAndMint(
        address tokenA,
        address tokenB,
        address pairAddress,
        uint amountA,
        uint amountB,
        address to
    ) private returns (uint liquidity) {
        IERC20(tokenA).safeTransferFrom(msg.sender, pairAddress, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pairAddress, amountB);
        liquidity = Pair(pairAddress).mint(to);
    }
}
