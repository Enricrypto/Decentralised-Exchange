#🚀 Decentralised Exchange (DEX) Solidity Contracts
This repository contains a simple implementation of a decentralized exchange (DEX) in Solidity, inspired by Uniswap V2. It includes contracts for creating liquidity pools (pairs), managing liquidity, and swapping ERC-20 tokens.

#📋 Overview
The DEX enables users to:

🔗 Create unique token pairs (liquidity pools)

➕ Add and remove liquidity to/from pools

🔄 Swap tokens via automated market-making (AMM) using a constant product formula

#📂 Contracts
1. Pair.sol
💧 Core liquidity pool contract managing two tokens

📊 Tracks reserves and LP tokens

🔥 Handles minting and burning of liquidity tokens

🔁 Implements token swaps with fee and invariant checks

2. Factory.sol
🏭 Creates and tracks all pairs (liquidity pools)

✅ Ensures only one unique pair per token combination

🧬 Uses CREATE2 for deterministic pair addresses

3. Router.sol
🧭 User-facing contract to interact with pairs

⚙️ Simplifies liquidity adding/removal and token swaps

📏 Maintains correct token ratios and implements slippage protection

🧮 Contains helper functions to calculate swap outputs and optimal liquidity amounts

#✨ Features
🪙 ERC-20 token support: Uses OpenZeppelin IERC20 interface for token transfers

📈 Constant product AMM: Implements x * y = k invariant with a 0.3% swap fee

🔐 Liquidity tokens: Minted and burned to represent shares of the pool

🛡️ Slippage protection: Users can specify minimum acceptable amounts

🎯 Deterministic pair deployment: Using CREATE2 to predict pair addresses

⚡ Gas optimization: Uses uint112 for reserve storage and minimizes redundant calls

#⚙️ Usage
📦 Deploy the Factory contract

🛠️ Deploy the Router contract with the Factory address

🔗 Create a pair for two tokens via the Factory or Router

➕ Add liquidity to a pair through the Router, which transfers tokens and mints LP tokens

🔄 Swap tokens using the Router's swapTokenForToken function

🔥 Remove liquidity by burning LP tokens and receiving underlying tokens back

#📋 Requirements
🛠️ Solidity ^0.8.20

📚 OpenZeppelin Contracts (IERC20, Math)

#📄 License
MIT License

#🤝 Contributing
Feel free to open issues or submit pull requests for improvements or bug fixes.

#📬 Contact
For questions, reach out via GitHub issues or contact the repository owner.
