#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RepositoryRoot = Split-Path $PSScriptRoot -Parent

function Invoke-CheckedCommand {
    param([string]$Command, [string[]]$Arguments)
    $global:LASTEXITCODE = 0
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE." }
}

function Read-ScenarioConfig {
    param([string]$Path)
    $config = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($id in $config.subscriptionId, $config.networking.hub.subscriptionId) {
        $guid = [guid]::Empty
        if (-not [guid]::TryParse($id, [ref]$guid) -or $guid -eq [guid]::Empty) { throw 'Invalid subscription ID.' }
    }
    if ($config.upstreamRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'Pin upstreamRevision to a full lowercase Git SHA.' }
    return $config
}

function Copy-PinnedUpstream {
    param([hashtable]$Config, [string]$OutputPath)
    if (Test-Path $OutputPath) { throw "Use a fresh output path; refusing to overwrite $OutputPath." }
    Invoke-CheckedCommand git @('clone', '--quiet', '--no-checkout', '--filter=blob:none', $Config.upstreamRepository, $OutputPath)
    Invoke-CheckedCommand git @('-C', $OutputPath, 'checkout', '--quiet', '--detach', $Config.upstreamRevision)
    $revision = Invoke-CheckedCommand git @('-C', $OutputPath, 'rev-parse', 'HEAD')
    if ($revision -cne $Config.upstreamRevision) { throw 'Upstream checkout does not match the pinned SHA.' }
}

function Write-ArmParameters {
    param([hashtable]$Values, [string]$Path)
    $parameters = @{}
    foreach ($key in $Values.Keys) { $parameters[$key] = @{ value = $Values[$key] } }
    @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = $parameters
    } | ConvertTo-Json -Depth 100 -WarningAction Stop | Set-Content $Path
}

function Invoke-ScenarioNetwork {
    param([hashtable]$Config, [string]$OutputPath, [switch]$ValidateOnly)
    New-Item $OutputPath -ItemType Directory -Force | Out-Null
    $template = Join-Path $OutputPath 'network.json'
    Invoke-CheckedCommand az @('bicep', 'build', '--file', (Join-Path $PSScriptRoot 'infra\main.bicep'), '--outfile', $template)
    $parameters = Join-Path $OutputPath 'network.parameters.json'
    Write-ArmParameters @{ config = $Config } $parameters
    if ($ValidateOnly) { return }
    $dns = Get-Content (Join-Path $script:RepositoryRoot 'platform-alz\config\private-dns.json') -Raw | ConvertFrom-Json -AsHashtable
    $zones = Invoke-CheckedCommand az @('network', 'private-dns', 'zone', 'list', '--subscription', $dns.subscriptionId, '--resource-group', $dns.resourceGroupName, '--output', 'json') | ConvertFrom-Json
    $zoneNames = @($dns.zones.Values | Select-Object -Unique)
    $missing = @($zoneNames | Where-Object { $_ -notin $zones.name })
    if ($missing.Count) { throw "Deploy platform DNS first; missing zones: $($missing -join ', ')." }
    Invoke-CheckedCommand az @('deployment', 'sub', 'create', '--subscription', $Config.subscriptionId, '--location', $Config.location, '--name', $Config.networking.vnetName, '--template-file', $template, '--parameters', "@$parameters", '--output', 'none')
    $vnetId = "/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.networking.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($Config.networking.vnetName)"
    $links = Join-Path $OutputPath 'dns.parameters.json'
    Write-ArmParameters @{ zoneNames = $zoneNames; virtualNetworkIds = @($vnetId) } $links
    Invoke-CheckedCommand az @('deployment', 'group', 'create', '--subscription', $dns.subscriptionId, '--resource-group', $dns.resourceGroupName, '--name', "$($Config.networking.vnetName)-dns", '--template-file', (Join-Path $script:RepositoryRoot 'platform-alz\config\private-dns-links.bicep'), '--parameters', "@$links", '--mode', 'Incremental', '--output', 'none')
}

function Assert-DeploymentGate {
    if ($env:GITHUB_REF -ne 'refs/heads/main') { throw 'Deployment workflows must run from main.' }
    foreach ($name in 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID') {
        $guid = [guid]::Empty
        if (-not [guid]::TryParse([Environment]::GetEnvironmentVariable($name), [ref]$guid) -or $guid -eq [guid]::Empty) { throw "Missing or invalid $name." }
    }
    $environment = Invoke-CheckedCommand gh @('api', "repos/$env:GITHUB_REPOSITORY/environments/demo") | ConvertFrom-Json
    $reviewers = @($environment.protection_rules | Where-Object { $_.type -eq 'required_reviewers' -and @($_.reviewers).Count -gt 0 })
    if (-not $reviewers.Count) { throw 'Configure required reviewers on the demo environment.' }
}
