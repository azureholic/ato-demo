# Upstream contribution TODO

Upstream: [Azure-Samples/ai-hub-gateway-solution-accelerator](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator).
Checked on **2026-11-07** against default-branch commit
[`81599b31dfbaee20ebd3a6d2ba9b07dde3c31814`](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/commit/81599b31dfbaee20ebd3a6d2ba9b07dde3c31814),
which matches our pinned revision.

## Existing issue / PR check

- [x] Search open and closed upstream issues for `logger`, `endpointAddress`,
  `canonical` and `Italy`; also review the existing issue titles.
- [x] Search upstream pull requests for `logger`, `endpointAddress` and `Italy`.
- **Result:** no matching issue or proposed fix found in these searches.
  The logger search returned older merged PRs, but the defect remains in the
  latest default-branch source.
- [ ] Repeat the searches before contributing, then open an issue if there is
  still no matching report. No upstream issue or PR has been created by us.

## 1. Bug: Event Hubs logger endpoint must be a hostname

Suggested issue / PR title:
**Fix APIM Event Hubs managed-identity logger endpoint hostname normalization**

### Evidence and reproduction

The failed [deployment run](https://github.com/azureholic/ato-demo/actions/runs/42369221515)
reported this error for both `usage-eventhub-logger` and
`pii-usage-eventhub-logger`:

```text
The Event Hubs logger endpointAddress must be a canonical Event Hubs
namespace hostname in the current Azure cloud.
```

Azure returned a namespace `serviceBusEndpoint` in this form:

```text
https://<namespace>.servicebus.windows.net:443/
```

The upstream expressions remove only `https://`, leaving
`<namespace>.servicebus.windows.net:443/`. APIM expects only
`<namespace>.servicebus.windows.net`, as shown in the official
[managed-identity logger documentation](https://learn.microsoft.com/azure/api-management/api-management-howto-log-event-hubs#option-1-create-a-logger-with-managed-identity-credentials-recommended).

### Required upstream change

File: [bicep/infra/modules/apim/apim.bicep](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/blob/81599b31dfbaee20ebd3a6d2ba9b07dde3c31814/bicep/infra/modules/apim/apim.bicep).

- [ ] Correct `credentials.endpointAddress` in both `ehUsageLogger` and
  `ehPIIUsageLogger`.

Current expressions, in their respective resource blocks:

```bicep
endpointAddress: replace(eventHubEndpoint, 'https://', '')
endpointAddress: replace(eventHubPIIEndpoint, 'https://', '')
```

The runner-only correction currently used by our adapter is:

```bicep
endpointAddress: split(split(split(eventHubEndpoint, '://')[1], '/')[0], ':')[0]
endpointAddress: split(split(split(eventHubPIIEndpoint, '://')[1], '/')[0], ':')[0]
```

- [ ] Preserve the hostname supplied by Azure, including its cloud-specific
  suffix. Do not hardcode `.servicebus.windows.net` or substitute a
  `privatelink` hostname.
- [ ] Keep managed identity credentials, Event Hub names, role assignments and
  the conditional PII logger unchanged. Do not disable logging as a workaround.
- [ ] Normalize only the logger credentials; do not change namespace endpoint
  outputs globally, because other consumers may require the complete URL.
- [ ] Add regression coverage for URLs with `:443/`, a trailing slash without a
  port, a port without a trailing slash, and a different Azure-cloud suffix.
- [ ] Compile the templates and verify an actual deployment creates both
  loggers successfully, with PII anonymization enabled.

**Verification so far:** our adapter regression tests pass; the full pinned
templates compile; both actual patched Bicep expressions produce hostname-only
values for the four URL shapes above. Azure deployment after this correction
has **not** yet been verified.

## 2. Separate enhancement: Italy North core-region support

This is a scenario compatibility adjustment, not the logger defect. Keep it in
a separate issue / PR.

Files:
[bicep/infra/main.bicep](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/blob/81599b31dfbaee20ebd3a6d2ba9b07dde3c31814/bicep/infra/main.bicep)
and
[bicep/infra/resources.bicep](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/blob/81599b31dfbaee20ebd3a6d2ba9b07dde3c31814/bicep/infra/resources.bicep).

- [ ] Confirm intended core-region support with upstream maintainers, then add
  `italynorth` to both `@allowed` annotations on `param location string`.
- [ ] Verify required service/SKU availability and document scenario limits.
  [APIM's v2 region table](https://learn.microsoft.com/azure/api-management/api-management-region-availability)
  lists Italy North for StandardV2; this alone does not establish support for
  every optional accelerator feature or guarantee live capacity.
- [ ] Keep core placement independent of Foundry/model locations: our core is
  in Italy North, while the two model backends remain in Poland and Sweden.
- [ ] Compile and deploy the supported scenario before claiming region support.

## After upstream fixes are merged

- [ ] Update `upstreamRevision` in [config/deployment.json](config/deployment.json)
  to a full commit SHA containing the accepted fixes.
- [ ] Remove each corresponding runner-only patch and its drift guard from
  [Invoke-AiGovernanceHub.ps1](Invoke-AiGovernanceHub.ps1) in the same change.
  The existing guards deliberately reject changed upstream expressions.
- [ ] Update [tests/Test-AiGovernanceHub.ps1](tests/Test-AiGovernanceHub.ps1) and
  [README.md](README.md), then compile and run a new deployment workflow.
- [ ] Keep our scenario configuration, platform DNS ownership and hub peering
  integration local; these contributions do not require vendoring upstream.
