# Agent Landing Zone

Scenario configuration for the [Agent Landing Zone full-stack deployment](https://azure.github.io/AI-Landing-Zones/agent-landing-zone/deploy-full-stack/).

## Source and scope

The requested [AI Landing Zones repository](https://github.com/Azure/AI-Landing-Zones) contains the documentation. The deployable template is [Azure/agent-landing-zone](https://github.com/Azure/agent-landing-zone), pinned in [deployment.json](config/deployment.json). Its manifest also pins infrastructure and application components. Clone those sources on the deployment runner; do not vendor them here.

The scenario uses Italy North and the GovHub subscription, with separate Foundry, application and network resource groups. Its spoke address space is `10.180.0.0/21`, separate from the existing hub and GovHub networks. Bootstrap creates both hub peerings and links platform-owned private DNS zones. Private GovHub traffic uses a source-scoped HTTPS application rule on the hub firewall: its SNAT preserves flow symmetry without changing GovHub subnet policies or return routing. Peering alone is not transitive.

GovHub and DNS configuration remain authoritative in [ai-governance-hub](../ai-governance-hub/config/deployment.json) and [platform-alz](../platform-alz/config/private-dns.json), respectively.

## Deploy

Run [Deploy AI Agent Landing Zone](../.github/workflows/ai-agent-deploy.yml) from `main`, using the normal `demo` approval gate and existing OIDC identity. Sources are cloned at immutable pins, outside this repository.

The existing workflow identity deliberately cannot delegate Owner, User Access Administrator or RBAC Administrator. Once the worker identity exists, an authorized administrator must grant it conditional RBAC Administrator on exactly the three Agent resource groups, retaining the same exclusions for privileged role assignment/deletion. Bootstrap verifies that prerequisite; do not weaken the workflow's management-group condition or grant an unconditional worker administrator role.

1. Validate configuration, real SDK protocol tests and the complete pinned Bicep.
2. Build both manifest-pinned Linux images on the GitHub-hosted Docker runner and retain checksummed same-run artifacts for one day. The builder never accesses private Azure services.
3. Bootstrap a private Italy North Consumption Container Apps Job, hub routing, source-scoped package/artifact egress and central DNS. The Azure-triggered executor uses a managed identity, not a registered self-hosted runner or persistent GitHub token.
4. Deploy upstream's Agent-specific GovHub product/subscription. Only the configured model and OpenAI API are granted, with explicit token limits. ARM writes the subscription key directly into the private Agent vault; keys are not workflow outputs.
5. Refresh exact registry/artifact egress, verify artifact run/revision/configuration and archive checksums, and import images into private ACR using `skopeo`. Publish digest-bound hosted agent and UI images, then verify effective configuration, private DNS/TLS, a completed GovHub response and signed-out UI denial in the same execution.
6. Stop owned executions and remove their encrypted ephemeral Job secrets, including failure paths. The manual Job scales to zero; retained agent services and environments can still incur costs.

The initial scenario is explicitly conversational-only: no local model deployments, RAG, MCP, ingestion, chat-history database or private attachments. These are configuration choices made before deployment, not error-recovery fallbacks. Agent hosting keeps its own Foundry project; all application model inference uses GovHub.

Italy North is listed in [hosted-agent region availability](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents#region-availability); allocation still requires upstream preflight. The UI stays private and needs connectivity to the landing-zone network.

Italy North has no ACR Task agent pools, and Container Apps Jobs do not support Docker-in-Docker. Therefore only the GitHub-hosted builder uses Docker. Private import uses no Docker daemon, privileged container, public registry access or remote ACR Task fallback. The native `BUILD_MODE=local` compatibility setting is retained only to pass upstream's private-network preflight; immutable hosted/UI overrides bypass its actual builders. No VM or regional VM SKU access is required.

## Small runner-only adapters

[Invoke-AiAgent.ps1](Invoke-AiAgent.ps1) clones/configures the template and runs its native lifecycle. [Invoke-AiAgentHost.ps1](Invoke-AiAgentHost.ps1) handles the private Job and verifies actual execution results. [Run-AiAgentJob.sh](Run-AiAgentJob.sh) bootstraps its tools and dispatches the pinned scenario; [Agent-Images.py](Agent-Images.py) validates same-run artifact identity and never forwards GitHub credentials to signed storage URLs.

The upstream orchestrator has no configurable APIM inference client. [Patch-AiAgent.py](Patch-AiAgent.py) therefore patches only the pinned runner checkouts:

- Native configuration requires a gateway endpoint/API version and a secret URI bound to the provisioned vault.
- [govhub.py](govhub.py) uses the SDK's Azure Responses client against `/openai/responses`, with the product's `api-key` and `api-version`. Missing/invalid settings, secrets or private gateway DNS fail closed; there is no direct Foundry or public inference fallback.
- The actual manifest-pinned Docker build source is adapted before the hosted-runner build. Its adapter/configuration fingerprint is included in the image label and manifest. Registry login credentials use an owned `/dev/shm` directory removed after private import. The actual native UI deployment script receives only a validated private-registry digest, preserving registry managed identity and image read-back verification.
- The foundation's empty-model fallback is removed: an empty deployment list genuinely means no local models, rather than silently deploying upstream's default chat and embedding models.
- Existing native hosting, delegated authorization, trusted caller partition, session ownership and toolbox behavior are preserved. Existing upstream secret-grant helpers assign runtime read access to the one named GovHub secret.

Guarded source anchors and immutable commits deliberately fail on incompatible upstream changes. No upstream application or infrastructure source is vendored here.

## Complete UI authentication after provisioning

The single-tenant `ai-agent-demo-ui` registration and consent are ready. It exposes version-2 UI tokens and exactly two delegated `user_impersonation` grants: its own UI API and Foundry (`https://ai.azure.com`). No Microsoft Graph/application permissions were granted to the deployment identity. Consent does not replace Foundry caller RBAC.

Before first application publication:

1. Register the exact frontend HTTPS callback, `https://<frontend-hostname>/auth/oauth/azure-ad/callback`. Publication derives `CHAINLIT_URL` from that deployed frontend hostname and verifies its effective value, keeping the UI origin consistent. No placeholder callback or public-client flow was enabled.
2. Create an expiring confidential-client credential and store it directly in the Agent Key Vault as `ui-oauth-client-secret`, together with a random `chainlit-auth-secret`. The configured URI is the planned reference, not evidence that a credential already exists. Never store their values in configuration, logs or plain execution parameters; use encrypted ephemeral Job secret references for the private handoff.
3. Configure upstream's UI OAuth settings with the registered client and exposed UI API scope, keeping the downstream Foundry audience separate. Add only the approved caller/source RBAC grants and verify sign-in and OBO.

The workflow explicitly fails publication when required vault secrets are missing. Complete the authorized administrator handoff and rerun; infrastructure is reusable. Normal workflow deployment never changes Graph permissions. Automated deployment verification is not proof of a complete end-user sign-in/OBO session.

The one-time administrator `Handoff` Job uses Azure execution verification without a GitHub token or check-run. Normal workflow phases use their ephemeral GitHub App token for bounded private diagnostics; an administrator's GitHub OAuth token cannot create checks.
