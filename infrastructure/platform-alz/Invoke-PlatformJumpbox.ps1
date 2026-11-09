#Requires -Version 7.4
<#
.SYNOPSIS
  Deploys the platform jumpbox: a hub subnet, Bastion Developer and a Windows Server desktop VM that can reach private APIM and Foundry.
.DESCRIPTION
  Validate  Compile the templates. No Azure calls.
  Deploy    Firewall egress rules for the jumpbox subnet, then the subnet/NSG/VM/Bastion Developer, then the tools install
            (Azure CLI and the hub-check helper, idempotent), then Check.
  Check     From inside the VM (Azure run command, no Bastion needed) verify the configured endpoints resolve to
            private addresses and answer over HTTPS.
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

function Invoke-VmScript {
    param([string]$ScriptPath)
    $global:LASTEXITCODE = 0
    $raw = & az vm run-command invoke --subscription $config.subscriptionId --resource-group $config.resourceGroupName `
        --name $config.vm.name --command-id RunPowerShellScript --scripts "@$ScriptPath" --query 'value[0].message' --output tsv
    if ($LASTEXITCODE -ne 0) { throw "Run command on $($config.vm.name) failed with exit code $LASTEXITCODE." }
    return ($raw -join "`n")
}

function Install-JumpboxTools {
    $targets = (@($config.connectivityTargets) | ForEach-Object { "'$_'" }) -join ','
    $script = (Get-Content (Join-Path $configRoot 'jumpbox-tools.ps1') -Raw).Replace('__TARGETS__', $targets)
    $path = Join-Path $OutputPath 'jumpbox-tools.rendered.ps1'
    Set-Content $path $script
    $text = Invoke-VmScript $path
    if ($text -notmatch 'azure-cli installed') { throw "The jumpbox tools were not installed:`n$text" }
    Write-Host ($text -split "`n" | Where-Object { $_ -match 'azure-cli installed' } | Select-Object -Last 1).Trim()
}

function Test-JumpboxConnectivity {
    $path = Join-Path $OutputPath 'jumpbox-check.ps1'
    Set-Content $path "& 'C:\ProgramData\jumpbox\hub-check.ps1'"
    $text = Invoke-VmScript $path
    $lines = @($text -split "`n" | Where-Object { $_ -match '\[(private|PUBLIC|unresolved)\]' })
    $lines | ForEach-Object { Write-Host $_.Trim() }
    if ($lines.Count -ne @($config.connectivityTargets).Count) {
        throw "Expected a result for each of $(@($config.connectivityTargets).Count) endpoints but got $($lines.Count). The tools install may not have run.`n$text"
    }
    $bad = @($lines | Where-Object { $_ -notmatch '\[private\]' -or $_ -match '=> 000' })
    if ($bad.Count -gt 0) {
        throw "Not every endpoint is privately reachable from the jumpbox:`n$($bad -join "`n")"
    }
    Write-Host 'Verified from the jumpbox: every endpoint resolves privately and answers over HTTPS.'
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
    Test-JumpboxConnectivity
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
Install-JumpboxTools
Test-JumpboxConnectivity
