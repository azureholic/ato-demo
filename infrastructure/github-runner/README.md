# Reusable private GitHub runner

A separate Sweden Central scenario in the Governance Hub subscription:
`rg-github-runner-swe`, `vnet-github-runner-swe` (`10.190.0.0/23`),
an internal workload-profile Container Apps environment, an event-driven ephemeral
Container App Job, private Premium ACR, private Key Vault and a Log Analytics workspace
with Application Insights. Monitoring is public (no Azure Monitor Private Link Scope);
Application Insights allows Entra authentication only.
Subnets use the platform firewall at `10.100.0.4`; platform DNS remains in `rg-dns`.

Sweden Central is intentional: managed VNet-connected ACR task pools are
[not supported in Italy North](https://learn.microsoft.com/azure/container-registry/tasks-agent-pools).
The pool bootstraps the runner image without a public registry, temporary public-access
exception or preexisting private runner. Its S2 instance is scaled to zero after
a successful build. Scale it up before later builds and back down afterward;
allocated pools and Premium ACR incur charges.

Configuration lives in [deployment.json](config/deployment.json). Bootstrap clones
the pinned [official runner sample](https://github.com/Azure-Samples/container-apps-ci-cd-runner-tutorial),
then overlays the maintained runner base, tools and GitHub App entrypoint.
The image is built inside the VNet and deployed by immutable ACR digest.
Container Apps Jobs do not support privileged Docker-in-Docker; use the ACR pool
for Docker builds, not a Docker daemon on the runner.

## GitHub App setup

Run interactively from the repository root with authenticated `gh`:

```powershell
.\infrastructure\github-runner\Initialize-GitHubApp.ps1 -GitHubUser azureholic
```

Approve the manifest and install the App **only on this repository** in the browser.
GitHub requires this consent step; neither `gh` nor REST can bypass it.
The script automates conversion, verifies installation, stores the private key
as encrypted `GH_RUNNER_APP_PRIVATE_KEY` in `demo`, and stores `GH_RUNNER_APP_ID`
and `GH_RUNNER_INSTALLATION_ID` as environment variables. These are mapped to
the container/process `GITHUB_APP_*` inputs; stored GitHub settings cannot use
GitHub's reserved `GITHUB_` prefix.
It does not print or write the key to disk. App client/webhook secrets are not used.
The listener is localhost-only, state checked and time limited.
Do not rerun to rotate: it creates another App; rotate the existing App's key instead.
With multiple CLI accounts, pass `-GitHubUser azureholic`; this uses that account
only for setup without changing the active CLI account. Administration access is
checked before opening the creation page. If manifest conversion failed after
creation, use `-ResumeAppSlug <existing-slug> -GitHubUser azureholic`, then paste the
original localhost callback URL into the local browser form within GitHub's
one-hour conversion window. Never paste that one-time URL into chat or logs.
Converted credentials are encrypted in the environment immediately, before
waiting for installation, so an interrupted installation does not discard the key.
Only the verified repository installation ID is stored after installation.
Setup records a fixed 90-day expiry in `GH_RUNNER_APP_KEY_EXPIRES_ON` (Unix
seconds), mapped to `GITHUB_APP_KEY_EXPIRES_ON`. Redeployment does not extend it.
Rotate the existing App's key, update the encrypted environment secret and expiry,
then redeploy before expiry. Revoke the old key in GitHub: Key Vault expiry alone
does not revoke a GitHub key. No credential is committed.
In the current GitHub UI, generate replacement keys under App settings ->
Credentials -> Key pairs -> New key, not the General page.

Permissions: repository Actions read, Administration write (runner registration),
Metadata read and Contents read. No organization-wide permissions or PAT.
Each execution signs an RS256 JWT, requests a repository-limited short-lived
installation token, then a registration token. The key is removed from the runner
process environment before workflows run. Scaling uses a managed-identity Key Vault reference.

## Bootstrap and verification

1. Configure `demo` reviewers and existing Azure OIDC variables.
   Provision [platform DNS and egress](../../.github/workflows/platform-workload-connectivity.yml)
   first. The previous Italy VNet must remain unpeered because its address range
   overlaps the new agent spoke.
2. Run [the runner deployment workflow](../../.github/workflows/github-runner-deploy.yml)
   from `main`. It prepares the agent spoke, creates runner infrastructure, links
   existing zones, peers directly to workload VNets, builds privately and enables scaling.
3. Run [the smoke workflow](../../.github/workflows/github-runner-smoke.yml).
   A queued job must start a runner and pass private DNS/TCP/TLS checks.
   A provisioned Azure Job alone does not prove runner readiness.
4. Run [the agent foundation workflow](../../.github/workflows/ai-agent-deploy.yml).

Bootstrap uses an ARM `secureString` parameter, removes its temporary parameter
file on failure, and never uploads generated contexts as workflow artifacts.
Do not enable shell tracing or command-argument logging. The managed identity has
only ACR pull and Key Vault Secrets User; Azure deployment uses a separate OIDC identity.

`targetNetworks` defines direct two-way peering to Agent and Governance Hub.
Hub peering is not transitive. Add approved scenarios there and update platform
egress/DNS as needed. For another repository use a separate App installation and
job/configuration; do not share a registration credential across untrusted repos.

Only trusted `main` deployment workflows should target
`runs-on: [self-hosted, linux, x64, private-azure]`, with `environment: demo`.
Never use this runner for pull-request/fork workflows. Workflow code has private
reachability and can access its managed identity; ephemeral registration does not
make untrusted workflow code safe.

## Validation and troubleshooting

Run these commands from the repository root:

```powershell
.\infrastructure\shared-infrastructure\tests\Test-Deployment.ps1
.\infrastructure\github-runner\Invoke-GitHubRunner.ps1 -Mode Validate -OutputPath "$env:TEMP\runner-validation"
python -m unittest discover -s .\infrastructure\github-runner\tests
```

Python tests require `cryptography` (installed in the image).
Validation does not create resources or test browser consent.
Checkov ARM scanning has one intentional exception: `CKV_AZURE_166` (image
quarantine). Images are built from approved pinned sources and pulled by digest;
quarantine requires a separate verification/attestation release pipeline and would
otherwise prevent bootstrap pulls. Do not enable it without adding that release step.
If scaling stalls, inspect Job logs, App permissions/installation, the runner label,
Key Vault RBAC propagation, firewall denies and private DNS. For failed builds
inspect the reported ACR run ID. Failed builds can leave allocated pool instances;
scale them to zero after inspecting failure. Keep public access disabled in recovery.
