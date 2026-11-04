#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')]
    [string]$SecurityContactEmail,

    [string]$OutputPath = (Join-Path $PSScriptRoot '..\output'),

    [switch]$Bootstrap
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module powershell-yaml -ErrorAction Stop
$alzRoot = Split-Path $PSScriptRoot -Parent
$outputDirectory = [IO.Path]::GetFullPath($OutputPath)
$resolvedConfigDirectory = Join-Path $outputDirectory 'config'
$targetDirectory = Join-Path $outputDirectory 'local-output'

$inputs = Get-Content (Join-Path $alzRoot 'config\inputs.yaml') -Raw | ConvertFrom-Yaml
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

Import-Module ALZ -RequiredVersion 7.1.5 -ErrorAction Stop
foreach ($command in 'az', 'terraform', 'git') {
    Get-Command $command -ErrorAction Stop | Out-Null
}
$accountJson = & az account show --output json
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI authentication is required. Run az login first.'
}
$account = $accountJson | ConvertFrom-Json
if ($account.id -ne $inputs.bootstrap_subscription_id) {
    throw "Select subscription $($inputs.bootstrap_subscription_id) with az account set before bootstrapping."
}
$env:ARM_SUBSCRIPTION_ID = $inputs.bootstrap_subscription_id

Deploy-Accelerator `
    -inputConfigFilePaths @($inputsPath, $tfvarsPath) `
    -output_folder_path $outputDirectory `
    -bootstrap_module_version 'v7.3.2' `
    -starter_module_version 'v17.6.0' `
    -terraform_version '1.14.9' `
    -auto_approve

if (-not (Test-Path (Join-Path $targetDirectory 'terraform.tf'))) {
    throw "Bootstrap did not produce the Terraform starter in $targetDirectory."
}
Write-Host "Bootstrap complete. Landing zone files: $targetDirectory"
Write-Host 'The landing zone itself has NOT been deployed.'
