#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')]
    [string]$SecurityContactEmail,

    [string]$SubscriptionId = $env:ARM_SUBSCRIPTION_ID,

    [string]$TenantId = $env:ARM_TENANT_ID,

    [string]$OutputPath = (Join-Path $PSScriptRoot '..\output'),

    [switch]$Bootstrap
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($setting in @{ SubscriptionId = $SubscriptionId; TenantId = $TenantId }.GetEnumerator()) {
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse($setting.Value, [ref]$parsedId) -or $parsedId -eq [guid]::Empty) {
        throw "$($setting.Key) must be a non-empty GUID. Supply the parameter or its ARM_SUBSCRIPTION_ID / ARM_TENANT_ID environment variable."
    }
}

function Install-RequiredModule {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$RequiredVersion
    )

    $module = Get-Module -ListAvailable -Name $Name
    if ($RequiredVersion) {
        $module = $module | Where-Object Version -eq ([version]$RequiredVersion)
    }
    if (-not $module) {
        if (-not (Get-PSRepository | Where-Object Name -eq 'PSGallery')) {
            Register-PSRepository -Default -ErrorAction Stop
        }
        $install = @{
            Name        = $Name
            Scope       = 'CurrentUser'
            Repository  = 'PSGallery'
            Force       = $true
            ErrorAction = 'Stop'
        }
        if ($RequiredVersion) {
            $install.RequiredVersion = $RequiredVersion
        }
        Write-Host "Installing required PowerShell module: $Name $RequiredVersion"
        Install-Module @install
    }
}

function Install-RequiredCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$PackageId
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        if (-not $IsWindows) {
            throw "Install $Name before bootstrap on this operating system."
        }
        Get-Command winget -ErrorAction Stop | Out-Null
        Write-Host "Installing required command: $Name ($PackageId)"
        & winget install --id $PackageId --exact --source winget --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            throw "Installation of $PackageId failed with exit code $LASTEXITCODE."
        }
        $env:PATH = "$env:PATH;$([Environment]::GetEnvironmentVariable('PATH', 'Machine'));$([Environment]::GetEnvironmentVariable('PATH', 'User'))"
        Get-Command $Name -ErrorAction Stop | Out-Null
    }
}

Install-RequiredModule -Name powershell-yaml
Import-Module powershell-yaml -ErrorAction Stop
$alzRoot = Split-Path $PSScriptRoot -Parent
$outputDirectory = [IO.Path]::GetFullPath($OutputPath)
$resolvedConfigDirectory = Join-Path $outputDirectory 'config'
$targetDirectory = Join-Path $outputDirectory 'local-output'

$inputs = Get-Content (Join-Path $alzRoot 'config\inputs.yaml') -Raw | ConvertFrom-Yaml
$inputs.bootstrap_subscription_id = $SubscriptionId
$inputs.subscription_ids.management = $SubscriptionId
$inputs.subscription_ids.connectivity = $SubscriptionId
if ([string]::IsNullOrWhiteSpace($inputs.root_parent_management_group_id)) {
    $inputs.root_parent_management_group_id = $TenantId
}
$inputs.target_directory = $targetDirectory
$tfvars = Get-Content (Join-Path $alzRoot 'config\platform-landing-zone.tfvars') -Raw
$tfvars = $tfvars.Replace('__SECURITY_CONTACT_EMAIL__', $SecurityContactEmail)

New-Item -ItemType Directory -Path $resolvedConfigDirectory -Force | Out-Null
$inputsPath = Join-Path $resolvedConfigDirectory 'inputs.json'
$tfvarsPath = Join-Path $resolvedConfigDirectory 'platform-landing-zone.tfvars'
$inputs | ConvertTo-Json -Depth 30 | Set-Content $inputsPath -Encoding utf8
$tfvars | Set-Content $tfvarsPath -Encoding utf8
Write-Host "Prepared configuration in $resolvedConfigDirectory"

if (-not $Bootstrap) {
    Write-Host 'No Azure changes made. Add -Bootstrap to run the accelerator.'
    return
}

Install-RequiredCommand -Name az -PackageId Microsoft.AzureCLI
Install-RequiredCommand -Name git -PackageId Git.Git
$accountJson = & az account show --output json
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI authentication is required. Run az login first.'
}
$account = $accountJson | ConvertFrom-Json
if ($account.id -ne $inputs.bootstrap_subscription_id) {
    throw "Select subscription $($inputs.bootstrap_subscription_id) with az account set before bootstrapping."
}
if ($account.tenantId -ne $TenantId) {
    throw 'The Azure CLI tenant does not match TenantId. Authenticate to the configured tenant before bootstrapping.'
}
$env:ARM_SUBSCRIPTION_ID = $inputs.bootstrap_subscription_id
$env:ARM_TENANT_ID = $TenantId

Install-RequiredModule -Name ALZ -RequiredVersion 7.1.5
Import-Module ALZ -RequiredVersion 7.1.5 -ErrorAction Stop
Deploy-Accelerator `
    -inputConfigFilePaths @($inputsPath, $tfvarsPath) `
    -output_folder_path $outputDirectory `
    -bootstrap_module_version 'v7.3.2' `
    -starter_module_version 'v17.6.0' `
    -terraform_version '1.14.9' `
    -skip_alz_module_version_requirements_check `
    -auto_approve

if (-not (Test-Path (Join-Path $targetDirectory 'terraform.tf'))) {
    throw "Bootstrap did not produce the Terraform starter in $targetDirectory."
}
Write-Host "Bootstrap complete. Landing zone files: $targetDirectory"
Write-Host 'The landing zone itself has NOT been deployed.'
