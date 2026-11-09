# Foundry Web IQ prompt agent - plan

Status: **Implemented, not yet deployed or tested against live Azure.** The text below is
the original design; the "Implementation status" section at the end records what was built,
the defaults chosen for the open decisions, and what remains unverified. See [README.md](README.md).
Date: 2026-11-09.

## 1. Recommendation

Build an ordinary **Foundry Agents v2 prompt agent** in the existing Agent Landing
Zone Foundry project. Connect its model through the AI Governance Hub APIM gateway
and attach Microsoft Web IQ as a remote MCP tool.

This is a good fit for a small, centrally governed web-research agent: Foundry
manages orchestration, the Governance Hub controls model consumption, and Web IQ
provides current public-web evidence. No hosted agent container, new Foundry
resource, or duplicate model deployment should be needed.

Proceed in two stages: prove the integration boundaries first, then implement the
repeatable agent project. Do not promise fully private end-to-end execution:
Web IQ is a public service, and connected-model gateway ingress needs particular
attention.

## 2. Scope and proposed first use case

Proposed use case, subject to review: a read-only public-web research assistant
that answers a question using current sources, provides clickable citations,
and distinguishes evidence from inference.

The agent should:

- Search public web content through Web IQ and optionally browse source pages.
- Use only the approved model exposed by the AI Governance Hub.
- Return an answer, supporting source URLs, and relevant uncertainty.
- Treat retrieved pages and tool descriptions as untrusted content, not instructions.
- Report access, search, model, and citation failures explicitly.
- Never send secrets or confidential enterprise content to public-web tools.

Out of scope for the first version:

- Work IQ / Microsoft 365 data, Fabric IQ, and Foundry IQ knowledge bases.
- Hosted agents, the Copilot harness, containers, a web frontend, and scheduling.
- New model deployments, infrastructure replacement, or changes to shared DNS ownership.
- Automatic writes, arbitrary tool execution, and automatic provider fallback.

**Web IQ is intentional here**, not Work IQ. Microsoft documents Web IQ as a
public-web service; Work IQ is a different integration for Microsoft 365 context.

## 3. Existing repository foundations

These are configured intentions, not verification of deployed Azure state.

| Component | Repository evidence | Implication |
| --- | --- | --- |
| Agent Landing Zone | [Foundation README](../../infrastructure/ai-agent/README.md), [configuration](../../infrastructure/ai-agent/config/deployment.json) | Reuse the Foundry project in `rg-ai-agent-foundry-ita`, Italy North. Resolve actual resource names and project endpoint from Azure outputs. |
| Private foundation | [Agent parameters](../../infrastructure/ai-agent/config/parameters.json) | Preserve private access and existing identity/network controls. The foundation currently targets hosted orchestration; verify prompt-agent capabilities rather than changing that binding. |
| AI Governance Hub | [Hub README](../../infrastructure/ai-governance-hub/README.md), [configuration](../../infrastructure/ai-governance-hub/config/deployment.json) | Consume the shared APIM model pool, currently configured as `gpt-6-astra` with Poland Central and Sweden Central backends. Verify actual deployment and tool-calling support. |
| Consumer authorization | [Hub access-contract guidance](../../infrastructure/ai-governance-hub/README.md) | Hub deployment does not authorize this agent automatically. A scoped consumer access contract is required. |
| Platform networking | [Egress configuration](../../infrastructure/platform-alz/config/workload-egress.json) | `api.microsoft.ai` is not currently listed. Determine the actual MCP outbound path before requesting narrowly scoped egress changes. |
| Deployment path | [Foundation workflow](../../.github/workflows/ai-agent-deploy.yml) | Reuse protected `demo` approval, GitHub OIDC, and the private runner pattern for project data-plane operations. Keep application deployment separate from foundation provisioning. |

Platform ALZ owns the shared private DNS zones; GovHub consumes existing zones
and links its own spoke. This project must not create parallel private DNS zones.

## 4. Proposed architecture

```text
Authorized caller / private deployment runner
    |
    | Entra authentication; private Foundry project endpoint
    v
Agent Landing Zone: Foundry project
    |
    +-- Prompt agent: instructions + approved connected model + MCP tool
          |
          +-- Model inference:
          |     Foundry managed inference plane
          |       -> Governance Hub APIM consumer contract
          |       -> approved regional model pool
          |
          +-- Web evidence:
                Foundry MCP execution
                  -> approved outbound path
                  -> https://api.microsoft.ai/v3/mcp
```

### Model connection

- Use the documented Foundry connected-model / AI gateway integration.
- Reference the model as `<connection-name>/<model-name>`, not a local model
  deployment name and not a direct regional backend URL.
- Match the gateway's actual API contract. The repository currently documents
  deployment-based Chat Completions; do not assume `/openai/v1/responses` exists.
  Prove multi-step tool calling using the selected protocol.
