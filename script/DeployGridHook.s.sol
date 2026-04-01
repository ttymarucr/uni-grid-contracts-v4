// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";

import { GridHook } from "src/hooks/GridHook.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";

/// @title DeployGridHook
/// @notice Deploys GridHook via CREATE2 so the hook lands at the same address on every chain.
///
///   The deterministic deployment proxy (Nick's factory, deployed at the same address on all major
///   EVM chains) is used as the CREATE2 deployer.  Because the factory address, the salt, and the
///   init-code are identical across chains, the resulting hook address is identical too.
///
///   The script also validates that the deployed address has the correct least-significant flag bits
///   required by Uniswap v4 for the callbacks GridHook enables.
///
/// Usage:
///
///   1. Mine a valid salt (simulation, no gas):
///
///        POOL_MANAGER=0x... forge script script/DeployGridHook.s.sol \
///          --sig "mineSalt()" -vvv
///
///   2. Deploy to a single chain:
///
///        POOL_MANAGER=0x... HOOK_SALT=0x... forge script script/DeployGridHook.s.sol \
///          --rpc-url ethereum --broadcast --verify -vvv
///
///   3. Deploy to all chains (see script/deploy-all-chains.sh).
contract DeployGridHookScript is Script {
    /// @dev Canonical Permit2 address (same on all major EVM chains).
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Exact hook-flag mask that GridHook requires (from requiredHookFlags()).
    uint160 constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG;

    // ──────────────────────────────  ENTRY POINTS  ──────────────────────────────

    /// @notice Default entry point: deploy GridHook on the connected chain.
    ///         Reads POOL_MANAGER (required) and HOOK_SALT (optional) from env.
    ///         When HOOK_SALT is omitted the script mines one automatically.
    function run() external returns (GridHook hook) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        bytes32 salt = _resolveSalt(poolManager);

        bytes memory initCode = _initCode(poolManager);
        address expected = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY);
        _assertValidFlags(expected);

        console.log("Chain ID      :", block.chainid);
        console.log("Pool Manager  :", poolManager);
        console.log("Salt          :", vm.toString(salt));
        console.log("Expected addr :", expected);

        vm.startBroadcast();
        (bool success,) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(success, "CREATE2 deployment failed");
        vm.stopBroadcast();

        hook = GridHook(payable(expected));
        require(address(hook.poolManager()) == poolManager, "PoolManager mismatch after deployment");

        console.log("GridHook deployed at:", address(hook));
    }

    /// @notice Mine-only mode: find and log a valid salt without broadcasting.
    function mineSalt() external view {
        address poolManager = vm.envAddress("POOL_MANAGER");
        (bytes32 salt, address hookAddr) = _mine(poolManager);

        console.log("Pool Manager  :", poolManager);
        console.log("Salt          :", vm.toString(salt));
        console.log("Hook address  :", hookAddr);
        console.log("Required flags: 0x%x", uint256(REQUIRED_FLAGS));
        console.log("Address  flags: 0x%x", uint256(uint160(hookAddr) & Hooks.ALL_HOOK_MASK));
    }

    // ──────────────────────────────  INTERNALS  ─────────────────────────────────

    /// @dev Returns a pre-mined salt from the environment, or mines a new one.
    function _resolveSalt(
        address poolManager
    ) internal view returns (bytes32 salt) {
        salt = vm.envOr("HOOK_SALT", bytes32(0));
        if (salt == bytes32(0)) {
            (salt,) = _mine(poolManager);
        }
    }

    /// @dev Brute-forces a CREATE2 salt whose resulting address satisfies the required hook flags.
    function _mine(
        address poolManager
    ) internal view returns (bytes32 salt, address hookAddr) {
        bytes32 initCodeHash = keccak256(_initCode(poolManager));

        for (uint256 i; i < type(uint256).max; i++) {
            salt = bytes32(i);
            hookAddr = vm.computeCreate2Address(salt, initCodeHash, CREATE2_FACTORY);

            if (uint160(hookAddr) & Hooks.ALL_HOOK_MASK == REQUIRED_FLAGS) {
                console.log("Salt found after %d iterations", i);
                return (salt, hookAddr);
            }
        }
        revert("Salt search space exhausted");
    }

    /// @dev ABI-encoded creation code for GridHook(poolManager).
    function _initCode(
        address poolManager
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(GridHook).creationCode, abi.encode(IPoolManager(poolManager), IAllowanceTransfer(PERMIT2))
        );
    }

    /// @dev Reverts if the address does not carry exactly the required hook-flag bits.
    function _assertValidFlags(
        address hookAddr
    ) internal pure {
        uint160 flags = uint160(hookAddr) & Hooks.ALL_HOOK_MASK;
        require(flags == REQUIRED_FLAGS, "Hook address flags mismatch");
    }
}
