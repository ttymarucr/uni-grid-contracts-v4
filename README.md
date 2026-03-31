# Uniswap V4 Grid Hook Strategy

## Overview

This repository provides a set of smart contracts and tools designed to implement a grid trading strategy on Uniswap V4. Grid trading is a systematic trading approach that places buy and sell orders at predefined price intervals, enabling automated and efficient liquidity management.

The hook is deployed as a **singleton** — a single `GridHook` instance serves all users. Each user independently configures, deploys, rebalances, and closes their own grid on any pool. There is no admin or owner role; the contract is fully permissionless.

## Purpose

The purpose of this project is to leverage Uniswap V4's concentrated liquidity model to implement a grid trading strategy. By utilizing the flexibility of Uniswap V4 Hooks, these contracts allow users to optimize their liquidity positions, capture profits from price fluctuations within a specified range, and customize liquidity distribution across grid positions. The ability to distribute liquidity using various strategies, such as flat, linear, Fibonacci, and more, provides users with enhanced control and adaptability to different market conditions.

## Features

- **Singleton Multi-Tenant**: One deployed hook supports all users. Each user manages their own grid independently.
- **Permissionless**: No admin or owner role. Any user can configure and deploy a grid on any initialized pool.
- **Pull-Based Token Settlement**: Users approve the hook, which pulls tokens via `transferFrom` at deploy/rebalance time. No need to pre-fund the contract.
- **Keeper-Friendly Rebalance**: Anyone can trigger `rebalance` for any user's grid, enabling automated keeper bots.
- **Close Grid**: Users can close their grid at any time to remove all positions and receive tokens back.
- **Automated Liquidity Management**: Deploy and manage liquidity positions across multiple price ranges.
- **Customizable Parameters**: Define grid intervals, distribution type, and liquidity amounts per user per pool.
- **Liquidity Distribution**: Distribute liquidity across grid positions using flat, linear, reverse linear, Fibonacci, sigmoid, or logarithmic distributions.

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
- **Sigmoid Distribution**: S-shaped curve that concentrates weight in the middle of the grid, transitioning smoothly from low to high.
- **Logarithmic Distribution**: Concave curve giving more weight to earlier intervals with diminishing increases toward the end.

These distribution types allow users to customize how liquidity is allocated across the grid, optimizing for specific market conditions or strategies.

## Typed Errors

- **PoolManagerAddressZero()**: The pool manager address cannot be zero.
- **InvalidGridQuantity(uint256 quantity)**: The grid quantity must be greater than 0 and less than or equal to 1,000.
- **InvalidGridStep(uint256 stepBps)**: The grid step must be greater than 0 and less than or equal to 10,000.
- **SlippageTooHigh(uint16 slippageBps)**: Slippage must be less than or equal to 500 basis points (5%).
- **TickSpacingMisaligned(int24 tickLower, int24 tickUpper, int24 tickSpacing)**: Ticks must align with the pool's tick spacing.
- **NoAssetsAvailable()**: No tokens available for the operation (zero liquidity).
- **GridNotConfigured(PoolId poolId, address user)**: The user has not configured a grid for this pool.
- **PoolNotInitialized(PoolId poolId)**: The pool has not been initialized yet.
- **GridAlreadyDeployed(PoolId poolId, address user)**: The user already has a deployed grid on this pool.
- **GridNotDeployed(PoolId poolId, address user)**: The user has no deployed grid on this pool.

## Usage

### 1. Deploy the Hook

Deploy a single `GridHook` instance with a reference to the Uniswap V4 `PoolManager`:

```solidity
GridHook hook = new GridHook(poolManager);
```

> The hook address must have the correct least-significant bits set for the enabled callbacks. Use vanity-address mining or `CREATE2` to obtain a compatible address before mainnet deployment.

### 2. Configure a Grid

Any user calls `setGridConfig` to register their grid parameters for a pool. This can be done before or after the pool is initialized:

```solidity
GridTypes.GridConfig memory config = GridTypes.GridConfig({
    gridSpacing: 60,                             // tick distance between each grid order
    maxOrders: 10,                                // number of grid orders to place
    rebalanceThresholdBps: 200,                   // stored for off-chain keeper reference
    distributionType: GridTypes.DistributionType.FLAT, // equal liquidity across orders
    autoRebalance: true                           // stored for off-chain keeper reference
});

hook.setGridConfig(poolKey, config);
```

Distribution weights are computed and stored at configuration time.

| Parameter | Description |
|---|---|
| `gridSpacing` | Tick distance between consecutive grid orders. Must be a multiple of the pool's `tickSpacing` and ≤ 10 000. |
| `maxOrders` | Number of grid orders (1–1 000). |
| `rebalanceThresholdBps` | Tick deviation threshold stored for off-chain keeper reference (≤ 500). |
| `distributionType` | How liquidity is spread across orders: `FLAT`, `LINEAR`, `REVERSE_LINEAR`, `FIBONACCI`, `SIGMOID`, or `LOGARITHMIC`. |
| `autoRebalance` | Stored for off-chain keeper reference. |

