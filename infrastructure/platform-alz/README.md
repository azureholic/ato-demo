# SMB platform landing zone - Bicep Accelerator

The [platform workflow](../../.github/workflows/alz-deploy.yml) runs on a public
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
7. After the official ALZ deployment succeeds, sign in to Azure CLI again with
   a fresh OIDC assertion and provision shared platform DNS. This avoids relying
   on the CLI login from before a potentially long stack deployment.
8. Add the dedicated agent/private-runner firewall rule collection from
   [workload-egress.json](config/workload-egress.json) using
   [workload-egress.bicep](config/workload-egress.bicep). Existing policy collections
   are not replaced.

The official script deploys **Azure deployment stacks**. Azure stores their
management metadata; no external state backend is involved. With
`create_bootstrap_resources_in_azure: false`, the Accelerator's internal Terraform
step only generates local files and uses disposable local state on the runner.
It does not create identities, role grants, storage or move subscriptions during
bootstrap. Existing private bootstrap storage and its state are left untouched.

## Version-controlled configuration

[private-dns.json](config/private-dns.json) owns the central DNS subscription,
`rg-dns` resource-group name, location, zone inventory and VNet discovery
subscriptions. The platform workflow runs
[Invoke-PlatformDns.ps1](Invoke-PlatformDns.ps1) after successful ALZ deployment
to create the group, shared zones and links to discovered VNets except those in
`excludedVirtualNetworkIds`, without a Private Resolver or autoregistration.
Included VNets must use Azure-provided DNS; custom DNS stops the stage before
changes. Exclusion prevents new links but does not remove existing ones.

[private-dns.bicep](config/private-dns.bicep) provisions zones and invokes the
reusable [link-only module](config/private-dns-links.bicep). This incremental DNS
stage belongs to the platform workflow but remains outside the ALZ deployment
stacks: keep `deployPrivateDnsZones: false` in the upstream hub parameters to
avoid duplicate ownership. Existing zones, DNS records and unrelated links are
preserved; no deletion or resource move is needed for this handover.

