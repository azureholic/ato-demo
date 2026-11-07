# Agent Landing Zone

Scenario configuration for the [Agent Landing Zone full-stack deployment](https://azure.github.io/AI-Landing-Zones/agent-landing-zone/deploy-full-stack/).

## Source and scope

The requested [AI Landing Zones repository](https://github.com/Azure/AI-Landing-Zones) contains the documentation. The deployable template is [Azure/agent-landing-zone](https://github.com/Azure/agent-landing-zone), pinned in [deployment.json](config/deployment.json). Its manifest also pins infrastructure and application components. Clone those sources on the deployment runner; do not vendor them here.

The scenario uses Italy North and the GovHub subscription, with separate Foundry, application and network resource groups. The proposed spoke address space is `10.180.0.0/21`, separate from the existing hub and GovHub networks. Provisioning must create both peering directions to the platform hub and reuse platform-owned private DNS zones, with direct links to this spoke. Peering alone does not provide private DNS or controlled hub egress.

GovHub and DNS configuration remain authoritative in [ai-governance-hub](../ai-governance-hub/config/deployment.json) and [platform-alz](../platform-alz/config/private-dns.json), respectively.

## Deployment prerequisites

**Not deployed: this folder currently contains scenario configuration only. No deployment workflow or runtime adapter has been implemented yet.**

- **UI authentication:** the single-tenant `ai-agent-demo-ui` registration is created. Its tenant/client IDs and exposed API scope are recorded in [deployment.json](config/deployment.json). It issues version-2 UI access tokens and has administrator consent for exactly two delegated `user_impersonation` permissions: its own UI API and the Foundry resource (`https://ai.azure.com`). No Microsoft Graph or other application permissions were assigned. Retain upstream's `user_delegated` mode; consent does not grant Foundry caller RBAC or bypass UI admission.
- **GovHub model routing:** the pinned native orchestrator constructs `FoundryChatClient` using its Foundry project endpoint. It does not expose an APIM model-endpoint/subscription-key setting. Adding a gateway URL alone will not route model calls through GovHub. A runner-only integration adapter is needed, including an authenticated GovHub access contract and a verified compatible model client. Do not substitute the gateway URL for the Foundry project endpoint or silently fall back to direct inference.
- **Private deployment runner:** the repository currently has no self-hosted runners. Private App Configuration, Key Vault, Foundry and registry operations need a runner with network access and private DNS resolution. A private ACR Tasks pool only connects image builds; it does not connect a GitHub-hosted deployment runner. Keep network isolation enabled.

Italy North is listed in the [Foundry hosted-agent region availability](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents#region-availability). Actual subscription quota and allocation capacity still require deployment preflight.

Once these prerequisites are resolved, deployment must use the normal `demo` approval gate and verify provisioning, application publication, both peerings, private DNS and an actual model call through GovHub before reporting success.

## Complete UI authentication after provisioning

Registration and delegated consent are ready for the first infrastructure provision. Before publishing the application:

1. Register the exact frontend HTTPS callback, `https://<frontend-hostname>/auth/oauth/azure-ad/callback`, and configure the UI origin. No placeholder callback or public-client flow was enabled.
2. Create the confidential-client credential under the tenant's expiry policy and store it directly in the Agent Key Vault as `ui-oauth-client-secret`. Set `authentication.uiClientSecretReference` to the secret URI, never its value. Credential creation is deliberately deferred until that vault exists.
3. Configure upstream's UI OAuth settings with the registered client and exposed UI API scope, keeping the downstream Foundry audience separate. Add only the approved caller/source RBAC grants and verify sign-in and OBO.

The application registration and consent were configured separately using administrator access. The GitHub deployment identity was not granted directory-wide permissions.
