// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, Vm } from "forge-std/Test.sol";

import { GridHook } from "src/hooks/GridHook.sol";
import { GridTypes } from "src/libraries/GridTypes.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/types/PoolOperation.sol";

contract MockPoolManager {
    mapping(bytes32 => bytes32) private _extsloadData;

    error CannotUpdateEmptyPosition();

    function extsload(
        bytes32 slot
    ) external view returns (bytes32) {
        return _extsloadData[slot];
    }

    function setExtsloadData(
        bytes32 slot,
        bytes32 value
    ) external {
        _extsloadData[slot] = value;
    }

    function unlock(
        bytes calldata data
    ) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(
        PoolKey memory,
        ModifyLiquidityParams memory params,
        bytes calldata
    ) external returns (BalanceDelta, BalanceDelta) {
        if (params.liquidityDelta == 0) revert CannotUpdateEmptyPosition();
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function sync(
        Currency
    ) external { }

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(
        Currency,
        address,
        uint256
    ) external { }
}

contract GridHookTest is Test {
    using PoolIdLibrary for PoolKey;

    GridHook internal hook;
    MockPoolManager internal mockPm;
    address internal mockPermit2 = makeAddr("permit2");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() external {
        mockPm = new MockPoolManager();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(uint160(type(uint160).max & ~uint160(Hooks.ALL_HOOK_MASK)) | flags);

        deployCodeTo(
            "GridHook.sol:GridHook",
            abi.encode(IPoolManager(address(mockPm)), IAllowanceTransfer(mockPermit2)),
            hookAddr
        );
        hook = GridHook(payable(hookAddr));
    }

    // ==================== Permissions ====================

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

    function testSetGridConfigAndReadBack() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();

        hook.setGridConfig(key, config);
        GridTypes.GridConfig memory stored = hook.getGridConfig(key, address(this));

        assertEq(stored.gridSpacing, config.gridSpacing);
        assertEq(stored.maxOrders, config.maxOrders);
        assertEq(stored.rebalanceThresholdBps, config.rebalanceThresholdBps);
        assertEq(uint256(stored.distributionType), uint256(config.distributionType));
        assertEq(stored.autoRebalance, config.autoRebalance);
    }

    function testSetGridConfigStoresWeights() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();

        hook.setGridConfig(key, config);
        uint256[] memory weights = hook.getPlannedWeights(key, address(this));

        assertEq(weights.length, config.maxOrders);
        // Fibonacci(5): [833, 833, 1666, 2500, 4166]
        assertEq(weights[0], 833);
        assertEq(weights[1], 833);
        assertEq(weights[2], 1666);
        assertEq(weights[3], 2500);
        assertEq(weights[4], 4166);
    }

    function testSetGridConfigRevertsForInvalidGridSpacing() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();
        config.gridSpacing = 0;

        vm.expectRevert(abi.encodeWithSelector(GridHook.InvalidGridStep.selector, 0));
        hook.setGridConfig(key, config);
    }

    function testSetGridConfigRevertsForInvalidMaxOrders() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();

        config.maxOrders = 0;
        vm.expectRevert(abi.encodeWithSelector(GridHook.InvalidGridQuantity.selector, 0));
        hook.setGridConfig(key, config);

        config.maxOrders = 1001;
        vm.expectRevert(abi.encodeWithSelector(GridHook.InvalidGridQuantity.selector, 1001));
        hook.setGridConfig(key, config);
    }

    function testSetGridConfigRevertsForInvalidRebalanceThreshold() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();
        config.rebalanceThresholdBps = 501;

        vm.expectRevert(abi.encodeWithSelector(GridHook.SlippageTooHigh.selector, 501));
        hook.setGridConfig(key, config);
    }

    function testConstructorRevertsForZeroPoolManager() external {
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );
        // We expect the revert before validateHookPermissions, so we can use any address
        vm.expectRevert(GridHook.PoolManagerAddressZero.selector);
        new GridHook(IPoolManager(address(0)), IAllowanceTransfer(mockPermit2));
    }

    // ==================== Multi-User Config Isolation ====================

    function testTwoUsersCanConfigureSamePool() external {
        PoolKey memory key = _poolKey();

        GridTypes.GridConfig memory fibConfig = _defaultConfig();

        GridTypes.GridConfig memory flatConfig = GridTypes.GridConfig({
            gridSpacing: 60,
            maxOrders: 4,
            rebalanceThresholdBps: 100,
            distributionType: GridTypes.DistributionType.FLAT,
            autoRebalance: false,
            maxSlippageDelta0: 0,
            maxSlippageDelta1: 0
        });

        vm.prank(alice);
        hook.setGridConfig(key, fibConfig);

        vm.prank(bob);
        hook.setGridConfig(key, flatConfig);

        GridTypes.GridConfig memory aliceStored = hook.getGridConfig(key, alice);
        GridTypes.GridConfig memory bobStored = hook.getGridConfig(key, bob);

        assertEq(aliceStored.maxOrders, 5);
        assertEq(uint256(aliceStored.distributionType), uint256(GridTypes.DistributionType.FIBONACCI));

        assertEq(bobStored.maxOrders, 4);
        assertEq(uint256(bobStored.distributionType), uint256(GridTypes.DistributionType.FLAT));

        uint256[] memory aliceWeights = hook.getPlannedWeights(key, alice);
        uint256[] memory bobWeights = hook.getPlannedWeights(key, bob);
        assertEq(aliceWeights.length, 5);
        assertEq(bobWeights.length, 4);
        assertEq(bobWeights[0], 2500);
    }

    // ==================== Callback Gating ====================

    function testAfterInitializeRevertsWhenNotPoolManager() external {
        vm.expectRevert(GridHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), _poolKey(), 1, 0);
    }

    function testAfterSwapRevertsWhenNotPoolManager() external {
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 0 });
        vm.expectRevert(GridHook.NotPoolManager.selector);
        hook.afterSwap(address(this), _poolKey(), params, BalanceDelta.wrap(0), bytes(""));
    }

    // ==================== After Initialize ====================

    function testAfterInitializeSetsPoolState() external {
        PoolKey memory key = _poolKey();

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 120);

        GridTypes.PoolState memory state = hook.getPoolState(key);

        assertTrue(state.initialized);
        assertEq(state.currentTick, 120);
        assertEq(state.swapCount, 0);
    }

    // ==================== Deploy Grid ====================

    function testDeployGridCreatesOrders() external {
        PoolKey memory key = _poolKey();
        hook.setGridConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key, address(this));
        assertEq(orders.length, 5);

        // Fibonacci weights [833, 833, 1666, 2500, 4166]
        assertEq(orders[0].liquidity, 83_300);
        assertEq(orders[1].liquidity, 83_300);
        assertEq(orders[2].liquidity, 166_600);
        assertEq(orders[3].liquidity, 250_000);
        assertEq(orders[4].liquidity, 416_800);

        assertEq(orders[0].tickLower, -120);
        assertEq(orders[0].tickUpper, -60);
        assertEq(orders[4].tickLower, 120);
        assertEq(orders[4].tickUpper, 180);

        GridTypes.UserGridState memory userState = hook.getUserState(key, address(this));
        assertTrue(userState.deployed);
        assertEq(userState.gridCenterTick, 0);
    }

    function testDeployGridRevertsWhenNotInitialized() external {
        PoolKey memory key = _poolKey();
        hook.setGridConfig(key, _defaultConfig());

        vm.expectRevert(abi.encodeWithSelector(GridHook.PoolNotInitialized.selector, key.toId()));
        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);
    }

    function testDeployGridRevertsWhenAlreadyDeployed() external {
        PoolKey memory key = _poolKey();
        hook.setGridConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(GridHook.GridAlreadyDeployed.selector, key.toId(), address(this)));
        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);
    }

    function testDeployGridRevertsWithZeroLiquidity() external {
        PoolKey memory key = _poolKey();
        hook.setGridConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        vm.expectRevert(GridHook.NoAssetsAvailable.selector);
        hook.deployGrid(key, 0, 0, 0, type(uint256).max);
    }

    function _deployAndVerifyZeroLiquidityOrders(GridTypes.DistributionType dist) internal {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = GridTypes.GridConfig({
            gridSpacing: 60,
            maxOrders: 30,
            rebalanceThresholdBps: 100,
            distributionType: dist,
            autoRebalance: true,
            maxSlippageDelta0: 0,
            maxSlippageDelta1: 0
        });
        hook.setGridConfig(key, config);

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        // Small liquidity + 30 orders → some distributions produce weight-0 orders
        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key, address(this));
        assertEq(orders.length, 30);

        // Total liquidity across all orders must equal the input
        uint128 totalLiq;
        for (uint256 i; i < orders.length; ++i) {
            totalLiq += orders[i].liquidity;
        }
        assertEq(totalLiq, 1_000_000);

        assertTrue(hook.getUserState(key, address(this)).deployed);

        // Rebalance should also succeed with zero-liquidity orders
        _setMockSlot0(key, 300);
        hook.rebalance(key, address(this), type(uint256).max);
        assertEq(hook.getUserState(key, address(this)).gridCenterTick, 300);

        // Close should also succeed with zero-liquidity orders
        hook.closeGrid(key, type(uint256).max);
        assertFalse(hook.getUserState(key, address(this)).deployed);
    }

    function testDeployWithZeroLiquidityOrders_Flat() external {
        _deployAndVerifyZeroLiquidityOrders(GridTypes.DistributionType.FLAT);
    }

    function testDeployWithZeroLiquidityOrders_Linear() external {
        _deployAndVerifyZeroLiquidityOrders(GridTypes.DistributionType.LINEAR);
    }

    function testDeployWithZeroLiquidityOrders_ReverseLinear() external {
        _deployAndVerifyZeroLiquidityOrders(GridTypes.DistributionType.REVERSE_LINEAR);
    }

    function testDeployWithZeroLiquidityOrders_Fibonacci() external {
        _deployAndVerifyZeroLiquidityOrders(GridTypes.DistributionType.FIBONACCI);
    }

    function testDeployWithZeroLiquidityOrders_Sigmoid() external {
        _deployAndVerifyZeroLiquidityOrders(GridTypes.DistributionType.SIGMOID);
    }

    function testDeployWithZeroLiquidityOrders_Logarithmic() external {
        _deployAndVerifyZeroLiquidityOrders(GridTypes.DistributionType.LOGARITHMIC);
    }

    function testDeployGridRevertsWhenNotConfigured() external {
        PoolKey memory key = _poolKey();

        vm.expectRevert(abi.encodeWithSelector(GridHook.GridNotConfigured.selector, key.toId(), address(this)));
        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);
    }

    function testDeployGridRevertsWhenSpacingMisaligned() external {
        PoolKey memory key = _poolKey();
        GridTypes.GridConfig memory config = _defaultConfig();
        config.gridSpacing = 50;
        hook.setGridConfig(key, config);

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        vm.expectRevert(
            abi.encodeWithSelector(GridHook.TickSpacingMisaligned.selector, int24(50), int24(60), int24(60))
        );
        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);
    }

    // ==================== Multi-User Deploy ====================

    function testTwoUsersDeployOnSamePool() external {
        PoolKey memory key = _poolKey();

        vm.prank(alice);
        hook.setGridConfig(key, _defaultConfig());

        GridTypes.GridConfig memory flatConfig = GridTypes.GridConfig({
            gridSpacing: 60,
            maxOrders: 4,
            rebalanceThresholdBps: 100,
            distributionType: GridTypes.DistributionType.FLAT,
            autoRebalance: false,
            maxSlippageDelta0: 0,
            maxSlippageDelta1: 0
        });
        vm.prank(bob);
        hook.setGridConfig(key, flatConfig);

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        vm.prank(alice);
        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);

        vm.prank(bob);
        hook.deployGrid(key, 400_000, 0, 0, type(uint256).max);

        GridTypes.GridOrder[] memory aliceOrders = hook.getGridOrders(key, alice);
        GridTypes.GridOrder[] memory bobOrders = hook.getGridOrders(key, bob);

        assertEq(aliceOrders.length, 5);
        assertEq(bobOrders.length, 4);

        assertEq(aliceOrders[0].liquidity, 83_300);
        assertEq(aliceOrders[4].liquidity, 416_800);

        assertEq(bobOrders[0].liquidity, 100_000);
        assertEq(bobOrders[1].liquidity, 100_000);
        assertEq(bobOrders[2].liquidity, 100_000);
        assertEq(bobOrders[3].liquidity, 100_000);

        assertTrue(hook.getUserState(key, alice).deployed);
        assertTrue(hook.getUserState(key, bob).deployed);
    }

    // ==================== Rebalance ====================

    function testRebalanceUpdatesGridCenter() external {
        PoolKey memory key = _poolKey();
        hook.setGridConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);

        _setMockSlot0(key, 300);

        hook.rebalance(key, address(this), type(uint256).max);

        GridTypes.UserGridState memory userState = hook.getUserState(key, address(this));
        assertEq(userState.gridCenterTick, 300);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key, address(this));
        assertEq(orders.length, 5);
        assertEq(orders[0].tickLower, 180);
        assertEq(orders[0].tickUpper, 240);
        assertEq(orders[4].tickLower, 420);
        assertEq(orders[4].tickUpper, 480);
    }

    function testRebalanceByKeeperSucceeds() external {
        PoolKey memory key = _poolKey();
        hook.setGridConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);

        // Authorize alice as keeper
        hook.setRebalanceKeeper(alice, true);

        _setMockSlot0(key, 300);

        vm.prank(alice);
        hook.rebalance(key, address(this), type(uint256).max);

        GridTypes.UserGridState memory userState = hook.getUserState(key, address(this));
        assertEq(userState.gridCenterTick, 300);
    }

    function testRebalanceRevertsWhenGridNotDeployed() external {
        PoolKey memory key = _poolKey();
        hook.setGridConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        vm.expectRevert(abi.encodeWithSelector(GridHook.GridNotDeployed.selector, key.toId(), address(this)));
        hook.rebalance(key, address(this), type(uint256).max);
    }

    function testRebalanceDoesNotAffectOtherUser() external {
        PoolKey memory key = _poolKey();

        vm.prank(alice);
        hook.setGridConfig(key, _defaultConfig());

        vm.prank(bob);
        hook.setGridConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        vm.prank(alice);
        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);

        vm.prank(bob);
        hook.deployGrid(key, 500_000, 0, 0, type(uint256).max);

        _setMockSlot0(key, 300);

        // Rebalance alice's grid as alice herself
        vm.prank(alice);
        hook.rebalance(key, alice, type(uint256).max);

        assertEq(hook.getUserState(key, alice).gridCenterTick, 300);
        assertEq(hook.getUserState(key, bob).gridCenterTick, 0);

        GridTypes.GridOrder[] memory bobOrders = hook.getGridOrders(key, bob);
        assertEq(bobOrders[0].tickLower, -120);
    }

    // ==================== Close Grid ====================

    function testCloseGridRemovesOrders() external {
        PoolKey memory key = _poolKey();
        hook.setGridConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);
        assertTrue(hook.getUserState(key, address(this)).deployed);

        hook.closeGrid(key, type(uint256).max);

        GridTypes.UserGridState memory userState = hook.getUserState(key, address(this));
        assertFalse(userState.deployed);
        assertEq(userState.gridCenterTick, 0);

        GridTypes.GridOrder[] memory orders = hook.getGridOrders(key, address(this));
        assertEq(orders.length, 0);
    }

    function testCloseGridRevertsWhenNotDeployed() external {
        PoolKey memory key = _poolKey();

        vm.expectRevert(abi.encodeWithSelector(GridHook.GridNotDeployed.selector, key.toId(), address(this)));
        hook.closeGrid(key, type(uint256).max);
    }

    function testCloseGridDoesNotAffectOtherUser() external {
        PoolKey memory key = _poolKey();

        vm.prank(alice);
        hook.setGridConfig(key, _defaultConfig());

        vm.prank(bob);
        hook.setGridConfig(key, _defaultConfig());

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1 << 96, 0);

        vm.prank(alice);
        hook.deployGrid(key, 1_000_000, 0, 0, type(uint256).max);

        vm.prank(bob);
        hook.deployGrid(key, 500_000, 0, 0, type(uint256).max);

        vm.prank(alice);
        hook.closeGrid(key, type(uint256).max);

        assertFalse(hook.getUserState(key, alice).deployed);
        assertTrue(hook.getUserState(key, bob).deployed);
        assertEq(hook.getGridOrders(key, bob).length, 5);
    }

    // ==================== After Swap ====================

    function testAfterSwapUpdatesPoolState() external {
        PoolKey memory key = _poolKey();

        vm.prank(address(mockPm));
        hook.afterInitialize(address(this), key, 1, 0);

        _setMockSlot0(key, 180);

        SwapParams memory swapParams = SwapParams({ zeroForOne: false, amountSpecified: -500, sqrtPriceLimitX96: 0 });

        vm.prank(address(mockPm));
        hook.afterSwap(address(this), key, swapParams, BalanceDelta.wrap(0), bytes(""));

        GridTypes.PoolState memory state = hook.getPoolState(key);
        assertEq(state.currentTick, 180);
        assertEq(state.swapCount, 1);
    }

    // ==================== Helpers ====================

    function _setMockSlot0(
        PoolKey memory key,
        int24 tick
    ) internal {
        PoolId poolId = key.toId();
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(uint256(6))));
        uint256 sqrtPriceX96 = 1 << 96;
        // casting is safe: int24 tick reinterpreted as uint24 then widened to uint256 for bit packing
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 packed = sqrtPriceX96 | (uint256(uint24(tick)) << 160);
        mockPm.setExtsloadData(stateSlot, bytes32(packed));
    }

    function _defaultConfig() private pure returns (GridTypes.GridConfig memory) {
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
