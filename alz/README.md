# ALZ Terraform SMB bootstrap

Single-region Azure Landing Zones configuration based on the official
[SMB hub-and-spoke example](https://github.com/Azure/alz-terraform-accelerator/blob/v17.6.0/templates/platform_landing_zone/examples/smb-single-region/hub-and-spoke-vnet.tfvars).

## Configuration

- Region: Belgium Central (`belgiumcentral`), including bootstrap resources.
- Hub VNet: `10.100.0.0/16`, Azure Firewall Basic and matching Basic policy.
- Management resources: Log Analytics, AMA managed identity and data collection rules.
- ALZ management group hierarchy and policies are retained.
- Environment: `demo` (GitHub environment, bootstrap resource naming and tags).
- Shared management/connectivity subscription: supplied through
  `AZURE_SUBSCRIPTION_ID` in the GitHub `demo` environment and resolved into
  the generated deployment configuration in `platform`.
  It is placed **once**, under `platform`; the dedicated management/connectivity/
  identity/security groups remain available for future subscriptions. Policies
  assigned only to those child groups do not apply to the shared subscription.
- VPN, ExpressRoute, Bastion, private DNS/resolver and a paid DDoS Network
  Protection plan are disabled. Revisit DNS when adding private endpoints.
- Paid Defender for Cloud policy settings from the SMB example are retained.
  Firewall, logging and Defender can incur charges. This is not a free baseline.
- Network DDoS Protection is not enabled. Evaluate DDoS IP Protection for exposed
  public IPs, subject to resource/SKU support.

Edit [inputs.yaml](config/inputs.yaml) and
[platform-landing-zone.tfvars](config/platform-landing-zone.tfvars) as needed.
An empty parent management group selects the explicitly supplied tenant root. Change
it before bootstrap to deploy below a different existing parent.

Pinned versions: ALZ PowerShell 7.1.5, bootstrap modules v7.3.2, Terraform starter
v17.6.0, accelerator-managed Terraform 1.14.9. Review upgrades deliberately.

## Local workflow

Use PowerShell 7. The bootstrap script installs missing `powershell-yaml` and
ALZ 7.1.5 modules for the current user, registering PSGallery if absent.
On Windows it installs missing Azure CLI/Git through WinGet; installer elevation
may still be required. The accelerator downloads Terraform 1.14.9 and its HCL
parser into the persistent output folder when needed. Azure authentication
cannot be automated without an already-authorized session.

Load the subscription and tenant settings from the GitHub `demo` environment.
GitHub CLI authentication is required; Azure login is not needed to prepare files:

```powershell
$settings = gh variable list --repo azureholic/ato-demo --env demo --json name,value | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not load GitHub environment variables.' }
$env:ARM_SUBSCRIPTION_ID = ($settings | Where-Object name -eq 'AZURE_SUBSCRIPTION_ID').value
$env:ARM_TENANT_ID = ($settings | Where-Object name -eq 'AZURE_TENANT_ID').value
```

Prepare resolved configuration only (no Azure changes):

```powershell
.\alz\scripts\Initialize-Alz.ps1 -SecurityContactEmail 'security@your-company.example'
```

For this demo, with Azure CLI already authenticated to the target subscription,
this **single command** installs missing dependencies and automatically approves
the entire bootstrap (not the landing-zone deployment):

```powershell
.\alz\scripts\Initialize-Alz.ps1 -SecurityContactEmail 'remcobrosky@microsoft.com' -SubscriptionId '6ffc8ff2-3d6f-4a9b-b2f9-3263eedb728c' -TenantId '6e689817-26c3-498a-a758-a45e53e81733' -OutputPath 'D:\alz-bootstrap\ato-demo\alz\state' -Bootstrap
```

Bootstrap creates Azure state storage, deployment identities, management group/
RBAC prerequisites, and writes the Terraform starter to
`D:\alz-bootstrap\ato-demo\alz\state\local-output`.
It does **not** apply the landing zone Terraform. The caller must have the
permissions needed to create management groups, custom roles/role assignments
under the configured parent, and bootstrap resources in the subscription.

Alternatively pass `-SubscriptionId` and `-TenantId` directly to the script.
Both must be non-empty GUIDs; bootstrap also checks the Azure CLI subscription
and tenant before making changes. The single supplied subscription is used for
bootstrap, management and connectivity, with only one management group placement.

Keep the entire persistent bootstrap output folder securely backed up. Bootstrap
has local Terraform state there; platform deployment uses a separate Azure
Storage backend. Do not lose bootstrap state, run from a fresh output path against
the same resources, or commit state/plan files. Keep the same output path and
version pins for reruns. Edit the reviewed deployment source in [platform](platform),
not the bootstrap-managed copy in `local-output`.

The generated root Terraform files, resolved `.tfvars`/JSON configuration,
`lib` and `modules` have been copied into [platform](platform).
The upstream MIT license is retained there. Do not copy the entire bootstrap
output into Git: exclude `.tools`, bootstrap state, plans, logs, caches, generated
local deployment scripts and credentials. Identifiers and the security contact
in the committed configuration are not secrets. Review configuration for secrets
before copying it again. Commit the provider dependency lock file.

Before deploying the generated landing zone, check Belgium Central service/SKU
availability and subscription quotas, then initialize the configured backend,
run `terraform validate`, review `terraform plan`, and explicitly approve apply.
Review the generated deployment script before using it: it can apply resources.

## GitHub Actions

[alz-deploy.yml](../.github/workflows/alz-deploy.yml) deploys the committed platform
Terraform source using a **GitHub-hosted `windows-latest` runner**, Terraform
1.14.9 and OIDC. No self-hosted runner or local bootstrap state is needed in CI.
The previous bootstrap workflow has been removed.

Use the GitHub environment named `demo` and configure required reviewers where
your GitHub plan supports them. These environment variables are configured:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | `4c598517-f198-46b6-a166-931ca6012b52` (`GitHub-ATO-Demos`) |
| `AZURE_SUBSCRIPTION_ID` | Shared bootstrap/management/connectivity subscription |
| `AZURE_TENANT_ID` | Tenant containing the subscription |
| `TF_STATE_RESOURCE_GROUP` | `rg-alz-demo-state-belgiumcentral-001` |
| `TF_STATE_STORAGE_ACCOUNT` | `stoalzdembel001jfwn` |
| `TF_STATE_CONTAINER` | `demo-tfstate` |

The backend key is `terraform.tfstate`. The security contact is already resolved
into the committed configuration; CI does not need `ALZ_SECURITY_CONTACT_EMAIL`
or `ALZ_OUTPUT_PATH`.

The service principal retains its existing Contributor and Role Based Access
Control Administrator assignments at the tenant root management group.
Resource Policy Contributor is assigned on management group `alz`, and Storage
Blob Data Contributor on the state container. This supplies policy-management
and backend data access without adding another tenant-root assignment.
The Entra federated credential `github-azureholic-ato-demo-demo` uses issuer
`https://token.actions.githubusercontent.com`, audience
`api://AzureADTokenExchange`, and subject
`repo:azureholic@7915366/ato-demo@1445961666:environment:demo`. This repository
uses GitHub's immutable OIDC subject format; check it with
`gh api repos/azureholic/ato-demo/actions/oidc/customization/sub` before
reconfiguring federation. No client secret is needed.
This existing service principal is used for CI instead of the separate plan/apply
managed identities created by local bootstrap.

State storage has public network access disabled by default. For each run the
workflow temporarily enables the endpoint with a default-deny firewall and
allows only the current runner IPv4 address. Blob access still requires Entra
authentication; anonymous access and shared keys are disabled. An `always()`
cleanup step disables public access before removing the runner rule. A forcibly
terminated runner or failed cleanup requires an administrator to disable public
access immediately. Workflow concurrency and Terraform state locking prevent
overlapping runs; do not run a local deployment concurrently.

If Azure still returns `publicNetworkAccess=Disabled` after the enable request,
the workflow fails before Terraform. Investigate the storage account's network
configuration and applicable Azure restrictions; do not remove the firewall or
enable anonymous/shared-key access to work around it.

Under Actions, select **Deploy ALZ Platform**, run from `main`, and choose
`plan` (the default) for a read-only Terraform plan. Review the result, region/SKU
availability and costs before choosing `apply` and typing `APPLY` to authorize
deployment. Apply creates a fresh plan and applies that exact saved plan in the
same job; it does not reuse a previous plan run. Environment reviewers, if
configured, approve the job before it starts. State and plans are not committed
or uploaded as workflow artifacts.
