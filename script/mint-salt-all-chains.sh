#!/usr/bin/env bash
# Deploy GridHook to every chain defined in foundry.toml via CREATE2.
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

declare -A POOL_MANAGERS=(
  [ethereum]="0x000000000004444c5dc75cB358380D2e3dE08A90"
  [unichain]="0x1f98400000000000000000000000000000000004"
  [arbitrum]="0x360e68faccca8ca495c1b759fd9eee466db9fb32"
  [base]="0x498581ff718922c3f8e6a244956af099b2652b2b"
  [bsc]="0x28e2ea090877bf75740558f6bfb36a5ffee9e9df"
)

for chain in "${!POOL_MANAGERS[@]}"; do
    pool_manager="${POOL_MANAGERS[$chain]}"
    echo "Mining salt for $chain (POOL_MANAGER=$pool_manager)..."
    POOL_MANAGER="$pool_manager" forge script script/DeployGridHook.s.sol --sig "mineSalt()" -vvv
done