#Requires -Version 7.4
<#
.SYNOPSIS
  Makes the Governance Hub API Management gateway private-endpoint-only.
.DESCRIPTION
  Azure cannot disable APIM public network access during creation; it must be done on an existing
  instance that already has an approved private endpoint. This runs after provisioning: it verifies the
  private endpoint and the shared platform DNS record, disables public network access, waits for it to
  apply, and checks that the public gateway rejects callers. It is idempotent and changes nothing else.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config'),

    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 1800,

    [ValidateRange(1, 60)]
    [int]$PollIntervalSeconds = 20,

    [ValidateRange(0, 3600)]
    [int]$ProbeTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = Get-Content (Join-Path $ConfigPath 'deployment.json') -Raw | ConvertFrom-Json
$dns = Get-Content (Join-Path $PSScriptRoot '..' 'platform-alz' 'config' 'private-dns.json') -Raw | ConvertFrom-Json
$subscription = [guid]$config.subscriptionId
if ($subscription -eq [guid]::Empty) { throw 'Configure a nonempty workload subscription.' }
$resourceGroup = $config.resourceGroupName
$zoneName = $dns.zones.apimGateway
if (-not $zoneName) { throw 'The shared DNS configuration must define the apimGateway zone.' }

function Invoke-ApimCommand {
    param([string[]]$Arguments)
    $global:LASTEXITCODE = 0
    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "APIM private access operation 'az $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

$common = @('--subscription', "$subscription", '--resource-group', $resourceGroup)
$names = @(Invoke-ApimCommand (@('apim', 'list') + $common + @('--query', '[].name', '--output', 'json')) | ConvertFrom-Json)
if ($names.Count -ne 1) {
    throw "Expected exactly one API Management instance in $resourceGroup but found $($names.Count)."
}
$name = $names[0]
$query = '{sku:sku.name,state:provisioningState,publicNetworkAccess:publicNetworkAccess,gatewayUrl:gatewayUrl,endpoints:privateEndpointConnections[].privateLinkServiceConnectionState.status}'
function Get-Apim {
    Invoke-ApimCommand (@('apim', 'show') + $common + @('--name', $name, '--query', $query, '--output', 'json')) | ConvertFrom-Json
}

$apim = Get-Apim
if ($apim.sku -cnotmatch 'V2$') { throw "API Management $name must be a v2 tier for the supported private endpoint design." }
if (@($apim.endpoints | Where-Object { $_ -ceq 'Approved' }).Count -eq 0) {
    throw "API Management $name has no approved private endpoint connection; refusing to disable public access."
}
$addresses = @(Invoke-ApimCommand @(
    'network', 'private-dns', 'record-set', 'a', 'show', '--subscription', $dns.subscriptionId,
    '--resource-group', $dns.resourceGroupName, '--zone-name', $zoneName, '--name', $name,
    '--query', 'aRecords[].ipv4Address', '--output', 'json'
) | ConvertFrom-Json)
if ($addresses.Count -eq 0 -or @($addresses | Where-Object { $_ -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' }).Count -gt 0) {
    throw "The shared zone $zoneName must hold a private A record for $name before public access is disabled; deploy platform DNS and check the private endpoint's DNS zone group."
}

if ($apim.publicNetworkAccess -cne 'Disabled') {
    $body = Join-Path ([IO.Path]::GetTempPath()) "apim-private-$([guid]::NewGuid()).json"
    try {
        Set-Content $body '{"properties":{"publicNetworkAccess":"Disabled"}}'
        Invoke-ApimCommand @(
            'rest', '--method', 'patch', '--body', "@$body", '--output', 'none', '--url',
            "https://management.azure.com/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/${name}?api-version=2024-06-01-preview"
        ) | Out-Null
    } finally {
        Remove-Item $body -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds $PollIntervalSeconds
        $apim = Get-Apim
        if ($apim.publicNetworkAccess -ceq 'Disabled' -and $apim.state -ceq 'Succeeded') { break }
    } while ((Get-Date) -lt $deadline)
    if ($apim.publicNetworkAccess -cne 'Disabled' -or $apim.state -cne 'Succeeded') {
        throw "API Management public access disable propagation timeout; state is $($apim.state), publicNetworkAccess $($apim.publicNetworkAccess)."
    }
}
Write-Host "API Management $name has public network access disabled and a private DNS record in $zoneName."

# Data-plane evidence from outside the VNet. A caller inside the VNet legitimately gets through, so this only warns.
$closed = $false
$deadline = (Get-Date).AddSeconds($ProbeTimeoutSeconds)
do {
    try {
        $response = Invoke-WebRequest -Uri "$($apim.gatewayUrl)/" -SkipHttpErrorCheck -TimeoutSec 30 -UseBasicParsing
        if ([string]$response.Content -match 'public network access on this .* is disabled') { $closed = $true; break }
    } catch {
        # An unreachable gateway from this network does not prove the setting applied; keep polling.
    }
    if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds $PollIntervalSeconds }
} while ((Get-Date) -lt $deadline)
if ($closed) {
    Write-Host 'Verified: the public gateway endpoint rejects callers outside the private network.'
} else {
    Write-Warning 'Could not observe the public gateway rejecting callers from this network (it may be inside the VNet, or propagation is slow). The management-plane setting is Disabled.'
}
