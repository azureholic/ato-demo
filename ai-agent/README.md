# Agent landing zone (Bicep)

Repository-owned configuration for the infrastructure-only lifecycle documented by
[AI Landing Zones](https://github.com/Azure/AI-Landing-Zones/tree/main/docs/agent-landing-zone).
The runner clones the pinned [Agent Landing Zone](https://github.com/Azure/agent-landing-zone)
source; upstream infrastructure is not vendored here. `azd provision` runs its Bicep
composition, validation and private post-provision hooks. It does not deploy agent images.

## Scope

- Italy North, subscription `9fd780c4-e4ec-4204-83b9-cedca2c91b8e`, matching Governance Hub.
- Foundry: `rg-ai-agent-foundry-ita`; application: `rg-ai-agent-app-ita`;
  network: `rg-ai-agent-spoke-ita`.
- `vnet-ai-agent-spoke-ita`, `10.180.0.0/21`, peers in both directions to the platform hub.
  All configured subnets route `0.0.0.0/0` to its firewall, `10.100.0.4`.
- Platform DNS zones in `rg-dns` are referenced by ID, with direct spoke links.
  Azure-provided DNS is used; peering alone is not DNS forwarding.
- Hosted-agent prerequisites, not an application deployment. The approved delegated
  `HOSTED_AGENT_RESOURCE_SCOPE` is required; no audience is guessed.
- Private ACR, workspace, Application Insights and AMPLS are reused from the Sweden
  runner scenario, avoiding unsupported Italy ACR pools and conflicting shared AMPLS DNS.
- Foundry IQ uses minimal extraction because standard extraction requires Content
  Understanding, which the upstream preflight does not support in Italy North.
  Scanned and image-only PDFs will not be searchable without OCR. Changing extraction
  mode after creating a knowledge source requires recreating it and its knowledge base.

The new spoke reuses the address range of the previous, unpeered
`vnet-ai-agent-ita` but has a different name and resource group; the old VNet is
excluded from new platform DNS links and is not managed by this deployment.
Existing DNS links are not removed. Do not reconnect the old VNet to the hub or the
runner spoke while it overlaps the new spoke. This adapter is not an import or
migration tool: it manages the complete new spoke subnet collection.
It never deletes the shared hub, platform DNS or Governance Hub.

## Deployment order

1. Provision platform workload DNS and egress using
   [the connectivity workflow](../.github/workflows/platform-workload-connectivity.yml).
   This adds required zones and a dedicated firewall rule collection group.
2. Initialize the GitHub App and deploy/verify [the reusable runner](../github-runner/README.md).
   Its bootstrap workflow prepares the agent spoke and both direct spoke peerings.
3. Set `HOSTED_AGENT_RESOURCE_SCOPE` in the protected GitHub `demo` environment
   to the approved delegated Foundry audience followed by `/.default`.
4. Run [the foundation workflow](../.github/workflows/ai-agent-deploy.yml) from `main`.
   Network preparation runs on a hosted runner; Bicep and data-plane hooks run on
      the ephemeral `private-azure` runner. The workflow directs azd to the runner's
      pinned Bicep binary instead of downloading another copy. Required reviewers
      are enforced.

The existing `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` variables and GitHub OIDC
identity are reused. Authorize workload RG creation, deployment and role assignment,
hub peering/remote peer action, platform DNS link/zone join, and access to shared
registry/monitoring scopes. The runner's managed identity only pulls its image and
reads its App key; Azure deployment uses GitHub OIDC.

## Local validation

```powershell
.\shared-infrastructure\tests\Test-Deployment.ps1
.\ai-agent\Invoke-AiAgent.ps1 -Mode Validate -OutputPath "$env:TEMP\agent-validation"
```

Use a fresh output directory. Validate compiles Bicep and checks overlay parameter names,
without Azure mutations; it is not a quota, Policy or private-connectivity check.
Deployment keeps upstream regional and topology preflights enabled and fails on blockers.
Model/hosted-agent availability and quota in Italy North must pass those live checks.
Review upstream model defaults before approving costs.

The generated checkout hardens three pinned upstream gaps with exact-match guards:
Foundry Key Vault purge protection, Foundry Storage shared-key disablement, and
App Configuration local-auth disablement. Solution Storage uses its native parameter.
Revision changes require reviewing these guards and upstream parameters.
The preprovision hook also escapes bracket-prefixed App Configuration values in the
generated ARM parameters; ARM resolves them back to their original values.
The pinned non-executable POSIX preup script is invoked through `sh`.
Before running upstream postprovision, its wrapper removes the two legacy
hosted-agent outputs from the transient azd environment: upstream's topology
resolver rejects them as obsolete inputs. The ARM deployment retains its outputs.

Generated azd state is transient and removed by workflow cleanup. Reuse the same
environment, resource names, application binding and pins on reruns; never run
`azd down` as routine recovery. The recorded resource-group and application
bindings in this repository restore upstream's retargeting guard on each runner;
do not change them to migrate existing resources. Future agent-image deployment is separate:
clone the application source and build container images using the Sweden private ACR
pool, not a local Docker daemon. Preserve immutable digests and the original application
definition.
