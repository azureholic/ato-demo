#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PYTHONIOENCODING=utf-8 AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no
export AZD_NON_INTERACTIVE=true
log=/tmp/ato-agent-job.log
exec > >(tee "$log") 2>&1

report() {
  local result=$?
  trap - EXIT
  if [[ "${ATO_PHASE:-}" == Handoff ]]; then
    echo "Private administrator handoff exit code: $result (verified by Azure execution status)."
    exit "$result"
  fi
  python - "$result" "$log" <<'PY'
import json, os, pathlib, re, sys, urllib.request
code = int(sys.argv[1])
text = pathlib.Path(sys.argv[2]).read_text(errors="replace")[-48000:]
for name, value in os.environ.items():
    if value and any(word in name for word in ("TOKEN", "SECRET", "PASSWORD")):
        text = text.replace(value, "[redacted]")
text = re.sub(r"(?i)(Bearer\s+)[^\s\"']+", r"\1[redacted]", text)
text = re.sub(r"(?i)([?&](?:sig|token|code)=)[^&\s\"']+", r"\1[redacted]", text)
text = re.sub(r"(?im)^.*(?:api[-_]key|accessToken|secretText|password)\s*[:=].*$", "[redacted credential field]", text)
body = {"status": "completed", "conclusion": "success" if code == 0 else "failure",
        "output": {"title": f"Private Agent {os.environ['ATO_PHASE']}",
                   "summary": "```\n" + text + "\n```"}}
request = urllib.request.Request(
    f"https://api.github.com/repos/{os.environ['ATO_REPOSITORY']}/check-runs/{os.environ['ATO_CHECK_RUN_ID']}",
    data=json.dumps(body).encode(), method="PATCH",
    headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"],
             "Accept": "application/vnd.github+json", "Content-Type": "application/json"})
with urllib.request.urlopen(request, timeout=60) as response:
    if response.status != 200:
        raise RuntimeError("Private execution diagnostic publication failed.")
PY
  local diagnostic_result=$?
  if [[ "$result" -eq 0 && "$diagnostic_result" -ne 0 ]]; then result=$diagnostic_result; fi
  exit "$result"
}
if [[ "${1:-}" != "--tools-check" ]]; then
  trap report EXIT

  if [[ ! "$ATO_REVISION" =~ ^[a-f0-9]{40}$ || ! "$ATO_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Invalid pinned job source." >&2
    exit 1
  fi
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "The deployment-tools container must run as container root, without host privileges." >&2
  exit 1
fi

missing=()
command -v pwsh >/dev/null || missing+=(powershell)
command -v az >/dev/null || missing+=(azure-cli)
command -v skopeo >/dev/null || missing+=(skopeo)
command -v jq >/dev/null || missing+=(jq)
command -v git >/dev/null || missing+=(git)
if [[ ${#missing[@]} -gt 0 ]]; then
  for file in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do
    if [[ -f "$file" ]]; then sed -i 's#http://#https://#g' "$file"; fi
  done
  curl -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/microsoft-packages.deb
  dpkg -i /tmp/microsoft-packages.deb
  rm /tmp/microsoft-packages.deb
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/ato-microsoft.gpg
  chmod 0644 /usr/share/keyrings/ato-microsoft.gpg
  printf '%s\n' 'deb [arch=amd64 signed-by=/usr/share/keyrings/ato-microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ bookworm main' > /etc/apt/sources.list.d/ato-azure-cli.list
  chmod 0644 /etc/apt/sources.list.d/ato-azure-cli.list
  for file in /etc/apt/sources.list.d/yarn.list /etc/apt/sources.list.d/yarn.sources; do
    if [[ -f "$file" ]]; then mv "$file" "$file.disabled"; fi
  done
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
fi
if ! command -v azd >/dev/null; then
  curl -fsSL https://aka.ms/install-azd.sh -o /tmp/ato-install-azd.sh
  bash /tmp/ato-install-azd.sh --version 1.37.3
  rm /tmp/ato-install-azd.sh
fi
az bicep install --version v0.48.1 --only-show-errors
if ! az containerapp --help >/dev/null 2>&1; then
  az extension add --name containerapp --only-show-errors
fi
if [[ "${1:-}" == "--tools-check" ]]; then
  pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
  az version
  azd version
  skopeo --version
  echo "Pinned worker image tool bootstrap verified; no Azure authentication or deployment performed."
  exit 0
fi
az login --identity --client-id "$AZURE_CLIENT_ID" --only-show-errors -o none
az account set --subscription 9fd780c4-e4ec-4204-83b9-cedca2c91b8e
azd auth login --managed-identity --client-id "$AZURE_CLIENT_ID" --no-prompt

mkdir -p /workspace
git clone --filter=blob:none --no-checkout "https://github.com/$ATO_REPOSITORY.git" /workspace/scenario
git -C /workspace/scenario checkout --detach "$ATO_REVISION"
if [[ "$(git -C /workspace/scenario rev-parse HEAD)" != "$ATO_REVISION" ]]; then exit 1; fi
cd /workspace/scenario
export ATO_ADAPTER_ROOT=/workspace/scenario/ai-agent
export ATO_IMAGE_ARTIFACT_PATH=/workspace/images
if [[ "$ATO_PHASE" == Provision || "$ATO_PHASE" == Publish ]]; then
  pwsh -NoProfile -File ai-agent/Invoke-AiAgent.ps1 -Mode Prepare -OutputPath /workspace/deployment
  if ! python -c 'import azure.identity, azure.appconfiguration' >/dev/null 2>&1; then
    python -m pip install --no-cache-dir -r /workspace/deployment/agent-landing-zone/config/requirements.txt
  fi
fi

case "$ATO_PHASE" in
  Provision)
    pwsh -NoProfile -File ai-agent/Invoke-AiAgent.ps1 -Mode Deploy -Phase Provision -OutputPath /workspace/deployment
    ;;
  Publish)
    python ai-agent/Agent-Images.py download --directory "$ATO_IMAGE_ARTIFACT_PATH"
    pwsh -NoProfile -File ai-agent/Invoke-AiAgent.ps1 -Mode Deploy -Phase Publish -OutputPath /workspace/deployment
    pwsh -NoProfile -File ai-agent/Invoke-AiAgent.ps1 -Mode Deploy -Phase Verify -OutputPath /workspace/deployment
    ;;
  Verify)
    echo "Verification must follow publication in the same private execution." >&2
    exit 1
    ;;
  Handoff)
    printf '%s' "$UI_OAUTH_CLIENT_SECRET" | az keyvault secret set --vault-name kv-agent-9fd780c4-ita --name ui-oauth-client-secret --file /dev/stdin --encoding utf-8 --expires "$UI_OAUTH_EXPIRES" --only-show-errors -o none
    printf '%s' "$CHAINLIT_AUTH_SECRET" | az keyvault secret set --vault-name kv-agent-9fd780c4-ita --name chainlit-auth-secret --file /dev/stdin --encoding utf-8 --only-show-errors -o none
    unset UI_OAUTH_CLIENT_SECRET CHAINLIT_AUTH_SECRET
    ;;
  *)
    echo "Unsupported private deployment phase." >&2
    exit 1
    ;;
esac
