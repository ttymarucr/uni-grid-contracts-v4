// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @title SwapRouter
/// @notice Minimal router for executing single-pool swaps against Uniswap v4 PoolManager.
///         Uses the unlock/callback pattern required by PoolManager and settles via Permit2.
contract SwapRouter is IUnlockCallback {
    IPoolManager public immutable poolManager;
    IAllowanceTransfer public immutable permit2;

    error NotPoolManager();
    error SwapFailed();
    error ETHRefundFailed();

    constructor(IPoolManager _poolManager, IAllowanceTransfer _permit2) {
        poolManager = _poolManager;
        permit2 = _permit2;
    }

    /// @notice Execute a single-pool swap.
    /// @param key The PoolKey identifying the pool (includes hook address).
    /// @param params SwapParams: zeroForOne, amountSpecified, sqrtPriceLimitX96.
    /// @param hookData Arbitrary data forwarded to the hook's beforeSwap/afterSwap.
    /// @return delta The balance delta from the swap.
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external payable returns (BalanceDelta delta) {
        bytes memory result = poolManager.unlock(
            abi.encode(msg.sender, key, params, hookData)
        );
        delta = abi.decode(result, (BalanceDelta));

        // Refund any excess ETH
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool ok,) = msg.sender.call{ value: balance }("");
            if (!ok) revert ETHRefundFailed();
        }
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (address user, PoolKey memory key, SwapParams memory params, bytes memory hookData) =
            abi.decode(data, (address, PoolKey, SwapParams, bytes));

        BalanceDelta delta = poolManager.swap(key, params, hookData);

        // delta.amount0() < 0 means user owes token0 to the pool
        // delta.amount0() > 0 means pool owes token0 to the user
        _settleDelta(key.currency0, user, delta.amount0());
        _settleDelta(key.currency1, user, delta.amount1());

        return abi.encode(delta);
    }

    function _settleDelta(Currency currency, address user, int128 delta) internal {
        if (delta < 0) {
            // User owes tokens to the pool
            uint256 amount = uint256(uint128(-delta));
            if (Currency.unwrap(currency) == address(0)) {
                poolManager.settle{ value: amount }();
            } else {
                poolManager.sync(currency);
                permit2.transferFrom(user, address(poolManager), uint160(amount), Currency.unwrap(currency));
                poolManager.settle();
            }
        } else if (delta > 0) {
            // Pool owes tokens to the user
            poolManager.take(currency, user, uint256(uint128(delta)));
        }
    }

    receive() external payable {}
}
