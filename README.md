# Uniswap V4 Grid Hook Strategy

## Overview

This repository provides a set of smart contracts and tools designed to implement a grid trading strategy on Uniswap V4. Grid trading is a systematic trading approach that places buy and sell orders at predefined price intervals, enabling automated and efficient liquidity management.

## Purpose

The purpose of this project is to leverage Uniswap V4's concentrated liquidity model to implement a grid trading strategy. By utilizing the flexibility of Uniswap V4 Hooks, these contracts allow users to optimize their liquidity positions, capture profits from price fluctuations within a specified range, and customize liquidity distribution across grid positions. The ability to distribute liquidity using various strategies, such as flat, linear, Fibonacci, and more, provides users with enhanced control and adaptability to different market conditions.

## Features

- **Automated Liquidity Management**: Deploy and manage liquidity positions across multiple price ranges.
- **Profit Capture**: Automatically execute buy and sell orders as prices move within the grid.
- **Customizable Parameters**: Define grid intervals, price ranges, and liquidity amounts to suit your strategy.
- **Liquidity Distribution**: Distribute liquidity across grid positions using various distribution types, such as flat, linear, reverse linear, Fibonacci, and more.
- **Gas Optimization**: Efficiently manage transactions to minimize gas costs.

## Use Cases

1. **Passive Income Generation**: Earn fees by providing liquidity within a grid structure.
2. **Market Making**: Facilitate trading by maintaining liquidity across a range of prices.
3. **Hedging Strategies**: Use grid trading to hedge against price volatility.

## Liquidity Distribution

The contracts support multiple liquidity distribution types to suit different trading strategies:

- **Flat Distribution**: Equal weight across all grid intervals.
- **Linear Distribution**: Increasing weight from the first to the last interval.
- **Reverse Linear Distribution**: Decreasing weight from the first to the last interval.
- **Fibonacci Distribution**: Weights based on the Fibonacci sequence.
- **Sigmoid Distribution**: (Not implemented) Typically creates an S-shaped curve.
- **Logarithmic Distribution**: (Not implemented) Typically creates a logarithmic curve.

These distribution types allow users to customize how liquidity is allocated across the grid, optimizing for specific market conditions or strategies.

## Typed Errors

- **PoolAddressZero()**: The pool address cannot be zero.
- **PositionManagerAddressZero()**: The position manager address cannot be zero.
- **InvalidGridQuantity(uint256 quantity)**: The grid quantity must be greater than 0 and less than or equal to 1,000.
- **InvalidGridStep(uint256 stepBps)**: The grid step must be greater than 0 and less than or equal to 10,000.
- **InvalidTokenAmountsForGridType()**: Invalid token amounts for the specified grid type.
- **SlippageTooHigh(uint16 slippageBps)**: Slippage must be less than or equal to 500 basis points (5%).
- **MaxActivePositionsExceeded(uint256 activePositions)**: Exceeded the maximum number of active positions (1,000).
- **TickSpacingMisaligned(int24 tickLower, int24 tickUpper, int24 tickSpacing)**: Ticks must align with the pool's tick spacing.
- **NoAssetsAvailable()**: No tokens or Ether available for the operation.
- **PriceDeviationTooHigh(uint256 observedDeviationBps, uint256 maxDeviationBps)**: Price deviation exceeds the maximum allowable deviation.
- **PositionNotFound(bytes32 positionKey)**: Position not found for the provided core position key (owner, tickLower, tickUpper, salt).
- **MissingToken1ForBuyGrid()**: Missing required token1 amount for the BUY grid type.
- **MissingToken0ForSellGrid()**: Missing required token0 amount for the SELL grid type.
- **MissingTokenAmountForAddLiquidity()**: Missing required token amount for adding liquidity.
- **DistributionTypeNotImplemented(GridTypes.DistributionType distributionType)**: Distribution type not implemented (e.g., Sigmoid or Logarithmic).

## Architecture

- `src/hooks/GridHook.sol`: hook entrypoint and pool-scoped state container
- `src/libraries/GridTypes.sol`: shared enums and structs for grid configuration
- `src/libraries/DistributionWeights.sol`: deterministic weight generation for flat, linear, reverse-linear, and Fibonacci grids
- `test/GridHook.t.sol`: starter test coverage for permissions, config writes, and weight generation

## Hook Model

The starter hook enables these callbacks:

- `afterInitialize`
- `afterAddLiquidity`
- `afterRemoveLiquidity`
- `afterSwap`

Uniswap v4 activates hooks from the least-significant bits of the deployed hook address. This repo exposes the required flag bitmap through `GridHook.requiredHookFlags()` so deployment tooling can mine or derive a compatible address.

This scaffold does not yet include vanity-address deployment tooling. That should be added before mainnet deployment.

## Development

Build:

```sh
forge build
```

Test:

```sh
forge test
```

Format:

```sh
forge fmt
```

## Dependencies

- `v4-core`
- `v4-periphery`
- `openzeppelin-contracts`
- `forge-std`

`v4-periphery` is installed for future integration work, but the current starter uses `v4-core` hook interfaces directly to keep the initial scaffold small and explicit.

## Contributing

Contributions are welcome! Please submit issues or pull requests to help improve the project. For major changes, please open an issue first to discuss your ideas.

## License

This project is licensed under the [MIT License](LICENSE).