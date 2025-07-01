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
        require(to != address(0), "Invalid LP recipient");

        // Get or create pair
        address pairAddress = factory.getPair(tokenA, tokenB);
        require(pairAddress != address(0), "Pair has not been created");

        Pair pair = Pair(pairAddress);

        {
            (uint reserveA, uint reserveB) = _getOrderedReserves(
                pair,
                tokenA,
                tokenB
            );

            (amountA, amountB) = _computeAmounts(
                amountADesired,
                amountBDesired,
                reserveA,
                reserveB,
                amountAMin,
                amountBMin
            );
        }

        // Transfer tokens and mint LP
        IERC20(tokenA).safeTransferFrom(msg.sender, pairAddress, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pairAddress, amountB);
        liquidity = pair.mint(to);

        emit LiquidityAdded(
            msg.sender,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity
        );
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
        (address token0, ) = _sortTokens(tokenA, tokenB);
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
        IERC20(path[0]).safeTransferFrom(
            msg.sender,
            getPair(path[0], path[1]), // first pair in the swap path
            amountIn
        );

        uint currentAmountIn = amountIn;

        for (uint i = 0; i < path.length - 1; i++) {
            address input = path[i];
            address output = path[i + 1];

            address to = i < path.length - 2
                ? getPair(output, path[i + 2])
                : msg.sender;

            currentAmountIn = _executeSwap(input, output, to, currentAmountIn);
        }

        require(currentAmountIn >= minAmountOut, "Slippage: Output too low");
        amountOut = currentAmountIn;

        emit MultiSwap(msg.sender, path, amountIn, amountOut);
    }

    // =====================
    // Public Helper Functions
    // =====================

    function getPair(
        address tokenA,
        address tokenB
    ) public view returns (address) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        return factory.getPair(token0, token1);
    }

    function quote(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) public pure returns (uint amountB) {
        require(amountA > 0, "Insufficient amount");
        require(reserveA > 0 && reserveB > 0, "Insufficient Liquidity");
        amountB = (amountA * reserveB) / reserveA;
    }

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

    // =====================
    // Internal Helper Functions
    // =====================

    function _sortTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "Identical addresses");
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "Zero address");
    }

    function _calculateOptimalAmounts(
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        uint reserveA,
        uint reserveB
    ) internal pure returns (uint amountA, uint amountB) {
        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }

        uint amountBOptimal = quote(amountADesired, reserveA, reserveB);
        if (amountBOptimal <= amountBDesired) {
            require(amountBOptimal >= amountBMin, "Insufficient B amount");
            return (amountADesired, amountBOptimal);
        } else {
            uint amountAOptimal = quote(amountBDesired, reserveB, reserveA);
            require(amountAOptimal <= amountADesired, "A optimal too high");
            require(amountAOptimal >= amountAMin, "Insufficient A amount");
            return (amountAOptimal, amountBDesired);
        }
    }

    function _getOrderedReserves(
        Pair pair,
        address tokenA,
        address tokenB
    ) internal view returns (uint reserveA, uint reserveB) {
        address token0 = pair.token0();
        address token1 = pair.token1();
        (uint reserve0, uint reserve1) = pair.getReserves();

        if (tokenA == token0 && tokenB == token1) {
            (reserveA, reserveB) = (reserve0, reserve1);
        } else if (tokenA == token1 && tokenB == token0) {
            (reserveA, reserveB) = (reserve1, reserve0);
        } else {
            revert("Invalid token pair");
        }
    }

    function _computeAmounts(
        uint amountADesired,
        uint amountBDesired,
        uint reserveA,
        uint reserveB,
        uint amountAMin,
        uint amountBMin
    ) internal pure returns (uint amountA, uint amountB) {
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "Insufficient B amount");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = quote(amountBDesired, reserveB, reserveA);
                require(amountAOptimal <= amountADesired, "A optimal too high");
                require(amountAOptimal >= amountAMin, "Insufficient A amount");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    // =====================
    // Private Helper Functions
    // =====================

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
}
