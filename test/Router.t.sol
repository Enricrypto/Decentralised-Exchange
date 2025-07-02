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
    Pair pairBC;
    Router router;
    Token public tokenA;
    Token public tokenB;
    Token public tokenC;
    Token public token0AB;
    Token public token1AB;
    Token public token0BC;
    Token public token1BC;
    address public pairAddress;
    address public pairAddressBC;
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
        tokenC = new Token("TokenC", "TKC", initialSupply);

        // Deploy factory contract
        factory = new Factory();

        // Deploy router contract
        router = new Router(address(factory));

        pairAddress = factory.createPair(address(tokenA), address(tokenB));
        pairAddressBC = factory.createPair(address(tokenB), address(tokenC));
        pair = Pair(pairAddress);
        pairBC = Pair(pairAddressBC);

        // Check right order of pair tokens (A/B)
        bool isTokenA0 = address(tokenA) == pair.token0();
        token0AB = isTokenA0 ? tokenA : tokenB;
        token1AB = isTokenA0 ? tokenB : tokenA;

        // Check right order of pair tokens (B/C)
        bool isTokenB0 = address(tokenB) == pairBC.token0();
        token0BC = isTokenB0 ? tokenB : tokenC;
        token1BC = isTokenB0 ? tokenC : tokenB;

        // Transfer some tokens to user for tests
        tokenA.transfer(user, 200 * 1e18); // 200 TKA to user
        tokenB.transfer(user, 200 * 1e18); // 200 TKB to user
        tokenC.transfer(user, 200 * 1e18); // 200 TKC to user

        vm.startPrank(user);
        tokenA.approve(address(pair), type(uint).max);
        tokenB.approve(address(pair), type(uint).max);
        tokenB.approve(address(pairBC), type(uint).max);
        tokenC.approve(address(pairBC), type(uint).max);
        vm.stopPrank();

        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        pair.approve(address(router), type(uint).max);
        tokenC.approve(address(router), type(uint).max);
        pairBC.approve(address(router), type(uint).max);
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
        token0AB.transfer(address(pair), 10 * 1e18);
        token1AB.transfer(address(pair), 10 * 1e18);
        pair.mint(user);

        /// User wants to swap tokenA for tokenB
        uint amountIn = 1 * 1e18; // 1 TokenA

        uint pairBalanceBefore = token1AB.balanceOf(address(pair));
        console.log("Pair token1 balance before transfer:", pairBalanceBefore);

        // Swap: send 1 token1 to get token0
        token1AB.transfer(address(pair), amountIn);

        uint pairBalanceAfter = token1AB.balanceOf(address(pair));
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

        uint userToken0Before = token0AB.balanceOf(user);
        console.log("User token0 balance before swap:", userToken0Before);

        // User calls swap, requesting tokenB out and sending tokenA in (already transferred)
        pair.swap(
            amountOut, //  amount1Out = amountOut token0 out
            0, // amount0Out = 0, no token1 out
            user // send token1 to user
        );

        vm.stopPrank();

        // User balance should increase by amountOut
        uint userToken0After = token0AB.balanceOf(user);
        console.log("User token0 balance after swap:", userToken0After);
        assertEq(
            userToken0After,
            userToken0Before + amountOut,
            "Incorrect user token0 after swap"
        );

        // Pair's token1 balance should have increased by amountIn
        uint pairToken1 = token1AB.balanceOf(address(pair));
        assertEq(
            pairToken1,
            pairBalanceAfter,
            "Incorrect pair token1 balance after swap"
        );

        // Pair's token0 balance should have decreased by amountOut
        uint pairToken0 = token0AB.balanceOf(address(pair));
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

    function testRemoveLiquidity() public {
        // add liquidity to the liquidity pair
        uint amountADesired = 100 * 1e18;
        uint amountBDesired = 100 * 1e18;
        uint amountAMin = 90 * 1e18;
        uint amountBMin = 90 * 1e18;

        vm.startPrank(user);

        // Add liquidity
        (, , uint liquidity) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            user
        );

        uint lpBalanceBefore = pair.balanceOf(user);
        uint totalSupplyBefore = pair.totalSupply();
        uint beforeRemoveTokenABalance = tokenA.balanceOf(user);
        uint beforeRemoveTokenBBalance = tokenB.balanceOf(user);

        // remove part of the liquidity
        (uint removeAmountA, uint removeAmountB) = router.removeLiquidity(
            address(tokenA),
            address(tokenB),
            liquidity / 2,
            0,
            0,
            user
        );

        vm.stopPrank();

        uint lpBalanceAfter = pair.balanceOf(user);
        uint totalSupplyAfter = pair.totalSupply();

        // get balances after removal
        uint afterRemoveTokenABalance = tokenA.balanceOf(user);
        uint afterRemoveTokenBBalance = tokenB.balanceOf(user);

        // LP tokens burned from user
        assertEq(
            lpBalanceAfter,
            lpBalanceBefore - (liquidity / 2),
            "LP balance not decreased"
        );

        // Total supply decreased
        assertEq(
            totalSupplyAfter,
            totalSupplyBefore - (liquidity / 2),
            "LP totalSupply not decreased"
        );

        assertGe(
            afterRemoveTokenABalance,
            beforeRemoveTokenABalance + removeAmountA,
            "TokenA not returned to user"
        );
        assertGe(
            afterRemoveTokenBBalance,
            beforeRemoveTokenBBalance + removeAmountB,
            "TokenB not returned to user"
        );
    }

    function testSwapTokenForToken() public {
        vm.startPrank(user);

        (, , uint liquidity) = router.addLiquidity(
            address(tokenA),
            address(tokenB),
            100 * 1e18,
            100 * 1e18,
            90 * 1e18,
            90 * 1e18,
            user
        );

        // Record balances before swap
        uint beforeTokenInBalance = tokenA.balanceOf(user);
        uint beforeTokenOutBalance = tokenB.balanceOf(user);

        // Get reserves before swap
        (uint reserve0Before, uint reserve1Before) = pair.getReserves();

        // Perform swap
        uint amountOut = router.swapTokenForToken(
            address(tokenA),
            address(tokenB),
            10 * 1e18,
            1 * 1e18
        );

        // Record balances after swap
        uint afterTokenInBalance = tokenA.balanceOf(user);
        uint afterTokenOutBalance = tokenB.balanceOf(user);

        // Get reserves after swap
        (uint reserve0After, uint reserve1After) = pair.getReserves();

        // Map reserves according to input token order
        uint reserveInBefore;
        uint reserveOutBefore;
        uint reserveInAfter;
        uint reserveOutAfter;

        if (address(tokenA) == pair.token0()) {
            reserveInBefore = reserve0Before;
            reserveOutBefore = reserve1Before;
            reserveInAfter = reserve0After;
            reserveOutAfter = reserve1After;
        } else {
            reserveInBefore = reserve1Before;
            reserveOutBefore = reserve0Before;
            reserveInAfter = reserve1After;
            reserveOutAfter = reserve0After;
        }

        // Assertions
        assertEq(
            beforeTokenInBalance - afterTokenInBalance,
            10 * 1e18,
            "TokenIn not deducted properly"
        );
        assertGe(
            afterTokenOutBalance - beforeTokenOutBalance,
            amountOut,
            "TokenOut not received properly"
        );
        assertGe(amountOut, 1 * 1e18, "Output less than minAmountOut");
        assertLt(reserveInBefore, reserveInAfter, "ReserveIn didn't increase");
        assertGt(
            reserveOutBefore,
            reserveOutAfter,
            "ReserveOut didn't decrease"
        );

        vm.stopPrank();
    }

    function testMultiHopSwap() public {
        vm.startPrank(user);

        // Add liquidity for tokenA-tokenB pair
        router.addLiquidity(
            address(tokenA),
            address(tokenB),
            100 * 1e18,
            100 * 1e18,
            90 * 1e18,
            90 * 1e18,
            user
        );

        // Add liquidity for tokenB-tokenC pair
        router.addLiquidity(
            address(tokenB),
            address(tokenC),
            100 * 1e18,
            100 * 1e18,
            90 * 1e18,
            90 * 1e18,
            user
        );

        uint amountIn = 10 * 1e18;
        uint minAmountOut = 1 * 1e18;

        uint N = 3;
        address[] memory path = new address[](N);

        for (uint i = 0; i < N; i++) {
            // Fill the path array elements, for example:
            if (i == 0) path[i] = address(tokenA);
            else if (i == 1) path[i] = address(tokenB);
            else if (i == 2) path[i] = address(tokenC);
        }

        // Record initial balances
        uint beforeTokenABalance = tokenA.balanceOf(user);
        uint beforeTokenCBalance = tokenC.balanceOf(user);

        // Perform multi-hop swap A -> B -> C
        uint amountOut = router.multiHopSwap(path, amountIn, minAmountOut);

        // Record final balances
        uint afterTokenABalance = tokenA.balanceOf(user);
        uint afterTokenCBalance = tokenC.balanceOf(user);

        // Assertions
        assertEq(
            beforeTokenABalance - afterTokenABalance,
            amountIn,
            "TokenA not deducted"
        );
        assertGe(
            afterTokenCBalance - beforeTokenCBalance,
            amountOut,
            "TokenC not received"
        );
        assertGe(amountOut, minAmountOut, "Output less than minAmountOut");

        vm.stopPrank();
    }
}
