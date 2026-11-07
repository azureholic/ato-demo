# AI governance hub

This folder adopts the MIT-licensed
[AI Hub Gateway Solution Accelerator (Citadel)](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator)
without vendoring its infrastructure, policies or application code.

The [manual workflow](../.github/workflows/ai-governance-hub-deploy.yml) uses the
existing `demo` approval environment and OIDC application, just like the ALZ
workflow. It clones a **pinned upstream commit into runner temporary storage**,
copies our configuration into the checkout, compiles the networking and GovHub
templates, checks the compact ARM request against the 4 MB limit, then
registers providers, prepares networking/DNS and runs upstream `azd provision`
followed by the scoped storage waiver and `azd deploy`. The latter publishes the usage ingestion Logic App;
infrastructure-only deployment would leave it unpublished.
No Terraform or external deployment state storage is needed.

## Configuration

- [deployment.json](config/deployment.json): subscription, primary region,
  environment/resource-group name, upstream revision, APIM sizing, network
  ranges, regional Foundry instances, shared model deployment settings and platform
  hub references.
- [private-dns.json](../platform-alz/config/private-dns.json): platform-owned
  central DNS subscription, resource group and zone inventory. GovHub consumes
  this shared file; it does not keep a duplicate DNS configuration.
- [main.bicepparam](config/main.bicepparam): small scenario overlay for the
  upstream entry point. Its `using './main.bicep'` reference resolves **after
  copying it into the upstream checkout**, not inside this repository.
- [Invoke-AiGovernanceHub.ps1](Invoke-AiGovernanceHub.ps1): clone, overlay,
  compile, prepare networking/DNS and optionally invoke upstream deployment commands.
- [Register-ResourceProviders.ps1](Register-ResourceProviders.ps1): idempotently
  request missing provider registrations and wait up to 15 minutes for readiness.
- [Set-LogicAppStorageExemption.ps1](Set-LogicAppStorageExemption.ps1): create or
  verify the runtime storage waiver, restore key access and restart the Logic App
  when the waiver or account changes.
- [spoke.bicep](networking/spoke.bicep) and [peering.bicep](networking/peering.bicep):
  small integration templates reusing the pinned upstream VNet module.
- [private-dns-links.bicep](../platform-alz/config/private-dns-links.bicep):
  link-only template referencing existing platform zones.

Initial scenario:

| Setting | Value |
| --- | --- |
| Primary region | Italy North |
| APIM | StandardV2, one unit |
| Network | `10.170.0.0/24` Italy spoke, peered both ways with platform `vnet-hub-swe` |
| Network resource group | `rg-ai-governance-network-ita` |
| GovHub resource group | `rg-ai-governance-ita` |
| Private DNS | Central `rg-dns` in the platform subscription; no Private Resolver |
| Monitoring | Dedicated Log Analytics workspace |
| Foundry backends | Poland Central (primary) and Sweden Central |
| Shared model | `gpt-6-astra`, version `2026-09-03` |
| Model SKU/capacity | GlobalStandard, 10 units **per region** |
| Optional extras | Redis, AI Search, Document Intelligence, API Center, realtime and dashboards disabled |

Both deployments share one model definition. The parameter overlay adds explicit
`aiserviceIndex: 0` and `1`: the pinned upstream deployment uses these indices
to populate each backend's `supportedModels`. Omitting them can create models
without making them routable through APIM.

Upstream automatically creates one model pool with two managed-identity
backends, equal priority and weight. Use the same gateway URL and model name
for both regions; clients do not choose a regional URL. For stateless chat:

```text
POST https://<APIM-gateway>/openai/deployments/gpt-6-astra/chat/completions?api-version=2025-04-01-preview
Ocp-Apim-Subscription-Key: <authorized subscription key>
```

Provisioning the hub does **not** onboard consumer access contracts. Follow the
[upstream access-contract guide](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/main/bicep/infra/citadel-access-contracts)
to authorize consumers before testing calls. Do not assume that deploying two
regional backends provides seamless failover for stateful Responses/Assistants
sessions. GlobalStandard does not guarantee EU-only inference processing.

## Provider readiness and network preparation

