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

CHAINS=("ethereum" "unichain" "arbitrum" "base" "bnb")

: "${POOL_MANAGER:?Set POOL_MANAGER to the canonical PoolManager address}"
: "${HOOK_SALT:?Set HOOK_SALT – run mineSalt() first}"

for chain in "${CHAINS[@]}"; do
  echo "══════════════════════════════════════════════"
  echo " Deploying to ${chain} ..."
  echo "══════════════════════════════════════════════"

  POOL_MANAGER="$POOL_MANAGER" HOOK_SALT="$HOOK_SALT" \
    forge script script/DeployGridHook.s.sol \
      --rpc-url "$chain" \
      --broadcast \
      --verify \
      -vvv

  echo ""
done

echo "All deployments complete."
