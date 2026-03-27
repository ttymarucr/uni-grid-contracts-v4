// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {GridHook} from "src/hooks/GridHook.sol";
import {GridTypes} from "src/libraries/GridTypes.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

contract GridHookForkTest is Test {
    using PoolIdLibrary for PoolKey;

    // Unichain mainnet tokens
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;

    // Unichain mainnet PoolManager (deployed by Uniswap)
    address constant POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

    // sqrtPriceX96 for price = 1 (tick 0)
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint128 constant GRID_LIQUIDITY = 1e15;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    GridHook hook;
    PoolKey key;

    function setUp() public {
        vm.createSelectFork("unichain");

        // Use the already-deployed PoolManager on Unichain
        manager = IPoolManager(POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);

        // Compute hook address with correct flag bits:
        // afterInitialize | afterAddLiquidity | afterRemoveLiquidity | afterSwap
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(uint160(type(uint160).max & ~uint160(Hooks.ALL_HOOK_MASK)) | flags);

        // Deploy impl (bakes immutable poolManager into bytecode), then etch to flag-compatible address
        GridHook impl = new GridHook(manager, address(this));
        vm.etch(hookAddr, address(impl).code);

        // Set Ownable._owner (slot 0) to this contract
        vm.store(hookAddr, bytes32(0), bytes32(uint256(uint160(address(this)))));

        hook = GridHook(hookAddr);

        // USDC < WETH by address on Unichain → currency0 = USDC, currency1 = WETH
        key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // Fund test contract for swaps and approve swap router
        deal(WETH, address(this), 1000e18);
        deal(USDC, address(this), 10_000_000_000e6);
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
    }

    // ==================== Full Lifecycle ====================

    function test_fork_fullLifecycle_configInitDeployGrid() public {
        GridTypes.GridConfig memory config = _defaultForkConfig();
        hook.setPoolConfig(key, config);

        manager.initialize(key, SQRT_PRICE_1_1);

        // Verify state after initialization
        GridTypes.PoolRuntimeState memory state = hook.getPoolState(key);
        assertTrue(state.initialized);
        assertEq(state.gridCenterTick, 0);
        assertFalse(state.gridDeployed);

        uint256[] memory weights = hook.getPlannedWeights(key);
        assertEq(weights.length, config.maxOrders);

        // Fund hook for liquidity settlement and deploy grid
        _fundHookWithTokens(100e18, 1_000_000_000e6);
        hook.deployGrid(key, GRID_LIQUIDITY);

        state = hook.getPoolState(key);
        assertTrue(state.gridDeployed);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key);
        assertEq(orders.length, 5);

        // Fibonacci weights: [833, 833, 1666, 2500, 4166] / 10_000
        assertEq(orders[0].liquidity, uint128(uint256(GRID_LIQUIDITY) * 833 / 10_000));
        assertEq(orders[1].liquidity, uint128(uint256(GRID_LIQUIDITY) * 833 / 10_000));
        assertEq(orders[2].liquidity, uint128(uint256(GRID_LIQUIDITY) * 1666 / 10_000));
        assertEq(orders[3].liquidity, uint128(uint256(GRID_LIQUIDITY) * 2500 / 10_000));
        assertEq(orders[4].liquidity, uint128(uint256(GRID_LIQUIDITY) * 4166 / 10_000));

        // Tick ranges centered at 0: halfOrders=2, bottom = 0 - 2*60 = -120
        assertEq(orders[0].tickLower, -120);
        assertEq(orders[0].tickUpper, -60);
        assertEq(orders[1].tickLower, -60);
        assertEq(orders[1].tickUpper, 0);
        assertEq(orders[2].tickLower, 0);
        assertEq(orders[2].tickUpper, 60);
        assertEq(orders[3].tickLower, 60);
        assertEq(orders[3].tickUpper, 120);
        assertEq(orders[4].tickLower, 120);
        assertEq(orders[4].tickUpper, 180);
    }

    // ==================== Swap ====================

    function test_fork_swapUpdatesRuntimeState() public {
        _setupFullGrid(GridTypes.DistributionType.FIBONACCI, 5);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e12, // exact input
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        GridTypes.PoolRuntimeState memory state = hook.getPoolState(key);
        assertEq(state.swapCount, 1);
        assertEq(state.lastSwapAmountSpecified, -1e12);
        assertTrue(state.currentTick < 0, "tick should decrease after zeroForOne swap");
    }

    function test_fork_swapEmitsRebalanceNeeded() public {
        GridTypes.GridConfig memory config = GridTypes.GridConfig({
            gridSpacing: 60,
            maxOrders: 5,
            rebalanceThresholdBps: 10, // very low threshold to trigger easily
            distributionType: GridTypes.DistributionType.FIBONACCI,
            autoRebalance: true
        });
        hook.setPoolConfig(key, config);
        manager.initialize(key, SQRT_PRICE_1_1);
        _fundHookWithTokens(100e18, 1_000_000_000e6);
        hook.deployGrid(key, GRID_LIQUIDITY);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e11, // swap to exceed low threshold
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Expect RebalanceNeeded event (check topic1=poolId only; data values are dynamic)
        vm.expectEmit(true, false, false, false);
        emit GridHook.RebalanceNeeded(key.toId(), int24(0), int24(0), 0);

        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function test_fork_swapNoRebalanceWhenBelowThreshold() public {
        GridTypes.GridConfig memory config = GridTypes.GridConfig({
            gridSpacing: 60,
            maxOrders: 5,
            rebalanceThresholdBps: 500, // high threshold
            distributionType: GridTypes.DistributionType.FIBONACCI,
            autoRebalance: true
        });
        hook.setPoolConfig(key, config);
        manager.initialize(key, SQRT_PRICE_1_1);
        _fundHookWithTokens(100e18, 1_000_000_000e6);
        hook.deployGrid(key, GRID_LIQUIDITY);

        // Tiny swap that won't move price much
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e8,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.recordLogs();
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 rebalanceSig = keccak256("RebalanceNeeded(bytes32,int24,int24,uint256)");
        for (uint256 i; i < entries.length; ++i) {
            assertTrue(entries[i].topics[0] != rebalanceSig, "RebalanceNeeded should not be emitted");
        }
    }

    // ==================== Rebalance ====================

    function test_fork_rebalanceRepositionsGrid() public {
        _setupFullGrid(GridTypes.DistributionType.FIBONACCI, 5);

        int24 oldCenter = hook.getPoolState(key).gridCenterTick;

        // Swap to move price down (moderate amount to avoid tick out-of-bounds)
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -2e11,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        // Fund hook for re-settlement after rebalance
        _fundHookWithTokens(100e18, 1_000_000_000e6);

        hook.rebalance(key);

        GridTypes.PoolRuntimeState memory state = hook.getPoolState(key);
        assertTrue(state.gridCenterTick != oldCenter, "center should have moved");
        assertTrue(state.gridCenterTick < oldCenter, "center should have moved down");

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key);
        assertEq(orders.length, 5);
        assertTrue(orders[0].tickLower < -120, "orders should have shifted down");
    }

    function test_fork_rebalanceEmitsEvent() public {
        _setupFullGrid(GridTypes.DistributionType.FIBONACCI, 5);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -2e11,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        _fundHookWithTokens(100e18, 1_000_000_000e6);

        vm.expectEmit(true, false, false, false);
        emit GridHook.GridRebalanced(key.toId(), int24(0), int24(0));

        hook.rebalance(key);
    }

    // ==================== Distribution Variants ====================

    function test_fork_deployGridWithFlatDistribution() public {
        _setupFullGrid(GridTypes.DistributionType.FLAT, 4);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key);
        assertEq(orders.length, 4);

        uint128 expectedLiq = uint128(uint256(GRID_LIQUIDITY) * 2500 / 10_000);
        assertEq(orders[0].liquidity, expectedLiq);
        assertEq(orders[1].liquidity, expectedLiq);
        assertEq(orders[2].liquidity, expectedLiq);
        assertEq(orders[3].liquidity, expectedLiq);
    }

    function test_fork_deployGridWithLinearDistribution() public {
        _setupFullGrid(GridTypes.DistributionType.LINEAR, 4);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key);
        assertEq(orders.length, 4);

        // LINEAR weights: [1000, 2000, 3000, 4000]
        assertEq(orders[0].liquidity, uint128(uint256(GRID_LIQUIDITY) * 1000 / 10_000));
        assertEq(orders[1].liquidity, uint128(uint256(GRID_LIQUIDITY) * 2000 / 10_000));
        assertEq(orders[2].liquidity, uint128(uint256(GRID_LIQUIDITY) * 3000 / 10_000));
        assertEq(orders[3].liquidity, uint128(uint256(GRID_LIQUIDITY) * 4000 / 10_000));

        assertTrue(orders[0].liquidity < orders[1].liquidity);
        assertTrue(orders[1].liquidity < orders[2].liquidity);
        assertTrue(orders[2].liquidity < orders[3].liquidity);
    }

    function test_fork_deployGridWithReverseLinearDistribution() public {
        _setupFullGrid(GridTypes.DistributionType.REVERSE_LINEAR, 4);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key);
        assertEq(orders.length, 4);

        // REVERSE_LINEAR weights: [4000, 3000, 2000, 1000]
        assertEq(orders[0].liquidity, uint128(uint256(GRID_LIQUIDITY) * 4000 / 10_000));
        assertEq(orders[1].liquidity, uint128(uint256(GRID_LIQUIDITY) * 3000 / 10_000));
        assertEq(orders[2].liquidity, uint128(uint256(GRID_LIQUIDITY) * 2000 / 10_000));
        assertEq(orders[3].liquidity, uint128(uint256(GRID_LIQUIDITY) * 1000 / 10_000));

        assertTrue(orders[0].liquidity > orders[1].liquidity);
        assertTrue(orders[1].liquidity > orders[2].liquidity);
        assertTrue(orders[2].liquidity > orders[3].liquidity);
    }

    // ==================== Callback ====================

    function test_fork_afterInitializeCallbackFires() public {
        GridTypes.GridConfig memory config = _defaultForkConfig();
        hook.setPoolConfig(key, config);

        vm.expectEmit(true, false, false, true);
        emit GridHook.PoolInitialized(key.toId(), SQRT_PRICE_1_1, int24(0));

        vm.expectEmit(true, false, false, true);
        emit GridHook.PoolInitializationPlanned(key.toId(), config.maxOrders, config.distributionType);

        manager.initialize(key, SQRT_PRICE_1_1);

        GridTypes.PoolRuntimeState memory state = hook.getPoolState(key);
        assertTrue(state.initialized);
        assertEq(state.currentTick, 0);
        assertEq(state.gridCenterTick, 0);

        uint256[] memory weights = hook.getPlannedWeights(key);
        assertEq(weights.length, config.maxOrders);
    }

    function test_fork_deployGridEmitsEvent() public {
        GridTypes.GridConfig memory config = _defaultForkConfig();
        hook.setPoolConfig(key, config);
        manager.initialize(key, SQRT_PRICE_1_1);
        _fundHookWithTokens(100e18, 1_000_000_000e6);

        vm.expectEmit(true, false, false, true);
        emit GridHook.GridDeployed(key.toId(), config.maxOrders, GRID_LIQUIDITY);

        hook.deployGrid(key, GRID_LIQUIDITY);
    }

    // ==================== Revert Cases ====================

    function test_fork_deployGridRevertsWithoutInit() public {
        hook.setPoolConfig(key, _defaultForkConfig());

        vm.expectRevert(abi.encodeWithSelector(GridHook.PoolNotInitialized.selector, key.toId()));
        hook.deployGrid(key, GRID_LIQUIDITY);
    }

    function test_fork_rebalanceRevertsWithoutDeploy() public {
        hook.setPoolConfig(key, _defaultForkConfig());
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.expectRevert(abi.encodeWithSelector(GridHook.GridNotDeployed.selector, key.toId()));
        hook.rebalance(key);
    }

    function test_fork_deployGridRevertsWhenAlreadyDeployed() public {
        _setupFullGrid(GridTypes.DistributionType.FIBONACCI, 5);

        vm.expectRevert(abi.encodeWithSelector(GridHook.GridAlreadyDeployed.selector, key.toId()));
        hook.deployGrid(key, GRID_LIQUIDITY);
    }

    function test_fork_deployGridRevertsWithZeroLiquidity() public {
        hook.setPoolConfig(key, _defaultForkConfig());
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.expectRevert(GridHook.NoAssetsAvailable.selector);
        hook.deployGrid(key, 0);
    }

    // ==================== Helpers ====================

    function _defaultForkConfig() internal pure returns (GridTypes.GridConfig memory) {
        return GridTypes.GridConfig({
            gridSpacing: 60,
            maxOrders: 5,
            rebalanceThresholdBps: 250,
            distributionType: GridTypes.DistributionType.FIBONACCI,
            autoRebalance: true
        });
    }

    function _fundHookWithTokens(uint256 wethAmount, uint256 usdcAmount) internal {
        deal(WETH, address(hook), IERC20(WETH).balanceOf(address(hook)) + wethAmount);
        deal(USDC, address(hook), IERC20(USDC).balanceOf(address(hook)) + usdcAmount);
    }

    function _setupFullGrid(GridTypes.DistributionType dist, uint24 maxOrders) internal {
        GridTypes.GridConfig memory config = GridTypes.GridConfig({
            gridSpacing: 60,
            maxOrders: maxOrders,
            rebalanceThresholdBps: 250,
            distributionType: dist,
            autoRebalance: true
        });
        hook.setPoolConfig(key, config);
        manager.initialize(key, SQRT_PRICE_1_1);
        _fundHookWithTokens(100e18, 1_000_000_000e6);
        hook.deployGrid(key, GRID_LIQUIDITY);
    }
}
