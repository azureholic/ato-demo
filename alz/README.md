# ALZ Bicep SMB landing zone

This Azure-only platform landing zone uses the official
[Azure/alz-bicep-accelerator v2.4.0](https://github.com/Azure/alz-bicep-accelerator/tree/v2.4.0)
templates and their version-pinned Azure Verified Modules. The upstream templates
and policy library are retained in [bicep/upstream](bicep/upstream), with the MIT
license. Demo configuration lives in [demo.json](config/demo.json).

## Baseline

- One region: Belgium Central (`belgiumcentral`).
- One shared management/connectivity subscription, placed **once** in `platform`.
  The management, connectivity, identity and security groups remain available for
  future dedicated subscriptions. Policies assigned only to those child groups
  do not apply to the shared subscription.
- Hub VNet `10.100.0.0/16`, Azure Firewall Basic and matching Basic firewall policy.
- Log Analytics (30-day retention), AMA identity and monitoring collection rules.
- ALZ management group hierarchy, custom policies, policy initiatives and RBAC.
- VPN, ExpressRoute, Bastion, private DNS/resolver and a paid DDoS Network
  Protection plan are disabled. The DDoS policies on connectivity/landing zones
  and private DNS deployment policy on corp are excluded accordingly.
- Paid Defender for Cloud settings from the previous SMB configuration remain
  enabled. Firewall, logging and Defender can incur charges.
- The Bicep release supplies its own ALZ policy catalog. Migration is not a
  byte-for-byte translation of the Terraform catalog; review what-if carefully.

The existing `alz` intermediate root is referenced, not recreated or reparented.
The ordered deployment stages are logging, hub networking, and one governance
deployment per management group. Logging and networking are subscription
deployments; governance targets management group `alz`. Each template is checked
against ARM's 4 MB size limit. ARM incremental deployments manage the platform without Terraform state,
deployment stacks or a storage backend.

## Local preparation and validation

Use PowerShell 7 on Windows x64. One command installs Azure CLI through WinGet if
missing, downloads Bicep CLI v0.44.1 into an ignored local tool cache, verifies its
pinned SHA-256 digest, restores the pinned public AVM modules and builds the
templates/parameters. It does not replace the machine's shared Bicep executable:

```powershell
.\alz\scripts\Initialize-Alz.ps1
```

This command makes **no Azure resource changes**. It uses the configured demo
tenant/subscription unless supplied through `ARM_TENANT_ID`/`ARM_SUBSCRIPTION_ID`
or explicit parameters; mismatched targets are rejected. Build output goes to
the ignored `alz\output\bicep` directory, or `-OutputPath`.
No ALZ PowerShell module, YAML module or Terraform installation is needed.
CLI installation can require elevation. Public internet access to Microsoft
Container Registry is needed to restore AVM modules.

Run the local build/configuration tests:

```powershell
.\alz\tests\Test-InitializeAlz.ps1
```

For an authenticated, read-only Azure preview, first select the configured tenant
and subscription, then run:

```powershell
.\alz\scripts\Invoke-AlzDeployment.ps1 -Operation WhatIf
```

The deployment order is declared in [deployments.json](bicep/deployments.json).
The script checks Azure CLI context before any deployment operation and stops at
the first failed stage. What-if uses `ProviderNoRbac`: it validates resource
configuration but does **not** prove all write permissions. First-deployment
what-if can short-circuit nested templates targeting management groups that do
not yet exist; inspect all warnings. A successful preview is not an apply or a
guarantee that every policy/resource will deploy.

## GitHub Actions

[alz-deploy.yml](../.github/workflows/alz-deploy.yml) uses a public GitHub-hosted
`windows-latest` runner and Entra OIDC. It runs only by manual dispatch on `main`.
The default operation is `what-if`. Actual deployment requires choosing `deploy`
and entering the exact confirmation `DEPLOY`. Neither pushing code nor running
what-if deploys the platform.

The GitHub `demo` environment needs only:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | `4c598517-f198-46b6-a166-931ca6012b52` |
| `AZURE_TENANT_ID` | `6e689817-26c3-498a-a758-a45e53e81733` |
| `AZURE_SUBSCRIPTION_ID` | `6ffc8ff2-3d6f-4a9b-b2f9-3263eedb728c` |

The existing federated credential uses issuer
`https://token.actions.githubusercontent.com`, audience
`api://AzureADTokenExchange`, and immutable subject
`repo:azureholic@7915366/ato-demo@1445961666:environment:demo`.
No client secret is needed. The service principal's existing Contributor and
RBAC Administrator assignments at the tenant root management group, plus
Resource Policy Contributor on `alz`, are retained. Verify deployment permissions
and Belgium Central service/SKU availability and quota before authorizing deploy.

Configure required environment reviewers where the GitHub plan supports them.
Concurrency serializes workflow runs; do not run a local deployment concurrently.
Deployment is incremental and multi-stage, not transactional: a later failure can
leave earlier stages deployed. Review changes and rerun deliberately.

There are no storage firewall changes, temporary IP rules, state containers,
backend keys or Terraform commands in this workflow. The legacy `TF_STATE_*`
environment variables are unused and can be removed separately.

## Preserved Terraform bootstrap

The old generated `platform` folder and Terraform configuration were removed.
The existing Azure bootstrap resources, role assignments and deployment
identities have **not** been deleted. In particular, state storage remains closed
to public network access and is not used by Bicep.

The original bootstrap state remains outside this repository at
`D:\alz-bootstrap\ato-demo\alz\state`. Keep that entire directory securely backed
up. Do not delete it, rerun bootstrap in a fresh folder, destroy the bootstrap
stack, or import/redeploy bootstrap-owned resources into Bicep. Existing resource
cleanup is a separate, explicitly authorized operation.
