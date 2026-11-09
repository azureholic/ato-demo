#Requires -Version 7.4
<#
.SYNOPSIS
  Lets the Foundry project send agent traces to the shared Application Insights resource with Microsoft Entra auth.
.DESCRIPTION
  The shared Application Insights resource disables local (key) authentication, but the upstream Agent Landing Zone
  creates the project's Application Insights connection with a key, so Foundry's server-side traces are rejected and
  the Traces view stays empty. This grants the Foundry project's managed identity Monitoring Metrics Publisher on the
  Application Insights resource and switches the account-level connection to ProjectManagedIdentity. It runs after
  provisioning (which recreates the key-based connection) and is idempotent.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = Get-Content (Join-Path $ConfigPath 'deployment.json') -Raw | ConvertFrom-Json
$runner = Get-Content (Join-Path $PSScriptRoot '..' 'github-runner' 'config' 'deployment.json') -Raw | ConvertFrom-Json
$subscription = $config.subscriptionId
$resourceGroup = $config.resourceGroupName
$metricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'

function Invoke-AzJson {
    param([string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $output = & az @Arguments --output json
    if ($LASTEXITCODE -ne 0) { throw "Trace ingestion setup 'az $($Arguments -join ' ')' failed with exit code $LASTEXITCODE." }
    return ($output | Out-String | ConvertFrom-Json)
}

$outputs = Invoke-AzJson @('deployment', 'group', 'show', '--subscription', $runner.subscriptionId, '--resource-group', $runner.resourceGroupName, '--name', 'github-runner', '--query', 'properties.outputs')
$insightsId = $outputs.appInsightsId.value
if (-not $insightsId) { throw 'The shared runner deployment must output appInsightsId.' }
$insights = Invoke-AzJson @('resource', 'show', '--ids', $insightsId)
$connectionString = $insights.properties.ConnectionString
if (-not $connectionString) { throw 'The shared Application Insights resource returned no connection string.' }

$accounts = @(Invoke-AzJson @('cognitiveservices', 'account', 'list', '--subscription', $subscription, '--resource-group', $resourceGroup, '--query', "[?kind=='AIServices'].name"))
if ($accounts.Count -ne 1) { throw "Expected exactly one Foundry account in $resourceGroup but found $($accounts.Count)." }
$accountName = $accounts[0]
$projects = @(Invoke-AzJson @('resource', 'list', '--subscription', $subscription, '--resource-group', $resourceGroup, '--resource-type', 'Microsoft.CognitiveServices/accounts/projects', '--query', '[].name'))
if ($projects.Count -ne 1) { throw "Expected exactly one Foundry project in $resourceGroup but found $($projects.Count)." }
$projectName = ($projects[0] -split '/')[-1]

$arm = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.CognitiveServices/accounts/$accountName"
$apiVersion = 'api-version=2026-03-01'
$global:LASTEXITCODE = 0
$token = (& az account get-access-token --resource https://management.azure.com --query accessToken --output tsv | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Cannot get an Azure Resource Manager token.' }
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

$project = Invoke-RestMethod -Headers $headers -Uri "$arm/projects/${projectName}?$apiVersion"
$principalId = $project.identity.principalId
if (-not $principalId) { throw "Foundry project $projectName has no system-assigned identity." }

$assigned = @(Invoke-AzJson @('role', 'assignment', 'list', '--subscription', $subscription, '--assignee', $principalId, '--scope', $insightsId, '--query', "[?roleDefinitionName=='Monitoring Metrics Publisher']"))
if ($assigned.Count -eq 0) {
    Invoke-AzJson @('role', 'assignment', 'create', '--subscription', $subscription, '--assignee-object-id', $principalId, '--assignee-principal-type', 'ServicePrincipal', '--role', $metricsPublisher, '--scope', $insightsId) | Out-Null
    Write-Host "Granted Monitoring Metrics Publisher on $($insights.name) to the Foundry project identity."
} else {
    Write-Host 'The Foundry project identity already publishes to the shared Application Insights resource.'
}

$connections = @((Invoke-RestMethod -Headers $headers -Uri "$arm/connections?$apiVersion").value | Where-Object { $_.properties.category -eq 'AppInsights' })
if ($connections.Count -gt 1) { throw 'A Foundry account may have only one Application Insights connection.' }
$name = if ($connections.Count -eq 1) { $connections[0].name } else { "$accountName-appinsights-connection" }
if ($connections.Count -eq 1 -and $connections[0].properties.authType -eq 'ProjectManagedIdentity' -and $connections[0].properties.target -eq $insightsId) {
    Write-Host "Application Insights connection $name already uses the project managed identity."
    return
}

$body = @{
    properties = @{
        category = 'AppInsights'
        target = $insightsId
        authType = 'ProjectManagedIdentity'
        isSharedToAll = $true
        metadata = @{ ApiType = 'Azure'; ResourceId = $insightsId; ApplicationInsightsConnectionString = $connectionString }
    }
} | ConvertTo-Json -Depth 6
Invoke-RestMethod -Method Put -Headers $headers -Uri "$arm/connections/${name}?$apiVersion" -Body $body | Out-Null
Write-Host "Application Insights connection $name now uses the project managed identity; role assignments can take a few minutes to apply."