- Prefer project managed identity if the consumer contract supports it. Otherwise,
  review a scoped APIM subscription key stored in a secured Foundry connection.
  Never assume APIM's managed identity to the backend authorizes inbound consumers.
- Keep quotas, usage attribution, routing, and backend credentials in the Hub.
- Do not independently load-balance stateful Responses sessions across regions.

### Web IQ connection

- Use the documented remote MCP endpoint `https://api.microsoft.ai/v3/mcp`.
- Initially allow only `web`; add `browse` if approved and useful. Exclude image,
  video, and news tools unless the use case requires them.
- Web IQ supports an `x-apikey` header and Entra client-credentials tokens.
  Actual tool availability depends on the account's allowed service list.
- Prefer a supported identity-based production connection, but first verify
  Foundry-to-Web-IQ token acquisition and renewal. Web IQ's documented app
  registration flow is not evidence that project managed identity works directly.
- If an API key is approved for the demo, store it in a secured project connection;
  use Key Vault where supported by that connection type. Do not put keys in the
  agent definition, source, command-line arguments, or workflow logs.
- Start with MCP approval required. The invocation client must surface the request
  and continue only after approval. Revisit automatic read-only approvals later.
- Confirm public-web data handling, licensing, account access, and costs before use.

## 5. Feasibility gates - complete before building the full project

### Gate A: Foundry project readiness

Discover the existing Foundry account/project, endpoint, runtime identity,
network-injection configuration, and applicable project-level capability host.
Confirm Agents v2 prompt-agent availability in the deployed region.

The existing hosted-agent subnet and capability configuration are not, by
themselves, proof that prompt-agent tools and connected models will work.
Do not retrofit network injection or reprovision the foundation without review.

### Gate B: Governance Hub model inference

Confirm consumer authorization, exact protocol/routes, model tool support,
and gateway reachability **from the managed Agent Service inference plane**.

Microsoft documents that connected-model inference does not originate from the
delegated agent subnet. A capability host, spoke peering, or a successful gateway
call from the private runner does not prove this path.

If existing APIM ingress is private-only and unreachable from that plane, stop
for an architecture decision. Do not silently enable public access or bypass
APIM. Options for review are a supported secured ingress design, waiting for a
compatible private topology, or a separately approved hosted-agent alternative.
The latter changes the requested agent type and is not the default solution.

### Gate C: Web IQ tool execution

Verify Web IQ entitlement and credentials, MCP discovery, allowed tools, approval
handling, and one real tool call from the deployed prompt agent. Test the tool
with the connected model, not just with a local MCP client.

Verify the applicable project-level capability host and outbound path. Request
specific firewall/DNS changes only where traffic actually traverses those controls.
Do not introduce a custom MCP proxy unless a demonstrated blocker requires a
separately reviewed design.

If Web IQ is unavailable, report the reason. Foundry's native Web Search may be
an alternative, but only after explicit approval and compatibility/data-handling
review; it is not an invisible fallback.

### Gate D: Governance and residency

Approve what may leave the project for Web IQ and the model gateway, log
redaction, retention, cost limits, and tool approvals. Current Hub GlobalStandard
configuration does not guarantee EU-only inference processing.

Connected-model documentation lists limitations including Foundry IQ, agent
optimization, memory, and Foundry Guardrails. Verify applicable protections and
APIM/backend content-filter behavior rather than promising unsupported features.

## 6. Implementation (original proposal; as built see section 11)

Keep all agent-specific source in this folder. Originally proposed files (the built layout is in [README.md](README.md)):

```text
foundry-webiq-agent/
  plan.md
  README.md
  agent.yaml                 # built as agent/instructions.md + config/deployment.json
  config.example.json        # built as config/deployment.json
  pyproject.toml             # built as requirements*.txt
  src/
    deploy_agent.py           # built as src/webiq_agent/publish.py
    invoke_agent.py           # built as src/webiq_agent/invoke.py
  tests/
    test_configuration.py     # built as tests/test_agent.py
    test_response_handling.py
```

Python is a proposal for the SDK client, not the agent runtime: orchestration
and tool execution stay in Foundry. Confirm the language during review and pin
compatible SDK dependencies when implementing.

Implementation sequence:

1. Record Gate A-D results and resolve the review decisions below.
2. Define the research prompt, source/citation contract, tool allow-list, and
   explicit failure behavior.
3. Implement configuration validation and connection lookup. Connection creation
   must be explicit and authorized; never overwrite existing shared connections.
4. Implement repeatable named-agent version creation, remote invocation, approval
   continuation, and citation display. Record the returned agent version.
5. Add focused local tests and live smoke/evaluation cases.
6. Document private execution, provisioning, invocation, troubleshooting, costs,
   rollback to a recorded version, and cleanup of project-owned resources only.
7. If requested, add a separate manually approved deployment workflow using the
   existing private runner/OIDC pattern; do not modify foundation deployment.

No Azure provisioning, firewall changes or credentials were made while implementing; deployment
is a separate, approval-gated workflow run.