### 3. Initialize the Pool

Initialize the Uniswap V4 pool through the `PoolManager` as usual. The `afterInitialize` callback records the initial tick and marks the pool as initialized:

```solidity
poolManager.initialize(poolKey, sqrtPriceX96);
```

### 4. Approve & Deploy the Grid

The user approves the hook to pull tokens, then calls `deployGrid` to place all grid orders on-chain:

```solidity
// Approve the hook to pull tokens
IERC20(token0).approve(address(hook), type(uint256).max);
IERC20(token1).approve(address(hook), type(uint256).max);

// Deploy the grid
uint128 totalLiquidity = 1_000_000e18;
hook.deployGrid(poolKey, totalLiquidity);
```

This distributes `totalLiquidity` across the configured number of orders according to the chosen weight distribution. The hook pulls the required tokens from the caller via `transferFrom`.

### 5. Rebalance the Grid

When the market price moves away from the grid center, call `rebalance` to remove all existing orders and re-deploy them around the new center tick. Anyone can trigger rebalance for any user's grid (keeper-friendly):

```solidity
// Rebalance a specific user's grid (callable by anyone)
hook.rebalance(poolKey, userAddress);
```

The user whose grid is being rebalanced must have token approvals in place, as the hook settles net deltas via `transferFrom`.

### 6. Close the Grid

A user can close their grid at any time to remove all positions and receive tokens back:

```solidity
hook.closeGrid(poolKey);
```

After closing, the user can reconfigure and redeploy a new grid on the same pool.

### 7. Read-Only Helpers

```solidity
// Preview distribution weights without deploying
uint256[] memory weights = hook.previewWeights(10, GridTypes.DistributionType.FIBONACCI);

// Preview grid orders for given parameters
GridTypes.GridOrder[] memory orders = hook.computeGridOrders(
    centerTick, gridSpacing, tickSpacing, maxOrders, weights, totalLiquidity
);

// Query on-chain state
GridTypes.GridConfig memory cfg        = hook.getGridConfig(poolKey, userAddress);
GridTypes.PoolState memory poolState   = hook.getPoolState(poolKey);
GridTypes.UserGridState memory userState = hook.getUserState(poolKey, userAddress);
GridTypes.GridOrder[] memory live       = hook.getGridOrders(poolKey, userAddress);
uint256[] memory planned                = hook.getPlannedWeights(poolKey, userAddress);
```

### End-to-End Example

```solidity
// 1. Deploy hook (address must satisfy hook-flag requirements)
GridHook hook = new GridHook(poolManager);

// 2. Any user configures a 10-order Fibonacci grid
hook.setGridConfig(poolKey, GridTypes.GridConfig({
    gridSpacing: 60,
    maxOrders: 10,
    rebalanceThresholdBps: 300,
    distributionType: GridTypes.DistributionType.FIBONACCI,
    autoRebalance: true
}));

// 3. Initialize the pool (triggers afterInitialize → records tick)
poolManager.initialize(poolKey, sqrtPriceX96);

// 4. Approve tokens and deploy the grid
IERC20(token0).approve(address(hook), type(uint256).max);
IERC20(token1).approve(address(hook), type(uint256).max);
hook.deployGrid(poolKey, 5_000_000e18);

// 5. A keeper rebalances when the price drifts
hook.rebalance(poolKey, msg.sender);

// 6. User closes the grid to withdraw
hook.closeGrid(poolKey);
```

## Architecture

- `src/hooks/GridHook.sol`: singleton hook entrypoint — multi-tenant state container keyed by `(address user, PoolId)`
- `src/libraries/GridTypes.sol`: shared enums and structs (`GridConfig`, `GridOrder`, `PoolState`, `UserGridState`)
- `src/libraries/DistributionWeights.sol`: deterministic weight generation for flat, linear, reverse-linear, Fibonacci, sigmoid, and logarithmic grids
- `test/GridHook.t.sol`: unit tests — permissions, config, deploy, rebalance, close, multi-user isolation
- `test/GridHookFork.t.sol`: fork tests against Unichain mainnet PoolManager — full lifecycle, pull settlement, multi-user, distribution variants

### State Model

| Scope | Key | Struct | Description |
|---|---|---|---|
| Pool-level | `PoolId` | `PoolState` | `initialized`, `currentTick`, `swapCount` |
| User-level | `(address, PoolId)` | `UserGridState` | `deployed`, `gridCenterTick` |
| User-level | `(address, PoolId)` | `GridConfig` | Grid parameters set by the user |
| User-level | `(address, PoolId)` | `uint256[]` | Pre-computed distribution weights |
| User-level | `(address, PoolId)` | `GridOrder[]` | Active grid positions |

### Token Flow (Pull Model)

- **Deploy / Rebalance (owe tokens to pool)**: `IERC20(token).transferFrom(user, poolManager, amount)` → `poolManager.settle()`
- **Rebalance / Close (pool returns tokens)**: `poolManager.take(token, user, amount)`

Users must approve the hook before deploying or rebalancing. The hook never holds user funds at rest.

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