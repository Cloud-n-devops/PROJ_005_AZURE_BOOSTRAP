# azure-tf-bootstrap

Repeatable, minimal-`az`-CLI bootstrap for a brand-new Azure subscription,
followed by a Terraform-managed baseline covering the configurations that
should exist in **almost every** production Azure subscription:

- Remote Terraform state (storage account + container, versioned, private)
- A dedicated CI/CD identity (`terraform_auth`) authenticated via
  **GitHub OIDC federation** — no long-lived client secrets
- Least-privilege RBAC for that identity
- Governance baseline (Azure Policy assignments, resource locks, tagging)
- Cost governance (subscription budget + action-group alerts)
- Observability baseline (Activity Log → Log Analytics, Microsoft Defender
  for Cloud)

## Philosophy

`az` CLI is used **only** for the handful of things that must exist before
Terraform can authenticate and run (a chicken-and-egg problem: Terraform
needs an identity + a place to store state before it can manage anything,
including that identity). Everything else — budgets, policy, monitoring,
RBAC — is Terraform-managed so it is version-controlled, reviewable, and
reproducible across subscriptions/environments.

```
bootstrap/bootstrap.sh   → one-time, az CLI, creates the minimum to unblock Terraform
terraform/               → everything else, managed as code
```

## GitOps flow: feature → staging → production

```
feature/*  --PR-->  staging  --PR-->  main
   |                   |                |
   |            plan-preview-staging    plan-preview-production
   |            (reviewer-gated)        (stricter reviewer-gated)
   |                   |                |
   |              merge = apply-staging merge = apply-production
   |              (terraform/envs/staging)   (terraform/core AND
   |                                           terraform/envs/production)
```

- **Feature work** happens on `feature/*` branches, PR'd into `staging`.
  The PR triggers `lint` (no credentials) then `plan-preview-staging`
  (live plan, gated behind a required reviewer on that GitHub
  Environment). Merging `staging` applies **only**
  `terraform/envs/staging` — core and production are untouched.
- **Promotion** happens by opening a PR from `staging` into `main` once
  staging has been validated. This triggers `plan-preview-production`
  (a *stricter* reviewer gate — it's a preview of what's about to reach
  production) against both `terraform/core` and
  `terraform/envs/production`. Merging applies both, core first.
- `terraform/core` has no staging equivalent — it's the one real
  subscription's landing zone (policy, budget, identity, monitoring),
  not a per-environment construct, so it only ever changes via the
  `main` path.

Each root module (`core`, `envs/staging`, `envs/production`) has its own
state blob in the **same** storage account/container created by
`bootstrap.sh` (`core.tfstate`, `staging.tfstate`, `production.tfstate`)
— fully isolated from each other, zero extra cost.

## Usage

