#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module powershell-yaml -RequiredVersion 0.4.12
$root = Split-Path $PSScriptRoot -Parent
$config = Get-Content (Join-Path $root 'config\inputs.yaml') -Raw | ConvertFrom-Yaml
$adapter = Join-Path $root 'Invoke-PlatformAlz.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "platform-alz-tests-$([guid]::NewGuid())"
$environmentNames = @(
    'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID',
    'TF_STATE_RESOURCE_GROUP', 'TF_STATE_STORAGE_ACCOUNT', 'TF_STATE_CONTAINER',
    'ALZ_target_directory', 'TF_CLI_ARGS_init'
)
$previous = @{}
foreach ($name in $environmentNames) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name)
}
$testState = @{ Mode = 'success'; GenerationCount = 0 }

function az {
    if ($args[0] -eq 'account') {
        @{
            id = if ($testState.Mode -eq 'wrong-context') { [guid]::Empty.ToString() } else { $config.bootstrap_subscription_id }
            tenantId = $config.root_parent_management_group_id
        } | ConvertTo-Json
    } else {
        throw "Unexpected Azure command: $args"
    }
}
function bicep {
    if ($testState.Mode -eq 'invalid-build') {
        @{ templateJson = ''; parametersJson = '{}' } | ConvertTo-Json
    } else {
        @{ templateJson = '{}'; parametersJson = '{}' } | ConvertTo-Json
    }
}
function Deploy-Accelerator {
    param([string[]]$inputConfigFilePaths, [string[]]$starter_additional_files, [string]$output, [switch]$autoApprove)
    if (-not $autoApprove -or $inputConfigFilePaths.Count -ne 2) {
        throw 'The adapter must pass both version-controlled inputs and enable unattended generation.'
    }
    if (-not [string]::IsNullOrEmpty($env:TF_CLI_ARGS_init)) {
        throw 'Platform backend arguments must not affect the local file-generation bootstrap.'
    }
    foreach ($path in $inputConfigFilePaths) {
        if (-not (Test-Path $path -PathType Leaf)) { throw "Missing input: $path" }
    }
    if ($starter_additional_files.Count -ne 1 -or
        -not (Test-Path (Join-Path $starter_additional_files[0] 'smb.json'))) {
        throw 'Missing version-controlled SMB parameter overrides.'
    }
    $testState.GenerationCount++
    $scriptsDirectory = Join-Path $env:ALZ_target_directory 'scripts'
    New-Item $scriptsDirectory -ItemType Directory -Force | Out-Null
    if ($testState.Mode -eq 'missing-script') { return }
    $content = if ($testState.Mode -eq 'native-failure') {
        '[CmdletBinding()]param(); exit 23'
    } else {
        @'
[CmdletBinding()]
param()
$answer = Read-Host -Prompt "Type 'yes' and hit Enter to continue with the full deployment"
if ($answer -cne 'yes') { throw 'Standard Bicep confirmation was not supplied.' }
if (-not [string]::IsNullOrEmpty($env:TF_CLI_ARGS_init)) { throw 'Bicep must not use a remote Terraform backend.' }
if ((Get-Location).Path -ne $env:ALZ_target_directory) { throw 'Wrong deployment working directory.' }
if (Test-Path backend.hcl) { throw 'Bicep must not create a state backend configuration.' }
Set-Content deployment-invoked.txt 'deployed'
'@
    }
    Set-Content (Join-Path $scriptsDirectory 'deploy-local.ps1') $content
}
function Assert-Failure {
    param([scriptblock]$Action, [string]$Expected)
    try { & $Action } catch {
        if ($_.ToString() -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected failure containing: $Expected"
}

try {
    New-Item $testRoot -ItemType Directory | Out-Null
    $env:ARM_CLIENT_ID = [guid]::NewGuid().ToString()
    $env:ARM_TENANT_ID = $config.root_parent_management_group_id
    $env:ARM_SUBSCRIPTION_ID = $config.bootstrap_subscription_id
    $env:TF_STATE_RESOURCE_GROUP = $null
    $env:TF_STATE_STORAGE_ACCOUNT = $null
    $env:TF_STATE_CONTAINER = $null
    $env:TF_CLI_ARGS_init = 'original-init-arguments'
    $env:ALZ_target_directory = 'original-target'
    $originalLocation = (Get-Location).Path

    & $adapter -OutputPath (Join-Path $testRoot 'success')
    if (-not (Test-Path (Join-Path $testRoot 'success\platform\deployment-invoked.txt'))) {
        throw 'Successful orchestration did not invoke the standard Bicep deployment script.'
    }
    Assert-Failure { & $adapter -OutputPath (Join-Path $testRoot 'success') } 'fresh output directory'
    $env:ARM_CLIENT_ID = ''
    Assert-Failure { & $adapter -OutputPath (Join-Path $testRoot 'missing-setting') } 'Missing environment variable'
    $env:ARM_CLIENT_ID = [guid]::NewGuid().ToString()
    foreach ($case in @(
        @{ Mode = 'wrong-context'; Error = 'must match the repository' }
    )) {
        $testState.Mode = $case.Mode
        Assert-Failure { & $adapter -OutputPath (Join-Path $testRoot $case.Mode) } $case.Error
    }
    if ($testState.GenerationCount -ne 1) { throw 'Generation ran despite a failed preflight.' }
    foreach ($case in @(
        @{ Mode = 'missing-script'; Error = 'did not generate' }
        @{ Mode = 'native-failure'; Error = '23' }
        @{ Mode = 'invalid-build'; Error = 'Invalid or oversized Bicep' }
    )) {
        $testState.Mode = $case.Mode
        Assert-Failure { & $adapter -OutputPath (Join-Path $testRoot $case.Mode) } $case.Error
    }
    if ((Get-Location).Path -ne $originalLocation -or
        $env:TF_CLI_ARGS_init -ne 'original-init-arguments' -or
        $env:ALZ_target_directory -ne 'original-target') {
        throw 'The adapter did not restore the caller environment and working directory.'
    }
    Write-Host 'PASS: Bicep handoff with standard-input confirmation, no state backend, preflight/build guards, native failure propagation and cleanup.'
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name])
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
