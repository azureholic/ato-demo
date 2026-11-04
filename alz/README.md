# ALZ Terraform SMB bootstrap

Single-region Azure Landing Zones configuration based on the official
[SMB hub-and-spoke example](https://github.com/Azure/alz-terraform-accelerator/blob/v17.6.0/templates/platform_landing_zone/examples/smb-single-region/hub-and-spoke-vnet.tfvars).

## Configuration

- Region: Belgium Central (`belgiumcentral`), including bootstrap resources.
- Hub VNet: `10.100.0.0/16`, Azure Firewall Basic and matching Basic policy.
- Management resources: Log Analytics, AMA managed identity and data collection rules.
- ALZ management group hierarchy and policies are retained.
- Shared management/connectivity subscription: `6ffc8ff2-3d6f-4a9b-b2f9-3263eedb728c`.
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
An empty parent management group selects the authenticated tenant root. Change
it before bootstrap to deploy below a different existing parent.

Pinned versions: ALZ PowerShell 7.1.5, bootstrap modules v7.3.2, Terraform starter
v17.6.0, accelerator-managed Terraform 1.14.9. Review upgrades deliberately.

## Local workflow

Use PowerShell 7 with Azure CLI, Git and Terraform installed. If missing, install
the PowerShell dependencies once:

```powershell
Install-Module ALZ -RequiredVersion 7.1.5 -Scope CurrentUser -Repository PSGallery
Install-Module powershell-yaml -Scope CurrentUser -Repository PSGallery
```

Prepare resolved configuration only (no Azure login or Azure changes):

```powershell
.\alz\scripts\Initialize-Alz.ps1 -SecurityContactEmail 'security@your-company.example'
```

When ready, explicitly authorize bootstrap:

```powershell
az login
az account set --subscription 6ffc8ff2-3d6f-4a9b-b2f9-3263eedb728c
.\alz\scripts\Initialize-Alz.ps1 -SecurityContactEmail 'security@your-company.example' -Bootstrap
```

Bootstrap creates Azure state storage, deployment identities, management group/
RBAC prerequisites, and writes the Terraform starter to `alz\output\local-output`.
It does **not** apply the landing zone Terraform. The caller must have the
permissions needed to create management groups, custom roles/role assignments
under the configured parent, and bootstrap resources in the subscription.

Keep the entire `alz\output` directory securely backed up. Bootstrap has local
Terraform state there; the generated landing zone is configured to use Azure
Storage state after bootstrap. Do not lose bootstrap state, run from a fresh
output path against the same resources, or commit state/plan files. Keep the same
output path and version pins for reruns, and do not manually edit generated files.

Before deploying the generated landing zone, check Belgium Central service/SKU
availability and subscription quotas, then initialize the configured backend,
run `terraform validate`, review `terraform plan`, and explicitly approve apply.
Review the generated deployment script before using it: it can apply resources.

## GitHub Actions

[alz-bootstrap.yml](../.github/workflows/alz-bootstrap.yml) is a manually dispatched
**bootstrap-only** workflow. It uses a dedicated **self-hosted Windows x64**
runner with label `alz`, PowerShell 7 and the dependencies above. A GitHub-hosted
ephemeral runner would lose the local bootstrap state, so it is intentionally
not used. Restrict this runner to a trusted/private repository; do not run
untrusted pull requests on it.

Create a GitHub environment named `alz-bootstrap`, with required reviewers, and
these environment variables:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | Client ID of an existing authorized bootstrap identity |
| `AZURE_TENANT_ID` | Tenant containing the subscription |
| `ALZ_SECURITY_CONTACT_EMAIL` | Real security contact mailbox |
| `ALZ_OUTPUT_PATH` | Persistent absolute path on the runner, e.g. `F:\alz-state\smb` |

The output path must be outside the checkout and runner temporary directory.
The generated landing zone will be in `<ALZ_OUTPUT_PATH>\local-output`.
For local and CI runs managing the same bootstrap, use the **same output path
on the same runner machine**, back it up, and never run them concurrently.

Provision the workflow identity and its permissions out of band before the first
run. Configure an Entra federated credential with issuer
`https://token.actions.githubusercontent.com`, audience
`api://AzureADTokenExchange`, and subject
`repo:OWNER/REPOSITORY:environment:alz-bootstrap`. No client secret is needed.
This bootstrap identity is separate from the deployment identities created by
the accelerator; do not assume those identities already authorize this workflow.

Push these files to a GitHub repository, select **Bootstrap ALZ Terraform SMB**
under Actions, and enter `BOOTSTRAP`. The environment approval gates Azure
changes. State and plans are not uploaded as workflow artifacts.
