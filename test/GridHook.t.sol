// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {GridHook} from "src/hooks/GridHook.sol";
import {GridTypes} from "src/libraries/GridTypes.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

contract MockPoolManager {
    mapping(bytes32 => bytes32) private _extsloadData;

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _extsloadData[slot];
    }

    function setExtsloadData(bytes32 slot, bytes32 value) external {
        _extsloadData[slot] = value;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(PoolKey memory, ModifyLiquidityParams memory, bytes calldata)
        external
        returns (BalanceDelta, BalanceDelta)
    {
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(Currency, address, uint256) external {}
}

contract GridHookTest is Test {
    using PoolIdLibrary for PoolKey;

    GridHook internal hook;
    MockPoolManager internal mockPm;

    function setUp() external {
        mockPm = new MockPoolManager();
        hook = new GridHook(IPoolManager(address(mockPm)), address(this));
    }

    // ==================== Permissions ====================

    function testRequiredHookFlags() external view {
        uint160 expected = Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG;

        assertEq(hook.requiredHookFlags(), expected);
    }

    function testGetHookPermissions() external view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertFalse(permissions.beforeInitialize);
        assertTrue(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertTrue(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertTrue(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
    }

    // ==================== Configuration ====================

    function testSetPoolConfigAndReadBack() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();

        hook.setPoolConfig(key, config);
        GridTypes.GridConfig memory stored = hook.getPoolConfig(key);

        assertEq(stored.gridSpacing, config.gridSpacing);
        assertEq(stored.maxOrders, config.maxOrders);
        assertEq(stored.rebalanceThresholdBps, config.rebalanceThresholdBps);
        assertEq(uint256(stored.distributionType), uint256(config.distributionType));
        assertEq(stored.autoRebalance, config.autoRebalance);
    }

    function testSetPoolConfigRevertsForInvalidGridSpacing() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();
        config.gridSpacing = 0;

        vm.expectRevert(abi.encodeWithSelector(GridHook.InvalidGridStep.selector, 0));
        hook.setPoolConfig(key, config);
    }

    function testSetPoolConfigRevertsForInvalidMaxOrders() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();

        config.maxOrders = 0;
        vm.expectRevert(abi.encodeWithSelector(GridHook.InvalidGridQuantity.selector, 0));
        hook.setPoolConfig(key, config);

        config.maxOrders = 1_001;
        vm.expectRevert(abi.encodeWithSelector(GridHook.InvalidGridQuantity.selector, 1_001));
        hook.setPoolConfig(key, config);
    }

    function testSetPoolConfigRevertsForInvalidRebalanceThreshold() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();
        config.rebalanceThresholdBps = 501;

        vm.expectRevert(abi.encodeWithSelector(GridHook.SlippageTooHigh.selector, 501));
        hook.setPoolConfig(key, config);
    }

    function testConstructorRevertsForZeroPoolManager() external {
        vm.expectRevert(GridHook.PositionManagerAddressZero.selector);
        new GridHook(IPoolManager(address(0)), address(this));
    }

    // ==================== Callback Gating ====================

    function testAfterInitializeRevertsWhenNotPoolManager() external {
        vm.expectRevert(GridHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), _poolKey(), 1, 0);
    }

    function testAfterInitializeRevertsWhenPoolNotConfigured() external {
        PoolKey memory key = _poolKey();

        vm.prank(address(mockPm));
        vm.expectRevert(abi.encodeWithSelector(GridHook.PoolNotConfigured.selector, key.toId()));
        hook.afterInitialize(address(this), key, 1, 0);
    }

    // ==================== After Initialize ====================

    function testAfterInitializeStoresPlannedWeights() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();

        hook.setPoolConfig(key, config);

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1, 0);

        GridTypes.PoolRuntimeState memory state = hook.getPoolState(key);
        uint256[] memory plannedWeights = hook.getPlannedWeights(key);

        assertTrue(state.initialized);
        assertEq(plannedWeights.length, config.maxOrders);
        assertEq(plannedWeights[0], 833);
        assertEq(plannedWeights[1], 833);
        assertEq(plannedWeights[2], 1666);
        assertEq(plannedWeights[3], 2500);
        assertEq(plannedWeights[4], 4166);
    }

    function testAfterInitializeStoresCurrentTick() external {
        PoolKey memory key = _poolKey();
        hook.setPoolConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 120);

        GridTypes.PoolRuntimeState memory state = hook.getPoolState(key);

        assertEq(state.currentTick, 120);
        assertEq(state.gridCenterTick, 120);
        assertFalse(state.gridDeployed);
    }

    function testAfterInitializeAlignsCenterTick() external {
        PoolKey memory key = _poolKey();
        hook.setPoolConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 85);

        GridTypes.PoolRuntimeState memory state = hook.getPoolState(key);

        assertEq(state.currentTick, 85);
        assertEq(state.gridCenterTick, 60); // aligned down to tickSpacing=60
    }

    // ==================== Weight Previews ====================

    function testPreviewWeightsSupportsFlatDistribution() external view {
        uint256[] memory weights = hook.previewWeights(4, GridTypes.DistributionType.FLAT);

        assertEq(weights.length, 4);
        assertEq(weights[0], 2500);
        assertEq(weights[1], 2500);
        assertEq(weights[2], 2500);
        assertEq(weights[3], 2500);
    }

    function testPreviewWeightsSupportsLinearDistribution() external view {
        uint256[] memory weights = hook.previewWeights(4, GridTypes.DistributionType.LINEAR);

        assertEq(weights.length, 4);
        assertEq(weights[0], 1000);
        assertEq(weights[1], 2000);
        assertEq(weights[2], 3000);
        assertEq(weights[3], 4000);
    }

    function testPreviewWeightsSupportsReverseLinearDistribution() external view {
        uint256[] memory weights = hook.previewWeights(4, GridTypes.DistributionType.REVERSE_LINEAR);

        assertEq(weights.length, 4);
        assertEq(weights[0], 4000);
        assertEq(weights[1], 3000);
        assertEq(weights[2], 2000);
        assertEq(weights[3], 1000);
    }

    function testPreviewWeightsSupportsFibonacciDistribution() external view {
        uint256[] memory weights = hook.previewWeights(5, GridTypes.DistributionType.FIBONACCI);

        assertEq(weights.length, 5);
        assertEq(weights[0], 833);
        assertEq(weights[1], 833);
        assertEq(weights[2], 1666);
        assertEq(weights[3], 2500);
        assertEq(weights[4], 4166);
    }

    // ==================== Grid Computation ====================

    function testComputeGridOrdersTickRanges() external view {
        uint256[] memory weights = hook.previewWeights(5, GridTypes.DistributionType.FLAT);
        GridTypes.GridOrder[] memory orders = hook.computeGridOrders(0, 60, 60, 5, weights, 1_000_000);

        assertEq(orders.length, 5);
        // halfOrders = 5/2 = 2, bottomTick = 0 - 2*60 = -120
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

    function testComputeGridOrdersLiquidityDistribution() external view {
        uint256[] memory weights = hook.previewWeights(4, GridTypes.DistributionType.LINEAR);
        // weights = [1000, 2000, 3000, 4000]
        GridTypes.GridOrder[] memory orders = hook.computeGridOrders(0, 60, 60, 4, weights, 100_000);

        assertEq(orders[0].liquidity, 10_000); // 100000 * 1000 / 10000
        assertEq(orders[1].liquidity, 20_000);
        assertEq(orders[2].liquidity, 30_000);
        assertEq(orders[3].liquidity, 40_000);
    }

    function testComputeGridOrdersSingleOrder() external view {
        uint256[] memory weights = hook.previewWeights(1, GridTypes.DistributionType.FLAT);
        GridTypes.GridOrder[] memory orders = hook.computeGridOrders(0, 60, 60, 1, weights, 500_000);

        assertEq(orders.length, 1);
        assertEq(orders[0].tickLower, 0);
        assertEq(orders[0].tickUpper, 60);
        assertEq(orders[0].liquidity, 500_000);
    }

    function testComputeGridOrdersNegativeCenter() external view {
        uint256[] memory weights = hook.previewWeights(4, GridTypes.DistributionType.FLAT);
        GridTypes.GridOrder[] memory orders = hook.computeGridOrders(-180, 60, 60, 4, weights, 40_000);

        // halfOrders = 2, bottomTick = -180 - 2*60 = -300
        assertEq(orders[0].tickLower, -300);
        assertEq(orders[0].tickUpper, -240);
        assertEq(orders[3].tickLower, -120);
        assertEq(orders[3].tickUpper, -60);
        assertEq(orders[0].liquidity, 10_000);
    }

    function testComputePositionKeyMatchesCoreFormula() external view {
        address owner = address(0xCAFE);
        int24 tickLower = -120;
        int24 tickUpper = 120;
        bytes32 salt = bytes32(uint256(42));

        bytes32 expected = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
        bytes32 computed = hook.computePositionKey(owner, tickLower, tickUpper, salt);

        assertEq(computed, expected);
    }

    // ==================== Liquidity & Swap Callbacks ====================

    function testAfterLiquidityAndSwapUpdateRuntimeState() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();
        hook.setPoolConfig(key, config);

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1, 0);

        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 10,
            salt: bytes32(0)
        });

        vm.prank(address(mockPm));
        hook.afterAddLiquidity(
            address(this), key, liquidityParams, BalanceDelta.wrap(0), BalanceDelta.wrap(0), bytes("")
        );

        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -1234, sqrtPriceLimitX96: 0});

        vm.prank(address(mockPm));
        hook.afterSwap(address(this), key, swapParams, BalanceDelta.wrap(0), bytes(""));

        GridTypes.PoolRuntimeState memory state = hook.getPoolState(key);

        assertEq(state.liquidityOperations, 1);
        assertEq(state.swapCount, 1);
        assertEq(state.lastLowerTick, -120);
        assertEq(state.lastUpperTick, 120);
        assertEq(state.lastSwapAmountSpecified, -1234);
    }

    // ==================== Deploy Grid ====================

    function testDeployGridCreatesOrders() external {
        PoolKey memory key = _poolKey();
        hook.setPoolConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        hook.deployGrid(key, 1_000_000);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key);
        assertEq(orders.length, 5);

        // Fibonacci weights [833, 833, 1666, 2500, 4166]
        assertEq(orders[0].liquidity, 83_300);
        assertEq(orders[1].liquidity, 83_300);
        assertEq(orders[2].liquidity, 166_600);
        assertEq(orders[3].liquidity, 250_000);
        assertEq(orders[4].liquidity, 416_600);

        // Check tick ranges centered on 0 with gridSpacing=60
        assertEq(orders[0].tickLower, -120);
        assertEq(orders[0].tickUpper, -60);
        assertEq(orders[4].tickLower, 120);
        assertEq(orders[4].tickUpper, 180);

        GridTypes.PoolRuntimeState memory state = hook.getPoolState(key);
        assertTrue(state.gridDeployed);
    }

    function testDeployGridRevertsWhenNotInitialized() external {
        PoolKey memory key = _poolKey();
        hook.setPoolConfig(key, _defaultConfig());

        vm.expectRevert(abi.encodeWithSelector(GridHook.PoolNotInitialized.selector, key.toId()));
        hook.deployGrid(key, 1_000_000);
    }

    function testDeployGridRevertsWhenAlreadyDeployed() external {
        PoolKey memory key = _poolKey();
        hook.setPoolConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        hook.deployGrid(key, 1_000_000);

        vm.expectRevert(abi.encodeWithSelector(GridHook.GridAlreadyDeployed.selector, key.toId()));
        hook.deployGrid(key, 1_000_000);
    }

    function testDeployGridRevertsWithZeroLiquidity() external {
        PoolKey memory key = _poolKey();
        hook.setPoolConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        vm.expectRevert(GridHook.NoAssetsAvailable.selector);
        hook.deployGrid(key, 0);
    }

    function testDeployGridRevertsWhenNotConfigured() external {
        PoolKey memory key = _poolKey();

        vm.expectRevert(abi.encodeWithSelector(GridHook.PoolNotConfigured.selector, key.toId()));
        hook.deployGrid(key, 1_000_000);
    }

    function testDeployGridRevertsWhenSpacingMisaligned() external {
        PoolKey memory key = _poolKey(); // tickSpacing=60
        GridTypes.GridConfig memory config = _defaultConfig();
        config.gridSpacing = 50; // not a multiple of 60
        hook.setPoolConfig(key, config);

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        vm.expectRevert(abi.encodeWithSelector(GridHook.TickSpacingMisaligned.selector, int24(50), int24(60), int24(60)));
        hook.deployGrid(key, 1_000_000);
    }

    // ==================== Rebalance ====================

    function testRebalanceUpdatesGridCenter() external {
        PoolKey memory key = _poolKey();
        hook.setPoolConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        hook.deployGrid(key, 1_000_000);

        // Simulate price moving to tick 300 by setting mock slot0
        _setMockSlot0(key, 300);

        hook.rebalance(key);

        GridTypes.PoolRuntimeState memory state = hook.getPoolState(key);
        assertEq(state.gridCenterTick, 300); // aligned: 300 / 60 * 60 = 300
        assertEq(state.currentTick, 300);

        // Verify new orders are centered on 300
        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key);
        assertEq(orders.length, 5);
        // halfOrders=2, bottomTick = 300 - 2*60 = 180
        assertEq(orders[0].tickLower, 180);
        assertEq(orders[0].tickUpper, 240);
        assertEq(orders[4].tickLower, 420);
        assertEq(orders[4].tickUpper, 480);
    }

    function testRebalanceRevertsWhenGridNotDeployed() external {
        PoolKey memory key = _poolKey();
        hook.setPoolConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        vm.expectRevert(abi.encodeWithSelector(GridHook.GridNotDeployed.selector, key.toId()));
        hook.rebalance(key);
    }

    // ==================== Swap + Rebalance Detection ====================

    function testAfterSwapEmitsRebalanceNeededWhenDeviationExceedsThreshold() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();
        config.rebalanceThresholdBps = 250;
        config.autoRebalance = true;
        hook.setPoolConfig(key, config);

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        hook.deployGrid(key, 1_000_000);

        // Simulate post-swap tick at 300 (deviation=300 > threshold=250)
        _setMockSlot0(key, 300);

        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 0});

        vm.expectEmit(true, false, false, true);
        emit GridHook.RebalanceNeeded(key.toId(), int24(300), int24(0), 300);

        vm.prank(address(mockPm));
        hook.afterSwap(address(this), key, swapParams, BalanceDelta.wrap(0), bytes(""));
    }

    function testAfterSwapNoRebalanceWhenDeviationBelowThreshold() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();
        config.rebalanceThresholdBps = 250;
        config.autoRebalance = true;
        hook.setPoolConfig(key, config);

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        hook.deployGrid(key, 1_000_000);

        // Simulate post-swap tick at 100 (deviation=100 < threshold=250)
        _setMockSlot0(key, 100);

        SwapParams memory swapParams = SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 0});

        // Record logs and verify no RebalanceNeeded event
        vm.recordLogs();

        vm.prank(address(mockPm));
        hook.afterSwap(address(this), key, swapParams, BalanceDelta.wrap(0), bytes(""));

        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            assertTrue(
                entries[i].topics[0] != keccak256("RebalanceNeeded(bytes32,int24,int24,uint256)"),
                "RebalanceNeeded should not be emitted"
            );
        }
    }

    function testAfterSwapUpdatesCurrentTick() external {
        PoolKey memory key = _poolKey();
        hook.setPoolConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        _setMockSlot0(key, 180);

        SwapParams memory swapParams = SwapParams({zeroForOne: false, amountSpecified: -500, sqrtPriceLimitX96: 0});

        vm.prank(address(mockPm));
        hook.afterSwap(address(this), key, swapParams, BalanceDelta.wrap(0), bytes(""));

        GridTypes.PoolRuntimeState memory state = hook.getPoolState(key);
        assertEq(state.currentTick, 180);
    }

    // ==================== Helpers ====================

    function _setMockSlot0(PoolKey memory key, int24 tick) internal {
        PoolId poolId = key.toId();
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(uint256(6))));
        uint256 sqrtPriceX96 = 1 << 96;
        uint256 packed = sqrtPriceX96 | (uint256(uint24(tick)) << 160);
        mockPm.setExtsloadData(stateSlot, bytes32(packed));
    }

    function _defaultConfig() private pure returns (GridTypes.GridConfig memory) {
        return GridTypes.GridConfig({
            gridSpacing: 60,
            maxOrders: 5,
            rebalanceThresholdBps: 250,
            distributionType: GridTypes.DistributionType.FIBONACCI,
            autoRebalance: true
        });
    }

    function _poolKey() private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }
}