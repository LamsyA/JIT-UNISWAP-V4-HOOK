# JIT V4 Hook

## Overview

This project implements a Just-In-Time (JIT) liquidity provider hook for Uniswap V4. The hook is designed to dynamically add liquidity right before large swaps take place, ensuring liquidity providers can maximize their profit from such swaps and their is no slippage for the swap which makes it more profitable and a win-win for all parties involved. The JIT V4 hook integrates with the Chainlink Price Feed to accurately calculate the amount of liquidity to be added at the time of the swap based on current token prices. After the swap, the remaining liquidity and profit are automatically removed and sent back to the JIT hook contract.

## Table of Contents

- [JIT V4 Hook](#jit-v4-hook)
  - [Overview](#overview)
  - [Table of Contents](#table-of-contents)
  - [Key Features](#key-features)
  - [How It Works](#how-it-works)
  - [Components](#components)
    - [JIT Hook Contract](#jit-hook-contract)
    - [Chainlink Price Feed](#chainlink-price-feed)
    - [Uniswap V4 Integration](#uniswap-v4-integration)
  - [How to Install](#how-to-install)
    - [Prerequisites](#prerequisites)
    - [Steps](#steps)
  - [Usage](#usage)
    - [Rebalancer Factory](#rebalancer-factory)
    - [Trigger Swap Handling](#trigger-swap-handling)
    - [Withdraw Liquidity \& Profits](#withdraw-liquidity--profits)
    - [Chainlink Price Fetching](#chainlink-price-fetching)
    - [Calculation Logic](#calculation-logic)
  - [License](#license)

## Key Features

- **Dynamic Liquidity Provisioning:** The hook calculates the amount of liquidity to provide based on the size of the swap and the price of the token at the time of the swap.
- **Chainlink Price Feed Integration:** The real-time price of tokens is fetched using the Chainlink Price Feed, allowing the JIT hook to provide accurate liquidity based on market conditions.
- **Post-Swap Liquidity Removal:** After the swap occurs, the liquidity and profit are removed, and the funds are sent back to the JIT hook contract.
- **Supports Pair Deposits:** Liquidity providers can deposit token pairs into the JIT hook to be used for liquidity provision.

## How It Works

1. **Swap Trigger Detection:** When a large swap is initiated, the JIT hook is triggered to take action.
2. **Price Fetching:** The hook fetches the token price using Chainlink’s decentralized oracle network.
3. **Liquidity Calculation:** Based on the token price, the JIT hook calculates the amount of liquidity to be added within the tick range where the swap will occur.
4. **Liquidity Addition:** The calculated liquidity is provided to the Uniswap V4 pool just before the swap is executed.
5. **Swap Execution:** The swap is carried out with the newly added liquidity.
6. **Profit Collection:** After the swap, the JIT hook automatically removes the remaining liquidity and collects any profits made from the transaction.
7. **Profit Distribution:** The removed liquidity and profits are sent back to the JIT hook contract.

## Components

### JIT Hook Contract

This is the core smart contract that manages the dynamic liquidity provisioning and profit distribution.

- **`depositLiquidity()`**: Allows liquidity providers (LPs) to deposit token pairs into the JIT hook.
- **`calculateLiquidity()`**: Uses the Chainlink Price Feed to determine how much liquidity to add based on the size of the swap and the token price at that moment.
- **`addLiquidity()`**: Adds liquidity to the Uniswap V4 pool right before the swap.
- **`removeLiquidity()`**: Removes liquidity and profits after the swap, sending them back to the JIT hook.
- **`fetchPrice()`**: Fetches the current token price from Chainlink Price Feed.

### Chainlink Price Feed

This is the external oracle that provides the real-time price data for tokens involved in the swap. The JIT hook queries the price feed whenever liquidity needs to be added.

### Uniswap V4 Integration

The JIT hook is integrated with the Uniswap V4 pool contract, enabling it to interact with the pool, add liquidity, and remove liquidity dynamically around swaps.

## How to Install

### Prerequisites

- Solidity development environment (e.g., Hardhat or Foundry)
- Access to a Uniswap V4 pool
- Chainlink Price Feed contract addresses for tokens
- LP tokens to deposit into the JIT hook

### Steps

1. Clone the repository.
2. Install dependencies:
   ```bash
   forge install
   ```
3. Configure the environment with the relevant Chainlink Price Feed addresses and Uniswap V4 pool addresses.
4. Compile the smart contract:
   ```bash
   forge compile
   ```

## Usage

### Rebalancer Factory

The rebalancer factory is used to create a new rebalancer contract for a given token pair and price feed.

```solidity
 function rebalancerFactory(address _token0, address _token1, address _priceFeed) public returns (address);
```

### Trigger Swap Handling

When a large swap is detected, the JIT hook will automatically execute the following:

1. Fetch the price from Chainlink.
2. Calculate the liquidity needed for the swap.
3. Add liquidity to the pool `beforeSwap`.
4. Execute the swap.
5. Remove the remaining liquidity and collect profits `afterSwap`.

### Withdraw Liquidity & Profits

After the swap, liquidity providers can withdraw their profits from the JIT hook.

```solidity
function withdrawLiquidity(uint256 shareAmount, address withdrawTo) external;
```

### Chainlink Price Fetching

The `_getPrice()()` function queries Chainlink to get the latest price for a given token pair.

```solidity
function _getPrice() public view returns (int256);
```

### Calculation Logic

The hook uses the current price to estimate how much liquidity should be provided. The formula depends on the swap size and the price returned by Chainlink.

## License

MIT License
