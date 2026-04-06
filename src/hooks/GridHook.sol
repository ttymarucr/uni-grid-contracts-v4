// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/types/BeforeSwapDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/types/PoolOperation.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { Permit2Forwarder } from "v4-periphery/base/Permit2Forwarder.sol";
import { Multicall_v4 } from "v4-periphery/base/Multicall_v4.sol";

import { GridTypes } from "../libraries/GridTypes.sol";
import { DistributionWeights } from "../libraries/DistributionWeights.sol";

contract GridHook is IHooks, IUnlockCallback, Permit2Forwarder, Multicall_v4 {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 private constant MAX_GRID_ORDERS = 500;
    uint16 private constant MAX_SLIPPAGE_BPS = 500;

    enum UnlockAction {
        DEPLOY_GRID,
        REBALANCE,
        CLOSE_GRID
    }

    error NotPoolManager();
    error PoolManagerAddressZero();
    error Permit2AddressZero();
    error ETHRefundFailed();
    error InvalidGridQuantity(uint256 quantity);
    error InvalidGridStep(uint256 stepBps);
    error SlippageTooHigh(uint16 slippageBps);
    error TickSpacingMisaligned(int24 tickLower, int24 tickUpper, int24 tickSpacing);
    error NoAssetsAvailable();
    error GridNotConfigured(PoolId poolId, address user);
    error PoolNotInitialized(PoolId poolId);
    error GridAlreadyDeployed(PoolId poolId, address user);
    error GridNotDeployed(PoolId poolId, address user);
    error NotAuthorizedRebalancer(address caller, address user);
    error SlippageExceeded(int128 actual0, int128 actual1, uint128 maxDelta0, uint128 maxDelta1);
    error TickRangeOutOfBounds(int24 bottomTick, int24 topTick);
    error DeadlineExpired();
    error RebalanceThresholdNotMet(int24 tickDelta, int24 minTickDelta);
    error Reentrancy();

    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tick);

    event GridConfigured(
        PoolId indexed poolId,
        address indexed user,
        int24 gridSpacing,
        uint24 maxOrders,
        uint16 rebalanceThresholdBps,
        GridTypes.DistributionType distributionType,
        bool autoRebalance
    );

    event GridDeployed(PoolId indexed poolId, address indexed user, uint24 orderCount, uint128 totalLiquidity);
    event GridRebalanced(PoolId indexed poolId, address indexed user, int24 oldCenterTick, int24 newCenterTick);
    event GridClosed(PoolId indexed poolId, address indexed user);

    event SwapObserved(PoolId indexed poolId, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96);

    IPoolManager public immutable poolManager;

    // Keeper authorization: user => keeper => authorized
    mapping(address user => mapping(address keeper => bool)) private _rebalanceKeepers;

    // Pool-level state (shared across all users)
    mapping(PoolId poolId => GridTypes.PoolState state) private _poolStates;

    // Reentrancy lock (transient storage)
    bytes32 private constant _LOCK_SLOT = bytes32(uint256(keccak256("GridHook.lock")) - 1);

    // User-scoped state
    mapping(address user => mapping(PoolId poolId => GridTypes.GridConfig config)) private _userConfigs;
    mapping(address user => mapping(PoolId poolId => GridTypes.UserGridState state)) private _userStates;
    mapping(address user => mapping(PoolId poolId => uint256[] weights)) private _userWeights;
    mapping(address user => mapping(PoolId poolId => GridTypes.GridOrder[] orders)) private _userOrders;

    constructor(
        IPoolManager poolManager_,
        IAllowanceTransfer permit2_
    ) Permit2Forwarder(permit2_) {
        if (address(poolManager_) == address(0)) revert PoolManagerAddressZero();
        if (address(permit2_) == address(0)) revert Permit2AddressZero();
        poolManager = poolManager_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier nonReentrant() {
        bytes32 slot = _LOCK_SLOT;
        uint256 locked;
        assembly { locked := tload(slot) }
        if (locked != 0) revert Reentrancy();
        assembly { tstore(slot, 1) }
        _;
        assembly { tstore(slot, 0) }
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    // --- Keeper Authorization ---

    function setRebalanceKeeper(
        address keeper,
        bool authorized
    ) external {
        _rebalanceKeepers[msg.sender][keeper] = authorized;
    }

    function isRebalanceKeeper(
        address user,
        address keeper
    ) external view returns (bool) {
        return _rebalanceKeepers[user][keeper];
    }

    // --- Configuration ---

    function setGridConfig(
        PoolKey calldata key,
        GridTypes.GridConfig calldata config
    ) external {
        uint256 spacing = config.gridSpacing > 0 ? uint256(uint24(config.gridSpacing)) : 0;
        if (spacing == 0 || spacing > 10_000) revert InvalidGridStep(spacing);
        if (config.maxOrders == 0 || config.maxOrders > MAX_GRID_ORDERS) {
            revert InvalidGridQuantity(config.maxOrders);
        }
        if (config.rebalanceThresholdBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh(config.rebalanceThresholdBps);
        if (config.gridSpacing % key.tickSpacing != 0) {
            revert TickSpacingMisaligned(config.gridSpacing, key.tickSpacing, key.tickSpacing);
        }

        PoolId poolId = key.toId();
        _userConfigs[msg.sender][poolId] = config;
        _userWeights[msg.sender][poolId] = DistributionWeights.getWeights(config.maxOrders, config.distributionType);

        emit GridConfigured(
            poolId,
            msg.sender,
            config.gridSpacing,
            config.maxOrders,
            config.rebalanceThresholdBps,
            config.distributionType,
            config.autoRebalance
        );
    }

    // --- View Functions ---

    function getGridConfig(
        PoolKey calldata key,
        address user
    ) external view returns (GridTypes.GridConfig memory) {
        return _userConfigs[user][key.toId()];
    }

    function getPoolState(
        PoolKey calldata key
    ) external view returns (GridTypes.PoolState memory) {
        return _poolStates[key.toId()];
    }

    function getUserState(
        PoolKey calldata key,
        address user
    ) external view returns (GridTypes.UserGridState memory) {
        return _userStates[user][key.toId()];
    }

    function getPlannedWeights(
        PoolKey calldata key,
        address user
    ) external view returns (uint256[] memory) {
        return _userWeights[user][key.toId()];
    }

    function getGridOrders(
        PoolKey calldata key,
        address user
    ) external view returns (GridTypes.GridOrder[] memory) {
        return _userOrders[user][key.toId()];
    }

    

    function getAccumulatedFees(
        PoolKey calldata key,
        address user
    ) external view returns (GridTypes.OrderFeeData[] memory perOrderFeeData) {
        PoolId poolId = key.toId();
        GridTypes.GridOrder[] storage orders = _userOrders[user][poolId];
        uint256 len = orders.length;
        perOrderFeeData = new GridTypes.OrderFeeData[](len);

        bytes32 userSalt = bytes32(uint256(uint160(user)));

        for (uint256 i; i < len; ++i) {
            GridTypes.GridOrder storage order = orders[i];
            if (order.liquidity == 0) continue;

            bytes32 salt = keccak256(abi.encodePacked(userSalt, i));

            (uint128 liq, uint256 fg0Last, uint256 fg1Last) = poolManager.getPositionInfo(
                poolId, address(this), order.tickLower, order.tickUpper, salt
            );

            (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthInside(
                poolId, order.tickLower, order.tickUpper
            );

            perOrderFeeData[i] = GridTypes.OrderFeeData(liq, fg0, fg1, fg0Last, fg1Last);
        }
    }

    function getPoolManagerSlot0(
        PoolKey calldata key
    ) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        return poolManager.getSlot0(key.toId());
    }

    // --- Grid Operations ---

    function deployGrid(
        PoolKey calldata key,
        uint128 totalLiquidity,
        uint128 maxDelta0,
        uint128 maxDelta1,
        uint256 deadline
    ) external payable nonReentrant checkDeadline(deadline) {
        PoolId poolId = key.toId();
        _requireUserConfigured(poolId, msg.sender);

        GridTypes.PoolState storage pool = _poolStates[poolId];
        if (!pool.initialized) revert PoolNotInitialized(poolId);

        GridTypes.UserGridState storage userState = _userStates[msg.sender][poolId];
        if (userState.deployed) revert GridAlreadyDeployed(poolId, msg.sender);
        if (totalLiquidity == 0) revert NoAssetsAvailable();

        GridTypes.GridConfig storage config = _userConfigs[msg.sender][poolId];
        if (config.gridSpacing % key.tickSpacing != 0) {
            revert TickSpacingMisaligned(config.gridSpacing, key.tickSpacing, key.tickSpacing);
        }

        poolManager.unlock(
            abi.encode(
                uint8(UnlockAction.DEPLOY_GRID), abi.encode(msg.sender, key, totalLiquidity, maxDelta0, maxDelta1)
            )
        );
        _refundETH(msg.sender);
    }

    function rebalance(
        PoolKey calldata key,
        address user,
        uint256 deadline
    ) external payable nonReentrant checkDeadline(deadline) {
        if (msg.sender != user && !_rebalanceKeepers[user][msg.sender]) {
            revert NotAuthorizedRebalancer(msg.sender, user);
        }

        PoolId poolId = key.toId();
        _requireUserConfigured(poolId, user);

        GridTypes.UserGridState storage userState = _userStates[user][poolId];
        if (!userState.deployed) revert GridNotDeployed(poolId, user);

        poolManager.unlock(abi.encode(uint8(UnlockAction.REBALANCE), abi.encode(user, key)));
        _refundETH(msg.sender);
    }

    function closeGrid(
        PoolKey calldata key,
        uint256 deadline
    ) external payable nonReentrant checkDeadline(deadline) {
        PoolId poolId = key.toId();

        GridTypes.UserGridState storage userState = _userStates[msg.sender][poolId];
        if (!userState.deployed) revert GridNotDeployed(poolId, msg.sender);

        poolManager.unlock(abi.encode(uint8(UnlockAction.CLOSE_GRID), abi.encode(msg.sender, key)));
        _refundETH(msg.sender);
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));

        if (action == uint8(UnlockAction.DEPLOY_GRID)) {
            (address user, PoolKey memory key, uint128 totalLiquidity, uint128 maxDelta0, uint128 maxDelta1) =
                abi.decode(payload, (address, PoolKey, uint128, uint128, uint128));
            _executeDeploy(user, key, totalLiquidity, maxDelta0, maxDelta1);
        } else if (action == uint8(UnlockAction.REBALANCE)) {
            (address user, PoolKey memory key) = abi.decode(payload, (address, PoolKey));
            _executeRebalance(user, key);
        } else {
            (address user, PoolKey memory key) = abi.decode(payload, (address, PoolKey));
            _executeClose(user, key);
        }

        return "";
    }

    // --- Utility ---

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

    // --- Hook Callbacks ---

    function beforeInitialize(
        address,
        PoolKey calldata,
        uint160
    ) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external override onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();

        GridTypes.PoolState storage pool = _poolStates[poolId];
        pool.initialized = true;
        pool.currentTick = tick;

        emit PoolInitialized(poolId, sqrtPriceX96, tick);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        bytes calldata
    ) external pure override returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();

        GridTypes.PoolState storage pool = _poolStates[poolId];
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        pool.currentTick = currentTick;
        pool.swapCount += 1;

        emit SwapObserved(poolId, params.zeroForOne, params.amountSpecified, params.sqrtPriceLimitX96);
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    // --- Internal: Unlock Actions ---

    function _executeDeploy(
        address user,
        PoolKey memory key,
        uint128 totalLiquidity,
        uint128 maxDelta0,
        uint128 maxDelta1
    ) internal {
        PoolId poolId = key.toId();
        GridTypes.PoolState storage pool = _poolStates[poolId];

        int24 centerTick = _alignTick(pool.currentTick, key.tickSpacing);

        delete _userOrders[user][poolId];

        (int128 totalDelta0, int128 totalDelta1) = _placeNewOrders(key, user, poolId, centerTick, totalLiquidity);

        _checkSlippage(totalDelta0, totalDelta1, maxDelta0, maxDelta1);
        _settleForUser(key, user, totalDelta0, totalDelta1);

        _userStates[user][poolId].deployed = true;
        _userStates[user][poolId].gridCenterTick = centerTick;

        GridTypes.GridConfig storage config = _userConfigs[user][poolId];
        emit GridDeployed(poolId, user, config.maxOrders, totalLiquidity);
    }

    function _executeRebalance(
        address user,
        PoolKey memory key
    ) internal {
        PoolId poolId = key.toId();
        GridTypes.GridConfig storage config = _userConfigs[user][poolId];
        int24 oldCenter = _userStates[user][poolId].gridCenterTick;

        (int128 removeDelta0, int128 removeDelta1, uint128 totalLiquidity) = _removeAllOrders(key, user, poolId);
        delete _userOrders[user][poolId];

        int24 newCenter;
        {
            (, int24 currentTick,,) = poolManager.getSlot0(poolId);
            newCenter = _alignTick(currentTick, key.tickSpacing);
        }

        // Enforce rebalance threshold — prevent no-op or dust rebalances
        {
            int24 tickDelta = newCenter > oldCenter ? newCenter - oldCenter : oldCenter - newCenter;
            int24 minTickDelta = config.gridSpacing * int24(uint24(config.rebalanceThresholdBps)) / 10_000;
            if (minTickDelta > 0 && tickDelta < minTickDelta) {
                revert RebalanceThresholdNotMet(tickDelta, minTickDelta);
            }
        }

        {
            (int128 addDelta0, int128 addDelta1) = _placeNewOrders(key, user, poolId, newCenter, totalLiquidity);
            removeDelta0 += addDelta0;
            removeDelta1 += addDelta1;
        }

        _checkSlippage(removeDelta0, removeDelta1, config.maxSlippageDelta0, config.maxSlippageDelta1);
        _settleForUser(key, user, removeDelta0, removeDelta1);

        _userStates[user][poolId].gridCenterTick = newCenter;

        emit GridRebalanced(poolId, user, oldCenter, newCenter);
    }

    function _placeNewOrders(
        PoolKey memory key,
        address user,
        PoolId poolId,
        int24 centerTick,
        uint128 totalLiquidity
    ) internal returns (int128, int128) {
        GridTypes.GridConfig storage config = _userConfigs[user][poolId];
        GridTypes.GridOrder[] memory orders = _computeGridOrders(
            centerTick,
            config.gridSpacing,
            key.tickSpacing,
            config.maxOrders,
            _userWeights[user][poolId],
            totalLiquidity
        );
        return _placeOrders(key, user, poolId, orders);
    }

    function _executeClose(
        address user,
        PoolKey memory key
    ) internal {
        PoolId poolId = key.toId();

        (int128 removeDelta0, int128 removeDelta1,) = _removeAllOrders(key, user, poolId);
        delete _userOrders[user][poolId];

        _settleForUser(key, user, removeDelta0, removeDelta1);

        _userStates[user][poolId].deployed = false;
        _userStates[user][poolId].gridCenterTick = 0;

        emit GridClosed(poolId, user);
    }

    function _removeAllOrders(
        PoolKey memory key,
        address user,
        PoolId poolId
    ) internal returns (int128 totalDelta0, int128 totalDelta1, uint128 totalLiquidity) {
        GridTypes.GridOrder[] storage existingOrders = _userOrders[user][poolId];
        uint256 orderCount = existingOrders.length;

        bytes32 userSalt = bytes32(uint256(uint160(user)));

        for (uint256 i; i < orderCount; ++i) {
            GridTypes.GridOrder storage order = existingOrders[i];
            totalLiquidity += order.liquidity;

            if (order.liquidity == 0) continue;

            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: order.tickLower,
                    tickUpper: order.tickUpper,
                    liquidityDelta: -int256(uint256(order.liquidity)),
                    salt: keccak256(abi.encodePacked(userSalt, i))
                }),
                ""
            );

            totalDelta0 += callerDelta.amount0();
            totalDelta1 += callerDelta.amount1();
        }
    }

    function _placeOrders(
        PoolKey memory key,
        address user,
        PoolId poolId,
        GridTypes.GridOrder[] memory orders
    ) internal returns (int128 totalDelta0, int128 totalDelta1) {
        bytes32 userSalt = bytes32(uint256(uint160(user)));

        for (uint256 i; i < orders.length; ++i) {
            _userOrders[user][poolId].push(orders[i]);

            if (orders[i].liquidity == 0) continue;

            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: orders[i].tickLower,
                    tickUpper: orders[i].tickUpper,
                    liquidityDelta: int256(uint256(orders[i].liquidity)),
                    salt: keccak256(abi.encodePacked(userSalt, i))
                }),
                ""
            );

            totalDelta0 += callerDelta.amount0();
            totalDelta1 += callerDelta.amount1();
        }
    }

    // --- Internal: Settlement ---

    function _settleForUser(
        PoolKey memory key,
        address user,
        int128 delta0,
        int128 delta1
    ) internal {
        _settleCurrency(key.currency0, user, delta0);
        _settleCurrency(key.currency1, user, delta1);
    }

    function _settleCurrency(
        Currency currency,
        address user,
        int128 delta
    ) internal {
        if (delta < 0) {
            // casting is safe: delta < 0 so -delta is positive and fits uint128; uint256 widening is lossless
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(uint128(-delta));
            if (currency.isAddressZero()) {
                poolManager.settle{ value: amount }();
            } else {
                poolManager.sync(currency);
                // casting is safe: Permit2 uses uint160 amounts; pool deltas cannot exceed uint160 for any realistic supply
                // forge-lint: disable-next-line(unsafe-typecast)
                permit2.transferFrom(user, address(poolManager), uint160(amount), Currency.unwrap(currency));
                poolManager.settle();
            }
        } else if (delta > 0) {
            // casting is safe: delta > 0 so positive int128 fits uint128; uint256 widening is lossless
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.take(currency, user, uint256(uint128(delta)));
        }
    }

    function _refundETH(
        address to
    ) internal {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success,) = to.call{ value: balance }("");
            if (!success) revert ETHRefundFailed();
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

        // casting is safe: maxOrders <= MAX_GRID_ORDERS (500), so maxOrders/2 <= 250 which fits int24
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 halfOrders = int24(uint24(maxOrders / 2));
        int24 bottomTick = _alignTick(centerTick - (halfOrders * gridSpacing), tickSpacing);
        // casting is safe: maxOrders <= 500 fits int24
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 topTick = bottomTick + int24(uint24(maxOrders)) * gridSpacing;

        if (bottomTick < TickMath.MIN_TICK || topTick > TickMath.MAX_TICK) {
            revert TickRangeOutOfBounds(bottomTick, topTick);
        }

        uint128 distributed;
        for (uint256 i; i < maxOrders; ++i) {
            // casting is safe: i < maxOrders <= 500, fits int256 and int24
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 tickLower = bottomTick + int24(int256(i)) * gridSpacing;
            int24 tickUpper = tickLower + gridSpacing;

            uint128 liquidity;
            if (i == maxOrders - 1) {
                liquidity = totalLiquidity - distributed;
            } else {
                liquidity = uint128((uint256(totalLiquidity) * weights[i]) / 10_000);
                distributed += liquidity;
            }

            orders[i] = GridTypes.GridOrder({ tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity });
        }
    }

    function _alignTick(
        int24 tick,
        int24 tickSpacing
    ) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _checkSlippage(
        int128 delta0,
        int128 delta1,
        uint128 maxDelta0,
        uint128 maxDelta1
    ) internal pure {
        // Only enforce when maxDelta > 0 (0 means no limit)
        if (maxDelta0 > 0 || maxDelta1 > 0) {
            // Negative deltas = user owes pool; check their absolute value
            uint128 abs0 = delta0 < 0 ? uint128(-delta0) : uint128(delta0);
            uint128 abs1 = delta1 < 0 ? uint128(-delta1) : uint128(delta1);
            if ((maxDelta0 > 0 && abs0 > maxDelta0) || (maxDelta1 > 0 && abs1 > maxDelta1)) {
                revert SlippageExceeded(delta0, delta1, maxDelta0, maxDelta1);
            }
        }
    }

    function _requireUserConfigured(
        PoolId poolId,
        address user
    ) private view {
        if (_userConfigs[user][poolId].maxOrders == 0) revert GridNotConfigured(poolId, user);
    }
}
