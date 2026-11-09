#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-CheckedCommand {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

$dns = Get-Content (Join-Path $PSScriptRoot 'config\private-dns.json') -Raw | ConvertFrom-Json
$settings = Get-Content (Join-Path $PSScriptRoot 'config\templates\smb.json') -Raw | ConvertFrom-Json
if ($dns.subscriptionId -ne $settings.subscriptionId -or $dns.location -ne $settings.location) {
    throw 'Shared DNS must target the configured platform subscription and location.'
}
New-Item $OutputPath -ItemType Directory -Force | Out-Null
$templatePath = Join-Path $OutputPath 'private-dns.template.json'
Invoke-CheckedCommand az @(
    'bicep', 'build', '--file', (Join-Path $PSScriptRoot 'config\private-dns.bicep'),
    '--outfile', $templatePath
)
if ($ValidateOnly) { return }

$virtualNetworkIds = [Collections.Generic.List[string]]::new()
foreach ($subscriptionId in ($dns.virtualNetworkSubscriptionIds | Select-Object -Unique)) {
    $vnets = Invoke-CheckedCommand az @('network', 'vnet', 'list', '--subscription', $subscriptionId, '--output', 'json')
    foreach ($vnet in ($vnets | ConvertFrom-Json)) {
        if ($vnet.id -in $dns.excludedVirtualNetworkIds) { continue }
        $dhcpOptions = $vnet.PSObject.Properties['dhcpOptions']
        if ($null -ne $dhcpOptions -and $null -ne $dhcpOptions.Value) {
            $dnsServers = $dhcpOptions.Value.PSObject.Properties['dnsServers']
            if ($null -ne $dnsServers -and $null -ne $dnsServers.Value -and @($dnsServers.Value).Count -gt 0) {
                throw "VNet $($vnet.id) uses custom DNS; direct zone links alone cannot provide resolver-free DNS."
            }
        }
        $virtualNetworkIds.Add($vnet.id)
    }
}
if ($virtualNetworkIds.Count -eq 0) { throw 'No VNets found for platform DNS links after ALZ deployment.' }
$parameters = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        zoneNames = @{ value = @($dns.zones.PSObject.Properties.Value | Select-Object -Unique) }
        virtualNetworkIds = @{ value = @($virtualNetworkIds.ToArray() | Select-Object -Unique) }
    }
}
$parameterPath = Join-Path $OutputPath 'private-dns.parameters.json'
$parameters | ConvertTo-Json -Depth 10 | Set-Content $parameterPath
Invoke-CheckedCommand az @(
    'group', 'create', '--subscription', $dns.subscriptionId, '--name', $dns.resourceGroupName,
    '--location', $dns.location, '--output', 'none'
)
Invoke-CheckedCommand az @(
    'deployment', 'group', 'create', '--subscription', $dns.subscriptionId,
    '--resource-group', $dns.resourceGroupName, '--name', 'platform-central-dns',
    '--template-file', $templatePath, '--parameters', "@$parameterPath",
    '--mode', 'Incremental', '--output', 'none'
)
Write-Host "Provisioned shared platform DNS and links for $($virtualNetworkIds.Count) VNets."
