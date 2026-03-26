// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GridTypes} from "./GridTypes.sol";

library DistributionWeights {
    error InvalidGridLength();

    uint256 private constant TOTAL_BPS = 10_000;
    uint256 private constant MAX_GRID_LENGTH = 1_000;

    function getWeights(uint256 gridLength, GridTypes.DistributionType distributionType)
        internal
        pure
        returns (uint256[] memory weights)
    {
        if (gridLength == 0 || gridLength > MAX_GRID_LENGTH) revert InvalidGridLength();

        weights = new uint256[](gridLength);

        if (distributionType == GridTypes.DistributionType.FLAT) {
            uint256 equalWeight = TOTAL_BPS / gridLength;
            for (uint256 index; index < gridLength; ++index) {
                weights[index] = equalWeight;
            }
            return weights;
        }

        if (distributionType == GridTypes.DistributionType.LINEAR) {
            uint256 denominator = gridLength * (gridLength + 1) / 2;
            for (uint256 index; index < gridLength; ++index) {
                weights[index] = ((index + 1) * TOTAL_BPS) / denominator;
            }
            return weights;
        }

        if (distributionType == GridTypes.DistributionType.REVERSE_LINEAR) {
            uint256 denominator = gridLength * (gridLength + 1) / 2;
            for (uint256 index; index < gridLength; ++index) {
                weights[index] = ((gridLength - index) * TOTAL_BPS) / denominator;
            }
            return weights;
        }

        if (gridLength == 1) {
            weights[0] = TOTAL_BPS;
            return weights;
        }

        uint256 total = 2;
        weights[0] = 1;
        weights[1] = 1;

        uint256 previous = 1;
        uint256 current = 1;
        for (uint256 index = 2; index < gridLength; ++index) {
            uint256 nextValue = previous + current;
            weights[index] = nextValue;
            total += nextValue;
            previous = current;
            current = nextValue;
        }

        for (uint256 index; index < gridLength; ++index) {
            weights[index] = (weights[index] * TOTAL_BPS) / total;
        }
    }
}