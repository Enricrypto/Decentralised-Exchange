// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

contract Pair {
    // Tokens in this pair
    address public token0;
    address public token1;

    // Reserves of token0 and token1 (stored as 112-bit integers to save gas)
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    // LP token tracking
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address to);
    event Swap(
        address indexed sender,
        uint amountIn0,
        uint amountIn1,
        uint amountOut0,
        uint amountOut1,
        address to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    modifier onlyTokens() {
        require(msg.sender == token0 || msg.sender == token1, "Not token");
        _;
    }

    function getReserves() public view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    // Updates internal reserves to match current token balances
    function _update(uint balance0, uint balance1) private {
        require(
            balance0 <= type(uint112).max && balance1 <= type(uint112).max,
            "Overflow"
        );

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp);

        emit Sync(reserve0, reserve1);
    }

    // create a function to calculate tokens send to LP

    // Adds liquidity to the pool
    function mint(address to) external returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1) = getReserves();

        // Using balances and reserves separately prevents minting if no actual tokens were added.
        // Get token balances after user sent tokens to the contract
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        // Calculate how many tokens were added
        uint amount0 = balance0 - _reserve0;
        uint amount1 = balance1 - _reserve1;

        // First LP mints sqrt(x*y) LP tokens
        // Others mint based on proportion of reserves
        if (totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1);
        } else {
            liquidity = Math.min(
                (amount0 * totalSupply) / _reserve0,
                (amount1 * totalSupply) / _reserve1
            );
        }

        require(liquidity > 0, "Insufficient Liquidity minted");

        // Mint LP tokens
        balanceOf[to] += liquidity;
        totalSupply += liquidity;

        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    // Removes liquidity from the pool
    function burn(address to) external returns (uint amount0, uint amount1) {
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        // Burn liquidity that was sent to this contract by the user
        uint liquidity = balanceOf[address(this)];
        require(liquidity > 0, "No liquidity to burn");

        // Calculate share of pool
        amount0 = (liquidity * balance0) / totalSupply;
        amount1 = (liquidity * balance1) / totalSupply;

        require(amount0 > 0 && amount1 > 0, "Insufficient amount");

        // Burn LP tokens user sent to the pair contract
        balanceOf[address(this)] -= liquidity;
        totalSupply -= liquidity;

        // Transfer tokens back to user
        IERC20(token0).transfer(to, amount0);
        IERC20(token1).transfer(to, amount1);

        // Update reserves
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this))
        );

        emit Burn(msg.sender, amount0, amount1, to);
    }

    // Swaps tokens from one side to the other
    // You’re allowed to specify one token to receive (amount0Out or amount1Out), and leave the other as 0
    // FIXED THIS, no amountIn, should work by itself
    // how to deal with slippage?
    function swap(uint amount0Out, uint amount1Out, address to) external {
        require(amount0Out > 0 || amount1Out > 0, "No output requested");
        (uint112 _reserve0, uint112 _reserve1) = getReserves();
        require(
            amount0Out < _reserve0 && amount1Out < _reserve1,
            "Insufficient Liquidity"
        );

        // Send output tokens to recipient
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);

        // Recalculate balances after swap
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        // Figure out how much was sent as input
        uint amount0In = balance0 > _reserve0 - amount0Out
            ? balance0 - (_reserve0 - amount0Out)
            : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out
            ? balance1 - (_reserve1 - amount1Out)
            : 0;

        require(amount0In > 0 || amount1In > 0, "Insufficient input");

        // Apply 0.3% fee
        uint balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint balance1Adjusted = balance1 * 1000 - amount1In * 3;
        require(
            balance0Adjusted * balance1Adjusted >=
                uint(_reserve0) * uint(_reserve1) * 1000 ** 2,
            "Invariant violation"
        );

        _update(balance0, balance1);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // Initialization for `CREATE2` deployments
    function initialize(address _token0, address _token1) external {
        require(
            token0 == address(0) && token1 == address(0),
            "Already initialized"
        );

        // Sort tokens by addresses
        (token0, token1) = _token0 < _token1
            ? (_token0, _token1)
            : (_token1, _token0);
    }
}
