#!/usr/bin/env bash
# Mine CREATE2 salts for GridHook on all supported chains.
#
# PoolManager addresses differ per chain in Uniswap v4, so the constructor
# args (and therefore the init-code hash) change. Each chain needs its own
# salt to produce a valid hook address with the required flag bits.
#
# Usage:
#   ./script/mint-salt-all-chains.sh
#
set -eu

declare -A POOL_MANAGERS=(
  [unichain]="0x1f98400000000000000000000000000000000004"
  [mainnet]="0x000000000004444c5dc75cB358380D2e3dE08A90"
  [bnb]="0x28e2ea090877bf75740558f6bfb36a5ffee9e9df"
  [base]="0x498581ff718922c3f8e6a244956af099b2652b2b"
  [arbitrum]="0x360e68faccca8ca495c1b759fd9eee466db9fb32"
  [optimism]="0x9a13f98cb987694c9f086b1f5eb990eea8264ec3"
)

CHAINS=("unichain" "mainnet" "bnb" "base" "arbitrum" "optimism")

for chain in "${CHAINS[@]}"; do
  pm="${POOL_MANAGERS[$chain]}"
  echo "══════════════════════════════════════════════"
  echo " Mining Salt for ${chain} (POOL_MANAGER=${pm}) ..."
  echo "══════════════════════════════════════════════"
  POOL_MANAGER="$pm" forge script script/DeployGridHook.s.sol --sig "mineSalt()" -vvv
  echo ""
done

echo "Salt mining complete. Set HOOK_SALT_<CHAIN> env vars before deploying."