// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// proxy holds data and contract pair has implementation

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract Pair is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public factory;

    // Tokens in this pair
    address public token0;
    address public token1;

    // Reserves of token0 and token1 (stored as 112-bit integers to save gas)
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

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
    event Initialized(address token0, address token1);

    // The LP token uses a generic name and symbol for all pairs (e.g., "MyDEX LP" and "LP").
    // This simplifies deployment and avoids needing to pass custom names/symbols per pair.
    // Token0 and token1 are tracked internally for each pair contract.
    constructor(address _factory) ERC20("MyDEX LP", "LP") {
        require(_factory != address(0), "Invalid factory");
        factory = _factory;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "Pair: only factory can call");
        _;
    }

    // Adds liquidity to the pool
    function mint(address to) external nonReentrant returns (uint liquidity) {
        require(
            token0 != address(0) && token1 != address(0),
            "Pair not initialized"
        );
        // Using balances and reserves separately prevents minting if no actual tokens were added.
        // Get token balances after user sent tokens to the contract
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        (uint112 _reserve0, uint112 _reserve1) = getReserves();

        // Calculate how many tokens were added. If someone tries to mint without adding real tokens,
        // the added amounts (amount0, amount1) will be 0, and the mint will revert or mint 0 LP tokens.
        uint amount0 = balance0 - _reserve0;
        uint amount1 = balance1 - _reserve1;

        // First LP mints sqrt(x*y) LP tokens
        // Others mint based on proportion of reserves
        if (totalSupply() == 0) {
            liquidity = Math.sqrt(amount0 * amount1);
        } else {
            liquidity = Math.min(
                (amount0 * totalSupply()) / _reserve0,
                (amount1 * totalSupply()) / _reserve1
            );
        }

        require(liquidity > 0, "Insufficient Liquidity minted");

        // Mint LP tokens to user
        _mint(to, liquidity); // Use ERC20 _mint

        // update reserves of LP pair
        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
     * @notice Burns liquidity tokens to withdraw underlying assets.
     * @dev The caller must send the LP tokens to this contract before calling burn().
     *      This function burns the LP tokens held by the contract, then transfers
     *      the underlying tokens to the `to` address.
     *      Typically, `burn()` is called by the Router contract’s `removeLiquidity()` function,
     *      which handles transferring LP tokens from the user before calling this.
     */
    function burn(
        address to
    ) external nonReentrant returns (uint amount0, uint amount1) {
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        // Burn liquidity that was sent to this contract by the user. If no liquidity in contract
        // function reverts.
        uint liquidity = balanceOf(address(this));
        require(liquidity > 0, "No liquidity to burn");

        // Calculate proportional share
        amount0 = (liquidity * balance0) / totalSupply();
        amount1 = (liquidity * balance1) / totalSupply();

        // Checking for "dust" or negligible amounts being burned
        require(amount0 > 0 && amount1 > 0, "Insufficient liquidity burned");

        // Burn LP tokens user sent to the pair contract
        _burn(address(this), liquidity); // Use ERC20 _burn

        // Transfer tokens back to user
        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);

        // Update reserves of LP pair
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this))
        );

        emit Burn(msg.sender, amount0, amount1, to);
    }

    // Swaps tokens from one side to the other
    // You’re allowed to specify one token to receive (amount0Out or amount1Out), and leave the other as 0
    // The check if (amount0Out > 0) and if (amount1Out > 0) helps infer which token is input and which is output
    // - How to deal with slippage?
    // 1. It lets the swap function be simple and generic, without needing to know about user preferences like slippage tolerance.
    // 2. It forces users to use the router to perform swaps safely, otherwise calling swap directly is risky and inconvenient.
    function swap(
        uint amount0Out,
        uint amount1Out,
        address to
    ) external nonReentrant {
        // Check that exactly one token amount is being output
        require(amount0Out > 0 || amount1Out > 0, "No output requested");
        require(
            (amount0Out > 0 && amount1Out == 0) ||
                (amount1Out > 0 && amount0Out == 0),
            "Only one token can be swapped out"
        );

        // It prevents the recipient of the swapped tokens from being one of the tokens in the pair contract itself
        require(to != token0 && to != token1, "Invalid to address");

        // Get the current stored reserves before the swap happens and checks liquidity
        (uint112 _reserve0, uint112 _reserve1) = getReserves();
        require(
            amount0Out < _reserve0 && amount1Out < _reserve1,
            "Insufficient Liquidity"
        );

        // Send output tokens to recipient. Transfer the token the user wants to receive
        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out); // user wants to get token0 out and must send in token1
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out); // user wants to get token1 out and must send in token0

        // Calculate the new balances after sending tokens out
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        // Infer how much of each token was sent into the contract
        uint amount0In = balance0 > _reserve0 - amount0Out
            ? balance0 - (_reserve0 - amount0Out)
            : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out
            ? balance1 - (_reserve1 - amount1Out)
            : 0;

        // Can’t swap out tokens without sending some tokens in
        require(amount0In > 0 || amount1In > 0, "Insufficient input");

        // Apply 0.3% fee and check the constant product invariant
        uint balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint balance1Adjusted = balance1 * 1000 - amount1In * 3;
        require(
            balance0Adjusted * balance1Adjusted >=
                (uint(_reserve0) * uint(_reserve1)) * 1000 ** 2,
            "Invariant violation"
        );

        // Store the new reserves for future swaps
        _update(balance0, balance1);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // HELPER FUNCTIONS
    // Initialization for `CREATE2` deployments
    function initialize(address _token0, address _token1) external onlyFactory {
        require(
            token0 == address(0) && token1 == address(0),
            "Already initialized"
        );

        require(_token0 != _token1, "Identical tokens");
        require(_token0 != address(0) && _token1 != address(0), "Zero address");

        token0 = _token0;
        token1 = _token1;

        emit Initialized(token0, token1);
    }

    // Function to get current reserves of LP contract
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
}
