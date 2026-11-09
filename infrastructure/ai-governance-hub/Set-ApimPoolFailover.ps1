#Requires -Version 7.4
<#
.SYNOPSIS
  Makes the Governance Hub model backend pools active/standby instead of load-balanced.
.DESCRIPTION
  The upstream template puts both Foundry instances (different regions) of a model into one pool with equal
  priority and weight, so every request goes to a random instance. Responses API conversations carry encrypted
  reasoning items that only the instance that produced them can decrypt, so a follow-up turn on the other instance
  fails with 'invalid_encrypted_content'. This gives every pool member after the first a lower priority, so the
  first member serves all traffic and the others are used only when it fails. Runs after every deploy; idempotent.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = Get-Content (Join-Path $ConfigPath 'deployment.json') -Raw | ConvertFrom-Json
if (-not [guid]::TryParse($config.subscriptionId, [ref][guid]::Empty)) { throw 'Configure a valid workload subscription.' }

function Get-ArmToken {
    $global:LASTEXITCODE = 0
    $token = & az account get-access-token --resource https://management.azure.com --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Cannot get an Azure Resource Manager token.' }
    return $token.Trim()
}

$global:LASTEXITCODE = 0
$names = @(& az apim list --subscription $config.subscriptionId --resource-group $config.resourceGroupName --query '[].name' --output json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $names.Count -ne 1) {
    throw "Expected exactly one API Management instance in $($config.resourceGroupName)."
}

$headers = @{ Authorization = "Bearer $(Get-ArmToken)"; 'Content-Type' = 'application/json' }
$base = "https://management.azure.com/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.resourceGroupName)/providers/Microsoft.ApiManagement/service/$($names[0])/backends"
$version = 'api-version=2024-05-01'

$pools = @((Invoke-RestMethod -Headers $headers -Uri "${base}?$version").value |
    Where-Object { $_.properties.PSObject.Properties['pool'] -and $_.properties.pool })
foreach ($pool in $pools) {
    $members = @($pool.properties.pool.services)
    if ($members.Count -lt 2 -or @($members.priority | Select-Object -Unique).Count -gt 1) {
        Write-Host "Backend pool $($pool.name): nothing to change."
        continue
    }
    $priority = 0
    $services = foreach ($member in $members) {
        $priority++
        @{ id = $member.id; weight = $member.weight; priority = $priority }
    }
    $body = @{ properties = @{ description = $pool.properties.description; type = 'Pool'; pool = @{ services = @($services) } } } | ConvertTo-Json -Depth 8
    Invoke-RestMethod -Method Put -Headers $headers -Uri "${base}/$($pool.name)?$version" -Body $body | Out-Null
    Write-Host "Backend pool $($pool.name): first member now serves all traffic; $($members.Count - 1) standby."
}