1. Read and run `bootstrap/bootstrap.sh` (interactively — review each step,
   don't blindly pipe it). It prints the values you need to add as GitHub
   Actions repository secrets, and the branch/environment setup steps
   below.
2. Add those values as GitHub Actions secrets.
3. Create the `staging` branch from `main`; add branch protection
   (require PR + review before merge) to both `main` and `staging`.
4. Create GitHub Environments `plan-preview-staging`,
   `plan-preview-production`, `staging`, and `production`; add a
   required-reviewer rule to each (strictest on the two `production`
   ones).
5. Fill in `storage_account_name` in `terraform/core/backend.tf`,
   `terraform/envs/staging/{backend.tf,providers.tf}`, and
   `terraform/envs/production/{backend.tf,providers.tf}` with the value
   `bootstrap.sh` printed.
6. For a first local run: `cd terraform/core && terraform init && terraform plan`
   (then the same for `terraform/envs/staging` and
   `terraform/envs/production`). In practice, let the GitHub Actions
   pipeline do this via the PR flow above instead of applying locally.

## GitHub Actions OIDC (no secrets, no rotation)

Once `bootstrap.sh` has created the federated credential, your workflow
authenticates like this — note there is no `client-secret`:

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: azure/login@v2
    with:
      client-id: ${{ secrets.ARM_CLIENT_ID }}
      tenant-id: ${{ secrets.ARM_TENANT_ID }}
      subscription-id: ${{ secrets.ARM_SUBSCRIPTION_ID }}
```

## Repo layout

```
.
├── bootstrap/
│   └── bootstrap.sh              # minimal az CLI, run once per subscription
├── scripts/
│   ├── teardown.sh                # destroy envs/staging + envs/production (keeps core)
│   ├── bring-up.sh                # redeploy them
│   └── teardown-everything.sh     # full reset, including core + the bootstrap identity
├── .github/workflows/terraform.yml   # lint / plan-staging / apply-staging / plan-production / apply-production
└── terraform/
    ├── core/                     # the ONE subscription landing zone — no staging equivalent
    │   ├── backend.tf            # state key: core.tfstate
    │   ├── providers.tf
    │   ├── variables.tf
    │   ├── main.tf                # wires identity/governance/budget/monitoring modules
    │   └── outputs.tf             # log_analytics_workspace_id, action_group_id — read by envs/*
    ├── envs/
    │   ├── staging/
    │   │   ├── backend.tf        # state key: staging.tfstate
    │   │   ├── providers.tf      # includes a terraform_remote_state read of core.tfstate
    │   │   ├── variables.tf
    │   │   ├── main.tf           # rg-staging + per-env budget; workloads added below the line
    │   │   └── outputs.tf
    │   └── production/           # identical shape to staging/ — same shared modules, own state
    └── modules/
        ├── identity/             # RBAC + federated credential management (day-2)
        ├── governance/           # Azure Policy assignments, resource locks, tags
        ├── budget/                # subscription- OR resource-group-scoped budget + alerts
        └── monitoring/            # Activity Log diagnostic settings, Defender for Cloud (core only)
```

## Hardening notes: OIDC trust and PR-triggered credentials

A federated credential scoped to a bare `pull_request` event
(`repo:org/repo:pull_request`) is a common pattern in examples online, but
it's worth understanding exactly what it trusts before using it on a
public repo:

- **Fork PRs are already safe by default.** GitHub does not issue OIDC
  tokens to workflows triggered by `pull_request` from a forked
  repository, regardless of the `id-token: write` permission declared —
  this is enforced by GitHub itself, not something this repo configures.
  The obvious "stranger forks the repo, opens a PR, steals the token"
  attack doesn't work.
- **Same-repo branch PRs are the real residual risk.** For the
  `pull_request` trigger, the workflow file is read from the *PR's
  branch*, not from `main`. Anyone who can push a branch to this repo —
  today just the owner, but this changes the moment collaborators are
  added — could open a PR from a branch with an edited workflow file and
  get a live, Contributor-scoped token before any review happens, if the
  job requesting `id-token: write` has no approval gate in front of it.

This repo's workflow addresses that with one credential-less job plus a
pair of environment-gated ones **per promotion stage**:

1. **`lint`** — runs on every PR unconditionally, requests no Azure
   credentials at all (`terraform fmt`, `validate -backend=false`,
   `tfsec`). Zero blast radius regardless of what the workflow file says,
   because it never requests `id-token: write`.
2. **`plan-preview-staging`** — live `terraform plan` against
   `envs/staging` for PRs targeting `staging`, gated by a required
   reviewer on the `plan-preview-staging` GitHub Environment.
3. **`plan-preview-production`** — live `terraform plan` against `core`
   and `envs/production` for PRs targeting `main`, gated by a *stricter*
   required-reviewer rule on `plan-preview-production` — this one is a
   preview of a change about to reach production, so it deserves more
   scrutiny than the staging preview.

Each `plan-preview-*` federated credential's subject is scoped to its
own GitHub environment name, never to the bare `pull_request` event —
GitHub will not mint the OIDC token for that job until a human approves
the run, closing the gap even for a maliciously edited workflow file on
a same-repo branch, independent of which promotion stage it targets.

The `apply-staging` and `apply-production` jobs follow the same
environment-gated pattern on push (`environment: staging` /
`environment: production`), combined with their credentials' subjects
being scoped to `ref:refs/heads/staging` / `ref:refs/heads/main`
respectively, plus ordinary branch protection (require PR + review
before merge) on both branches.

## Tearing down and bringing back up

Three scripts in `scripts/`, for three different situations:

| Script | Destroys | When to use |
|---|---|---|
| `scripts/teardown.sh` | `envs/staging` + `envs/production` only | Pausing work — your normal "I'm done for today/this week" command |
| `scripts/bring-up.sh` | (creates, not destroys) | Resuming — redeploys whatever `teardown.sh` tore down |
| `scripts/teardown-everything.sh` | Everything, including `core/` and the bootstrap-created identity + state storage | Abandoning the project entirely, or a genuine from-scratch reset |

```bash
az login                          # once per local session; falls back to this automatically
./scripts/teardown.sh             # tears down both staging and production
./scripts/teardown.sh staging     # or just one
./scripts/bring-up.sh             # redeploys both, whenever you're ready again
```

**Why `core/` is deliberately excluded from the everyday command:** it
costs effectively $0 whether running or not (see table below), and
destroying it means destroying `terraform_auth`'s own federated
credentials and RBAC — recreating it gets you a *new* app ID, which
breaks every GitHub Actions secret until you update them. Tearing down
`envs/*` removes everything that could actually cost money (VMs, AKS
nodes, databases — once a project adds them) while leaving the
reusable plumbing intact.

If you only did `az login` and nothing else, both scripts fall back to
your own Azure CLI session automatically (see the auth comment in each
`providers.tf`) — no extra setup needed beyond the login itself.

## Staying at $0

Every resource in this baseline was chosen to sit inside an always-free
allowance (verified against current Azure pricing docs, since these
terms shift):

| Resource | Free allowance used | Notes |
|---|---|---|
| Storage account (tfstate) | Blob Storage: 5 GB free (Microsoft's own pages disagree on whether this is "always" or "first 12 months" — treat it as the latter to be safe) | Even at full list price (~$0.02/GB/month LRS Hot), a KB-sized `.tfstate` file costs a fraction of a cent/month either way |
| Log Analytics workspace | Activity Log/platform metric ingestion: **always free, unmetered**; Analytics Logs: 5 GB/month free | `daily_quota_gb` caps ingestion at 0.2 GB/day as a hard stop, protecting you if a future module (e.g. Container Insights) sends real volume |
| Log Analytics retention | 31 days free | Set to 30 in this repo, inside the window |
| Microsoft Defender for Cloud | `tier = "Free"` explicitly | The paid "Standard" plans are what generate charges — this repo pins `Free` |
| Consumption budget + alerts | Free (a management feature, not a billed resource) | Default **$1** on all three: `core` (subscription-wide), `envs/staging` and `envs/production` (resource-group-scoped) — each a separate tripwire |
| Azure Policy assignments | Policy evaluation is always free | |
| Management locks | Free | |
| Entra ID app registration / service principal / role assignments | Free (Entra ID Free tier: 50,000 objects) | |
| GitHub Actions | Free (public repo: unlimited; private: 2,000 min/month) | |

**Important caveat: a budget is an alert, not a spend cap.** Azure removed
the hard "spending limit" feature for new Pay-As-You-Go subscriptions —
once you exceed free allowances, charges accrue and you get notified,
you're not automatically cut off. If your subscription is still on the
free-trial $200/30-day credit, that credit acts as a soft ceiling; after
that, this budget module is your only automated guardrail, so treat the
low `$1` default as a tripwire to check in on, not a hard stop.

**Biggest future risk isn't this baseline — it's what you deploy next.**
Nothing in this repo provisions a VM, AKS cluster, or App Service; those
are the resources that actually cost money. When you get there:
- VMs: only the `B1S` burstable size is free (12 months, 750 hrs/month, one instance's worth) — anything else bills immediately.
- AKS: the control plane (Free tier) costs nothing, but every worker node is a billed VM — there's no free node pool.
- Always tag learning resources and set a resource group-scoped budget alongside the subscription one so you can see cost per project.

## Notes on least privilege

`bootstrap.sh` grants `terraform_auth` **Contributor** at the subscription
scope so it can bootstrap everything in this repo. Once your baseline is
stable, consider tightening this to a custom role scoped to only the
resource types you actually manage, and/or splitting identities per
environment (`terraform_auth_dev`, `terraform_auth_prod`) with
environment-scoped federated credential `subject` claims.
