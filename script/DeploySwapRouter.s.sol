// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { SwapRouter } from "src/SwapRouter.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title DeploySwapRouter
/// @notice Deploys a minimal SwapRouter for executing single-pool swaps against Uniswap v4.
///
/// Usage:
///
///   POOL_MANAGER=0x... forge script script/DeploySwapRouter.s.sol \
///     --rpc-url unichain --broadcast --verify -vvv
contract DeploySwapRouterScript is Script {
    /// @dev Canonical Permit2 address (same on all major EVM chains).
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external returns (SwapRouter router) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("Chain ID      :", block.chainid);
        console.log("Pool Manager  :", poolManager);
        console.log("Permit2       :", PERMIT2);

        vm.startBroadcast(deployerPrivateKey);
        router = new SwapRouter(IPoolManager(poolManager), IAllowanceTransfer(PERMIT2));
        vm.stopBroadcast();

        console.log("SwapRouter deployed at:", address(router));
    }
}
