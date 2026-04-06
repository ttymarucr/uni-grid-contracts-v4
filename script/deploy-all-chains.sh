#!/usr/bin/env bash
# Deploy GridHook to Unichain via CREATE2.
#
# Prerequisites:
#   - HOOK_SALT : Pre-mined salt (run `mineSalt()` first, see below)
#
# Mine the salt once:
#   POOL_MANAGER=0x... forge script script/DeployGridHook.s.sol --sig "mineSalt()" -vvv
#
# Then deploy:
#   ./script/deploy-all-chains.sh
#
set -eu

POOL_MANAGER="0x1f98400000000000000000000000000000000004"
SALT="0x"
CHAIN="unichain"

{
  chain="$CHAIN"

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
}

echo "Deployment complete."
