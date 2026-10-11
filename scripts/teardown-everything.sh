#!/usr/bin/env bash
#
# teardown-everything.sh — full reset, including the landing zone and
# the bootstrap-created identity/state storage itself.
#
# This is NOT the "pausing for a while" command — that's teardown.sh.
# Use this only when you're actually done with the project (abandoning
# it, or starting completely fresh). It destroys core/ (policy, budget,
# monitoring, identity role assignments), then deletes everything
# bootstrap.sh created imperatively via az CLI: the terraform_auth app
# registration (and every federated credential on it), and the tfstate
# storage account + its resource group.
#
# After this runs, re-running bootstrap/bootstrap.sh from scratch gets
# you a NEW terraform_auth app ID — every GitHub Actions secret
# (ARM_CLIENT_ID, TERRAFORM_AUTH_OBJECT_ID) will need updating to match.
#
# Usage: ./scripts/teardown-everything.sh        (asks for confirmation)
#        ./scripts/teardown-everything.sh --yes   (skips confirmation — be sure)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT="$SCRIPT_DIR/../terraform"

AUTO_YES=false
[ "${1:-}" = "--yes" ] && AUTO_YES=true

if ! az account show >/dev/null 2>&1; then
  echo "Not logged in. Run 'az login' first." >&2
  exit 1
fi

if ! $AUTO_YES; then
  cat <<'WARN'
============================================================
 THIS DESTROYS EVERYTHING: workloads, the landing zone, the
 Terraform state storage account, and the terraform_auth
 identity. This is NOT reversible and is NOT what you want if
 you're just pausing work — use teardown.sh for that instead.
============================================================
WARN
  read -r -p "Type 'destroy everything' to continue: " confirm
  [ "$confirm" = "destroy everything" ] || { echo "Aborted."; exit 1; }
fi

# 1. Workloads first (envs depend on core's outputs, so they must go
#    before core, and core must go before its own backing storage).
"$SCRIPT_DIR/teardown.sh" --yes

# 2. The landing zone itself.
echo "============================================================"
echo " Destroying terraform/core"
echo "============================================================"
(cd "$TF_ROOT/core" && terraform init -input=false && terraform destroy -auto-approve)

# 3. Bootstrap-created, az-CLI-managed artifacts — not in any
#    Terraform state, so removed imperatively, same layer bootstrap.sh
#    created them in.
echo "============================================================"
echo " Removing bootstrap-created identity and state storage"
echo "============================================================"
SP_NAME="terraform_auth"
TFSTATE_RG="rg-terraform-state"

APP_ID=$(az ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv || true)
if [ -n "${APP_ID:-}" ]; then
  echo "Deleting app registration $SP_NAME ($APP_ID) — removes all its federated credentials too"
  az ad app delete --id "$APP_ID"
else
  echo "No app registration named $SP_NAME found — already removed?"
fi

if az group show --name "$TFSTATE_RG" >/dev/null 2>&1; then
  echo "Deleting resource group $TFSTATE_RG (tfstate storage account + core's monitoring RG are both inside it or siblings — review before confirming)"
  az group delete --name "$TFSTATE_RG" --yes --no-wait
else
  echo "$TFSTATE_RG not found — already removed?"
fi

echo
echo "Full reset requested. Resource group deletion runs in the background"
echo "(--no-wait) — check 'az group list -o table' to confirm when it's clear."
