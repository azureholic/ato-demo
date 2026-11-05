#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SubscriptionId = $env:ARM_SUBSCRIPTION_ID,
    [string]$TenantId = $env:ARM_TENANT_ID,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\output\bicep')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$alzRoot = Split-Path $PSScriptRoot -Parent
$settings = Get-Content (Join-Path $alzRoot 'config\demo.json') -Raw | ConvertFrom-Json
if (-not $PSBoundParameters.ContainsKey('SubscriptionId') -and [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = $settings.subscriptionId
}
if (-not $PSBoundParameters.ContainsKey('TenantId') -and [string]::IsNullOrWhiteSpace($TenantId)) {
    $TenantId = $settings.tenantId
}
foreach ($setting in @{ SubscriptionId = $SubscriptionId; TenantId = $TenantId }.GetEnumerator()) {
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse($setting.Value, [ref]$parsedId) -or $parsedId -eq [guid]::Empty) {
        throw "$($setting.Key) must be a non-empty GUID."
    }
}
if ($SubscriptionId -ne $settings.subscriptionId -or $TenantId -ne $settings.tenantId) {
    throw 'The target does not match config\demo.json. Review the configuration before changing tenants or subscriptions.'
}
if ($settings.securityContactEmail -notmatch '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
    throw 'config\demo.json must contain a valid security contact email address.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    if (-not $IsWindows) { throw 'Install Azure CLI before preparing the Bicep deployment.' }
    Get-Command winget -ErrorAction Stop | Out-Null
    & winget install --id Microsoft.AzureCLI --exact --source winget --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI installation failed.' }
    $env:PATH = "$env:PATH;$([Environment]::GetEnvironmentVariable('PATH', 'Machine'));$([Environment]::GetEnvironmentVariable('PATH', 'User'))"
    Get-Command az -ErrorAction Stop | Out-Null
}
if (-not $IsWindows -or [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This local preparation script requires Windows x64, matching the GitHub-hosted runner.'
}
$bicep = Join-Path $alzRoot 'output\.tools\bicep-0.44.1.exe'
if (-not (Test-Path -LiteralPath $bicep)) {
    New-Item -ItemType Directory -Path (Split-Path $bicep -Parent) -Force | Out-Null
    Write-Host 'Downloading pinned Bicep CLI v0.44.1 into the local tool cache.'
    Invoke-WebRequest -Uri 'https://github.com/Azure/bicep/releases/download/v0.44.1/bicep-win-x64.exe' -OutFile $bicep
}
if ((Get-FileHash -LiteralPath $bicep -Algorithm SHA256).Hash -ne '5153ab5898e70f1f822e0b844ae902a5acc5692f5a6303814af7b202e1072160') {
    throw 'Bicep CLI checksum mismatch. The downloaded executable will not be run.'
}

$env:ARM_SUBSCRIPTION_ID = $SubscriptionId
$env:ARM_TENANT_ID = $TenantId
$outputDirectory = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$bicepRoot = Join-Path $alzRoot 'bicep'
$deployments = Get-Content (Join-Path $bicepRoot 'deployments.json') -Raw | ConvertFrom-Json
foreach ($entry in $deployments) {
    Write-Host "Building $($entry.name)."
    $buildJson = & $bicep build-params (Join-Path $bicepRoot "$($entry.name).bicepparam") --stdout
    if ($LASTEXITCODE -ne 0) { throw "Bicep build failed for $($entry.name)." }
    $build = ($buildJson -join [Environment]::NewLine) | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($build.templateJson) -or [string]::IsNullOrWhiteSpace($build.parametersJson)) {
        throw "Bicep did not return both template and parameters for $($entry.name)."
    }
    $build.templateJson | Set-Content (Join-Path $outputDirectory "$($entry.name).template.json") -Encoding utf8
    $build.parametersJson | Set-Content (Join-Path $outputDirectory "$($entry.name).parameters.json") -Encoding utf8
    foreach ($extension in 'template', 'parameters') {
        if ((Get-Item (Join-Path $outputDirectory "$($entry.name).$extension.json")).Length -gt 4MB) {
            throw "$($entry.name) $extension exceeds the ARM 4 MB limit."
        }
    }
}
Write-Host "Bicep templates and parameters prepared in $outputDirectory."
Write-Host 'No Azure resources were changed. No Terraform state or storage backend is needed.'