## 7. Verification and acceptance criteria

| Check | Required evidence |
| --- | --- |
| Correct runtime | Agent exists as an ordinary prompt agent in the existing landing-zone project; no hosted container or new Foundry account. |
| Governed inference | A real agent invocation correlates with the authorized consumer's APIM usage telemetry and approved model route; no direct-backend fallback. |
| Web IQ integration | Foundry trace shows an allowed Web IQ tool call and successful approval continuation using the connected model. |
| Grounding | Current-information questions return supporting clickable URLs; an unverified claim or unavailable source is identified explicitly. |
| Credential boundary | Unauthorized Hub/Web IQ calls fail visibly; credentials do not appear in tracked files, output, or telemetry. |
| Failure handling | Missing configuration, tool denial, timeout, empty results, gateway throttling, and tool authentication failure produce actionable outcomes without fabricated success. |
| Network boundary | Foundry private access remains unchanged; actual model and tool traffic paths are recorded and approved. |
| Safety | Retrieved prompt-injection content does not override instructions or trigger unapproved tools. |
| Repeatability | A second deployment produces an identifiable version without recreating shared infrastructure; the prior version remains available for rollback. |

Use synthetic public queries for smoke tests. Evaluate a small reviewed set of
current research, conflicting evidence, no-result, and hostile-page cases.
Set a numerical quality threshold together once the intended research task is
agreed; do not invent a passing score for an unspecified use case.

## 8. Decisions for our review

1. Is a general web-research assistant the right first scenario, or should it
   specialize in a domain such as Azure architecture or regulatory research?
2. Confirm Web IQ account availability and permitted public-web data.
3. Is secured public gateway ingress acceptable if the existing private-only
   topology cannot support managed prompt-agent model inference?
4. Prefer managed identity where supported; approve a scoped secret-backed
   connection if necessary for the demo?
5. Keep per-call tool approval initially, and allow `browse` as well as `web`?
6. Approve Python for the deployment/invocation client, or choose another language?
7. Start with manual private-runner execution, or include CI/CD in the first build?
8. Agree the cost ceiling, retention policy, and measurable evaluation threshold.

These are review items, not decisions already taken.

## 9. Planning limitations and tooling prerequisite

This draft is based on repository configuration and Microsoft documentation;
no live Azure resources, routes, entitlements, or model availability were tested.

The Foundry skill's prerequisite check attempted to install the missing
`microsoft.foundry` azd extension and failed because the installed
`azure.ai.agents` extension (`0.1.41-preview`) did not satisfy its `~1.0.0`
dependency constraint. No follow-up upgrade or environment repair was attempted.
Resolve compatible tooling before any azd-based implementation path; this does
not prevent reviewing the architecture.

## 10. Microsoft references

- [Connected models through an AI gateway](https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway)
- [Foundry MCP tools](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol)
- [Foundry network isolation and tool traffic](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link#agent-tools-with-network-isolation)
- [Web IQ MCP endpoint and tools](https://learn.microsoft.com/web-iq/integrations/mcp)
- [Web IQ authentication](https://learn.microsoft.com/web-iq/get-started/authentication)
- [Web IQ FAQ and distinction from other IQ services](https://learn.microsoft.com/web-iq/resources/faq)

## 11. Implementation status

Built on 2026-11-09 after the review request to implement. Key points:

- **Access contract (correction to section 4):** Citadel onboards consumers through a Bicep
  access contract, which is now part of the implementation. It mints an APIM product and
  subscription with model RBAC and token limits, and creates the Foundry project connection.
  The contract's subscription key is required; managed-identity auth is an *additional* JWT layer,
  not a replacement, and needs product-policy JWT settings plus the project identity's client ID.
- **Defaults chosen for the open decisions in section 8:**
  1. General web-research assistant (instructions in `agent/instructions.md`).
  2. Web IQ entitlement is still **unconfirmed**; the deployment needs the `WEBIQ_API_KEY` secret.
  3. Gateway ingress is **not** changed; reachability from Foundry's managed inference plane is Gate B.
  4. Contract uses `ApiKey`; Web IQ uses a custom-key header connection (secret-backed).
  5. Approval is always required; `web` and `browse` are allowed.
  6. Python SDK client (`azure-ai-projects` 2.x).
  7. Manual, approval-gated workflow on the existing `demo` environment and private runner.
  8. Starting limits 10,000 tokens/min and 1,000,000 tokens/month, matching the Hub model's 10 capacity
     units; cost ceiling, retention and the quality threshold are **not** decided.
- **Verified locally:** both Bicep overlays compile against the pinned upstream, the policy matches the
  configuration, and 12 unit tests pass against the real SDK models.
- **Not verified:** everything in sections 5 and 7 that needs live Azure, including Gates A-D.
  The Foundry skill's azd extension check still fails (see section 9); the implementation does
  not use the `microsoft.foundry` azd extension.
