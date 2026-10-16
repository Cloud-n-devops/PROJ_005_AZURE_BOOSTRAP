#!/usr/bin/env bash
#
# bootstrap.sh
# Idempotent (safe to re-run), minimal az CLI setup to unblock Terraform on a brand-new
# Azure subscription. Everything that does NOT need to exist before
# Terraform can authenticate is deliberately left out of this script —
# it belongs in terraform/modules/* instead.
#
# Run this interactively. Review each section before running the whole file.
#
# Prerequisites: az CLI >= 2.60, logged in with an account that has
# Owner (or User Access Administrator + Contributor) on the target subscription.

set -euo pipefail

### ---- 0. Variables — edit these ----------------------------------------
LOCATION="eastus"                                  # pick your primary region
TFSTATE_RG="rg-terraform-state"
TFSTATE_SA_NAME="sttfstate$RANDOM"                  # storage account names must be globally unique
TFSTATE_CONTAINER="tfstate"
SP_NAME="terraform_auth"
GITHUB_ORG="Cloud-n-devops"
GITHUB_REPO="PROJ_005_AZURE_BOOSTRAP"
PRODUCTION_BRANCH="main"                            # merges here apply terraform/core + terraform/envs/production
STAGING_BRANCH="staging"                             # merges here apply terraform/envs/staging

### ---- 1. Login + subscription context -----------------------------------
az account show >/dev/null 2>&1 || az login
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
az account set --subscription "$SUBSCRIPTION_ID"

echo "Subscription: $SUBSCRIPTION_ID"
echo "Tenant:       $TENANT_ID"

# Idempotency: if the state resource group already holds a storage account,
# reuse it instead of letting $RANDOM mint a second one on every re-run.
EXISTING_SA=$(az storage account list --resource-group "$TFSTATE_RG" --query "[0].name" -o tsv 2>/dev/null || true)
if [ -n "$EXISTING_SA" ]; then
  TFSTATE_SA_NAME="$EXISTING_SA"
  echo "Reusing existing state storage account: $TFSTATE_SA_NAME"
fi

### ---- 1b. Idempotency helpers (safe to re-run this script) ----------------
LAST_ROLE_NEW=false
ensure_role() { # usage: ensure_role <assignee> <role> <scope>
  local existing
  existing=$(az role assignment list --assignee "$1" --role "$2" --scope "$3" --query "[0].id" -o tsv)
  if [ -n "$existing" ]; then
    echo "Role '$2' already assigned at $3 - skipping"
    LAST_ROLE_NEW=false
  else
    az role assignment create --assignee "$1" --role "$2" --scope "$3" >/dev/null
    LAST_ROLE_NEW=true
  fi
}

ensure_fed_cred() { # usage: ensure_fed_cred <credential-name> <subject>
  local existing
  existing=$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='$1'].name | [0]" -o tsv)
  if [ -n "$existing" ]; then
    echo "Federated credential '$1' already exists - skipping"
  else
    az ad app federated-credential create --id "$APP_ID" --parameters "{
      \"name\": \"$1\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$2\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" >/dev/null
  fi
}

### ---- 2. Register resource providers Terraform will need ----------------
# Only what's needed for this baseline; add more as your modules grow.
for ns in Microsoft.Storage Microsoft.Authorization Microsoft.PolicyInsights \
          Microsoft.Consumption Microsoft.Insights Microsoft.Security \
          Microsoft.ManagedIdentity; do
  az provider register --namespace "$ns" --wait
done

### ---- 3. Remote state backend: resource group + storage account ---------
az group create \
  --name "$TFSTATE_RG" \
  --location "$LOCATION"

if az storage account show --name "$TFSTATE_SA_NAME" --resource-group "$TFSTATE_RG" >/dev/null 2>&1; then
  echo "Storage account $TFSTATE_SA_NAME already exists - skipping create"
else
  az storage account create \
    --name "$TFSTATE_SA_NAME" \
    --resource-group "$TFSTATE_RG" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --https-only true
