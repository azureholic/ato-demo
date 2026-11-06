# SMB platform landing zone - Bicep Accelerator

The [single workflow](../.github/workflows/alz-deploy.yml) runs on a public
GitHub-hosted Windows runner. **No state storage account, public state-storage
endpoint, Blob state access or remote Terraform state is required.**

1. Wait for approval on the existing `demo` GitHub environment.
2. Install ALZ PowerShell, powershell-yaml, Az PowerShell and Bicep CLI.
   Terraform is installed only for the Accelerator's local file-generation step.
   Each pinned PowerShell module install gets up to five attempts against
   PSGallery, waiting 10, 20, 40 and 80 seconds between failures. Only the failed
   module is retried; exhausted retries fail the workflow with the module name,
   version and underlying error.
3. Sign in with the existing Entra OIDC application, enabling both Azure CLI
   and Az PowerShell sessions.
4. Run `Deploy-Accelerator` with `iac_type: bicep` and repository configuration.
5. Compile the SMB parameters before any platform deployment, checking ARM's
   4 MB template/parameter limit.
6. Run the generated `scripts/deploy-local.ps1` entry point unchanged. The adapter
   supplies `yes` to its standard-input confirmation after GitHub approval.
   The Bicep script has no Terraform-style `auto_approve` parameter.
   In GitHub Actions, `-RefreshGitHubOidc` adds an authentication call to the
   generated `scripts/bicep-deploy.ps1` retry loop. Every stage attempt, including
   retries, obtains a new GitHub assertion and signs in to Az PowerShell again.

The official script deploys **Azure deployment stacks**. Azure stores their
management metadata; no external state backend is involved. With
`create_bootstrap_resources_in_azure: false`, the Accelerator's internal Terraform
step only generates local files and uses disposable local state on the runner.
It does not create identities, role grants, storage or move subscriptions during
bootstrap. Existing private bootstrap storage and its state are left untouched.

## Version-controlled configuration

- [inputs.yaml](config/inputs.yaml): based on the official Bicep local bootstrap
  example; Azure bootstrap resource creation is disabled.
- [platform-landing-zone.yaml](config/platform-landing-zone.yaml): based on the
  official Bicep platform example, selecting one region and hub networking.
- [templates](config/templates): SMB parameter overrides copied through the
  Accelerator's supported `starter_additional_files` option. Only parameters
  and their shared settings are retained here, not vendored upstream templates.
- [smb.json](config/templates/smb.json): Sweden Central, shared subscription,
  existing `alz` root, security contact, hub range and tags.
- [Invoke-PlatformAlz.ps1](Invoke-PlatformAlz.ps1): validates matching configuration,
  generates the platform, builds parameters and invokes the official local script.
  It passes the generated platform directory through `TF_VAR_target_directory`,
  the bootstrap module's supported environment override, and restores the
  caller's previous value afterward. `ALZ_target_directory` is not recognized
  for this bootstrap variable.
- [Connect-GitHubOidc.ps1](Connect-GitHubOidc.ps1): requests a fresh GitHub OIDC
  assertion for `api://AzureADTokenExchange` and renews the process-scoped
  Az PowerShell login. Tokens are masked in Actions logs; no client secret or
  longer token lifetime is required.

The Bicep release provides a general platform example, **not** the Terraform
release's dedicated SMB tfvars example. These Bicep parameters retain the demo's
SMB choices: **Sweden Central (`swedencentral`)**, Firewall Basic, one
`10.100.0.0/16` hub, 30-day Log Analytics retention, AMA/DCRs and paid Defender
settings. VPN, ExpressRoute, Bastion, private DNS/resolver and a paid DDoS Network
Protection plan are disabled. The corresponding policy and cross-management-group
RBAC exclusions are kept consistent. Review these cost/protection trade-offs.

The shared subscription is placed **once**, under `platform`, not both management
and connectivity. Policies assigned only to those child groups do not cover the
shared subscription. The existing `alz` root is referenced, not recreated or
reparented. `root_parent_management_group_id` remains the tenant root ID.

