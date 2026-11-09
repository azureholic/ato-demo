#Requires -Version 7.4
<#
.SYNOPSIS
  Deploys the platform jumpbox: a hub subnet, Bastion Developer and a Windows Server VM with a full desktop.
.DESCRIPTION
  Validate  Compile the templates. No Azure calls.
  Deploy    Firewall egress rules for the jumpbox subnet, then the subnet/NSG/VM/Bastion Developer, then wait until the
            VM is running. Nothing is installed or run inside the VM; install what you need yourself.
  Check     Report whether the VM exists and is running (Azure control plane only).
  The local administrator password comes from JUMPBOX_ADMIN_PASSWORD and is read by the bicepparam file, so it is never
  written to a parameter file or passed on a command line. Connect with Bastion Developer (RDP) from the Azure portal.
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
if (@($config.egressFqdns).Count -eq 0) {
    throw 'Configure the allowed egress FQDNs.'
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

function Wait-JumpboxRunning {
    $deadline = (Get-Date).AddMinutes(20)
    do {
        $view = (Invoke-CheckedCommand az @(
            'vm', 'get-instance-view', '--subscription', $config.subscriptionId,
            '--resource-group', $config.resourceGroupName, '--name', $config.vm.name, '--output', 'json'
        ) | Out-String) | ConvertFrom-Json
        $running = @($view.instanceView.statuses | Where-Object { $_.code -eq 'PowerState/running' }).Count -gt 0
        if ($running -and $view.provisioningState -eq 'Succeeded') { break }
        Start-Sleep -Seconds 20
    } while ((Get-Date) -lt $deadline)
    if (-not $running) { throw "VM $($config.vm.name) is not running (provisioning state $($view.provisioningState))." }
    if ($view.provisioningState -ne 'Succeeded') {
        Write-Warning "VM $($config.vm.name) is running but still reports provisioning state $($view.provisioningState); platform policy extensions may still be installing."
    }
    $ip = (Invoke-CheckedCommand az @(
        'network', 'nic', 'show', '--subscription', $config.subscriptionId, '--resource-group', $config.resourceGroupName,
        '--name', "nic-$($config.vm.name)", '--query', 'ipConfigurations[0].privateIPAddress', '--output', 'tsv'
    ) | Out-String).Trim()
    Write-Host "VM $($config.vm.name) is running ($($config.vm.image.sku), $($config.vm.size)) at $ip."
}

$templates = Build-Templates
if ($Mode -eq 'Validate') {
    # Compiled parameters embed secure values, so use a placeholder and keep the output out of the repository.
    $saved = $env:JUMPBOX_ADMIN_PASSWORD
    $env:JUMPBOX_ADMIN_PASSWORD = 'Validate-only-1!'
    try {
        Invoke-CheckedCommand az @('bicep', 'build-params', '--file', (Join-Path $configRoot 'jumpbox.bicepparam'), '--outfile', (Join-Path $OutputPath 'jumpbox.parameters.json'))
    } finally {
        $env:JUMPBOX_ADMIN_PASSWORD = $saved
        Remove-Item (Join-Path $OutputPath 'jumpbox.parameters.json') -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'Jumpbox templates compiled; no Azure resources changed.'
    return
}

if ($Mode -eq 'Check') {
    Wait-JumpboxRunning
    return
}

$password = $env:JUMPBOX_ADMIN_PASSWORD
if ([string]::IsNullOrWhiteSpace($password) -or $password.Length -lt 14 -or $password.Length -gt 123 -or
    @('[a-z]', '[A-Z]', '\d', '[^a-zA-Z0-9]' | Where-Object { $password -match $_ }).Count -lt 4) {
    throw 'Set JUMPBOX_ADMIN_PASSWORD to a 14-123 character password with upper, lower, digit and special characters.'
}

# Firewall rules first so the VM's downloads can pass the firewall from first boot.
Invoke-CheckedCommand az @(
    'deployment', 'group', 'create', '--subscription', $config.subscriptionId,
    '--resource-group', $config.hub.resourceGroupName, '--name', 'platform-jumpbox-egress',
    '--template-file', $templates['jumpbox-egress'], '--mode', 'Incremental', '--output', 'none'
)
Invoke-CheckedCommand az @(
    'deployment', 'sub', 'create', '--subscription', $config.subscriptionId, '--location', $config.location,
    '--name', 'platform-jumpbox', '--parameters', (Join-Path $configRoot 'jumpbox.bicepparam'), '--output', 'none'
)
Write-Host "Deployed jumpbox $($config.vm.name) in $($config.hub.vnetName)/$($config.subnet.name); connect with Bastion Developer (RDP) from the Azure portal."
Wait-JumpboxRunning
