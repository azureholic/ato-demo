# SMB platform landing zone - Bicep Accelerator

The [single workflow](../.github/workflows/alz-deploy.yml) runs on a public
GitHub-hosted Windows runner. **No state storage account, public state-storage
endpoint, Blob state access or remote Terraform state is required.**

1. Wait for approval on the existing `demo` GitHub environment.
2. Install ALZ PowerShell, powershell-yaml, Az PowerShell and Bicep CLI.
   Terraform is installed only for the Accelerator's local file-generation step.
3. Sign in with the existing Entra OIDC application, enabling both Azure CLI
   and Az PowerShell sessions.
4. Run `Deploy-Accelerator` with `iac_type: bicep` and repository configuration.
5. Compile the SMB parameters before any platform deployment, checking ARM's
   4 MB template/parameter limit.
6. Run the generated, **unmodified** `scripts/deploy-local.ps1`. The adapter
   supplies `yes` to its standard-input confirmation after GitHub approval.
   The Bicep script has no Terraform-style `auto_approve` parameter.

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

Pinned versions: ALZ PowerShell 7.1.5, bootstrap modules v7.3.2, Bicep starter
v2.4.0, Bicep CLI v0.44.1, powershell-yaml 0.4.12, Az.Accounts 5.5.4,
Az.Resources 10.2.2, and generation-only Terraform 1.14.9. Change the Terraform
version in both workflow and bootstrap inputs together.

## GitHub setup and deployment cautions

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

The deployment identity needs ALZ management-group, policy, custom-role,
role-assignment, subscription and **deployment-stack** permissions. The old
Bicep identity grants do not prove that stack operations and deployment-history
deletion are allowed. Review conditional RBAC permissions and pre-existing roles;
this workflow does not grant itself permissions. No storage data-plane role is
needed. Verify Sweden Central SKU availability and quotas before approval.

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

Run the orchestration tests without Azure access or resource changes:

```powershell
.\platform-alz\tests\Test-PlatformAlz.ps1
```

The previous custom Bicep orchestration remains in [alz](../alz) as a legacy
reference only. GitHub Actions now uses the official Accelerator local flow.
