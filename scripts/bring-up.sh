#!/usr/bin/env bash
#
# bring-up.sh — redeploy whatever teardown.sh tore down.
#
# Re-applies terraform/envs/staging and/or terraform/envs/production.
# Safe to run even if nothing was torn down (Terraform no-ops on
# resources that already match state). core/ is applied first if its
# state looks empty, since envs/* read core's outputs via
# terraform_remote_state and will fail if core has never been applied.
#
# Usage: same arguments as teardown.sh
#   ./scripts/bring-up.sh
#   ./scripts/bring-up.sh staging
#   ./scripts/bring-up.sh --yes

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
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(staging production)

if ! az account show >/dev/null 2>&1; then
  echo "Not logged in. Run 'az login' first." >&2
  exit 1
fi

echo "============================================================"
echo " Ensuring terraform/core is applied (envs depend on its outputs)"
echo "============================================================"
(
  cd "$TF_ROOT/core"
  terraform init -input=false
  if $AUTO_YES; then terraform apply -auto-approve; else terraform apply; fi
)

for env in "${TARGETS[@]}"; do
  dir="$TF_ROOT/envs/$env"
  echo "============================================================"
  echo " Applying: $env  ($dir)"
  echo "============================================================"
  (
    cd "$dir"
    terraform init -input=false
    if $AUTO_YES; then terraform apply -auto-approve; else terraform apply; fi
  )
done

echo
echo "Done."