The failed deployment reported:

- `MissingSubscriptionRegistration` for `Microsoft.AlertsManagement`.
- `SubnetSubscriptionMustBeRegisteredWithMicrosoftWeb` for StandardV2 subnet
  integration. `Microsoft.Web` was registered by the time of investigation,
  but registration was not ready when APIM tried to integrate.
- App Service/Logic App hosting capacity exhaustion in Sweden. Provider
  registration does not resolve regional capacity exhaustion.

The workflow explicitly checks the two observed providers before a full
deployment. Already-registered providers are skipped; providers already
registering are waited on without duplicate requests. Unregistering providers,
CLI failures and timeouts stop the run. Other template providers remain
subject to ARM's normal registration requirements.

Network preparation creates the Italy spoke in its own resource group using
the unchanged upstream VNet module, preserving APIM/Logic App delegations,
NSGs and service endpoints. Its DNS-zone list is empty, so it creates no local
zones or links. Both peerings enable VNet access and forwarded traffic, but no
gateway transit or remote gateway. Peering does not force egress through the
Sweden firewall; firewall routing is not changed here.

The **ALZ platform workflow** provisions `rg-dns`, the 11 shared zones and links
to all VNets discovered in the subscriptions listed in the platform DNS
configuration. GovHub checks that the group and every configured zone already
exist **before creating its spoke or deploying services**; otherwise it fails
with instructions to deploy the platform first. It never creates the DNS
resource group or zones.

After spoke deployment, GovHub adds links only for its own VNet to those
existing zones, using the same deterministic link names as the platform.
Autoregistration remains disabled. No resolver is deployed, and the spoke must
use Azure-provided DNS; custom DNS stops the run. Other new VNets receive links
on the next platform DNS deployment, not continuously.

GovHub uses the supported `useExistingVnet` mode and explicit central zone
resource IDs. Private endpoints remain workload resources; their zone groups
manage records in the shared zones. The platform zone template is incremental
and does not delete existing records or unrelated links. Do not also enable ALZ's
zone creation for the same zone names in a different resource group.

Keep central zone resource-ID casing stable after deployment. Changing
`rg-DNS` to `rg-dns` can trigger
`UpdatingPrivateDnsZoneIdOnPrivateDnsZoneConfigNotAllowed` on existing private
endpoint zone groups. Deleting the DNS resource group does not remove those
workload-side associations. Such a migration requires explicitly approved
recreation of the affected zone groups, preserving the private endpoints and
verifying their DNS records afterward; DNS can be interrupted during repair.

