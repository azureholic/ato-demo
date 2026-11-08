#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$name = $env:AZURE_ENV_NAME
if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw 'A valid azd environment name is required.' }
$path = Join-Path $root ".azure\$name\.env"
$lines = [IO.File]::ReadAllLines($path)
$legacyOutputs = @('DEPLOY_HOSTED_AGENT', 'HOSTED_AGENT_PREPARED')
foreach ($key in $legacyOutputs) {
    if (@($lines | Where-Object { $_ -match "^$key=" }).Count -gt 1) { throw "Duplicate azd output $key." }
    $lines = @($lines | Where-Object { $_ -notmatch "^$key=" })
    if (Test-Path "Env:\$key") { Remove-Item "Env:\$key" }
}
[IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($false))
# The OIDC assertion from the workflow login expires within minutes; provisioning outlasts it.
if ($env:ACTIONS_ID_TOKEN_REQUEST_URL) {
    foreach ($required in 'ACTIONS_ID_TOKEN_REQUEST_TOKEN', 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID') {
        if (-not (Get-Item "Env:\$required" -ErrorAction SilentlyContinue)) { throw "$required is required to refresh the federated Azure CLI login." }
    }
    $separator = if ($env:ACTIONS_ID_TOKEN_REQUEST_URL.Contains('?')) { '&' } else { '?' }
    $assertion = (Invoke-RestMethod -Uri "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)${separator}audience=api://AzureADTokenExchange" -Headers @{ Authorization = "bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)" }).value
    if (-not $assertion) { throw 'GitHub did not return an OIDC token.' }
    Write-Host "::add-mask::$assertion"
    az login --service-principal --username $env:AZURE_CLIENT_ID --tenant $env:AZURE_TENANT_ID --federated-token $assertion --allow-no-subscriptions --output none
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI federated login refresh failed.' }
    az account set --subscription $env:AZURE_SUBSCRIPTION_ID
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI subscription selection failed after login refresh.' }
}
if ($IsWindows) {
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'postProvision.ps1')
} else {
    & bash (Join-Path $PSScriptRoot 'postProvision.sh')
}
if ($LASTEXITCODE -ne 0) { throw "Upstream postprovision failed with exit code $LASTEXITCODE." }
