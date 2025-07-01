// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import "../src/core/Factory.sol";
import "../src/core/Pair.sol";
import "../src/router/Router.sol";
import "../src/tokens/Token.sol";

contract FactoryTest is Test {
    Factory factory;
    Pair pair;
    Router router;
    Token public tokenA;
    Token public tokenB;
    Token public token0;
    Token public token1;
    address public pairAddress;
    address public user = address(0xBEEF);
    address public DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function setUp() public {
        // Fork the Ethereum mainnet at the latest block
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        // Mint 1,000 tokens (1e3 * 1e18)
        uint initialSupply = 1000 * 1e18;
        tokenA = new Token("TokenA", "TKA", initialSupply);
        tokenB = new Token("TokenB", "TKB", initialSupply);

        // Deploy factory contract
        factory = new Factory();

        // Deploy router contract
        router = new Router(address(factory));

        pairAddress = factory.createPair(address(tokenA), address(tokenB));
        pair = Pair(pairAddress);

        // Check right order of pair tokens
        bool isTokenA0 = address(tokenA) == pair.token0();
        token0 = isTokenA0 ? tokenA : tokenB;
        token1 = isTokenA0 ? tokenB : tokenA;

        // Transfer some tokens to user for tests
        tokenA.transfer(user, 100 * 1e18); // 100 TKA to user
        tokenB.transfer(user, 100 * 1e18); // 100 TKB to user

        vm.startPrank(user);
        tokenA.approve(address(pair), type(uint).max);
        tokenB.approve(address(pair), type(uint).max);
        vm.stopPrank();

        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function testCreatePair() public {
        vm.startPrank(address(factory));
        // Create pair for USDC / DAI
        pairAddress = factory.createPair(USDC, DAI);
        vm.stopPrank();

        // Assert that the pair address is not zero
        assertTrue(
            pairAddress != address(0),
            "Pair address should not be zero"
        );

        // Assert that the getPair function returns the same address
        address expected = factory.getPair(USDC, DAI);
        assertEq(pairAddress, expected, "Factory did not store pair correctly");

        uint length = factory.allPairsLength();
        assertEq(length, 2, "Not the right length of created pairs");
    }

    function testMintLiquidity() public {
        // Transfer tokens to pair contract
        vm.startPrank(user);
        tokenA.transfer(address(pair), 10 * 1e18); // 10 TKA
        tokenB.transfer(address(pair), 10 * 1e18); // 10 TKB

        // Mint LP tokens for user
        uint liquidity = pair.mint(user);

        // Check reserves and pair token balances are equal
        (uint112 reserve0, uint112 reserve1) = pair.getReserves();
        uint balanceA = tokenA.balanceOf(address(pair));
        uint balanceB = tokenB.balanceOf(address(pair));

        assertEq(balanceA, reserve0, "TokenA balance and reserve mismatch");
        assertEq(balanceB, reserve1, "TokenB balance and reserve mismatch");

        assertGt(liquidity, 0, "Liquidity should be minted");
        assertEq(pair.balanceOf(user), liquidity, "User LP balance incorrect");
        vm.stopPrank();
    }

    // Test burn function
    function testBurnLiquidity() public {
        // Transfer LP tokens back to the pair contract to burn
        vm.startPrank(user);

        // Transfer tokens to pair
        tokenA.transfer(address(pair), 1e18); // 1 token A
        tokenB.transfer(address(pair), 1e18); // 1 token B

        // Call mint
        pair.mint(user); // mint tokens to the user

        // Get LP balance
        uint liquidity = pair.balanceOf(user);
        // Transfer LP tokens to pair to burn
        pair.transfer(address(pair), liquidity);

        // Get token balances before burn
        uint beforeTokenABalance = tokenA.balanceOf(user);
        uint beforeTokenBBalance = tokenB.balanceOf(user);

        // Burn LP tokens and receive back pair tokens
        (uint amount0, uint amount1) = pair.burn(user);

        // Check token balances after burn
        uint afterTokenABalance = tokenA.balanceOf(user);
        uint afterTokenBBalance = tokenB.balanceOf(user);
        vm.stopPrank();

        // Assert tokens were returned
        assertEq(
            afterTokenABalance,
            beforeTokenABalance + amount0,
            "Token A not received correctly"
        );
        assertEq(
            afterTokenBBalance,
            beforeTokenBBalance + amount1,
            "Token B not received correctly"
        );

        // Assert LP tokens were burned
        assertEq(pair.balanceOf(user), 0, "LP tokens not burned");

        // Assert some liquidity was returned
        assertGt(amount0, 0, "No Token A returned");
        assertGt(amount1, 0, "No Token B returned");
    }

    function testSwap() public {
        // Transfer tokens to pair contract
        vm.startPrank(user);
        // Provide liquidity first
        token0.transfer(address(pair), 10 * 1e18);
        token1.transfer(address(pair), 10 * 1e18);
        pair.mint(user);

        /// User wants to swap tokenA for tokenB
        uint amountIn = 1 * 1e18; // 1 TokenA

        uint pairBalanceBefore = token1.balanceOf(address(pair));
        console.log("Pair token1 balance before transfer:", pairBalanceBefore);

        // Swap: send 1 token1 to get token0
        token1.transfer(address(pair), amountIn);

        uint pairBalanceAfter = token1.balanceOf(address(pair));
        console.log("Pair token1 balance after transfer:", pairBalanceAfter);

        // Check that the pair received the correct amount in
        assertEq(
            pairBalanceAfter,
            pairBalanceBefore + amountIn,
            "Pair didn't receive correct amountIn"
        );

        // Get reserves for calculation
        (uint112 reserve0, uint112 reserve1) = pair.getReserves();

        // Calculate output amount using router
        uint amountOut = router.getAmountOut(amountIn, reserve0, reserve1);
        console.log("amountOut", amountOut);
        assertGt(amountOut, 0, "Amount out must be greater than zero");

        uint userToken0Before = token0.balanceOf(user);
        console.log("User token0 balance before swap:", userToken0Before);

        // User calls swap, requesting tokenB out and sending tokenA in (already transferred)
        pair.swap(
            amountOut, //  amount1Out = amountOut token0 out
            0, // amount0Out = 0, no token1 out
            user // send token1 to user
        );

        vm.stopPrank();

        // User balance should increase by amountOut
        uint userToken0After = token0.balanceOf(user);
        console.log("User token0 balance after swap:", userToken0After);
        assertEq(
            userToken0After,
            userToken0Before + amountOut,
            "Incorrect user token0 after swap"
        );

        // Pair's token1 balance should have increased by amountIn
        uint pairToken1 = token1.balanceOf(address(pair));
        assertEq(
            pairToken1,
            pairBalanceAfter,
            "Incorrect pair token1 balance after swap"
        );

        // Pair's token0 balance should have decreased by amountOut
        uint pairToken0 = token0.balanceOf(address(pair));
        assertEq(
            pairToken0,
            10 * 1e18 - amountOut,
            "Incorrect pair token0 balance after swap"
        );

        // Check updated reserves after swap
        (uint112 updatedReserve0, uint112 updatedReserve1) = pair.getReserves();
        console.log("Updated reserves:", updatedReserve0, updatedReserve1);
    }

    function testAddLiquidity() public {
        vm.startPrank(user);
        uint amountADesired = 100 * 1e18;
        uint amountBDesired = 100 * 1e18;
        uint amountAMin = 90 * 1e18;
        uint amountBMin = 90 * 1e18;

        (uint amountA, uint amountB, uint liquidity) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            user
        );

        // Basic assertions
        assertGt(amountA, 0);
        assertGt(amountB, 0);
        assertGt(liquidity, 0);

        // Check LP tokens received
        uint lpBalance = pair.balanceOf(user);
        assertEq(lpBalance, liquidity);

        vm.stopPrank();
    }
}
