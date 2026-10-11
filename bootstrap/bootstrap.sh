#!/usr/bin/env bash
#
# bootstrap.sh
# One-time, minimal az CLI setup to unblock Terraform on a brand-new
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
GITHUB_ORG="your-github-org-or-username"
GITHUB_REPO="your-repo-name"
PRODUCTION_BRANCH="main"                            # merges here apply terraform/core + terraform/envs/production
STAGING_BRANCH="staging"                            # merges here apply terraform/envs/staging

### ---- 1. Login + subscription context -----------------------------------
az login
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
az account set --subscription "$SUBSCRIPTION_ID"

echo "Subscription: $SUBSCRIPTION_ID"
echo "Tenant:       $TENANT_ID"

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

az storage account create \
  --name "$TFSTATE_SA_NAME" \
  --resource-group "$TFSTATE_RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --https-only true

# Versioning + soft delete on the state container — protects you from a
# bad `apply` or an accidental `terraform state rm`.
az storage account blob-service-properties update \
  --account-name "$TFSTATE_SA_NAME" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30

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
APP_ID=$(az ad app create --display-name "$SP_NAME" --query appId -o tsv)
az ad sp create --id "$APP_ID"
OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

echo "terraform_auth appId:    $APP_ID"
echo "terraform_auth objectId: $OBJECT_ID"

### ---- 5. Minimal RBAC so Terraform can bootstrap the rest ---------------
# Contributor at subscription scope — deliberately broad for initial
# bootstrap (see README "Notes on least privilege" for tightening this
# later). Do NOT grant Owner/User Access Administrator unless your
# Terraform code also needs to manage RBAC role assignments broadly.
az role assignment create \
  --assignee "$APP_ID" \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

# Storage Blob Data Contributor on the state account specifically —
# needed for the azurerm backend to read/write state blobs.
az role assignment create \
  --assignee "$APP_ID" \
  --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$TFSTATE_RG/providers/Microsoft.Storage/storageAccounts/$TFSTATE_SA_NAME"

### ---- 6. Federated credentials for GitHub Actions OIDC -------------------
# No client secret is ever created or stored. Each credential below
# trusts GitHub's OIDC token only for one specific branch or one
# specific GitHub *environment* — never a bare "any PR" subject — so a
# token minted for one promotion stage can't be replayed to apply a
# different, more sensitive one. See README "Hardening notes & GitOps
# flow" for the full reasoning behind each scope.

# -- Branch-scoped credentials: used by `apply` jobs on push (merge) --
# Merging into main applies terraform/core AND terraform/envs/production.
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "{
    \"name\": \"github-actions-branch-${PRODUCTION_BRANCH}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/${PRODUCTION_BRANCH}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

# Merging into staging applies terraform/envs/staging only.
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "{
    \"name\": \"github-actions-branch-${STAGING_BRANCH}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/${STAGING_BRANCH}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

# -- Environment-scoped credentials: used by `plan-*` jobs on PR -------
# Each requires a "Required reviewers" rule on its matching GitHub
# Environment (Settings -> Environments, created automatically the
# first time a workflow references it, or create them up front) before
# GitHub will mint a token for it — so a live plan against real state
# only ever runs after a human approves, regardless of which branch the
# PR came from or what its workflow file says.
#
# PRs opened against staging (feature/* -> staging):
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "{
    \"name\": \"github-actions-plan-preview-staging\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:plan-preview-staging\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

# PRs opened against main (staging -> main promotion) — give this
# environment a stricter reviewer rule than plan-preview-staging, since
# it previews a change about to reach production.
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters "{
    \"name\": \"github-actions-plan-preview-production\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:plan-preview-production\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

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
