#Requires -Version 7.4
<#
.SYNOPSIS
  Deploys the platform jumpbox: a hub subnet, Bastion Developer and an Ubuntu VM that can reach private APIM and Foundry.
.DESCRIPTION
  Validate  Compile the templates. No Azure calls.
  Deploy    Firewall egress rules for the jumpbox subnet, then the subnet/NSG/VM/Bastion Developer, then the Azure CLI
            install (idempotent), then Check. Do not edit jumpbox-cloud-init.yaml on an existing VM: Azure rejects
            customData changes; put new tooling in jumpbox-tools.sh instead.
  Check     From inside the VM (Azure run command, no Bastion needed) verify the configured endpoints resolve to
            private addresses and answer over HTTPS.
  The administrator SSH public key comes from JUMPBOX_SSH_PUBLIC_KEY; password authentication is disabled.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath,

    [ValidateSet('Validate', 'Deploy', 'Check')]
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

$configRoot = Join-Path $PSScriptRoot 'config'
$config = Get-Content (Join-Path $configRoot 'jumpbox.json') -Raw | ConvertFrom-Json
$settings = Get-Content (Join-Path $configRoot 'templates' 'smb.json') -Raw | ConvertFrom-Json
if ($config.subscriptionId -ne $settings.subscriptionId -or $config.location -ne $settings.location) {
    throw 'The jumpbox must target the configured platform subscription and location.'
}
if ($config.subnet.addressPrefix -notmatch '^10\.100\.\d{1,3}\.\d{1,3}/(2[4-9])$') {
    throw 'The jumpbox subnet must be a /24-/29 inside the hub address space.'
}
if (@($config.connectivityTargets).Count -eq 0 -or @($config.egressFqdns).Count -eq 0) {
    throw 'Configure the endpoints to verify and the allowed egress FQDNs.'
}

New-Item $OutputPath -ItemType Directory -Force | Out-Null

function Build-Templates {
    $built = @{}
    foreach ($name in 'jumpbox', 'jumpbox-egress') {
        $built[$name] = Join-Path $OutputPath "$name.json"
        Invoke-CheckedCommand az @('bicep', 'build', '--file', (Join-Path $configRoot "$name.bicep"), '--outfile', $built[$name])
    }
    return $built
}

function Install-JumpboxTools {
    $global:LASTEXITCODE = 0
    $result = & az vm run-command invoke --subscription $config.subscriptionId --resource-group $config.resourceGroupName `
        --name $config.vm.name --command-id RunShellScript --scripts "@$(Join-Path $configRoot 'jumpbox-tools.sh')" `
        --query 'value[0].message' --output tsv
    if ($LASTEXITCODE -ne 0) { throw "Installing tools on $($config.vm.name) failed with exit code $LASTEXITCODE." }
    $text = $result -join "`n"
    if ($text -notmatch 'azure-cli (already )?installed') { throw "The Azure CLI is not installed on the jumpbox:`n$text" }
    Write-Host ($text -split "`n" | Where-Object { $_ -match 'azure-cli' } | Select-Object -Last 1).Trim()
}

function Test-JumpboxConnectivity {
    $vm = $config.vm.name
    $script = 'timeout 600 cloud-init status --wait >/dev/null 2>&1; /usr/local/bin/hub-check'
    $global:LASTEXITCODE = 0
    $raw = & az vm run-command invoke --subscription $config.subscriptionId --resource-group $config.resourceGroupName `
        --name $vm --command-id RunShellScript --scripts $script --query 'value[0].message' --output tsv
    if ($LASTEXITCODE -ne 0) { throw "Run command on $vm failed with exit code $LASTEXITCODE." }
    $lines = @(($raw -join "`n") -split "`n" | Where-Object { $_ -match '\[(private|PUBLIC|unresolved)\]' })
    $lines | ForEach-Object { Write-Host $_.Trim() }
    if ($lines.Count -ne @($config.connectivityTargets).Count) {
        throw "Expected a result for each of $(@($config.connectivityTargets).Count) endpoints but got $($lines.Count). The VM bootstrap may still be running or hub-check is missing."
    }
    $bad = @($lines | Where-Object { $_ -notmatch '\[private\]' -or $_ -match '=> 000' })
    if ($bad.Count -gt 0) {
        throw "Not every endpoint is privately reachable from the jumpbox:`n$($bad -join "`n")"
    }
    Write-Host 'Verified from the jumpbox: every endpoint resolves privately and answers over HTTPS.'
}

$templates = Build-Templates
if ($Mode -eq 'Validate') {
    Write-Host 'Jumpbox templates compiled; no Azure resources changed.'
    return
}

if ($Mode -eq 'Check') {
    Test-JumpboxConnectivity
    return
}

$key = $env:JUMPBOX_SSH_PUBLIC_KEY
if ([string]::IsNullOrWhiteSpace($key) -or $key -notmatch '^ssh-(ed25519|rsa) [A-Za-z0-9+/=]+( [^\r\n]*)?$') {
    throw 'Set JUMPBOX_SSH_PUBLIC_KEY to a single-line ssh-ed25519 or ssh-rsa public key.'
}
$parameters = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{ adminPublicKey = @{ value = $key.Trim() } }
}
$parameterPath = Join-Path $OutputPath 'jumpbox.parameters.json'
$parameters | ConvertTo-Json -Depth 10 | Set-Content $parameterPath

# Firewall rules first so the VM's first-boot package installs can pass the firewall.
Invoke-CheckedCommand az @(
    'deployment', 'group', 'create', '--subscription', $config.subscriptionId,
    '--resource-group', $config.hub.resourceGroupName, '--name', 'platform-jumpbox-egress',
    '--template-file', $templates['jumpbox-egress'], '--mode', 'Incremental', '--output', 'none'
)
Invoke-CheckedCommand az @(
    'deployment', 'sub', 'create', '--subscription', $config.subscriptionId, '--location', $config.location,
    '--name', 'platform-jumpbox', '--template-file', $templates['jumpbox'],
    '--parameters', "@$parameterPath", '--output', 'none'
)
Write-Host "Deployed jumpbox $($config.vm.name) in $($config.hub.vnetName)/$($config.subnet.name); connect with Bastion Developer from the Azure portal."
Install-JumpboxTools
Test-JumpboxConnectivity
