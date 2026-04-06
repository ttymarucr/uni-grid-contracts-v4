#!/usr/bin/env bash
# Mine a CREATE2 salt for GridHook on Unichain.
#
# Prerequisites:
#   - POOL_MANAGER : PoolManager address (same on all target chains)
#   - HOOK_SALT    : Pre-mined salt (run `mineSalt()` first, see below)
#
# Mine the salt once:
#   POOL_MANAGER=0x... forge script script/DeployGridHook.s.sol --sig "mineSalt()" -vvv
#
# Then deploy:
#   POOL_MANAGER=0x... HOOK_SALT=0x... ./script/deploy-all-chains.sh
#
set -eu

POOL_MANAGER="0x1f98400000000000000000000000000000000004"

echo "Mining salt for unichain (POOL_MANAGER=$POOL_MANAGER)..."
POOL_MANAGER="$POOL_MANAGER" forge script script/DeployGridHook.s.sol --sig "mineSalt()" -vvv