fi

# Versioning + soft delete on the state container — protects you from a
# bad `apply` or an accidental `terraform state rm`.
az storage account blob-service-properties update \
  --account-name "$TFSTATE_SA_NAME" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30

# Shared-key access is disabled above, so even you need an RBAC *data* role
# to touch the state container (Owner/Contributor carry no data-plane
# access). Grant it to the signed-in user, then wait for propagation.
SA_ID=$(az storage account show --name "$TFSTATE_SA_NAME" --resource-group "$TFSTATE_RG" --query id -o tsv)
ensure_role "$(az ad signed-in-user show --query id -o tsv)" "Storage Blob Data Contributor" "$SA_ID"
if $LAST_ROLE_NEW; then
  echo "Waiting 60s for RBAC propagation..."
  sleep 60
fi

az storage container create \
  --name "$TFSTATE_CONTAINER" \
  --account-name "$TFSTATE_SA_NAME" \
  --auth-mode login

# One blob per environment inside this single container — core.tfstate,
# staging.tfstate, production.tfstate. No extra storage account needed:
# blob storage's 5 GB always-free allowance covers all three comfortably.
# Terraform creates the blobs themselves on first `init`; nothing to do
# here beyond having the container exist. The rg-staging and
# rg-production resource groups are likewise Terraform-managed (created
# by terraform/envs/*/main.tf on first apply, with subscription-wide
# Contributor from step 5 below) — not created here, to keep the "only
# the unblocking minimum happens via az CLI" rule intact.

### ---- 4. App registration + service principal for Terraform -------------
# Entra display names are NOT unique, so a bare `az ad app create` would add
# a duplicate "terraform_auth" on every re-run. Look first; refuse to guess
# if duplicates already exist.
APP_COUNT=$(az ad app list --filter "displayName eq '$SP_NAME'" --query "length(@)" -o tsv)
if [ "$APP_COUNT" -gt 1 ]; then
  echo "ERROR: $APP_COUNT app registrations named '$SP_NAME' exist. Delete the duplicates first." >&2
  exit 1
fi
APP_ID=$(az ad app list --filter "displayName eq '$SP_NAME'" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$SP_NAME" --query appId -o tsv)
else
  echo "App registration '$SP_NAME' already exists - reusing"
fi

OBJECT_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)
if [ -z "$OBJECT_ID" ]; then
  az ad sp create --id "$APP_ID" >/dev/null
  OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
else
  echo "Service principal already exists - reusing"
fi

echo "terraform_auth appId:    $APP_ID"
echo "terraform_auth objectId: $OBJECT_ID"

### ---- 5. Minimal RBAC so Terraform can bootstrap the rest ---------------
# Contributor at subscription scope — deliberately broad for initial
# bootstrap (see README "Notes on least privilege" for tightening this
# later). Do NOT grant Owner/User Access Administrator unless your
# Terraform code also needs to manage RBAC role assignments broadly.
ensure_role "$APP_ID" "Contributor" "/subscriptions/$SUBSCRIPTION_ID"

# Storage Blob Data Contributor on the state account specifically —
# needed for the azurerm backend to read/write state blobs.
ensure_role "$APP_ID" "Storage Blob Data Contributor" "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$TFSTATE_RG/providers/Microsoft.Storage/storageAccounts/$TFSTATE_SA_NAME"

# Resource Policy Contributor: lets terraform_auth manage Azure Policy
# assignments. Contributor deliberately excludes Microsoft.Authorization
# writes, so without this the core/ apply fails in CI (it only worked
# locally because you are Owner).
ensure_role "$APP_ID" "Resource Policy Contributor" "/subscriptions/$SUBSCRIPTION_ID"

