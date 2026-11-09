# Web IQ research agent

A read-only public-web research assistant, built as a Foundry **prompt agent** in the
Agent Landing Zone project:

- **Models** come from the [AI Governance Hub](../../infrastructure/ai-governance-hub/README.md)
  through a Citadel **access contract** (Bicep). The contract creates the APIM product,
  subscription, model/token policy and the Foundry project connection.
- **Web evidence** comes from [Microsoft Web IQ](https://learn.microsoft.com/web-iq/integrations/mcp)
  (`https://api.microsoft.ai/v3/mcp`) attached as a remote MCP tool with approval required.
- Design rationale, risks and open decisions are in [plan.md](plan.md).

Web IQ is **public web only**. It is not Work IQ (Microsoft 365) or Foundry IQ (enterprise knowledge).

## Layout

| Path | Purpose |
| --- | --- |
| [config/deployment.json](config/deployment.json) | Single source of truth: pinned Citadel revision, targets, model, Web IQ and agent settings. |
| [access-contract/](access-contract) | `.bicepparam` overlay and APIM product policy for the pinned upstream contract template. Not vendored. |
| [infra/webiq-connection.bicep](infra/webiq-connection.bicep) | Project connection (`RemoteTool`, custom-key header) for Web IQ. |
| [agent/instructions.md](agent/instructions.md) | Agent instructions: citations, untrusted-content handling, failure behavior. |
| [src/webiq_agent/](src/webiq_agent) | Python client: `publish` creates an agent version, `invoke` asks a question and handles tool approvals. |
| [Invoke-WebIqAgent.ps1](Invoke-WebIqAgent.ps1) | `Validate`, `Contract`, `WebIq`, `Agent` modes. |
| [workflow](../../.github/workflows/web-research-agent-deploy.yml) | Manual, approval-gated deployment on the existing `demo` environment. |

## How it fits together

```text
Caller -> Foundry project (Agent Landing Zone, private)
            prompt agent "web-research-agent"
              model   = govhub-web-research-LLM/gpt-6-astra
                          -> Hub APIM product LLM-Platform-WebResearch-DEMO -> regional model pool
              tool    = MCP "web_iq" (allowed: web, browse; approval: always)
                          -> https://api.microsoft.ai/v3/mcp   (project connection web-iq-mcp)
```

The model name uses Foundry's `<connection-name>/<model-name>` form. The connection name
is `<connectionNamePrefix>-LLM`, created by the contract; `config.py` derives it from the same setting.

## Deployment order

1. The Agent Landing Zone and Governance Hub must already be deployed.
2. In the protected GitHub `demo` environment, add the `WEBIQ_API_KEY` **secret** (approved Web IQ account).
3. Run [the workflow](../../.github/workflows/web-research-agent-deploy.yml) from `main`:
   1. `infrastructure` job (hosted runner): unit tests, template validation, access contract, Web IQ connection.
   2. `agent` job (private `private-azure` runner): publish the agent version and run the smoke question.
      Foundry's data plane is private, so this step cannot run from a hosted runner.

Resource names (APIM, Foundry account and project) are discovered in the configured resource
groups. If a group contains more than one candidate, the script stops; set the name explicitly
in `config/deployment.json`.

## Local validation

```powershell
.\code\foundry-webiq-agent\Invoke-WebIqAgent.ps1 -Mode Validate -OutputPath "$env:TEMP\web-research-validate"
python -m pip install -r code\foundry-webiq-agent\requirements.txt -r code\foundry-webiq-agent\requirements-dev.txt
python -m pytest code\foundry-webiq-agent
```

Validate compiles the contract overlay against the pinned upstream and checks that the APIM policy
matches the model name and token limits in `config/deployment.json`. It does not prove quota, Policy,
APIM routing or private connectivity.

## Ask the agent

From a host with private access to the project, after signing in with `az login`:

```powershell
$env:FOUNDRY_PROJECT_ENDPOINT = 'https://<account>.services.ai.azure.com/api/projects/<project>'
$env:PYTHONPATH = 'code\foundry-webiq-agent\src'
python -m webiq_agent.invoke "What changed in the latest Azure Foundry agent release? Cite sources."
```

Each Web IQ call prompts for approval. `--auto-approve-allowed-tools` approves only the configured
server and allowed tools and denies everything else; the workflow smoke test uses it.

## Security and operations notes

- **Gateway key:** the contract uses `authType: ApiKey`. With Key Vault publishing disabled, the upstream
  template returns the APIM subscription key as a deployment output, so `Contract` mode deletes the
  subscription-scope *deployment record* afterwards and warns if it cannot. This removes history
  only; it deletes no Azure resources. Rotation follows the upstream
  [key rotation guide](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/blob/81599b31dfbaee20ebd3a6d2ba9b07dde3c31814/bicep/infra/citadel-access-contracts/access-contract-key-rotation-guide.md).
  `ProjectManagedIdentity` would also need JWT validation in the product policy and the project identity's client ID.
- **Web IQ key:** passed through an environment variable to `az` and stored only in the Foundry connection.
  The compiled parameter file embeds secure values, so deployment passes the `.bicepparam` directly
  and Validate uses a placeholder and deletes its output.
- **Tools:** approval is always required; an empty `allowedTools` list is rejected because it would allow every tool.
  Retrieved content is untrusted and the instructions say so.
- **Re-runs:** each publish creates a new agent version; earlier versions remain for rollback.
  Existing project connections are never deleted.
- Remove the contract by hand only after reviewing consumers; this project contains no resource deletion.

## Not verified yet

Not tested against live Azure. Before first use, confirm in order:

1. **Gateway reachability.** Connected-model inference originates from Foundry's managed inference
   plane, not the delegated agent subnet ([Microsoft guidance](https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway)).
   The Hub's APIM gateway has no public endpoint; Foundry reaches it through the Hub-spoke private
   endpoint (`privatelink.azure-api.net`, agent spoke linked, firewall FQDN rule `private-gateway-443`).
   An earlier run showed a Foundry-originated request in the APIM logs while the gateway was still public;
   re-run `ModelCheck` after any networking change to confirm Foundry still reaches it privately.
2. **Tool calling.** The Hub model must support function/tool calling through the OpenAI-v1
   `universal-llm-api` route (`/models/chat/completions`). The legacy `azure-openai-api` route returned 404
   from the Hub's backends, so the contract uses `universal-llm-api`. Run `ModelCheck` to verify.
3. **Web IQ.** The account is entitled to `web`/`browse`, the key works from Foundry's MCP execution
   path, and any firewall egress to `api.microsoft.ai` is approved (it is not in the current
   [workload egress list](../../infrastructure/platform-alz/config/workload-egress.json)).
4. **Data handling.** Public-web query handling, retention, residency (the Hub's GlobalStandard model
   does not guarantee EU-only processing) and cost limits are approved.
5. The project-level capability host exists for tool calls leaving through the VNet.

Connected models do not support Foundry Guardrails, memory or agent optimization.
