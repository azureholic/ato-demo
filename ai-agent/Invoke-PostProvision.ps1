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
if ($IsWindows) {
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'postProvision.ps1')
} else {
    & bash (Join-Path $PSScriptRoot 'postProvision.sh')
}
if ($LASTEXITCODE -ne 0) { throw "Upstream postprovision failed with exit code $LASTEXITCODE." }
