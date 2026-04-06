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

declare -A SALTS=(
  [ethereum]="0x"
  [unichain]="0x"
  [arbitrum]="0x"
  [base]="0x"
  [bsc]="0x"
)

CHAINS=("ethereum" "unichain" "arbitrum" "base" "bsc")

for chain in "${CHAINS[@]}"; do
  POOL_MANAGER="${POOL_MANAGERS[$chain]}"
  SALT="${SALTS[$chain]}"

  echo "══════════════════════════════════════════════"
  echo " Deploying to ${chain} ..."
  echo " Pool Manager: ${POOL_MANAGER}"
  echo " Salt        : ${SALT}"
  echo "══════════════════════════════════════════════"

  POOL_MANAGER="$POOL_MANAGER" \
    HOOK_SALT="$SALT" \
    forge script script/DeployGridHook.s.sol \
      --rpc-url "$chain" \
      --broadcast \
      --verify \
      -vvv

  echo ""
done

echo "All deployments complete."