The [GovHub workflow](../../.github/workflows/ai-governance-hub-deploy.yml) consumes
the same platform DNS configuration, requires existing zones and creates only
its spoke's links and private-endpoint DNS associations. Both workflows use the
same link names, so platform redeployment does not create duplicate links.
Other new VNets receive links on the next platform DNS run. GovHub preparation
also adds cross-subscription peerings to the existing hub; it does not modify
its subnets or firewall routing. See the
[GovHub networking guidance](../ai-governance-hub/README.md#provider-readiness-and-network-preparation)
for permissions, execution order and migration cautions.

The [agent scenario](../ai-agent/README.md) and
[reusable private runner](../github-runner/README.md) also consume this inventory.
Additional Search, App Configuration, ACR, region-specific Container Apps and
private-monitoring zones remain centrally owned. Their spoke preparation only
links existing zones. All workloads sharing the private-monitoring DNS network
reuse one AMPLS rather than creating competing scopes.

For an existing platform, run the separately approved
[workload connectivity workflow](../../.github/workflows/platform-workload-connectivity.yml)
to add these zones and scoped egress rules without rerunning the full Accelerator.
The firewall source CIDRs and package/control-plane allow-list are version-controlled
in [workload-egress.json](config/workload-egress.json). New spokes use Azure-provided
DNS and a default route to the hub firewall; peering does not make spoke connectivity
transitive, so the private runner has explicit direct workload peerings.

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
settings. VPN, ExpressRoute, Bastion, upstream-managed private DNS/resolver and a
paid DDoS Network Protection plan are disabled; central zones are provisioned by
the separate platform DNS stage. The corresponding policy and cross-management-group
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
v2.4.0, powershell-yaml 0.4.12, Az.Accounts 5.5.4,
Az.Resources 10.2.2, and generation-only Terraform 1.14.9. Bicep CLI is not pinned; the workflow installs the latest. Change the Terraform
version in both workflow and bootstrap inputs together.

## GitHub setup and deployment cautions

The deployment identity needs permissions to create `rg-dns` and zones in the
platform subscription, create VNet links, and read/join VNets in every
`virtualNetworkSubscriptionIds` subscription. The workflow does not grant
itself these permissions. Shared DNS configuration now belongs entirely to
the platform; do not change deployed resource-ID casing during migration.

For a local platform deployment, run `Invoke-PlatformAlz.ps1` first, then from the repository root:

```powershell
.\infrastructure\platform-alz\Invoke-PlatformDns.ps1 -OutputPath "$env:TEMP\platform-dns"
```

Use `-ValidateOnly` on the DNS adapter for offline compilation without Azure
reads or writes. Run the platform workflow before GovHub for a new environment.

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

## Jumpbox with Bastion Developer

[The jumpbox workflow](../../.github/workflows/platform-jumpbox.yml) adds a small VM for reaching
private services from inside the platform network, for example the Governance Hub APIM gateway and
the Agent Landing Zone Foundry project. It is separate from the ALZ deployment: it neither
changes nor is overwritten by the Accelerator, because the Accelerator's VNet module also writes
subnets as child resources.

| Piece | Details (config in [jumpbox.json](config/jumpbox.json)) |
| --- | --- |
| Subnet | `snet-jumpbox` `10.100.1.0/27` in the hub VNet `vnet-hub-swe`, with an NSG (SSH only from the VNet) and the Accelerator's `rt-hub-std-swe` route table (default route via the hub firewall). No default outbound access. |
| VM | `vm-jumpbox-swe`, Ubuntu 24.04 LTS, `Standard_B2s_v2`, Trusted Launch, no public IP, SSH key only (no password). Tools installed at first boot: `curl`, `jq`, `dnsutils`, Python 3, Azure CLI. |
| Bastion | **Developer SKU**: free, no `AzureBastionSubnet` or public IP, one connection at a time, portal only, and **only VMs in its own VNet**, so the VM is in the hub VNet, not a spoke. Available in Sweden Central. |
| Egress | Dedicated firewall rule group `platform-jumpbox` (priority 320): Entra sign-in, Azure Resource Manager, Microsoft/Ubuntu package feeds and PyPI only. |
| Private access | The hub VNet is peered directly with the GovHub, agent and runner spokes and linked to the shared private DNS zones, so `*.azure-api.net` and `*.services.ai.azure.com` resolve to private endpoints. |

Set the GitHub `demo` environment **variable** `JUMPBOX_SSH_PUBLIC_KEY` to a single-line `ssh-ed25519` or
`ssh-rsa` public key (it is not a secret), then run the workflow. It deploys the firewall rules,
the subnet, NSG, VM and Bastion, then runs `hub-check` inside the VM through an Azure run command and
fails unless every endpoint in `connectivityTargets` resolves to a private address and answers over HTTPS.

Connect: Azure portal > `vm-jumpbox-swe` > **Connect** > **Connect via Bastion**, choose SSH with
**Local file** and select the private key that matches the public key. On the VM:

```bash
hub-check                       # resolution and HTTPS reachability of the private endpoints
az login --use-device-code      # allowed through the firewall
```

Add more endpoints under `connectivityTargets`. The endpoint names are generated by the Hub and
Foundry deployments, so update them if those resources are recreated. Anyone with the private key
can reach the VM; keep it off shared machines. This is a development convenience, not a production
access pattern (Bastion Developer is not for production workloads).

## Local use and tests

With PowerShell 7.4+, Azure CLI, Bicep CLI on `PATH`, the pinned modules, and
matching authenticated **Azure CLI and Az PowerShell** contexts, run from the repository root:

```powershell
Import-Module ALZ -RequiredVersion 7.1.5
.\infrastructure\platform-alz\Invoke-PlatformAlz.ps1 -OutputPath "$env:TEMP\platform-alz-new-run"
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
.\infrastructure\platform-alz\tests\Test-PlatformAlz.ps1
```

The previous custom Bicep orchestration remains in [alz](../alz) as a legacy
reference only. GitHub Actions now uses the official Accelerator local flow.
