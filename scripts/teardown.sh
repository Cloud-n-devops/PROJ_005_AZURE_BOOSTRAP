#!/usr/bin/env bash
#
# teardown.sh — destroy every billed workload, keep the landing zone.
#
# Destroys terraform/envs/production and terraform/envs/staging (every
# resource group, VM, AKS cluster, budget — everything each environment
# owns). Deliberately does NOT touch terraform/core or the bootstrap
# artifacts (tfstate storage account, terraform_auth app registration,
# its federated credentials): those cost ~$0 whether running or not, and
# destroying+recreating the identity would rotate its appId, breaking
# your GitHub Actions secrets every time. Run bring-up.sh to redeploy
# whatever was destroyed, any time you're ready to resume.
#
# Usage:
#   ./scripts/teardown.sh              # destroys both staging and production, asks to confirm each
#   ./scripts/teardown.sh staging      # destroys staging only
#   ./scripts/teardown.sh production   # destroys production only
#   ./scripts/teardown.sh --yes        # skip confirmation prompts (CI/non-interactive use)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT="$SCRIPT_DIR/../terraform"

AUTO_YES=false
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
    staging|production) TARGETS+=("$arg") ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(production staging) # order doesn't matter — staging and production are independent siblings, neither depends on the other, only on core

# Local run assumes `az login` has already been done as yourself or as
# terraform_auth (az login --service-principal ...). No ARM_* env vars
# are set here, so the azurerm provider falls back to that session.
if ! az account show >/dev/null 2>&1; then
  echo "Not logged in. Run 'az login' first." >&2
  exit 1
fi

for env in "${TARGETS[@]}"; do
  dir="$TF_ROOT/envs/$env"
  echo "============================================================"
  echo " Destroying: $env  ($dir)"
  echo "============================================================"
  (
    cd "$dir"
    terraform init -input=false
    if $AUTO_YES; then
      terraform destroy -auto-approve
    else
      terraform destroy
    fi
  )
done

echo
echo "Done. terraform/core (identity, policy, monitoring, budget) was left untouched."
echo "Run ./scripts/bring-up.sh to redeploy any of the destroyed environments."
