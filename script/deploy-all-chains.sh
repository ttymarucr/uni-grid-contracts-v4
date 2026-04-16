#!/usr/bin/env bash
# Deploy GridHook to all supported chains via CREATE2.
#
# PoolManager addresses differ per chain (Uniswap v4), so each chain needs
# its own salt mined to satisfy hook-flag constraints. Set HOOK_SALT_<CHAIN>
# env vars, or fall back to HOOK_SALT for all.
#
# Mine salts first:
#   ./script/mint-salt-all-chains.sh
#
# Then deploy:
#   ./script/deploy-all-chains.sh
#
set -eu

# ── Per-chain PoolManager addresses (Uniswap v4) ──
declare -A POOL_MANAGERS=(
  [unichain]="0x1f98400000000000000000000000000000000004"
  [mainnet]="0x000000000004444c5dc75cB358380D2e3dE08A90"
  [bnb]="0x28e2ea090877bf75740558f6bfb36a5ffee9e9df"
  [base]="0x498581ff718922c3f8e6a244956af099b2652b2b"
  [arbitrum]="0x360e68faccca8ca495c1b759fd9eee466db9fb32"
  [optimism]="0x9a13f98cb987694c9f086b1f5eb990eea8264ec3"
)

CHAINS=("unichain" "mainnet" "bnb" "base" "arbitrum" "optimism")

HOOK_SALT_MAINNET="0x0000000000000000000000000000000000000000000000000000000000009b9b"
HOOK_SALT_BNB="0x00000000000000000000000000000000000000000000000000000000000047ec"
HOOK_SALT_BASE="0x0000000000000000000000000000000000000000000000000000000000005581"
HOOK_SALT_ARBITRUM="0x000000000000000000000000000000000000000000000000000000000000151a"
HOOK_SALT_OPTIMISM="0x000000000000000000000000000000000000000000000000000000000000055b"

for chain in "${CHAINS[@]}"; do
  pm="${POOL_MANAGERS[$chain]}"

  # Per-chain salt: HOOK_SALT_MAINNET, HOOK_SALT_BNB, … (fallback: HOOK_SALT)
  salt_var="HOOK_SALT_${chain^^}"
  salt="${!salt_var:-${HOOK_SALT:-}}"
  if [[ -z "$salt" ]]; then
    echo "ERROR: No salt for ${chain}. Set ${salt_var} or HOOK_SALT." >&2
    exit 1
  fi

  echo "══════════════════════════════════════════════"
  echo " Deploying GridHook to ${chain} ..."
  echo " Pool Manager: ${pm}"
  echo " Salt        : ${salt}"
  echo "══════════════════════════════════════════════"

  POOL_MANAGER="$pm" \
    HOOK_SALT="$salt" \
    forge script script/DeployGridHook.s.sol \
      --rpc-url "$chain" \
      --broadcast \
      --verify \
      -vvv

  echo ""
done

echo "GridHook deployment complete on all chains."
