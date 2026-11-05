#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('WhatIf', 'Deploy')]
    [string]$Operation = 'WhatIf',
    [string]$Confirmation,
    [string]$SubscriptionId = $env:ARM_SUBSCRIPTION_ID,
    [string]$TenantId = $env:ARM_TENANT_ID,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\output\bicep')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Operation -eq 'Deploy' -and $Confirmation -cne 'DEPLOY') {
    throw 'Deploying requires explicit DEPLOY confirmation.'
}
$settings = Get-Content (Join-Path $PSScriptRoot '..\config\demo.json') -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { $SubscriptionId = $settings.subscriptionId }
if ([string]::IsNullOrWhiteSpace($TenantId)) { $TenantId = $settings.tenantId }
& (Join-Path $PSScriptRoot 'Initialize-Alz.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -OutputPath $OutputPath
$accountJson = & az account show --output json
if ($LASTEXITCODE -ne 0) { throw 'Authenticate with Azure CLI before running what-if or deployment.' }
$account = $accountJson | ConvertFrom-Json
if ($account.id -ne $SubscriptionId -or $account.tenantId -ne $TenantId) {
    throw 'Azure CLI context does not match the configured subscription and tenant.'
}
$outputDirectory = [IO.Path]::GetFullPath($OutputPath)
$deployments = Get-Content (Join-Path $PSScriptRoot '..\bicep\deployments.json') -Raw | ConvertFrom-Json
foreach ($entry in $deployments) {
    $name = $entry.name
    $scope = $entry.scope
    $command = if ($Operation -eq 'WhatIf') { 'what-if' } else { 'create' }
    $arguments = @(
        'deployment', $scope, $command,
        '--name', "alz-demo-$name",
        '--location', $settings.location,
        '--template-file', (Join-Path $outputDirectory "$name.template.json"),
        '--parameters', "@$(Join-Path $outputDirectory "$name.parameters.json")"
    )
    if ($scope -eq 'mg') {
        $arguments += @('--management-group-id', $settings.intermediateRootManagementGroupId)
    } else {
        $arguments += @('--subscription', $SubscriptionId)
    }
    if ($Operation -eq 'WhatIf') {
        $arguments += @('--validation-level', 'ProviderNoRbac')
    }
    Write-Host "$Operation for $name ($scope scope)."
    & az @arguments
    if ($LASTEXITCODE -ne 0) { throw "$Operation failed for $name." }
}
