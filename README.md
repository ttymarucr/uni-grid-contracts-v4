# Uniswap V4 Grid Hook Strategy

## Overview

This repository provides a set of smart contracts and tools designed to implement a grid trading strategy on Uniswap V4. Grid trading is a systematic trading approach that places buy and sell orders at predefined price intervals, enabling automated and efficient liquidity management.

The hook is deployed as a **singleton** — a single `GridHook` instance serves all users. Each user independently configures, deploys, rebalances, and closes their own grid on any pool. There is no admin or owner role; the contract is fully permissionless.

## Purpose

The purpose of this project is to leverage Uniswap V4's concentrated liquidity model to implement a grid trading strategy. By utilizing the flexibility of Uniswap V4 Hooks, these contracts allow users to optimize their liquidity positions, capture profits from price fluctuations within a specified range, and customize liquidity distribution across grid positions. The ability to distribute liquidity using various strategies, such as flat, linear, Fibonacci, and more, provides users with enhanced control and adaptability to different market conditions.

## Features

- **Singleton Multi-Tenant**: One deployed hook supports all users. Each user manages their own grid independently.
- **Permissionless**: No admin or owner role. Any user can configure and deploy a grid on any initialized pool.
- **Permit2 Token Settlement**: Users approve tokens via [Permit2](https://github.com/Uniswap/permit2). The hook pulls tokens through `permit2.transferFrom` at deploy/rebalance time. No need to pre-fund the contract.
- **Smart Account Safe**: Inherits `Permit2Forwarder` and `Multicall_v4` from v4-periphery. Compatible with smart contract wallets — no `tx.origin` dependency. ETH refunds are sent back to `msg.sender` after each operation.
- **Keeper-Authorized Rebalance**: Users authorize specific keeper addresses via `setRebalanceKeeper`. Only the grid owner or an authorized keeper can trigger `rebalance`.
- **Slippage Protection**: `deployGrid` accepts `maxDelta0` / `maxDelta1` parameters to cap token amounts. `rebalance` reads slippage bounds (`maxSlippageDelta0` / `maxSlippageDelta1`) from the user's stored `GridConfig`, preventing keepers from choosing permissive slippage.
- **Deadline Protection**: All mutative grid operations (`deployGrid`, `rebalance`, `closeGrid`) require a `deadline` parameter and revert with `DeadlineExpired` if `block.timestamp > deadline`.
- **On-Chain Rebalance Threshold**: `rebalanceThresholdBps` is enforced on-chain — the rebalance reverts with `RebalanceThresholdNotMet` if the tick has not moved far enough, preventing no-op or dust rebalances.
- **Reentrancy Guard**: All external payable entry points use a transient-storage–based reentrancy lock, preventing `multicall` + `msg.value` reuse and other reentrancy vectors.
- **Native ETH Support**: Grid operations are `payable` and the settlement layer handles native ETH pools automatically. `receive()` is restricted to the PoolManager.
- **Close Grid**: Users can close their grid at any time to remove all positions and receive tokens back.
- **Automated Liquidity Management**: Deploy and manage liquidity positions across multiple price ranges.
- **Customizable Parameters**: Define grid intervals, distribution type, slippage bounds, and liquidity amounts per user per pool.
- **Liquidity Distribution**: Distribute liquidity across grid positions using flat, linear, reverse linear, Fibonacci, sigmoid, or logarithmic distributions.
- **Deterministic Deployment**: CREATE2-based deploy script with automatic salt mining for hook-flag-compatible addresses. Supports multi-chain deterministic deploys.

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

- **NotPoolManager()**: The caller is not the PoolManager (enforced on callbacks and `receive()`).
- **PoolManagerAddressZero()**: The pool manager address cannot be zero.
- **Permit2AddressZero()**: The Permit2 address cannot be zero.
- **ETHRefundFailed()**: The ETH refund transfer to `msg.sender` failed.
- **InvalidGridQuantity(uint256 quantity)**: The grid quantity must be greater than 0 and less than or equal to 500.
- **InvalidGridStep(uint256 stepBps)**: The grid step must be greater than 0 and less than or equal to 10,000.
- **SlippageTooHigh(uint16 slippageBps)**: Slippage must be less than or equal to 500 basis points (5%).
- **TickSpacingMisaligned(int24 tickLower, int24 tickUpper, int24 tickSpacing)**: Ticks must align with the pool's tick spacing.
- **NoAssetsAvailable()**: No tokens available for the operation (zero liquidity).
- **GridNotConfigured(PoolId poolId, address user)**: The user has not configured a grid for this pool.
- **PoolNotInitialized(PoolId poolId)**: The pool has not been initialized yet.
- **GridAlreadyDeployed(PoolId poolId, address user)**: The user already has a deployed grid on this pool.
- **GridNotDeployed(PoolId poolId, address user)**: The user has no deployed grid on this pool.
- **NotAuthorizedRebalancer(address caller, address user)**: The caller is not the grid owner and has not been authorized as a keeper for that user.
- **SlippageExceeded(int128 actual0, int128 actual1, uint128 maxDelta0, uint128 maxDelta1)**: The net token delta exceeded the slippage bounds.
- **TickRangeOutOfBounds(int24 bottomTick, int24 topTick)**: The computed grid range falls outside the valid tick range (`TickMath.MIN_TICK` / `TickMath.MAX_TICK`).
- **DeadlineExpired()**: The transaction was submitted after the caller-specified deadline.
- **RebalanceThresholdNotMet(int24 tickDelta, int24 minTickDelta)**: The tick has not moved far enough from the grid center to justify a rebalance.
- **Reentrancy()**: A reentrant call was detected.

## Usage

### 1. Deploy the Hook

Deploy a single `GridHook` instance with references to the Uniswap V4 `PoolManager` and the canonical `Permit2` contract:

```solidity
GridHook hook = new GridHook(poolManager, permit2);
```

> The hook address must have the correct least-significant bits set for the enabled callbacks. Use vanity-address mining or `CREATE2` to obtain a compatible address before mainnet deployment.

### 2. Configure a Grid

Any user calls `setGridConfig` to register their grid parameters for a pool. This can be done before or after the pool is initialized:

```solidity
GridTypes.GridConfig memory config = GridTypes.GridConfig({
    gridSpacing: 60,                             // tick distance between each grid order
    maxOrders: 10,                                // number of grid orders to place
    rebalanceThresholdBps: 200,                   // min tick delta to allow rebalance (enforced on-chain)
    distributionType: GridTypes.DistributionType.FLAT, // equal liquidity across orders
    autoRebalance: true,                          // stored for off-chain keeper reference
    maxSlippageDelta0: 0,                         // max token0 slippage for rebalance (0 = no limit)
    maxSlippageDelta1: 0                          // max token1 slippage for rebalance (0 = no limit)
});

hook.setGridConfig(poolKey, config);
```

Distribution weights are computed and stored at configuration time.

| Parameter | Description |
|---|---|
| `gridSpacing` | Tick distance between consecutive grid orders. Must be a multiple of the pool's `tickSpacing` and ≤ 10 000. |
| `maxOrders` | Number of grid orders (1–500). |
| `rebalanceThresholdBps` | Minimum tick movement (as fraction of `gridSpacing`) required to allow a rebalance. Enforced on-chain (≤ 500). |
| `distributionType` | How liquidity is spread across orders: `FLAT`, `LINEAR`, `REVERSE_LINEAR`, `FIBONACCI`, `SIGMOID`, or `LOGARITHMIC`. |
| `autoRebalance` | Stored for off-chain keeper reference. |
| `maxSlippageDelta0` | Maximum absolute token0 delta allowed during rebalance. Set by the user, not the keeper. `0` disables the check. |
| `maxSlippageDelta1` | Maximum absolute token1 delta allowed during rebalance. Set by the user, not the keeper. `0` disables the check. |

### 3. Initialize the Pool

Initialize the Uniswap V4 pool through the `PoolManager` as usual. The `afterInitialize` callback records the initial tick and marks the pool as initialized:

```solidity
poolManager.initialize(poolKey, sqrtPriceX96);
```

### 4. Approve via Permit2 & Deploy the Grid

The user approves tokens through [Permit2](https://github.com/Uniswap/permit2), then calls `deployGrid` to place all grid orders on-chain. The `maxDelta0` and `maxDelta1` parameters provide slippage protection — the call reverts if the pool requires more tokens than these bounds (pass `0` to disable the check for a given token). A `deadline` parameter ensures the transaction cannot be executed after a specified timestamp:

```solidity
// Step 1: Approve Permit2 to spend your tokens (one-time)
IERC20(token0).approve(PERMIT2, type(uint256).max);
IERC20(token1).approve(PERMIT2, type(uint256).max);

// Step 2: Grant the hook an allowance on Permit2
IAllowanceTransfer(PERMIT2).approve(token0, address(hook), type(uint160).max, type(uint48).max);
IAllowanceTransfer(PERMIT2).approve(token1, address(hook), type(uint160).max, type(uint48).max);

// Step 3: Deploy the grid with slippage bounds and deadline
uint128 totalLiquidity = 1_000_000e18;
uint256 deadline = block.timestamp + 300; // 5 minutes
hook.deployGrid(poolKey, totalLiquidity, maxDelta0, maxDelta1, deadline);
```

This distributes `totalLiquidity` across the configured number of orders according to the chosen weight distribution. The hook pulls the required tokens from the caller via `permit2.transferFrom`.

### 5. Authorize Keepers (Optional)

A user can authorize specific addresses to trigger rebalance on their behalf. This enables automated keeper bots while keeping the operation permissioned:

```solidity
// Authorize a keeper
hook.setRebalanceKeeper(keeperAddress, true);

// Revoke authorization
hook.setRebalanceKeeper(keeperAddress, false);

// Check authorization
bool authorized = hook.isRebalanceKeeper(userAddress, keeperAddress);
```

### 6. Rebalance the Grid

When the market price moves away from the grid center, call `rebalance` to remove all existing orders and re-deploy them around the new center tick. Only the grid owner or an authorized keeper can trigger rebalance.

Slippage bounds are read from the user's stored `GridConfig` (`maxSlippageDelta0` / `maxSlippageDelta1`), not from the caller — this prevents keepers from choosing permissive slippage. The on-chain `rebalanceThresholdBps` check also ensures the tick has moved far enough to justify the rebalance:

```solidity
// Rebalance your own grid
hook.rebalance(poolKey, msg.sender, deadline);

// A keeper rebalances a user's grid (requires prior authorization)
hook.rebalance(poolKey, userAddress, deadline);
```

The user whose grid is being rebalanced must have Permit2 approvals in place, as the hook settles net deltas via `permit2.transferFrom`.

### 7. Close the Grid

A user can close their grid at any time to remove all positions and receive tokens back:

```solidity
hook.closeGrid(poolKey, deadline);
```

After closing, the user can reconfigure and redeploy a new grid on the same pool.

### 8. Read-Only Helpers

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
GridHook hook = new GridHook(poolManager, permit2);

// 2. Any user configures a 10-order Fibonacci grid with slippage bounds
hook.setGridConfig(poolKey, GridTypes.GridConfig({
    gridSpacing: 60,
    maxOrders: 10,
    rebalanceThresholdBps: 300,
    distributionType: GridTypes.DistributionType.FIBONACCI,
    autoRebalance: true,
    maxSlippageDelta0: 1e18,    // max 1 token0 slippage on rebalance
    maxSlippageDelta1: 2000e6   // max 2000 token1 slippage on rebalance
}));

// 3. Initialize the pool (triggers afterInitialize → records tick)
poolManager.initialize(poolKey, sqrtPriceX96);

// 4. Approve tokens via Permit2 and deploy the grid
IERC20(token0).approve(PERMIT2, type(uint256).max);
IERC20(token1).approve(PERMIT2, type(uint256).max);
IAllowanceTransfer(PERMIT2).approve(token0, address(hook), type(uint160).max, type(uint48).max);
IAllowanceTransfer(PERMIT2).approve(token1, address(hook), type(uint160).max, type(uint48).max);
hook.deployGrid(poolKey, 5_000_000e18, maxDelta0, maxDelta1, block.timestamp + 300);

// 5. Authorize a keeper for automated rebalancing
hook.setRebalanceKeeper(keeperAddress, true);

// 6. A keeper rebalances when the price drifts (slippage from config, not caller)
hook.rebalance(poolKey, msg.sender, block.timestamp + 300);

// 7. User closes the grid to withdraw
hook.closeGrid(poolKey, block.timestamp + 300);
```

## Architecture

- `src/hooks/GridHook.sol`: singleton hook entrypoint — multi-tenant state container keyed by `(address user, PoolId)`. Inherits `Permit2Forwarder` and `Multicall_v4` from v4-periphery. Includes Permit2 settlement, keeper authorization, slippage protection, deadline enforcement, on-chain rebalance threshold, reentrancy guard, and native ETH settlement.
- `src/libraries/GridTypes.sol`: shared enums and structs (`GridConfig`, `GridOrder`, `PoolState`, `UserGridState`)
- `src/libraries/DistributionWeights.sol`: deterministic weight generation for flat, linear, reverse-linear, Fibonacci, sigmoid, and logarithmic grids
- `script/DeployGridHook.s.sol`: CREATE2 deployment script with automatic salt mining for hook-flag-compatible addresses. Supports multi-chain deterministic deploys.
- `script/deploy-all-chains.sh`: shell wrapper to deploy the hook across multiple chains.
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

### Token Flow (Pull Model via Permit2)

- **Deploy / Rebalance (owe tokens to pool)**: For ERC-20 tokens — `permit2.transferFrom(user, poolManager, amount, token)` → `poolManager.settle()`. For native ETH — `poolManager.settle{value: amount}()`.
- **Rebalance / Close (pool returns tokens)**: `poolManager.take(token, user, amount)`

Users must approve the hook through Permit2 before deploying or rebalancing. The hook never holds user funds at rest. Grid operations (`deployGrid`, `rebalance`, `closeGrid`) are `payable` to support native ETH pools. Excess ETH is refunded to `msg.sender` after each operation.

### Fee Settlement

Uniswap v4 does not auto-compound fees. When liquidity is removed (during `rebalance` or `closeGrid`), accrued fees are included in the `BalanceDelta` returned by `modifyLiquidity`. The hook settles these deltas back to **the grid owner** — not the caller. This means:

- When a **keeper** triggers `rebalance`, earned fees flow to the user whose grid is being rebalanced. The keeper pays nothing and receives nothing.
- During `closeGrid`, all accrued fees are returned to the user along with the principal.
- Fees are **not** reinvested into new positions. They are settled as a net token transfer to the grid owner after each operation.

## Hook Model

The starter hook enables these callbacks:

- `afterInitialize`
- `afterAddLiquidity`
- `afterRemoveLiquidity`
- `afterSwap`

Uniswap v4 activates hooks from the least-significant bits of the deployed hook address. This repo exposes the required flag bitmap through `GridHook.requiredHookFlags()` so deployment tooling can mine or derive a compatible address.

A CREATE2 deployment script (`script/DeployGridHook.s.sol`) is included that automatically mines a valid salt and deploys to a flag-compatible address. Use `script/deploy-all-chains.sh` for deterministic multi-chain deploys.

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
- `v4-periphery` (provides `Permit2Forwarder`, `Multicall_v4`)
- `permit2` (canonical Permit2 contract, nested via `v4-periphery/lib/permit2/`)
- `openzeppelin-contracts`
- `forge-std`

## Contributing

Contributions are welcome! Please submit issues or pull requests to help improve the project. For major changes, please open an issue first to discuss your ideas.

## License

This project is licensed under the [MIT License](LICENSE).