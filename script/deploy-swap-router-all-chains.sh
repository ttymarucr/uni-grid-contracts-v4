#!/usr/bin/env bash
# Deploy SwapRouter to all supported chains.
#
# SwapRouter uses CREATE (not CREATE2), so the deployed address will differ
# per chain. Record each address after deployment.
#
# Prerequisites:
#   - PRIVATE_KEY : Deployer private key (set in env)
#   - RPC endpoints configured in foundry.toml (or via env vars)
#
# Usage:
#   ./script/deploy-swap-router-all-chains.sh
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

for chain in "${CHAINS[@]}"; do
  pm="${POOL_MANAGERS[$chain]}"

  echo "══════════════════════════════════════════════"
  echo " Deploying SwapRouter to ${chain} ..."
  echo " Pool Manager: ${pm}"
  echo "══════════════════════════════════════════════"

  POOL_MANAGER="$pm" \
    forge script script/DeploySwapRouter.s.sol \
      --rpc-url "$chain" \
      --broadcast \
      --verify \
      -vvv

  echo ""
done

echo "SwapRouter deployment complete on all chains."
