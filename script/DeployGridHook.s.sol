// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {GridHook} from "src/hooks/GridHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract DeployGridHookScript is Script {
    function run() external returns (GridHook hook) {
        address poolManagerAddress = vm.envAddress("POOL_MANAGER");
        address initialOwner = vm.envOr("INITIAL_OWNER", msg.sender);

        vm.startBroadcast();
        hook = new GridHook(IPoolManager(poolManagerAddress), initialOwner);
        vm.stopBroadcast();
    }
}