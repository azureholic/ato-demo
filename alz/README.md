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
configuration but does **not** prove all write permissions. Run the local bootstrap
below before the first preview: it creates the empty management-group hierarchy,
so read authorization for subscription placement does not depend on a prior
platform deployment. What-if remains read-only and uses the same provider
validation level before and after the first deployment. Nested resources can
still be short-circuited by ARM when expressions cannot be evaluated.
Inspect all warnings; a successful preview is not an apply or a guarantee that
every policy/resource will deploy.

## GitHub Actions

### Local permission and hierarchy bootstrap

Run this once using your personal Azure CLI login, not the deployment service
principal. Your user needs permission to manage custom role definitions and
role assignments on the existing `alz` management group, plus permission to create
child management groups:

```powershell
az login --tenant 6e689817-26c3-498a-a758-a45e53e81733
az account set --subscription 6ffc8ff2-3d6f-4a9b-b2f9-3263eedb728c
.\alz\scripts\Initialize-AlzBootstrap.ps1 -WhatIf
.\alz\scripts\Initialize-AlzBootstrap.ps1
```

The script validates the user, tenant, subscription, existing management group
and deployment identity from [demo.json](config/demo.json). It creates and assigns
`ALZ Role Definition Writer (alz)` **only on `alz`**, with the single action
`Microsoft.Authorization/roleDefinitions/write`. Existing roles already provide
read access. Incremental deployments need create/update, not role-definition
deletion; no delete, wildcard, data-plane or role-assignment actions are added.
An existing custom role must match these exact permissions and scope, or the
script stops for review.

After verifying the persisted custom-role assignment, the script removes the
deployment identity's direct Owner assignments on `alz`, including the previous
bootstrap grant. It verifies the final state and can be safely rerun. Unrelated
assignments and parent scopes are not modified; inherited Owner access, if any,
produces a warning and requires separate review. The existing conditional RBAC
Administrator assignment retains its restrictions.

Custom-role write access is still privileged: it can change permissions in custom
roles. This is the minimal additional action for the current templates, not a
claim that the pre-existing tenant-root deployment roles are least privilege.
It does not grant Owner, change OIDC credentials, alter Terraform bootstrap
resources, or deploy platform workloads.
The normal [Initialize-Alz.ps1](scripts/Initialize-Alz.ps1) build remains
read-only with respect to Azure; GitHub does not run this local bootstrap.
Allow time for RBAC propagation after a new assignment.

The same command compiles the Bicep parameters and creates the empty management
groups declared by the governance deployment stages, in parent-before-child
order. It uses those compiled configurations as the source of truth, rather than
a separate hierarchy list. Existing groups must already have the expected parent;
bootstrap never reparents them or recreates the existing `alz` root. `-WhatIf`
builds locally and previews both permission and management-group changes without
writing to Azure. A rerun verifies existing groups and creates only missing ones.

Bootstrap does **not** move the subscription or deploy policies, logging,
networking, or other workloads. It is an explicit Azure-changing prerequisite,
not part of what-if. After bootstrap, dispatch the GitHub workflow to preview the
platform before any platform deployment. Review all what-if output and warnings,
then approve the pending `deploy` job only when ready for the platform changes
and their charges. Reject the deployment if the preview is not acceptable.

Test the local bootstrap without Azure changes:

```powershell
.\alz\tests\Test-InitializeAlzBootstrap.ps1
```

[alz-deploy.yml](../.github/workflows/alz-deploy.yml) uses a public GitHub-hosted
`windows-latest` runner and Entra OIDC. It runs only by manual dispatch on `main`.
Each run has two jobs: `whatif` previews the changes, then `deploy` waits for
approval on the `demo` environment. Both jobs use `demo`, so its required-reviewer
gate also applies before what-if runs. Deployment is skipped if what-if fails.
There is no operation selector or typed confirmation at dispatch; environment
approval authorizes deployment. Pushing code does not start this workflow.

Use the `demo` environment for both preview and deployment. Configure these
variables on `demo`:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | `4c598517-f198-46b6-a166-931ca6012b52` |
| `AZURE_TENANT_ID` | `6e689817-26c3-498a-a758-a45e53e81733` |
| `AZURE_SUBSCRIPTION_ID` | `6ffc8ff2-3d6f-4a9b-b2f9-3263eedb728c` |

The existing federated credential uses issuer
`https://token.actions.githubusercontent.com`, audience
`api://AzureADTokenExchange`, and immutable subject
`repo:azureholic@7915366/ato-demo@1445961666:environment:demo`.
Both jobs use this existing `demo` credential unchanged. No additional federated
credential or client secret is needed.
The service principal's existing Contributor and
RBAC Administrator assignments at the tenant root management group, plus
Resource Policy Contributor on `alz`, are retained. These roles do not grant
`Microsoft.Authorization/roleDefinitions/write`, which the ALZ custom roles
require. The local permission bootstrap above adds only that missing action on
the intermediate root. Role-definition deletion is not needed by these
incremental deployments. Owner is not required for this
configuration. Retain the existing resource/RBAC permissions on the shared
subscription for stages executed before its move under `alz`. No directory
administrator role or storage data-plane role is needed by this Bicep workflow.
Verify Belgium Central service/SKU availability and quota before authorizing deploy.

Before dispatching, configure **required reviewers** on `demo` in repository
Settings > Environments, restrict deployment branches to `main`, and disable
administrator bypass. Enable prevention of self-review if approval must come
from another person. Approve the `whatif` job to allow preview to run, then review
its output before approving `deploy`. Required reviewers must be supported by the repository's
GitHub plan/visibility; the workflow fails closed if it cannot verify a nonempty
reviewer rule on `demo`. These environment settings must be configured outside
the workflow YAML.
Review the `whatif` job logs before approving the pending deployment.
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
