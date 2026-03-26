// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {GridTypes} from "../libraries/GridTypes.sol";
import {DistributionWeights} from "../libraries/DistributionWeights.sol";

contract GridHook is IHooks, IUnlockCallback, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 private constant MAX_GRID_ORDERS = 1_000;
    uint16 private constant MAX_SLIPPAGE_BPS = 500;

    enum UnlockAction {
        DEPLOY_GRID,
        REBALANCE
    }

    error NotPoolManager();
    error PoolAddressZero();
    error PositionManagerAddressZero();
    error InvalidGridQuantity(uint256 quantity);
    error InvalidGridStep(uint256 stepBps);
    error InvalidTokenAmountsForGridType();
    error SlippageTooHigh(uint16 slippageBps);
    error MaxActivePositionsExceeded(uint256 activePositions);
    error TickSpacingMisaligned(int24 tickLower, int24 tickUpper, int24 tickSpacing);
    error NoAssetsAvailable();
    error PriceDeviationTooHigh(uint256 observedDeviationBps, uint256 maxDeviationBps);
    error PositionNotFound(bytes32 positionKey);
    error MissingToken1ForBuyGrid();
    error MissingToken0ForSellGrid();
    error MissingTokenAmountForAddLiquidity();
    error DistributionTypeNotImplemented(GridTypes.DistributionType distributionType);
    error PoolNotConfigured(PoolId poolId);
    error PoolNotInitialized(PoolId poolId);
    error GridAlreadyDeployed(PoolId poolId);
    error GridNotDeployed(PoolId poolId);

    event PoolConfigured(
        PoolId indexed poolId,
        int24 gridSpacing,
        uint24 maxOrders,
        uint16 rebalanceThresholdBps,
        GridTypes.DistributionType distributionType,
        bool autoRebalance
    );

    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tick);

    event PoolInitializationPlanned(
        PoolId indexed poolId, uint24 orderCount, GridTypes.DistributionType distributionType
    );

    event LiquidityObserved(
        PoolId indexed poolId,
        bool isAdd,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        bytes32 salt
    );

    event SwapObserved(PoolId indexed poolId, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96);

    event GridDeployed(PoolId indexed poolId, uint24 orderCount, uint128 totalLiquidity);
    event GridRebalanced(PoolId indexed poolId, int24 oldCenterTick, int24 newCenterTick);
    event RebalanceNeeded(PoolId indexed poolId, int24 currentTick, int24 gridCenterTick, uint256 deviationTicks);

    IPoolManager public immutable poolManager;

    mapping(PoolId poolId => GridTypes.GridConfig config) private _poolConfigs;
    mapping(PoolId poolId => GridTypes.PoolRuntimeState state) private _poolStates;
    mapping(PoolId poolId => uint256[] weights) private _plannedWeights;
    mapping(PoolId poolId => GridTypes.GridOrder[] orders) private _gridOrders;

    constructor(IPoolManager poolManager_, address initialOwner) Ownable(initialOwner) {
        if (address(poolManager_) == address(0)) revert PositionManagerAddressZero();
        poolManager = poolManager_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function setPoolConfig(PoolKey calldata key, GridTypes.GridConfig calldata config) external onlyOwner {
        uint256 spacing = config.gridSpacing > 0 ? uint256(uint24(config.gridSpacing)) : 0;
        if (spacing == 0 || spacing > 10_000) revert InvalidGridStep(spacing);
        if (config.maxOrders == 0 || config.maxOrders > MAX_GRID_ORDERS) {
            revert InvalidGridQuantity(config.maxOrders);
        }
        if (config.rebalanceThresholdBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh(config.rebalanceThresholdBps);

        PoolId poolId = key.toId();
        _poolConfigs[poolId] = config;

        emit PoolConfigured(
            poolId,
            config.gridSpacing,
            config.maxOrders,
            config.rebalanceThresholdBps,
            config.distributionType,
            config.autoRebalance
        );
    }

    function getPoolConfig(PoolKey calldata key) external view returns (GridTypes.GridConfig memory) {
        return _poolConfigs[key.toId()];
    }

    function getPoolState(PoolKey calldata key) external view returns (GridTypes.PoolRuntimeState memory) {
        return _poolStates[key.toId()];
    }

    function getPlannedWeights(PoolKey calldata key) external view returns (uint256[] memory) {
        return _plannedWeights[key.toId()];
    }

    function getGridOrders(PoolKey calldata key) external view returns (GridTypes.GridOrder[] memory) {
        return _gridOrders[key.toId()];
    }

    // --- Grid Operations ---

    function deployGrid(PoolKey calldata key, uint128 totalLiquidity) external onlyOwner {
        PoolId poolId = key.toId();
        _requireConfigured(poolId);

        GridTypes.PoolRuntimeState storage state = _poolStates[poolId];
        if (!state.initialized) revert PoolNotInitialized(poolId);
        if (state.gridDeployed) revert GridAlreadyDeployed(poolId);
        if (totalLiquidity == 0) revert NoAssetsAvailable();

        GridTypes.GridConfig storage config = _poolConfigs[poolId];
        if (config.gridSpacing % key.tickSpacing != 0) {
            revert TickSpacingMisaligned(config.gridSpacing, key.tickSpacing, key.tickSpacing);
        }

        poolManager.unlock(abi.encode(uint8(UnlockAction.DEPLOY_GRID), abi.encode(key, totalLiquidity)));
    }

    function rebalance(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        _requireConfigured(poolId);

        GridTypes.PoolRuntimeState storage state = _poolStates[poolId];
        if (!state.gridDeployed) revert GridNotDeployed(poolId);

        poolManager.unlock(abi.encode(uint8(UnlockAction.REBALANCE), abi.encode(key)));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));

        if (action == uint8(UnlockAction.DEPLOY_GRID)) {
            (PoolKey memory key, uint128 totalLiquidity) = abi.decode(payload, (PoolKey, uint128));
            _executeDeploy(key, totalLiquidity);
        } else {
            PoolKey memory key = abi.decode(payload, (PoolKey));
            _executeRebalance(key);
        }

        return "";
    }

    // --- Utility ---

    function computePositionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        pure
        returns (bytes32)
    {
        return Position.calculatePositionKey(owner, tickLower, tickUpper, salt);
    }

    function previewWeights(uint256 gridLength, GridTypes.DistributionType distributionType)
        external
        pure
        returns (uint256[] memory)
    {
        return DistributionWeights.getWeights(gridLength, distributionType);
    }

    function computeGridOrders(
        int24 centerTick,
        int24 gridSpacing,
        int24 tickSpacing,
        uint24 maxOrders,
        uint256[] memory weights,
        uint128 totalLiquidity
    ) external pure returns (GridTypes.GridOrder[] memory) {
        return _computeGridOrders(centerTick, gridSpacing, tickSpacing, maxOrders, weights, totalLiquidity);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions = Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function requiredHookFlags() public pure returns (uint160) {
        return Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_SWAP_FLAG;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        _requireConfigured(poolId);

        GridTypes.GridConfig storage config = _poolConfigs[poolId];
        _plannedWeights[poolId] = DistributionWeights.getWeights(config.maxOrders, config.distributionType);

        GridTypes.PoolRuntimeState storage state = _poolStates[poolId];
        state.initialized = true;
        state.currentTick = tick;
        state.gridCenterTick = _alignTick(tick, key.tickSpacing);

        emit PoolInitialized(poolId, sqrtPriceX96, tick);
        emit PoolInitializationPlanned(poolId, config.maxOrders, config.distributionType);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        _requireConfigured(poolId);

        GridTypes.PoolRuntimeState storage state = _poolStates[poolId];
        state.liquidityOperations += 1;
        state.lastLowerTick = params.tickLower;
        state.lastUpperTick = params.tickUpper;

        emit LiquidityObserved(poolId, true, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        _requireConfigured(poolId);

        GridTypes.PoolRuntimeState storage state = _poolStates[poolId];
        state.liquidityOperations += 1;
        state.lastLowerTick = params.tickLower;
        state.lastUpperTick = params.tickUpper;

        emit LiquidityObserved(poolId, false, params.tickLower, params.tickUpper, params.liquidityDelta, params.salt);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        _requireConfigured(poolId);

        GridTypes.PoolRuntimeState storage state = _poolStates[poolId];
        state.swapCount += 1;
        state.lastSwapAmountSpecified = params.amountSpecified;

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        state.currentTick = currentTick;

        if (state.gridDeployed) {
            GridTypes.GridConfig storage config = _poolConfigs[poolId];
            if (config.autoRebalance) {
                int24 center = state.gridCenterTick;
                int24 diff = currentTick > center ? currentTick - center : center - currentTick;
                uint256 deviation = uint256(int256(diff));
                if (deviation >= uint256(config.rebalanceThresholdBps)) {
                    emit RebalanceNeeded(poolId, currentTick, center, deviation);
                }
            }
        }

        emit SwapObserved(poolId, params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96);
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // --- Internal: Unlock Actions ---

    function _executeDeploy(PoolKey memory key, uint128 totalLiquidity) internal {
        PoolId poolId = key.toId();
        GridTypes.GridConfig storage config = _poolConfigs[poolId];
        GridTypes.PoolRuntimeState storage state = _poolStates[poolId];

        int24 centerTick = state.gridCenterTick;

        GridTypes.GridOrder[] memory orders = _computeGridOrders(
            centerTick, config.gridSpacing, key.tickSpacing, config.maxOrders, _plannedWeights[poolId], totalLiquidity
        );

        delete _gridOrders[poolId];

        (int128 totalDelta0, int128 totalDelta1) = _placeOrders(key, poolId, orders);

        _settleDeltas(key, totalDelta0, totalDelta1);

        state.gridDeployed = true;
        emit GridDeployed(poolId, config.maxOrders, totalLiquidity);
    }

    function _executeRebalance(PoolKey memory key) internal {
        PoolId poolId = key.toId();

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        int24 oldCenter = _poolStates[poolId].gridCenterTick;

        (int128 removeDelta0, int128 removeDelta1, uint128 totalLiquidity) = _removeAllOrders(key, poolId);
        delete _gridOrders[poolId];

        int24 newCenter = _alignTick(currentTick, key.tickSpacing);
        (int128 addDelta0, int128 addDelta1) = _rebalancePlaceNewOrders(key, poolId, newCenter, totalLiquidity);

        _settleDeltas(key, removeDelta0 + addDelta0, removeDelta1 + addDelta1);

        _poolStates[poolId].gridCenterTick = newCenter;
        _poolStates[poolId].currentTick = currentTick;

        emit GridRebalanced(poolId, oldCenter, newCenter);
    }

    function _rebalancePlaceNewOrders(PoolKey memory key, PoolId poolId, int24 newCenter, uint128 totalLiquidity)
        internal
        returns (int128, int128)
    {
        GridTypes.GridConfig storage config = _poolConfigs[poolId];
        GridTypes.GridOrder[] memory newOrders = _computeGridOrders(
            newCenter, config.gridSpacing, key.tickSpacing, config.maxOrders, _plannedWeights[poolId], totalLiquidity
        );
        return _placeOrders(key, poolId, newOrders);
    }

    function _removeAllOrders(PoolKey memory key, PoolId poolId)
        internal
        returns (int128 totalDelta0, int128 totalDelta1, uint128 totalLiquidity)
    {
        GridTypes.GridOrder[] storage existingOrders = _gridOrders[poolId];
        uint256 orderCount = existingOrders.length;

        for (uint256 i; i < orderCount; ++i) {
            GridTypes.GridOrder storage order = existingOrders[i];
            totalLiquidity += order.liquidity;

            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: order.tickLower,
                    tickUpper: order.tickUpper,
                    liquidityDelta: -int256(uint256(order.liquidity)),
                    salt: bytes32(uint256(i))
                }),
                ""
            );

            totalDelta0 += callerDelta.amount0();
            totalDelta1 += callerDelta.amount1();
        }
    }

    function _placeOrders(PoolKey memory key, PoolId poolId, GridTypes.GridOrder[] memory orders)
        internal
        returns (int128 totalDelta0, int128 totalDelta1)
    {
        for (uint256 i; i < orders.length; ++i) {
            _gridOrders[poolId].push(orders[i]);

            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: orders[i].tickLower,
                    tickUpper: orders[i].tickUpper,
                    liquidityDelta: int256(uint256(orders[i].liquidity)),
                    salt: bytes32(uint256(i))
                }),
                ""
            );

            totalDelta0 += callerDelta.amount0();
            totalDelta1 += callerDelta.amount1();
        }
    }

    // --- Internal: Settlement ---

    function _settleDeltas(PoolKey memory key, int128 delta0, int128 delta1) internal {
        if (delta0 < 0) {
            poolManager.sync(key.currency0);
            key.currency0.transfer(address(poolManager), uint256(uint128(-delta0)));
            poolManager.settle();
        } else if (delta0 > 0) {
            poolManager.take(key.currency0, address(this), uint256(uint128(delta0)));
        }

        if (delta1 < 0) {
            poolManager.sync(key.currency1);
            key.currency1.transfer(address(poolManager), uint256(uint128(-delta1)));
            poolManager.settle();
        } else if (delta1 > 0) {
            poolManager.take(key.currency1, address(this), uint256(uint128(delta1)));
        }
    }

    // --- Internal: Grid Computation ---

    function _computeGridOrders(
        int24 centerTick,
        int24 gridSpacing,
        int24 tickSpacing,
        uint24 maxOrders,
        uint256[] memory weights,
        uint128 totalLiquidity
    ) internal pure returns (GridTypes.GridOrder[] memory orders) {
        orders = new GridTypes.GridOrder[](maxOrders);

        int24 halfOrders = int24(uint24(maxOrders / 2));
        int24 bottomTick = _alignTick(centerTick - (halfOrders * gridSpacing), tickSpacing);

        for (uint256 i; i < maxOrders; ++i) {
            int24 tickLower = bottomTick + int24(int256(i)) * gridSpacing;
            int24 tickUpper = tickLower + gridSpacing;

            uint128 liquidity = uint128((uint256(totalLiquidity) * weights[i]) / 10_000);

            orders[i] = GridTypes.GridOrder({tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity});
        }
    }

    function _alignTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _requireConfigured(PoolId poolId) private view {
        if (_poolConfigs[poolId].maxOrders == 0) revert PoolNotConfigured(poolId);
    }
}