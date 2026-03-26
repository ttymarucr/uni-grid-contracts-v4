// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library GridTypes {
    enum DistributionType {
        FLAT,
        LINEAR,
        REVERSE_LINEAR,
        FIBONACCI
    }

    struct GridConfig {
        int24 gridSpacing;
        uint24 maxOrders;
        uint16 rebalanceThresholdBps;
        DistributionType distributionType;
        bool autoRebalance;
    }

    struct GridOrder {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct PoolRuntimeState {
        bool initialized;
        uint32 liquidityOperations;
        uint32 swapCount;
        int24 lastLowerTick;
        int24 lastUpperTick;
        int256 lastSwapAmountSpecified;
        int24 currentTick;
        int24 gridCenterTick;
        bool gridDeployed;
    }
}