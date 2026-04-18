// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import { GridHook } from "src/hooks/GridHook.sol";
import { GridTypes } from "src/libraries/GridTypes.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { SwapParams, ModifyLiquidityParams } from "v4-core/types/PoolOperation.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";

contract GridHookForkTest is Test {
    using PoolIdLibrary for PoolKey;

    // Unichain mainnet tokens
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;

    // Unichain mainnet PoolManager (deployed by Uniswap)
    address constant POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

    // Canonical Permit2 address (same on all major EVM chains)
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // sqrtPriceX96 for price = 1 (tick 0)
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    uint128 constant GRID_LIQUIDITY = 1e15;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    GridHook hook;
    IAllowanceTransfer permit2;
    PoolKey key;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork("unichain");

        manager = IPoolManager(POOL_MANAGER);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(manager);

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(uint160(type(uint160).max & ~uint160(Hooks.ALL_HOOK_MASK)) | flags);

        deployCodeTo("GridHook.sol:GridHook", abi.encode(manager, permit2), hookAddr);

        hook = GridHook(payable(hookAddr));

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
        hook.setGridConfig(key, config);

        manager.initialize(key, SQRT_PRICE_1_1);

        // Verify pool state after initialization
        GridTypes.PoolState memory poolState = hook.getPoolState(key);
        assertTrue(poolState.initialized);
        assertEq(poolState.currentTick, 0);

        // Verify user weights stored at config time
        uint256[] memory weights = hook.getPlannedWeights(key, address(this));
        assertEq(weights.length, config.maxOrders);

        // Approve hook to pull tokens, then deploy grid
        _approveHookForTokens(address(this));
        hook.deployGrid(key, GRID_LIQUIDITY, 0, 0, type(uint256).max);

        GridTypes.UserGridState memory userState = hook.getUserState(key, address(this));
        assertTrue(userState.deployed);
        assertTrue(userState.lastActionTimestamp > 0);
        assertEq(userState.rebalanceCount, 0);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key, address(this));
        assertEq(orders.length, 5);

        // Fibonacci weights: [833, 833, 1666, 2500, 4166] / 10_000
        assertEq(orders[0].liquidity, uint128(uint256(GRID_LIQUIDITY) * 833 / 10_000));
        assertEq(orders[1].liquidity, uint128(uint256(GRID_LIQUIDITY) * 833 / 10_000));
        assertEq(orders[2].liquidity, uint128(uint256(GRID_LIQUIDITY) * 1666 / 10_000));
        assertEq(orders[3].liquidity, uint128(uint256(GRID_LIQUIDITY) * 2500 / 10_000));
        // Last order gets remainder (rounding fix)
        assertEq(
            orders[4].liquidity,
            GRID_LIQUIDITY - uint128(uint256(GRID_LIQUIDITY) * 833 / 10_000)
                - uint128(uint256(GRID_LIQUIDITY) * 833 / 10_000) - uint128(uint256(GRID_LIQUIDITY) * 1666 / 10_000)
                - uint128(uint256(GRID_LIQUIDITY) * 2500 / 10_000)
        );

        // Tick ranges centered at 0
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

    function test_fork_swapUpdatesPoolState() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        // Use a small swap to stay within MAX_TICK_MOVEMENT_PER_BLOCK (500 ticks)
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: -1e10, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });

        swapRouter.swap(key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        GridTypes.PoolState memory poolState = hook.getPoolState(key);
        assertEq(poolState.swapCount, 1);
        assertTrue(poolState.currentTick < 0, "tick should decrease after zeroForOne swap");
    }

    // ==================== Rebalance ====================

    function test_fork_rebalanceRepositionsGrid() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        int24 oldCenter = hook.getUserState(key, address(this)).gridCenterTick;

        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: -2e11, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        // Re-approve for rebalance settlement
        _approveHookForTokens(address(this));

        // Advance block and time to satisfy MEV guards
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        hook.rebalance(key, address(this), type(uint256).max);

        GridTypes.UserGridState memory userState = hook.getUserState(key, address(this));
        assertTrue(userState.gridCenterTick != oldCenter, "center should have moved");
        assertTrue(userState.gridCenterTick < oldCenter, "center should have moved down");
        assertTrue(userState.lastActionTimestamp > 0);
        assertEq(userState.rebalanceCount, 1);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key, address(this));
        assertEq(orders.length, 5);
        assertTrue(orders[0].tickLower < -120, "orders should have shifted down");
    }

    function test_fork_rebalanceByKeeperSucceeds() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: -2e11, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        _approveHookForTokens(address(this));

        // Advance block and time to satisfy MEV guards
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        // Authorize alice as keeper, then trigger rebalance for address(this)
        hook.setRebalanceKeeper(alice, true);

        vm.prank(alice);
        hook.rebalance(key, address(this), type(uint256).max);

        GridTypes.UserGridState memory userState = hook.getUserState(key, address(this));
        assertTrue(userState.gridCenterTick < 0, "center should have moved down");
    }

    function test_fork_rebalanceEmitsEvent() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: -2e11, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        _approveHookForTokens(address(this));

        // Advance block and time to satisfy MEV guards
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        vm.expectEmit(true, true, false, false);
        emit GridHook.GridRebalanced(key.toId(), address(this), int24(0), int24(0));

        hook.rebalance(key, address(this), type(uint256).max);
    }

    // ==================== Close Grid ====================

    function test_fork_closeGridReturnsTokens() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        hook.closeGrid(key, type(uint256).max);

        GridTypes.UserGridState memory userState = hook.getUserState(key, address(this));
        assertFalse(userState.deployed);
        assertEq(userState.lastActionTimestamp, 0);
        assertEq(userState.rebalanceCount, 0);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key, address(this));
        assertEq(orders.length, 0);

        // Should have received tokens back
        uint256 wethAfter = IERC20(WETH).balanceOf(address(this));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        assertTrue(wethAfter >= wethBefore || usdcAfter >= usdcBefore, "should have received tokens back");
    }

    // ==================== Multi-User ====================

    function test_fork_twoUsersDeployDifferentConfigs() public {
        // Alice: FIBONACCI, 5 orders
        vm.prank(alice);
        hook.setGridConfig(key, _defaultForkConfig());

        // Bob: FLAT, 4 orders
        GridTypes.GridConfig memory flatConfig = GridTypes.GridConfig({
            gridSpacing: 60,
            maxOrders: 4,
            rebalanceThresholdBps: 250,
            distributionType: GridTypes.DistributionType.FLAT,
            autoRebalance: false,
            maxSlippageDelta0: 0,
            maxSlippageDelta1: 0
        });
        vm.prank(bob);
        hook.setGridConfig(key, flatConfig);

        manager.initialize(key, SQRT_PRICE_1_1);

        // Fund and approve both users
        _fundAndApproveUser(alice, 100e18, 1_000_000_000e6);
        _fundAndApproveUser(bob, 50e18, 500_000_000e6);

        vm.prank(alice);
        hook.deployGrid(key, GRID_LIQUIDITY, 0, 0, type(uint256).max);

        vm.prank(bob);
        hook.deployGrid(key, GRID_LIQUIDITY / 2, 0, 0, type(uint256).max);

        // Verify isolation
        GridTypes.GridOrder[] memory aliceOrders = hook.getGridOrders(key, alice);
        GridTypes.GridOrder[] memory bobOrders = hook.getGridOrders(key, bob);
        assertEq(aliceOrders.length, 5);
        assertEq(bobOrders.length, 4);

        assertTrue(hook.getUserState(key, alice).deployed);
        assertTrue(hook.getUserState(key, bob).deployed);
    }

    function test_fork_rebalanceOneUserDoesNotAffectOther() public {
        // Both users set up grids
        vm.prank(alice);
        hook.setGridConfig(key, _defaultForkConfig());

        vm.prank(bob);
        hook.setGridConfig(key, _defaultForkConfig());

        manager.initialize(key, SQRT_PRICE_1_1);

        _fundAndApproveUser(alice, 100e18, 1_000_000_000e6);
        _fundAndApproveUser(bob, 100e18, 1_000_000_000e6);

        vm.prank(alice);
        hook.deployGrid(key, GRID_LIQUIDITY, 0, 0, type(uint256).max);

        vm.prank(bob);
        hook.deployGrid(key, GRID_LIQUIDITY, 0, 0, type(uint256).max);

        int24 bobCenterBefore = hook.getUserState(key, bob).gridCenterTick;

        // Swap to move price
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: -2e11, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        // Re-approve alice for rebalance
        _approveHookForUser(alice);

        // Advance block and time to satisfy MEV guards
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);

        // Rebalance only alice (as alice herself)
        vm.prank(alice);
        hook.rebalance(key, alice, type(uint256).max);

        // Bob grid unchanged
        assertEq(hook.getUserState(key, bob).gridCenterTick, bobCenterBefore);

        GridTypes.GridOrder[] memory bobOrders = hook.getGridOrders(key, bob);
        assertEq(bobOrders.length, 5);
        assertEq(bobOrders[0].tickLower, -120);
    }

    // ==================== Distribution Variants ====================

    function test_fork_deployGridWithFlatDistribution() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FLAT, 4);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key, address(this));
        assertEq(orders.length, 4);

        uint128 expectedLiq = uint128(uint256(GRID_LIQUIDITY) * 2500 / 10_000);
        assertEq(orders[0].liquidity, expectedLiq);
        assertEq(orders[1].liquidity, expectedLiq);
        assertEq(orders[2].liquidity, expectedLiq);
        assertEq(orders[3].liquidity, expectedLiq);
    }

    function test_fork_deployGridWithLinearDistribution() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.LINEAR, 4);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key, address(this));
        assertEq(orders.length, 4);

        assertEq(orders[0].liquidity, uint128(uint256(GRID_LIQUIDITY) * 1000 / 10_000));
        assertEq(orders[1].liquidity, uint128(uint256(GRID_LIQUIDITY) * 2000 / 10_000));
        assertEq(orders[2].liquidity, uint128(uint256(GRID_LIQUIDITY) * 3000 / 10_000));
        assertEq(orders[3].liquidity, uint128(uint256(GRID_LIQUIDITY) * 4000 / 10_000));

        assertTrue(orders[0].liquidity < orders[1].liquidity);
        assertTrue(orders[1].liquidity < orders[2].liquidity);
        assertTrue(orders[2].liquidity < orders[3].liquidity);
    }

    function test_fork_deployGridWithReverseLinearDistribution() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.REVERSE_LINEAR, 4);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key, address(this));
        assertEq(orders.length, 4);

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
        hook.setGridConfig(key, _defaultForkConfig());

        vm.expectEmit(true, false, false, true);
        emit GridHook.PoolInitialized(key.toId(), SQRT_PRICE_1_1, int24(0));

        manager.initialize(key, SQRT_PRICE_1_1);

        GridTypes.PoolState memory poolState = hook.getPoolState(key);
        assertTrue(poolState.initialized);
        assertEq(poolState.currentTick, 0);
    }

    function test_fork_deployGridEmitsEvent() public {
        hook.setGridConfig(key, _defaultForkConfig());
        manager.initialize(key, SQRT_PRICE_1_1);
        _approveHookForTokens(address(this));

        vm.expectEmit(true, true, false, true);
        emit GridHook.GridDeployed(key.toId(), address(this), 5, GRID_LIQUIDITY);

        hook.deployGrid(key, GRID_LIQUIDITY, 0, 0, type(uint256).max);
    }

    // ==================== Revert Cases ====================

    function test_fork_deployGridRevertsWithoutInit() public {
        hook.setGridConfig(key, _defaultForkConfig());

        vm.expectRevert(abi.encodeWithSelector(GridHook.PoolNotInitialized.selector, key.toId()));
        hook.deployGrid(key, GRID_LIQUIDITY, 0, 0, type(uint256).max);
    }

    function test_fork_rebalanceRevertsWithoutDeploy() public {
        hook.setGridConfig(key, _defaultForkConfig());
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.expectRevert(abi.encodeWithSelector(GridHook.GridNotDeployed.selector, key.toId(), address(this)));
        hook.rebalance(key, address(this), type(uint256).max);
    }

    function test_fork_deployGridRevertsWhenAlreadyDeployed() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        vm.expectRevert(abi.encodeWithSelector(GridHook.GridAlreadyDeployed.selector, key.toId(), address(this)));
        hook.deployGrid(key, GRID_LIQUIDITY, 0, 0, type(uint256).max);
    }

    function test_fork_deployGridRevertsWithZeroLiquidity() public {
        hook.setGridConfig(key, _defaultForkConfig());
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.expectRevert(GridHook.NoAssetsAvailable.selector);
        hook.deployGrid(key, 0, 0, 0, type(uint256).max);
    }

    // ==================== MEV Protection ====================

    function test_fork_antiSandwich_blocksExcessivePriceImpact() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        // A massive swap that should exceed MAX_TICK_MOVEMENT_PER_BLOCK (500 ticks)
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });

        vm.expectRevert();
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");
    }

    function test_fork_antiSandwich_allowsNormalSwap() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        // A small swap that should stay within limits
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: -1e10, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });

        swapRouter.swap(key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        GridTypes.PoolState memory poolState = hook.getPoolState(key);
        assertEq(poolState.swapCount, 1);
        assertTrue(poolState.swapsThisBlock == 1);
        assertEq(poolState.lastSwapBlock, block.number);
    }

    function test_fork_antiSandwich_tracksBlockStartTick() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        // First small swap
        SwapParams memory params1 =
            SwapParams({ zeroForOne: true, amountSpecified: -1e9, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        swapRouter.swap(key, params1, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        GridTypes.PoolState memory stateAfterFirst = hook.getPoolState(key);
        int24 blockStartTick = stateAfterFirst.blockStartTick;
        assertEq(blockStartTick, 0, "blockStartTick should be 0 (initial tick)");
        assertEq(stateAfterFirst.swapsThisBlock, 1);

        // Second small swap in the same block — blockStartTick should not change
        SwapParams memory params2 =
            SwapParams({ zeroForOne: true, amountSpecified: -1e9, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        swapRouter.swap(key, params2, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        GridTypes.PoolState memory stateAfterSecond = hook.getPoolState(key);
        assertEq(stateAfterSecond.blockStartTick, blockStartTick, "blockStartTick should not change within same block");
        assertEq(stateAfterSecond.swapsThisBlock, 2);
    }

    function test_fork_rebalanceRevertsInSameBlockAsSwap() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        // Small swap to set lastSwapBlock to current block
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: -1e10, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        _approveHookForTokens(address(this));

        // Rebalance in same block should revert
        vm.expectRevert(GridHook.RebalanceInSameBlockAsSwap.selector);
        hook.rebalance(key, address(this), type(uint256).max);
    }

    function test_fork_rebalanceCooldownEnforced() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        // Swap to move price
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: -2e11, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        _approveHookForTokens(address(this));

        // Advance block and time so same-block + cooldown checks pass
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 61);
        hook.rebalance(key, address(this), type(uint256).max);

        // Swap again to move price further
        SwapParams memory params2 =
            SwapParams({ zeroForOne: true, amountSpecified: -1e11, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        swapRouter.swap(key, params2, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        _approveHookForTokens(address(this));

        // Advance block but NOT enough time — cooldown should block
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 30); // only 30s, cooldown is 60s

        vm.expectRevert(GridHook.RebalanceCooldownNotMet.selector);
        hook.rebalance(key, address(this), type(uint256).max);
    }

    function test_fork_keeperCannotRebalanceDuringVolatileBlock() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        // Swap to move price
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: -1e10, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        _approveHookForTokens(address(this));
        hook.setRebalanceKeeper(alice, true);

        // Keeper tries to rebalance in same block as swap
        vm.prank(alice);
        vm.expectRevert(GridHook.RebalanceInSameBlockAsSwap.selector);
        hook.rebalance(key, address(this), type(uint256).max);
    }

    function test_fork_rebalanceSucceedsAfterBlockAdvances() public {
        _setupFullGrid(address(this), GridTypes.DistributionType.FIBONACCI, 5);

        // Swap to move price
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: -2e11, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), "");

        _approveHookForTokens(address(this));

        // Advance block and enough time
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 120);

        hook.rebalance(key, address(this), type(uint256).max);

        GridTypes.UserGridState memory userState = hook.getUserState(key, address(this));
        assertEq(userState.rebalanceCount, 1);
    }

    // ==================== Helpers ====================

    function _defaultForkConfig() internal pure returns (GridTypes.GridConfig memory) {
        return GridTypes.GridConfig({
            gridSpacing: 60,
            maxOrders: 5,
            rebalanceThresholdBps: 250,
            distributionType: GridTypes.DistributionType.FIBONACCI,
            autoRebalance: true,
            maxSlippageDelta0: 0,
            maxSlippageDelta1: 0
        });
    }

    function _approveHookForTokens(
        address user
    ) internal {
        vm.startPrank(user);
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        permit2.approve(WETH, address(hook), type(uint160).max, type(uint48).max);
        permit2.approve(USDC, address(hook), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _approveHookForUser(
        address user
    ) internal {
        vm.startPrank(user);
        IERC20(WETH).approve(PERMIT2, type(uint256).max);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        permit2.approve(WETH, address(hook), type(uint160).max, type(uint48).max);
        permit2.approve(USDC, address(hook), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _fundAndApproveUser(
        address user,
        uint256 wethAmount,
        uint256 usdcAmount
    ) internal {
        deal(WETH, user, IERC20(WETH).balanceOf(user) + wethAmount);
        deal(USDC, user, IERC20(USDC).balanceOf(user) + usdcAmount);
        _approveHookForTokens(user);
    }

    function _setupFullGrid(
        address user,
        GridTypes.DistributionType dist,
        uint24 maxOrders
    ) internal {
        GridTypes.GridConfig memory config = GridTypes.GridConfig({
            gridSpacing: 60,
            maxOrders: maxOrders,
            rebalanceThresholdBps: 250,
            distributionType: dist,
            autoRebalance: true,
            maxSlippageDelta0: 0,
            maxSlippageDelta1: 0
        });

        vm.prank(user);
        hook.setGridConfig(key, config);

        // Initialize pool only if not already initialized
        GridTypes.PoolState memory poolState = hook.getPoolState(key);
        if (!poolState.initialized) {
            manager.initialize(key, SQRT_PRICE_1_1);
        }

        // Fund and approve, then deploy
        _fundAndApproveUser(user, 100e18, 1_000_000_000e6);

        vm.prank(user);
        hook.deployGrid(key, GRID_LIQUIDITY, 0, 0, type(uint256).max);
    }
}