# Custom role limited to management locks, assigned below to the state
# resource group only. Avoids User Access Administrator, which would let
# terraform_auth grant itself Owner.
if [ -z "$(az role definition list --name "Terraform Lock Manager" --query "[0].name" -o tsv)" ]; then
  LOCK_ROLE_FILE=$(mktemp)
  cat > "$LOCK_ROLE_FILE" <<JSON
{
  "Name": "Terraform Lock Manager",
  "Description": "Read, create and delete management locks only.",
  "Actions": [
    "Microsoft.Authorization/locks/read",
    "Microsoft.Authorization/locks/write",
    "Microsoft.Authorization/locks/delete"
  ],
  "NotActions": [],
  "AssignableScopes": ["/subscriptions/$SUBSCRIPTION_ID"]
}
JSON
  az role definition create --role-definition "@$LOCK_ROLE_FILE"
  rm -f "$LOCK_ROLE_FILE"
  echo "Waiting 30s for role definition propagation..."
  sleep 30
else
  echo "Custom role 'Terraform Lock Manager' already exists - skipping"
fi
ensure_role "$APP_ID" "Terraform Lock Manager" "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$TFSTATE_RG"

### ---- 6. Federated credentials for GitHub Actions OIDC -------------------
# No client secret is ever created or stored. Each credential below
# trusts GitHub's OIDC token only for one specific branch or one
# specific GitHub *environment* — never a bare "any PR" subject — so a
# token minted for one promotion stage can't be replayed to apply a
# different, more sensitive one. See README "Hardening notes & GitOps
# flow" for the full reasoning behind each scope.

# -- Branch-scoped credentials: used by `apply` jobs on push (merge) --
# Merging into main applies terraform/core AND terraform/envs/production.
ensure_fed_cred "github-actions-branch-${PRODUCTION_BRANCH}" "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/${PRODUCTION_BRANCH}"

# Merging into staging applies terraform/envs/staging only.
ensure_fed_cred "github-actions-branch-${STAGING_BRANCH}" "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/${STAGING_BRANCH}"

# -- Environment-scoped credentials: used by `plan-*` jobs on PR -------
# Each requires a "Required reviewers" rule on its matching GitHub
# Environment (Settings -> Environments, created automatically the
# first time a workflow references it, or create them up front) before
# GitHub will mint a token for it — so a live plan against real state
# only ever runs after a human approves, regardless of which branch the
# PR came from or what its workflow file says.
#
# PRs opened against staging (feature/* -> staging):
ensure_fed_cred "github-actions-plan-preview-staging" "repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:plan-preview-staging"

# PRs opened against main (staging -> main promotion) — give this
# environment a stricter reviewer rule than plan-preview-staging, since
# it previews a change about to reach production.
ensure_fed_cred "github-actions-plan-preview-production" "repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:plan-preview-production"

### ---- 7. Output values for GitHub Actions secrets ------------------------
cat <<EOF

============================================================
Bootstrap complete. Add these as GitHub Actions repo secrets:

  ARM_CLIENT_ID             = $APP_ID
  ARM_TENANT_ID             = $TENANT_ID
  ARM_SUBSCRIPTION_ID       = $SUBSCRIPTION_ID
  TERRAFORM_AUTH_OBJECT_ID  = $OBJECT_ID
  BUDGET_ALERT_EMAILS       = <comma-separated list as JSON array, e.g. ["you@example.com"]>

Fill in storage_account_name = "$TFSTATE_SA_NAME" in all three of:
  terraform/core/backend.tf
  terraform/envs/staging/backend.tf       (also set it in providers.tf's remote_state block)
  terraform/envs/production/backend.tf    (also set it in providers.tf's remote_state block)

Then, once the repo exists on GitHub:
  1. Create the 'staging' branch from 'main'.
  2. Branch protection: require PR + review on BOTH 'main' and 'staging'
     before merge (Settings -> Branches).
  3. Create GitHub Environments 'plan-preview-staging',
     'plan-preview-production', 'staging', and 'production'. Add a
     required-reviewer rule to all four (stricter/more reviewers on the
     two 'production' ones).
============================================================
EOF