Resource groups and platform resources have **no numeric `-001` suffix**:
for example, `rg-management-swe`, `rg-hub-swe` and
`law-management-swe`. The `resource_names` overrides in
[inputs.yaml](config/inputs.yaml) also omit the numeric postfix token from
bootstrap names; the Accelerator's internal numeric default is not used by
these explicit name templates. A random suffix is retained only for the dormant
bootstrap storage-account name's global uniqueness. Azure bootstrap remains
disabled, so these overrides do not create storage or rename existing bootstrap
resources.

All region-bearing names use the same short-location rule as the pinned
[Accelerator naming module](https://github.com/Azure/accelerator-bootstrap-modules/blob/v7.3.2/modules/resource_names/locals.tf):
`azure_location_short = substr(azure_location, 0, 3)`. Sweden Central therefore
becomes `swe`. This is a simple string abbreviation, not an official or globally
unique region code; for example, Sweden South would also become `swe`.
Actual Azure location properties remain `swedencentral`.

Most names use parameter overrides. The upstream hub template hardcodes two
route-table names and the firewall-policy name without a naming parameter;
the adapter changes only those three name expressions after generation and
before compilation. Each must match exactly once or the run stops for review.
The deployment entry point is not modified. With `-RefreshGitHubOidc`, the
adapter locates exactly one retry loop and its top-level result initialization
in the pinned stack helper using the PowerShell parser, then inserts authentication
before that initialization and outside the helper's retry catch. An unexpected
upstream structure stops the run before deployment. Stack names, scope, retry
limits, deployment-history cleanup, `DeleteAll` and deny settings remain unchanged.
Changing existing Azure resource names
can create replacement resources; review stack ownership and `DeleteAll`
behavior before deploying this naming change.

Pinned versions: ALZ PowerShell 7.1.5, bootstrap modules v7.3.2, Bicep starter
v2.4.0, Bicep CLI v0.44.1, powershell-yaml 0.4.12, Az.Accounts 5.5.4,
Az.Resources 10.2.2, and generation-only Terraform 1.14.9. Change the Terraform
version in both workflow and bootstrap inputs together.

## GitHub setup and deployment cautions

### First-deployment prerequisites

Establish the management-group hierarchy declared in the governance parameters
before the first full policy deployment. ARM validates nested deployment
permissions against their target scopes before creating resources. A missing
target group can therefore produce `Microsoft.Resources/deployments/write`
authorization errors even for an administrator. Create missing groups under
their configured parents rather than granting broader roles to work around
this error. The official governance stacks can subsequently manage those groups.
Allow the new hierarchy and inherited RBAC permissions to propagate, then
validate the governance templates before restarting the full deployment.

Deploy the pinned `templates/core/logging/main.bicep` with this repository's
logging parameters as the subscription stack **`core-logging`** before running
policies that reference its workspace. Use the same `DeleteAll` and `None` stack
settings as the official deployment, and review any existing stack first.
The pinned deployment order puts logging after governance; a failed governance
stage prevents the workspace from being created. Meanwhile, existing Defender
export and subscription diagnostic policies can evaluate and fail because
`law-management-swe` does not exist. After logging succeeds, retry failed policy
remediations; deploying the workspace alone does not rerun failed remediations.

These are initial provisioning prerequisites, not additional workflow permission
grants. Subsequent runs reuse the same hierarchy and logging stack without
changing the official script's deployment order or stack ownership.

### GitHub environment

Configure only these variables on the existing `demo` environment:

| Variable | Meaning |
| --- | --- |
| `AZURE_CLIENT_ID` | Existing deployment application's client ID |
| `AZURE_TENANT_ID` | Tenant matching repository configuration |
| `AZURE_SUBSCRIPTION_ID` | Shared subscription matching repository configuration |

`TF_STATE_*` variables are neither required nor used. Keep the existing `demo`
OIDC federated credential. Configure required reviewers, restrict deployments to
`main`, and disable administrator bypass. The workflow rejects non-main runs and
verifies a nonempty reviewer rule. One approval authorizes generation and the
subsequent deployment; there is no separate what-if approval gate.

Service-principal OIDC logins use a short-lived GitHub assertion. The initial
`azure/login` session alone cannot reliably authenticate an entire multi-hour
deployment. The workflow enables per-attempt renewal in the deployment process,
not a separate timer or background login process. If a long-running Az command
outlives its assertion/access token and fails authentication, the next existing
deployment retry signs in with a fresh assertion rather than reusing the expired
credential. Authentication-renewal failures stop immediately instead of consuming
the deployment retry budget. GitHub token requests have bounded HTTP retries.
This does not resolve genuine Azure deployment or subscription-move errors.

The deployment identity needs ALZ management-group, policy, custom-role,
role-assignment, subscription and **deployment-stack** permissions. The old
Bicep identity grants do not prove that stack operations and deployment-history
deletion are allowed. Review conditional RBAC permissions and pre-existing roles;
this workflow does not grant itself permissions. No storage data-plane role is
needed. Verify Sweden Central SKU availability and quotas before approval.

Subscription placement specifically requires
`Microsoft.Authorization/roleAssignments/write` and
`Microsoft.Authorization/roleAssignments/delete` on the subscription or an
ancestor. Conditional role-assignment grants can fail this authorization check.
For this demo, the deployment identity has unconditional **Role Based Access
Control Administrator** on the shared subscription, alongside its existing
management-group permissions. This allows managing all role assignments,
including Owner, within that subscription only; tenant-wide conditional grants
remain unchanged. Provision this grant administratively, outside the workflow.

**Important upstream behavior:** the pinned official deployment script uses
`ActionOnUnmanage = DeleteAll` and `DenySettingsMode = None`. Removing resources
from an existing stack's template can delete them. It also deletes deployment
history records at the target scope before deployment. Review existing stack
ownership and configuration before first use; do not run it blindly against an
estate managed by another stack/tool. Moving from previous incremental Bicep
deployments is a stack-ownership change, not a Terraform import operation.
Public runner access to Azure management APIs and public module/package registries
is still necessary; a public storage data endpoint is not.

The old bootstrap state at `D:\alz-bootstrap\ato-demo\alz\state` remains separate.
Back it up and leave it and its Azure resources alone. Do not rerun its
Azure-resource bootstrap in a fresh directory or destroy it.

Firewall, logging and Defender can incur charges. Deployment is multi-stage and
not transactional. Resolve partial failures before rerunning, and do not deploy
locally at the same time as GitHub Actions.

## Local use and tests

With PowerShell 7.4+, Azure CLI, Bicep CLI on `PATH`, the pinned modules, and
matching authenticated **Azure CLI and Az PowerShell** contexts:

```powershell
Import-Module ALZ -RequiredVersion 7.1.5
.\platform-alz\Invoke-PlatformAlz.ps1 -OutputPath "$env:TEMP\platform-alz-new-run"
```

Set `ARM_CLIENT_ID`, `ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID` to the matching
deployment identity/environment. The command **deploys without another prompt**;
use a fresh output directory. GitHub configures OIDC automatically; local
interactive logins can be used without `ARM_USE_OIDC`.
Local runs omit `-RefreshGitHubOidc` and leave the generated stack helper
unchanged. That switch requires GitHub's `ACTIONS_ID_TOKEN_REQUEST_URL` and
`ACTIONS_ID_TOKEN_REQUEST_TOKEN`, provided to the workflow with `id-token: write`.

Run the orchestration tests without Azure access or resource changes:

```powershell
.\platform-alz\tests\Test-PlatformAlz.ps1
```

The previous custom Bicep orchestration remains in [alz](../alz) as a legacy
reference only. GitHub Actions now uses the official Accelerator local flow.
