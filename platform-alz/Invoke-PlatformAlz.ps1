#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

foreach ($name in 'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID') {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Missing environment variable: $name."
    }
}
Get-Command az, bicep, Deploy-Accelerator -ErrorAction Stop | Out-Null
Import-Module powershell-yaml -RequiredVersion 0.4.12
$inputsPath = Join-Path $PSScriptRoot 'config\inputs.yaml'
$config = Get-Content $inputsPath -Raw | ConvertFrom-Yaml
$platformConfig = Get-Content (Join-Path $PSScriptRoot 'config\platform-landing-zone.yaml') -Raw | ConvertFrom-Yaml
$settings = Get-Content (Join-Path $PSScriptRoot 'config\templates\smb.json') -Raw | ConvertFrom-Json
if ($config.iac_type -ne 'bicep' -or $config.create_bootstrap_resources_in_azure -ne $false -or
    $settings.tenantId -ne $config.root_parent_management_group_id -or
    $settings.subscriptionId -ne $config.bootstrap_subscription_id -or
    $settings.subscriptionId -ne $config.subscription_ids.management -or
    $settings.subscriptionId -ne $config.subscription_ids.connectivity -or
    $platformConfig.network_type -ne 'hubNetworking' -or
    $platformConfig.management_group_id_prefix -ne '' -or
    $platformConfig.management_group_id_postfix -ne '' -or
    $platformConfig.starter_locations.Count -ne 1 -or
    $settings.location -ne $platformConfig.starter_locations[0] -or
    $settings.location -ne $config.bootstrap_location -or
    $settings.intermediateRootManagementGroupId -ne $platformConfig.management_group_int_root_id) {
    throw 'Bicep bootstrap, platform inputs and SMB parameters must describe the same single-subscription environment without Azure bootstrap creation.'
}
$account = (& az account show --output json) | ConvertFrom-Json
if ($account.tenantId -ne $env:ARM_TENANT_ID -or $account.id -ne $env:ARM_SUBSCRIPTION_ID -or
    $account.tenantId -ne $config.root_parent_management_group_id -or
    $account.id -ne $config.bootstrap_subscription_id) {
    throw 'Azure login and environment must match the repository tenant and subscription configuration.'
}

$outputDirectory = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path $outputDirectory) {
    throw 'Use a fresh output directory. Generated bootstrap files must not reuse the preserved bootstrap state.'
}
$previousTarget = $env:ALZ_target_directory
$previousInitArguments = $env:TF_CLI_ARGS_init
try {
    $env:ALZ_target_directory = Join-Path $outputDirectory 'platform'
    $env:TF_CLI_ARGS_init = $null
    Deploy-Accelerator -inputConfigFilePaths @(
        $inputsPath
        (Join-Path $PSScriptRoot 'config\platform-landing-zone.yaml')
    ) -starter_additional_files @(
        (Join-Path $PSScriptRoot 'config\templates')
    ) -output $outputDirectory -autoApprove

    $platformDirectory = $env:ALZ_target_directory
    $deployScript = Join-Path $platformDirectory 'scripts\deploy-local.ps1'
    if (-not (Test-Path $deployScript -PathType Leaf)) {
        throw 'The Accelerator did not generate the expected official local deployment script.'
    }

    $parameterRoot = Join-Path $PSScriptRoot 'config\templates'
    foreach ($file in Get-ChildItem $parameterRoot -Filter '*.bicepparam' -Recurse) {
        $relativePath = [IO.Path]::GetRelativePath($parameterRoot, $file.FullName)
        $generatedPath = Join-Path $platformDirectory "templates\$relativePath"
        $build = ((& bicep build-params $generatedPath --stdout) -join [Environment]::NewLine) | ConvertFrom-Json
        foreach ($property in 'templateJson', 'parametersJson') {
            if ([string]::IsNullOrWhiteSpace($build.$property) -or
                [Text.Encoding]::UTF8.GetByteCount($build.$property) -gt 4MB) {
                throw "Invalid or oversized Bicep $property for $relativePath."
            }
        }
    }

    Push-Location $platformDirectory
    try {
        # The pinned Bicep script uses Read-Host, not Terraform's auto_approve switch.
        'yes' | & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -InputFormat Text -OutputFormat Text -Command '
            $ErrorActionPreference = "Stop"
            $PSNativeCommandUseErrorActionPreference = $true
            $global:LASTEXITCODE = 0
            & (Join-Path $env:ALZ_target_directory "scripts\deploy-local.ps1") -Verbose:$false
            exit $LASTEXITCODE
        '
    } finally {
        Pop-Location
    }
} finally {
    $env:TF_CLI_ARGS_init = $previousInitArguments
    $env:ALZ_target_directory = $previousTarget
}