The pinned upstream main/resource templates do not list Italy North in their
location allow-lists. The adapter adds only `italynorth` to those two
annotations **on the runner**, requiring the exact pinned source structure.
Unexpected source changes fail before deployment. API Center remains disabled
with its location override blank. Policies, application code, deployment entry
points, subnet module and `azure.yaml` remain unchanged.
The official [APIM v2 region table](https://learn.microsoft.com/azure/api-management/api-management-region-availability)
lists Italy North for StandardV2, but does not list Poland Central. This is why
the core moved to Italy rather than Poland; the model backends remain in Poland
and Sweden. Availability listings are not a reservation or guarantee of live
regional capacity.

The adapter also corrects the two pinned APIM Event Hubs logger expressions on
the runner. Namespace `serviceBusEndpoint` values are URLs such as
`https://<namespace>.servicebus.windows.net:443/`; managed-identity loggers
require only `<namespace>.servicebus.windows.net`. The upstream expressions
remove the scheme but leave the port/path, which APIM rejects. The adapter
extracts the hostname for both usage and PII loggers, preserving the namespace's
Azure-cloud suffix and leaving managed identity credentials and RBAC unchanged.
Each original expression must match exactly once or the run stops for review
before deployment. This is not a DNS, peering or provider-registration workaround.

The pinned legacy OpenAI API definition also has an invalid schema on the
`GET /deployments/{deployment-id}` path parameter: an empty `type` and an enum
containing only an empty string. The adapter corrects that one schema to
`type: string` without the enum, on the runner only. It preserves the operation
ID, other API definitions and OpenAPI version. The original parameter and
invalid schema must match exactly or deployment stops for upstream review.
See [TODO.md](TODO.md) for the upstream contribution details.

## Runtime storage policy waiver

The inherited `MCAPSGovDeployPolicies` initiative modifies storage accounts to
disable shared-key access. This conflicts with the accelerator's key-based
runtime storage connections. [Workflow Service Plan hosting still requires
storage account key access](https://learn.microsoft.com/azure/logic-apps/create-single-tenant-workflows-azure-portal#set-up-managed-identity-access-to-your-storage-account),
even when other runtime connections use managed identity. This is a tenant
policy compatibility issue, not another upstream template defect.

The adapter runs the waiver script **after `azd provision`, before `azd deploy`**,
when the account exists but the Logic App package has not yet been uploaded.
It resolves the account from the pinned upstream `storage` deployment output,
not a hardcoded generated resource name. The exemption is a child of that
single account and exempts only `StorageAccountDisableLocalAuth` within the
assignment configured in `deployment.json`. It does not exempt the resource
group, subscription, public-network policy or entire initiative.

The approved category is **Waiver, with no expiry**. Existing exemptions with
different policies, category or expiry stop the run rather than being silently
overwritten. Revisit this permanent exception through the governance process.
The script explicitly restores key access because creating an exemption does
not reverse an earlier policy modification. It waits up to 15 minutes for
propagation, verifies public storage access remains disabled, and restarts the
Logic App only when it created the waiver or repaired the account.
Reruns read the exemption directly by its exact ARM resource ID; they do not
depend on list results. Only an explicit HTTP 404 triggers creation. Existing
matching exemptions require read permission, not exemption write permission.
Permission, scope, verification
and propagation failures stop before application deployment; no tags are used
to bypass the policy and no permissions are self-assigned.

The deployment identity needs `Microsoft.Authorization/policyExemptions/write`
on the storage account **and**
`Microsoft.Authorization/policyAssignments/exempt/action` on the inherited
assignment. Workload subscription Owner alone might not supply the latter
management-group permission. A governance administrator must authorize these
permissions outside this workflow. The existing `demo` approval gate remains.

The `GitHub-ATO-Demos` identity has these administratively assigned custom roles:

| Role | Actions | Assignment scope |
| --- | --- | --- |
| GovHub Policy Exemption Writer | Exemption read/write | GovHub workload resource group |
| GovHub MCAPS Exemption Approver | Assignment read and `exempt/action` | The configured `MCAPSGovDeployPolicies` assignment only |

These roles do not grant Owner, policy assignment edits or exemption deletion.
Azure RBAC cannot limit `exempt/action` to one reference inside an initiative;
the adapter still restricts every waiver to the shared-key reference and one
runtime storage account. If the workload resource group is deleted/recreated,
an administrator must restore its writer role assignment. Account-only
recreation retains the resource-group grant. Allow RBAC propagation and use
a fresh workflow login after granting permissions.

## Run from GitHub

1. Review the configuration, costs, provider registration and quotas. Changing
   primary region, environment name or resource names can create new resources.
   The subscription and deployment region come from configuration, **not**
   the ALZ workflow's `AZURE_SUBSCRIPTION_ID` environment variable.
2. On the existing `demo` environment, retain `AZURE_CLIENT_ID` and
   `AZURE_TENANT_ID`. Reuse its federated credential for
   `repo:azureholic/ato-demo:environment:demo`; no client secret is required.
   Require reviewers, restrict deployments to `main`, and disable approval
   bypass. The workflow rejects other branches and missing reviewer rules.
3. The identity needs subscription deployment/resource permissions plus
   role-assignment permissions (upstream recommends Owner, or Contributor
   plus User Access Administrator). ALZ management-group permissions alone
   are insufficient. Provision these permissions administratively, outside
   this workflow, on the subscription selected in configuration. Provider
   registration requires `/register/action` (included in Contributor/Owner).
   The same OIDC identity also needs deployment, DNS-link/zone-join and peering
   permissions in the **platform** subscription: existing `rg-dns`, the hub RG,
   and permission to join the GovHub spoke. GovHub does not require permission
   to create `rg-dns` or zones. This workflow does not grant itself access.
4. Deploy **Actions > Deploy ALZ Platform (Bicep Accelerator)** first to provision
   central DNS. Existing `rg-dns`, zones and links are reused incrementally;
   do not delete them for this ownership change. This code contains **no
   resource deletion**, resource moves or soft-delete purges.
5. Open **Actions > Deploy AI Governance Hub > Run workflow** on `main` and
   approve the `demo` environment gate. There is no mode selector: every run
   registers required providers, compiles the templates, prepares spoke/peerings
   and links its spoke to existing platform DNS, then provisions/publishes the
   complete GovHub.
   Compilation and safety checks remain mandatory; there is no separate
   validation-only workflow run.

Deployment uses native `azd` GitHub federated authentication rather than a
client secret or delegation to an old Azure CLI login. Azure CLI also signs in
with OIDC for provider registration and cross-subscription networking. Versions are pinned:
upstream commit in configuration, azd 1.37.3 and Bicep CLI 0.48.1 in the workflow.
azd manages its own Bicep tool for provisioning. Review upstream release changes
and run validation before updating the commit; do not replace it with `main`.

## Deployment cautions

- This is an initial hub deployment workflow. For gateway-only day-2 upgrades
  and backend/access/publish onboarding, use the
  [upstream operational modules](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator#day-to-day-operation).
  They are not automatically deployed by this workflow.
- StandardV2, Logic App hosting, Event Hubs, Cosmos DB, Foundry models and
  monitoring incur charges. Confirm model availability and capacity in both
  regions and all required resource providers using the
  [full deployment guide](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/blob/main/guides/full-deployment-guide.md).
- APIM and Logic App website/SCM access remain public so a hosted runner can
  publish the application. Key Vault, Cosmos DB and Foundry use upstream private
  connectivity; Event Hubs retains the public access required by upstream
  StandardV2 provisioning. This is not a private-only production configuration.
- Gateway consumer Entra authentication is separate from deployment OIDC and
  is disabled here. Use access contracts and configure consumer authentication
  before exposing the gateway to applications.
- Configurable inference diagnostics disable LLM message logging and
  Application Insights body capture. Other upstream APIs/policies may have
  their own diagnostics; review those before sending sensitive prompts.
- The existing ALZ hub is peered, but its subnets/firewall, workspace, management
  groups and policies are not changed. Central DNS has its own platform template,
  separate from the ALZ deployment stacks. Resources remain subject to inherited
  ALZ policies, which may block deployment. Do not run the two workflows
  concurrently while changing hub networking.
- Deployment is multi-stage, not transactional. Resolve partial failures before
  retrying. Do not run concurrent deployments locally and in GitHub. The main
  upstream template is for initial implementation, not a general day-2 upgrade.
- Offline compilation may report upstream schema/linter warnings. Compilation
  is not proof of live deployment success or working gateway calls.

## Local validation and tests

PowerShell 7.4+, Git and Azure CLI with Bicep CLI are required for real compilation.
No Azure login is required for **Validate**:

```powershell
.\ai-governance-hub\Invoke-AiGovernanceHub.ps1 -OutputPath "$env:TEMP\ai-governance-hub-new-run"
```

Always use a fresh output directory. The compiled template and parameters remain
there for inspection; generated sources/configuration are never committed here.
For local writes, authenticate Azure CLI and ensure access to both subscriptions.
Register providers first; then explicitly choose `-Mode Network` or `-Mode Deploy`.
Full Deploy also requires `azd auth login`. There is no local approval prompt:

```powershell
$config = Get-Content .\ai-governance-hub\config\deployment.json -Raw | ConvertFrom-Json
.\ai-governance-hub\Register-ResourceProviders.ps1 -SubscriptionId $config.subscriptionId
.\ai-governance-hub\Invoke-AiGovernanceHub.ps1 -OutputPath "$env:TEMP\govhub-network-new-run" -Mode Network
```

Run focused orchestration tests without Azure access, clones or installed modules:

```powershell
.\ai-governance-hub\tests\Test-AiGovernanceHub.ps1
```
