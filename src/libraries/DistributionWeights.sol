// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { GridTypes } from "./GridTypes.sol";

library DistributionWeights {
    error InvalidGridLength();

    uint256 private constant TOTAL_BPS = 10_000;
    uint256 private constant MAX_GRID_LENGTH = 1000;

    function getWeights(
        uint256 gridLength,
        GridTypes.DistributionType distributionType
    ) internal pure returns (uint256[] memory weights) {
        if (gridLength == 0 || gridLength > MAX_GRID_LENGTH) revert InvalidGridLength();

        weights = new uint256[](gridLength);

        if (distributionType == GridTypes.DistributionType.FLAT) {
            uint256 equalWeight = TOTAL_BPS / gridLength;
            unchecked {
                for (uint256 index; index < gridLength; ++index) {
                    weights[index] = equalWeight;
                }
            }
            return weights;
        }

        if (distributionType == GridTypes.DistributionType.LINEAR) {
            uint256 denominator = gridLength * (gridLength + 1) / 2;
            unchecked {
                for (uint256 index; index < gridLength; ++index) {
                    weights[index] = ((index + 1) * TOTAL_BPS) / denominator;
                }
            }
            return weights;
        }

        if (distributionType == GridTypes.DistributionType.REVERSE_LINEAR) {
            uint256 denominator = gridLength * (gridLength + 1) / 2;
            unchecked {
                for (uint256 index; index < gridLength; ++index) {
                    weights[index] = ((gridLength - index) * TOTAL_BPS) / denominator;
                }
            }
            return weights;
        }

        if (distributionType == GridTypes.DistributionType.SIGMOID) {
            return _sigmoidWeights(gridLength);
        }

        if (distributionType == GridTypes.DistributionType.LOGARITHMIC) {
            return _logarithmicWeights(gridLength);
        }

        if (distributionType == GridTypes.DistributionType.REVERSE_FIBONACCI) {
            return _reverseFibonacciWeights(gridLength);
        }

        if (distributionType == GridTypes.DistributionType.BELL) {
            return _bellWeights(gridLength);
        }

        if (distributionType == GridTypes.DistributionType.U_SHAPE) {
            return _uShapeWeights(gridLength);
        }

        // Fibonacci (default fallback for the enum)
        if (gridLength == 1) {
            weights[0] = TOTAL_BPS;
            return weights;
        }

        uint256 total = 2;
        weights[0] = 1;
        weights[1] = 1;

        uint256 previous = 1;
        uint256 current = 1;
        unchecked {
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

    /// @dev Sigmoid distribution using a piecewise-linear approximation of the
    ///      logistic function centred at the grid midpoint.  Maps each index to
    ///      a value in [1, 1000] that follows an S-shaped curve, then normalises
    ///      to TOTAL_BPS.
    function _sigmoidWeights(
        uint256 gridLength
    ) private pure returns (uint256[] memory weights) {
        weights = new uint256[](gridLength);
        uint256 total;

        unchecked {
            // Scale factor: we work in units of 1e6 to keep integer precision.
            uint256 SCALE = 1e6;

            // steepness controls how sharp the transition is.  A value of 10
            // gives a nice S-curve across the grid range.
            uint256 steepness = 10;

            // Pre-compute constants outside the loop.
            uint256 halfSteepnessScaled = (steepness * SCALE) / 2; // 5e6
            uint256 divisor = gridLength > 1 ? gridLength - 1 : 1;
            // casting is safe: SCALE/2 = 500000 which fits int256
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 HALF = int256(SCALE / 2);
            int256 THRESHOLD = int256((5 * SCALE) / 2); // 2.5 in SCALE
            // casting is safe: 5 * SCALE = 5e6 which fits int256
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 FIVE_SCALE = int256(5 * SCALE);

            for (uint256 i; i < gridLength; ++i) {
                // x ranges from -steepness/2 to +steepness/2 (scaled)
                int256 x;
                if (gridLength == 1) {
                    x = 0;
                } else {
                    // casting is safe: steepness=10, SCALE=1e6, i<1000, divisor>=1 → max ~10e9; halfSteepnessScaled=5e6; both fit int256
                    // forge-lint: disable-next-line(unsafe-typecast)
                    x = int256((steepness * SCALE * i) / divisor) - int256(halfSteepnessScaled);
                }

                // Piecewise-linear sigmoid approximation:
                //   if x < -2.5 => ~0   (mapped to 1 to avoid zero weight)
                //   if x >  2.5 => ~1   (mapped to SCALE)
                //   else        => linear interpolation 0.5 + x/5
                uint256 value;
                if (x < -THRESHOLD) {
                    value = 1; // floor — avoid zero
                } else if (x > THRESHOLD) {
                    value = SCALE;
                } else {
                    // 0.5 + x / 5  (all in SCALE)
                    // casting is safe: SCALE = 1e6 fits int256; result > 0 guard ensures uint256 cast is non-negative
                    // forge-lint: disable-next-line(unsafe-typecast)
                    int256 result = HALF + (x * int256(SCALE)) / FIVE_SCALE;
                    // forge-lint: disable-next-line(unsafe-typecast)
                    value = result > 0 ? uint256(result) : 1;
                }

                weights[i] = value;
                total += value;
            }

            // Normalise to TOTAL_BPS
            for (uint256 i; i < gridLength; ++i) {
                weights[i] = (weights[i] * TOTAL_BPS) / total;
            }
        }
    }

    /// @dev Reverse Fibonacci: same Fibonacci sequence but mirrored so the
    ///      highest weight is at index 0 and the lowest at the end.
    function _reverseFibonacciWeights(
        uint256 gridLength
    ) private pure returns (uint256[] memory weights) {
        weights = new uint256[](gridLength);

        if (gridLength == 1) {
            weights[0] = TOTAL_BPS;
            return weights;
        }

        uint256 total = 2;
        uint256[] memory fwd = new uint256[](gridLength);
        fwd[0] = 1;
        fwd[1] = 1;

        uint256 previous = 1;
        uint256 current = 1;
        unchecked {
            for (uint256 i = 2; i < gridLength; ++i) {
                uint256 nextValue = previous + current;
                fwd[i] = nextValue;
                total += nextValue;
                previous = current;
                current = nextValue;
            }

            // Reverse: weights[i] = fwd[gridLength - 1 - i]
            for (uint256 i; i < gridLength; ++i) {
                weights[i] = (fwd[gridLength - 1 - i] * TOTAL_BPS) / total;
            }
        }
    }

    /// @dev Bell distribution: high liquidity at the center, tapering linearly
    ///      and symmetrically toward both edges.  For neutral / range-bound
    ///      markets where price oscillates around the current level.
    ///      weight[i] = distance_from_nearest_edge + 1  (triangle peak at centre).
    function _bellWeights(
        uint256 gridLength
    ) private pure returns (uint256[] memory weights) {
        weights = new uint256[](gridLength);
        uint256 total;

        unchecked {
            for (uint256 i; i < gridLength; ++i) {
                uint256 distFromEdge = i < gridLength - 1 - i ? i : gridLength - 1 - i;
                uint256 value = distFromEdge + 1;
                weights[i] = value;
                total += value;
            }

            for (uint256 i; i < gridLength; ++i) {
                weights[i] = (weights[i] * TOTAL_BPS) / total;
            }
        }
    }

    /// @dev U-shape distribution: high liquidity at both edges, tapering
    ///      linearly toward the center.  For high-volatility markets where
    ///      price swings between extremes.
    ///      weight[i] = distance_from_center + 1  (valleys at centre, peaks at edges).
    function _uShapeWeights(
        uint256 gridLength
    ) private pure returns (uint256[] memory weights) {
        weights = new uint256[](gridLength);
        uint256 total;

        unchecked {
            for (uint256 i; i < gridLength; ++i) {
                uint256 distFromCenter = i > gridLength - 1 - i ? i : gridLength - 1 - i;
                uint256 value = distFromCenter + 1;
                weights[i] = value;
                total += value;
            }

            for (uint256 i; i < gridLength; ++i) {
                weights[i] = (weights[i] * TOTAL_BPS) / total;
            }
        }
    }

    /// @dev Logarithmic distribution: weight[i] = ln(i + 2).
    ///      Uses an integer log2 approximation and the identity
    ///      ln(x) ≈ log2(x) * ln(2) ≈ log2(x) * 6931 / 10000.
    ///      This produces a concave curve that gives more weight to earlier
    ///      intervals with diminishing increases toward the end.
    function _logarithmicWeights(
        uint256 gridLength
    ) private pure returns (uint256[] memory weights) {
        weights = new uint256[](gridLength);
        uint256 total;

        unchecked {
            for (uint256 i; i < gridLength; ++i) {
                // ln(i + 2) so the first weight is ln(2) ≈ 6931 (scaled)
                uint256 value = _lnScaled(i + 2);
                weights[i] = value;
                total += value;
            }

            // Normalise to TOTAL_BPS
            for (uint256 i; i < gridLength; ++i) {
                weights[i] = (weights[i] * TOTAL_BPS) / total;
            }
        }
    }

    /// @dev Returns ln(x) * 1e4 using integer log2 and the conversion factor
    ///      ln(x) = log2(x) * ln(2).  Precision is sufficient for weight
    ///      distribution purposes.  x must be >= 1.
    function _lnScaled(
        uint256 x
    ) private pure returns (uint256) {
        // Compute integer part of log2 using binary search (constant-time).
        uint256 log2Int;
        assembly {
            let v := x
            let half := shr(128, v)
            if half {
                log2Int := 128
                v := half
            }
            half := shr(64, v)
            if half {
                log2Int := or(log2Int, 64)
                v := half
            }
            half := shr(32, v)
            if half {
                log2Int := or(log2Int, 32)
                v := half
            }
            half := shr(16, v)
            if half {
                log2Int := or(log2Int, 16)
                v := half
            }
            half := shr(8, v)
            if half {
                log2Int := or(log2Int, 8)
                v := half
            }
            half := shr(4, v)
            if half {
                log2Int := or(log2Int, 4)
                v := half
            }
            half := shr(2, v)
            if half {
                log2Int := or(log2Int, 2)
                v := half
            }
            half := shr(1, v)
            if half { log2Int := or(log2Int, 1) }
        }

        unchecked {
            // Fractional refinement: use the remaining bits for one level of
            // interpolation.  frac = (x - 2^log2Int) / 2^log2Int  (in 1e4)
            // 1 << log2Int correctly computes 2^log2Int
            // forge-lint: disable-next-line(incorrect-shift)
            uint256 power = 1 << log2Int;
            uint256 frac = ((x - power) * 10_000) / power;

            // log2(x) ≈ log2Int + frac/10000  (frac already in 1e4)
            // ln(x)   = log2(x) * 6931 / 10000
            uint256 log2Scaled = log2Int * 10_000 + frac; // in 1e4
            return (log2Scaled * 6931) / 10_000; // ln scaled by 1e4
        }
    }
}
