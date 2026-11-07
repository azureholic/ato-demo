# AI governance hub

This folder adopts the MIT-licensed
[AI Hub Gateway Solution Accelerator (Citadel)](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator)
without vendoring its infrastructure, policies or application code.

The [manual workflow](../.github/workflows/ai-governance-hub-deploy.yml) uses the
existing `demo` approval environment and OIDC application, just like the ALZ
workflow. It clones a **pinned upstream commit into runner temporary storage**,
copies our two configuration files into `bicep/infra`, compiles the templates,
checks the compact ARM request against the 4 MB limit, and optionally runs the
upstream `azd provision` followed by `azd deploy`. The latter deploys the usage
ingestion Logic App; infrastructure-only deployment would leave it unpublished.
Upstream templates, policies, application code and `azure.yaml` remain unchanged.
No Terraform or external deployment state storage is needed.

## Configuration

- [deployment.json](config/deployment.json): subscription, primary region,
  environment/resource-group name, upstream revision, APIM sizing, network
  ranges, regional Foundry instances and shared model deployment settings.
- [main.bicepparam](config/main.bicepparam): small scenario overlay for the
  upstream entry point. Its `using './main.bicep'` reference resolves **after
  copying it into the upstream checkout**, not inside this repository.
- [Invoke-AiGovernanceHub.ps1](Invoke-AiGovernanceHub.ps1): clone, overlay,
  compile and optionally invoke upstream deployment commands.

Initial scenario:

| Setting | Value |
| --- | --- |
| Primary region | Sweden Central |
| APIM | StandardV2, one unit |
| Network | New `10.170.0.0/24` VNet; no ALZ hub changes or peering |
| Monitoring | Dedicated Log Analytics workspace |
| Foundry backends | Sweden Central and Poland Central |
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
   this workflow, on the subscription selected in configuration.
4. Open **Actions > Deploy AI Governance Hub > Run workflow** on `main`.
   Run **Validate** first. This only clones and compiles; it does not call
   Azure validation/what-if APIs or verify live permissions, quotas or DNS.
5. Run again with **Deploy** and approve the `demo` environment gate.

Deployment uses native `azd` GitHub federated authentication rather than a
client secret or delegation to an old Azure CLI login. Versions are pinned:
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
- No ALZ VNet, workspace, management group or policy is reused or modified.
  Resources remain subject to inherited ALZ policies, which may block deployment.
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
For local **Deploy**, authenticate with `azd auth login` first and explicitly
pass `-Mode Deploy`; there is no local approval prompt.

Run focused orchestration tests without Azure access, clones or installed modules:

```powershell
.\ai-governance-hub\tests\Test-AiGovernanceHub.ps1
```
