// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library GridTypes {
    enum DistributionType {
        FLAT,
        LINEAR,
        REVERSE_LINEAR,
        FIBONACCI,
        SIGMOID,
        LOGARITHMIC
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

    struct PoolState {
        bool initialized;
        int24 currentTick;
        uint32 swapCount;
    }

    struct UserGridState {
        bool deployed;
        int24 gridCenterTick;
    }
}
