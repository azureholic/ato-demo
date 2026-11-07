#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config'),

    [ValidateSet('Validate', 'Deploy')]
    [string]$Mode = 'Validate'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-CheckedCommand {
    param([string]$Command, [string[]]$Arguments)
    $global:LASTEXITCODE = 0
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

$configFile = Join-Path $ConfigPath 'deployment.json'
$parameterFile = Join-Path $ConfigPath 'main.bicepparam'
$config = Get-Content $configFile -Raw | ConvertFrom-Json
if ($config.upstreamRevision -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Pin upstreamRevision to a full lowercase Git commit SHA.'
}
$subscriptionId = [guid]::Empty
if (-not [guid]::TryParse($config.subscriptionId, [ref]$subscriptionId) -or
    $subscriptionId -eq [guid]::Empty) {
    throw 'subscriptionId must be a nonempty Azure subscription GUID.'
}
if ($config.environmentName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$' -or
    $config.location -notmatch '^[a-z]+$') {
    throw 'Configure a valid environmentName and Azure location.'
}
if (@($config.aiFoundryInstances).Count -ne 2) {
    throw 'This scenario requires exactly two Foundry instances for the shared model endpoint.'
}
if (-not (Test-Path $parameterFile -PathType Leaf)) {
    throw "Missing parameter overlay: $parameterFile."
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path $OutputPath) {
    throw "Use a fresh output directory; refusing to overwrite $OutputPath."
}

Invoke-CheckedCommand git @(
    'clone', '--quiet', '--no-checkout', '--filter=blob:none',
    'https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator.git', $OutputPath
)
Invoke-CheckedCommand git @('-C', $OutputPath, 'checkout', '--quiet', '--detach', $config.upstreamRevision)
$revision = Invoke-CheckedCommand git @('-C', $OutputPath, 'rev-parse', 'HEAD')
if ($revision -cne $config.upstreamRevision) {
    throw "Upstream checkout does not match $($config.upstreamRevision)."
}
$infraPath = Join-Path $OutputPath 'bicep\infra'
foreach ($relativePath in 'azure.yaml', 'bicep\infra\main.bicep', 'src\usage-ingestion-logicapp\package.json') {
    if (-not (Test-Path (Join-Path $OutputPath $relativePath) -PathType Leaf)) {
        throw "Pinned upstream is missing $relativePath; review its deployment contract."
    }
}
Copy-Item $configFile (Join-Path $infraPath 'deployment.json')
Copy-Item $parameterFile (Join-Path $infraPath 'main.bicepparam') -Force
Invoke-CheckedCommand az @(
    'bicep', 'build-params', '--file', (Join-Path $infraPath 'main.bicepparam'),
    '--outfile', (Join-Path $OutputPath 'main.parameters.json')
)
Invoke-CheckedCommand az @(
    'bicep', 'build', '--file', (Join-Path $infraPath 'main.bicep'),
    '--outfile', (Join-Path $OutputPath 'main.json')
)
$template = Get-Content (Join-Path $OutputPath 'main.json') -Raw | ConvertFrom-Json -AsHashtable
$parameters = Get-Content (Join-Path $OutputPath 'main.parameters.json') -Raw | ConvertFrom-Json -AsHashtable
if (-not $template.ContainsKey('resources') -or -not $parameters.ContainsKey('parameters')) {
    throw 'Bicep did not produce a valid ARM template and parameter document.'
}
$payload = @{
    properties = @{
        mode = 'Incremental'
        template = $template
        parameters = $parameters.parameters
    }
} | ConvertTo-Json -Depth 100 -Compress -WarningAction Stop
$payloadBytes = [Text.Encoding]::UTF8.GetByteCount($payload)
if ($payloadBytes -gt 4MB) {
    throw "Compiled ARM request exceeds the 4 MB limit ($payloadBytes bytes)."
}
Write-Host "Compiled ARM request: $payloadBytes bytes."
Write-Host "Validated upstream $revision with repository configuration."
if ($Mode -eq 'Validate') { return }

$previousLocation = Get-Location
try {
    Set-Location $OutputPath
    Invoke-CheckedCommand azd @(
        'env', 'new', $config.environmentName, '--subscription', $config.subscriptionId,
        '--location', $config.location, '--no-prompt'
    )
    Invoke-CheckedCommand azd @('provision', '--environment', $config.environmentName, '--no-prompt')
    Invoke-CheckedCommand azd @('deploy', '--environment', $config.environmentName, '--no-prompt')
} finally {
    Set-Location $previousLocation
}
