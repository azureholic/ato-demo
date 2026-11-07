#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module powershell-yaml -RequiredVersion 0.4.12
Import-Module ALZ -RequiredVersion 7.1.5
$root = Split-Path $PSScriptRoot -Parent
$config = Get-Content (Join-Path $root 'config\inputs.yaml') -Raw | ConvertFrom-Yaml
$adapter = Join-Path $root 'Invoke-PlatformAlz.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "platform-alz tests-$([guid]::NewGuid())"
$environmentNames = @(
    'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID',
    'TF_STATE_RESOURCE_GROUP', 'TF_STATE_STORAGE_ACCOUNT', 'TF_STATE_CONTAINER',
    'ALZ_target_directory', 'TF_VAR_target_directory', 'TF_CLI_ARGS_init',
    'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN', 'PLATFORM_ALZ_TEST_MODE'
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
    $targetDirectory = & (Get-Module ALZ) {
        param($defaultDirectory)
        $parameters = [pscustomobject]@{
            target_directory = [pscustomobject]@{
                Source = 'input'
                Value = ''
                DefaultValue = $defaultDirectory
            }
        }
        (Set-Config -configurationParameters $parameters -inputConfig ([pscustomobject]@{}) -copyEnvVarToConfig).target_directory.Value
    } (Join-Path $output 'local-output')
    $scriptsDirectory = Join-Path $targetDirectory 'scripts'
    New-Item $scriptsDirectory -ItemType Directory -Force | Out-Null
    if ($testState.Mode -eq 'missing-script') { return }
    $hubDirectory = Join-Path $targetDirectory 'templates\networking\hubnetworking'
    New-Item $hubDirectory -ItemType Directory -Force | Out-Null
    $hubTemplate = @'
var resources = [
  { name: 'rt-hub-fw-${hub.location}', location: hub.location }
  { name: 'rt-hub-std-${hub.location}', location: hub.location }
  { name: 'afwp-alz-${hub.location}', location: hub.location }
]
'@
    if ($testState.Mode -eq 'unexpected-hub-name') {
        $hubTemplate = $hubTemplate.Replace('afwp-alz', 'afwp-changed-upstream')
    } elseif ($testState.Mode -eq 'duplicate-hub-name') {
        $hubTemplate += "`n" + 'var extra = { name: ''rt-hub-fw-${hub.location}'' }'
    }
    Set-Content (Join-Path $hubDirectory 'main.bicep') $hubTemplate
    $content = if ($testState.Mode -eq 'native-failure') {
        '[CmdletBinding()]param(); exit 23'
    } else {
        @'
[CmdletBinding()]
param()
$answer = Read-Host -Prompt "Type 'yes' and hit Enter to continue with the full deployment"
if ($answer -cne 'yes') { throw 'Standard Bicep confirmation was not supplied.' }
if (-not [string]::IsNullOrEmpty($env:TF_CLI_ARGS_init)) { throw 'Bicep must not use a remote Terraform backend.' }
if ((Get-Location).Path -ne $env:TF_VAR_target_directory) { throw 'Wrong deployment working directory.' }
if (Test-Path backend.hcl) { throw 'Bicep must not create a state backend configuration.' }
$hubTemplate = Get-Content 'templates\networking\hubnetworking\main.bicep' -Raw
if ([regex]::Matches($hubTemplate, [regex]::Escape('${substring(hub.location, 0, 3)}')).Count -ne 3 -or
    -not $hubTemplate.Contains('location: hub.location') -or $hubTemplate.Contains('${hub.location}')) {
    throw 'Hub names must be shortened without changing Azure deployment locations.'
}
Set-Content deployment-invoked.txt 'deployed'
'@
    }
    Set-Content (Join-Path $scriptsDirectory 'deploy-local.ps1') $content
    if ($testState.Mode -like 'oidc-*') {
        $stackScript = @'
param([string]$name)
$retryCount = 0
$retryMax = 2
$finalSuccess = $false
while ($retryCount -lt $retryMax) {
    $result = $null
    try {
        Add-Content deployment-attempts.txt $name
        if ($global:oidcTestState.SessionToken -ne "test-assertion-$($global:oidcTestState.RequestCount)") {
            throw 'The expired assertion was reused.'
        }
        $global:oidcTestState.DeploymentCount++
        if ($global:oidcTestState.DeploymentCount -eq 1) {
            $global:oidcTestState.SessionToken = 'expired'
            throw 'Simulated ClientAssertionCredential expiration during a long operation.'
        }
        $result = 'succeeded'
    } catch {
        $retryCount++
        continue
    }
    if ($result -eq 'succeeded') {
        $finalSuccess = $true
        break
    }
}
if (-not $finalSuccess) { throw 'Deployment could not recover from expired authentication.' }
'@
        if ($testState.Mode -eq 'oidc-changed-upstream') {
            $stackScript = $stackScript.Replace('$result = $null', '$result = @{}')
        }
        Set-Content (Join-Path $scriptsDirectory 'bicep-deploy.ps1') $stackScript
        Set-Content (Join-Path $scriptsDirectory 'deploy-local.ps1') @'
[CmdletBinding()]
param()
$answer = Read-Host -Prompt 'Confirm deployment'
if ($answer -cne 'yes') { throw 'Confirmation was not supplied.' }
$global:oidcTestState = @{ RequestCount = 0; SessionToken = ''; DeploymentCount = 0 }
function Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec, $MaximumRetryCount, $RetryIntervalSec)
    if ($Uri -notlike '*&audience=api%3A%2F%2FAzureADTokenExchange' -or
        $Headers.Authorization -ne 'Bearer test-request-token') {
        throw 'Incorrect GitHub OIDC request.'
    }
    $global:oidcTestState.RequestCount++
    Add-Content oidc-requests.txt 'request'
    if ($env:PLATFORM_ALZ_TEST_MODE -eq 'oidc-request-failure') { throw 'OIDC request denied.' }
    if ($env:PLATFORM_ALZ_TEST_MODE -eq 'oidc-empty-token') { return @{} }
    [pscustomobject]@{ value = "test-assertion-$($global:oidcTestState.RequestCount)" }
}
function Import-Module {
    param($Name, $RequiredVersion)
    if ($Name -ne 'Az.Accounts' -or $RequiredVersion -ne '5.5.4') {
        throw 'Unexpected module import.'
    }
}
function Connect-AzAccount {
    param([switch]$ServicePrincipal, $ApplicationId, $Tenant, $Subscription,
        $FederatedToken, $Scope, [switch]$Force, [switch]$SkipContextPopulation)
    if (-not $ServicePrincipal -or -not $Force -or -not $SkipContextPopulation -or
        $Scope -ne 'Process' -or $ApplicationId -ne $env:ARM_CLIENT_ID -or
        $Tenant -ne $env:ARM_TENANT_ID -or $Subscription -ne $env:ARM_SUBSCRIPTION_ID) {
        throw 'Incorrect process-scoped Azure login.'
    }
    if ($env:PLATFORM_ALZ_TEST_MODE -eq 'oidc-login-failure') { throw 'Federated login rejected.' }
    $global:oidcTestState.SessionToken = $FederatedToken
    Add-Content oidc-logins.txt $FederatedToken
}
& (Join-Path $PSScriptRoot 'bicep-deploy.ps1') -name first-stage
& (Join-Path $PSScriptRoot 'bicep-deploy.ps1') -name second-stage
Set-Content deployment-invoked.txt 'deployed'
'@
    }
}
function Assert-Failure {
    param([scriptblock]$Action, [string]$Expected)
    try { & $Action } catch {
        if ($_.ToString() -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected failure containing: $Expected"
}

function Test-ModuleInstallRetries {
    $workflow = Get-Content (Join-Path $root '..\.github\workflows\alz-deploy.yml') -Raw | ConvertFrom-Yaml
    $installStep = @($workflow.jobs.deploy.steps | Where-Object name -eq 'Install ALZ PowerShell dependencies')
    if ($installStep.Count -ne 1) { throw 'Expected exactly one module installation step.' }
    $installScript = [scriptblock]::Create($installStep[0].run)
    $installState = @{
        Mode = 'success'
        Calls = [Collections.Generic.List[string]]::new()
        Delays = [Collections.Generic.List[int]]::new()
    }
    function Install-Module {
        [CmdletBinding()]
        param([string]$Name, [string]$RequiredVersion, [string]$Scope, [string]$Repository, [switch]$Force)
        if ($Scope -ne 'CurrentUser' -or $Repository -ne 'PSGallery' -or -not $Force) {
            throw 'Module installation settings changed unexpectedly.'
        }
        $installState.Calls.Add($Name)
        if (($installState.Mode -eq 'transient' -and $Name -eq 'Az.Resources' -and
                @($installState.Calls | Where-Object { $_ -eq $Name }).Count -lt 3) -or
            ($installState.Mode -eq 'exhausted' -and $Name -eq 'ALZ')) {
            Write-Error "Package '$Name' failed to download."
        }
    }
    function Start-Sleep {
        param([int]$Seconds)
        $installState.Delays.Add($Seconds)
    }
    & $installScript
    if (($installState.Calls -join ',') -ne 'powershell-yaml,ALZ,Az.Accounts,Az.Resources' -or
        $installState.Delays.Count -ne 0) {
        throw 'Successful installations must not be repeated or delayed.'
    }
    $installState.Mode = 'transient'
    $installState.Calls.Clear()
    & $installScript
    if (($installState.Calls -join ',') -ne 'powershell-yaml,ALZ,Az.Accounts,Az.Resources,Az.Resources,Az.Resources' -or
        ($installState.Delays -join ',') -ne '10,20') {
        throw 'Transient download errors must retry only the failed module with backoff.'
    }
    $installState.Mode = 'exhausted'
    $installState.Calls.Clear()
    $installState.Delays.Clear()
    Assert-Failure { & $installScript } "Failed to install ALZ 7.1.5 after 5 attempts: Package 'ALZ' failed to download."
    if (($installState.Calls -join ',') -ne 'powershell-yaml,ALZ,ALZ,ALZ,ALZ,ALZ' -or
        ($installState.Delays -join ',') -ne '10,20,40,80') {
        throw 'Exhausted installation retries must stop at five attempts without installing subsequent modules.'
    }
}

function Test-PlatformDns {
    $platformDns = Get-Content (Join-Path $root 'config\private-dns.json') -Raw | ConvertFrom-Json
    $dnsTestState = @{ Failure = ''; Calls = [Collections.Generic.List[string]]::new() }
    function az {
        $dnsTestState.Calls.Add("az $($args -join ' ')")
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'bicep') {
            if ($dnsTestState.Failure -eq 'compile') { $global:LASTEXITCODE = 17; return }
            Set-Content $args[-1] '{"resources":[]}'
        } elseif ($args[0] -eq 'network') {
            if ($dnsTestState.Failure -eq 'inventory') { $global:LASTEXITCODE = 19; return }
            $vnets = @(
                @{ id = "/subscriptions/$($args[4])/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test"; dhcpOptions = @{ dnsServers = @() } }
            )
            if ($args[4] -eq $platformDns.subscriptionId) {
                $vnets += @{ id = "/subscriptions/$($args[4])/resourceGroups/rg-other/providers/Microsoft.Network/virtualNetworks/vnet-other"; dhcpOptions = @{ dnsServers = @() } }
            }
            if ($dnsTestState.Failure -eq 'custom-dns') { $vnets[0].dhcpOptions.dnsServers = @('10.100.0.4') }
            if ($dnsTestState.Failure -eq 'implicit-dns') {
                foreach ($vnet in $vnets) { $vnet.Remove('dhcpOptions') }
            }
            if ($dnsTestState.Failure -eq 'empty-inventory') { $vnets = @() }
            ConvertTo-Json -InputObject $vnets -Depth 10
        } elseif ($args[0] -eq 'group') {
            if ($dnsTestState.Failure -eq 'group') { $global:LASTEXITCODE = 21 }
        } elseif ($args[0] -eq 'deployment') {
            if ($dnsTestState.Failure -eq 'deployment') { $global:LASTEXITCODE = 31 }
        } else { throw "Unexpected platform DNS command: $args" }
    }
    $dnsAdapter = Join-Path $root 'Invoke-PlatformDns.ps1'
    & $dnsAdapter -OutputPath (Join-Path $testRoot 'dns-validate') -ValidateOnly
    if ($dnsTestState.Calls.Count -ne 1 -or $dnsTestState.Calls[0] -notlike 'az bicep build *') {
        throw 'DNS validation must compile offline without Azure reads or writes.'
    }
    $dnsTestState.Calls.Clear()
    $dnsOutput = Join-Path $testRoot 'dns-success'
    & $dnsAdapter -OutputPath $dnsOutput
    $parameters = Get-Content (Join-Path $dnsOutput 'private-dns.parameters.json') -Raw | ConvertFrom-Json
    if ($parameters.parameters.virtualNetworkIds.value.Count -ne 3 -or
        $parameters.parameters.zoneNames.value.Count -ne @($platformDns.zones.PSObject.Properties).Count -or
        @($dnsTestState.Calls | Where-Object { $_ -like "az group create --subscription $($platformDns.subscriptionId) --name $($platformDns.resourceGroupName)*" }).Count -ne 1 -or
        @($dnsTestState.Calls | Where-Object { $_ -like "az deployment group create --subscription $($platformDns.subscriptionId)*--mode Incremental*" }).Count -ne 1) {
        throw 'Platform DNS must own group/zone provisioning and link every discovered VNet in its configured subscriptions.'
    }
    foreach ($case in @(
        @{ Failure = 'compile'; Error = 'exit code 17' },
        @{ Failure = 'inventory'; Error = 'exit code 19' },
        @{ Failure = 'empty-inventory'; Error = 'No VNets found' },
        @{ Failure = 'custom-dns'; Error = 'uses custom DNS' },
        @{ Failure = 'group'; Error = 'exit code 21' },
        @{ Failure = 'deployment'; Error = 'exit code 31' }
    )) {
        $dnsTestState.Failure = $case.Failure
        $dnsTestState.Calls.Clear()
        Assert-Failure { & $dnsAdapter -OutputPath (Join-Path $testRoot "dns-$($case.Failure)") } $case.Error
        if ($case.Failure -in 'compile', 'inventory', 'empty-inventory', 'custom-dns', 'group' -and
            @($dnsTestState.Calls | Where-Object { $_ -like 'az deployment *' }).Count -ne 0) {
            throw 'DNS prerequisite failures must stop before platform DNS deployment.'
        }
    }
    $dnsTestState.Failure = 'implicit-dns'
    & $dnsAdapter -OutputPath (Join-Path $testRoot 'dns-implicit')
    $workflow = Get-Content (Join-Path $root '..\.github\workflows\alz-deploy.yml') -Raw | ConvertFrom-Yaml
    $stepNames = @($workflow.jobs.deploy.steps.name)
    $alzIndex = [array]::IndexOf($stepNames, 'Generate from repository configuration and run official local deployment')
    $refreshIndex = [array]::IndexOf($stepNames, 'Refresh Azure CLI login for shared platform DNS')
    $dnsIndex = [array]::IndexOf($stepNames, 'Provision shared platform DNS')
    if ($alzIndex -lt 0 -or $refreshIndex -le $alzIndex -or $dnsIndex -le $refreshIndex) {
        throw 'Platform DNS must run after successful ALZ deployment and a refreshed Azure CLI login.'
    }
    Write-Host 'PASS: platform DNS ownership, all-VNet discovery, offline compilation, prerequisite failures and workflow order.'
}

try {
    New-Item $testRoot -ItemType Directory | Out-Null
    Test-PlatformDns
    Test-ModuleInstallRetries
    $env:ARM_CLIENT_ID = [guid]::NewGuid().ToString()
    $env:ARM_TENANT_ID = $config.root_parent_management_group_id
    $env:ARM_SUBSCRIPTION_ID = $config.bootstrap_subscription_id
    $env:TF_STATE_RESOURCE_GROUP = $null
    $env:TF_STATE_STORAGE_ACCOUNT = $null
    $env:TF_STATE_CONTAINER = $null
    $env:TF_CLI_ARGS_init = 'original-init-arguments'
    $env:ALZ_target_directory = 'original-target'
    $originalBootstrapTarget = Join-Path $testRoot 'original-bootstrap-target'
    $env:TF_VAR_target_directory = $originalBootstrapTarget
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
    $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://example.test/oidc?job=test'
    $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'test-request-token'
    $testState.Mode = 'oidc-success'
    $env:PLATFORM_ALZ_TEST_MODE = $testState.Mode
    $oidcOutput = Join-Path $testRoot 'oidc-success'
    & $adapter -OutputPath $oidcOutput -RefreshGitHubOidc
    $logins = @(Get-Content (Join-Path $oidcOutput 'platform\oidc-logins.txt'))
    $attempts = @(Get-Content (Join-Path $oidcOutput 'platform\deployment-attempts.txt'))
    if (($logins -join ',') -ne 'test-assertion-1,test-assertion-2,test-assertion-3' -or
        ($attempts -join ',') -ne 'first-stage,first-stage,second-stage' -or
        -not (Test-Path (Join-Path $oidcOutput 'platform\deployment-invoked.txt'))) {
        throw 'OIDC must be renewed before the first attempt, after expiry, and before the next stage.'
    }
    foreach ($mode in 'oidc-request-failure', 'oidc-empty-token', 'oidc-login-failure') {
        $testState.Mode = $mode
        $env:PLATFORM_ALZ_TEST_MODE = $mode
        $failureOutput = Join-Path $testRoot $mode
        Assert-Failure { & $adapter -OutputPath $failureOutput -RefreshGitHubOidc } '1'
        if (Test-Path (Join-Path $failureOutput 'platform\deployment-attempts.txt')) {
            throw 'Authentication failure must stop before deployment, outside the upstream retry catch.'
        }
        if (@(Get-Content (Join-Path $failureOutput 'platform\oidc-requests.txt')).Count -ne 1) {
            throw 'The deployment loop must not retry a failed authentication renewal.'
        }
    }
    $testState.Mode = 'oidc-changed-upstream'
    Assert-Failure {
        & $adapter -OutputPath (Join-Path $testRoot 'oidc-changed-upstream') -RefreshGitHubOidc
    } 'Expected the pinned deployment retry loop'
    foreach ($case in @(
        @{ Mode = 'missing-script'; Error = 'did not generate' }
        @{ Mode = 'native-failure'; Error = '23' }
        @{ Mode = 'invalid-build'; Error = 'Invalid or oversized Bicep' }
        @{ Mode = 'unexpected-hub-name'; Error = 'Expected exactly one upstream name expression' }
        @{ Mode = 'duplicate-hub-name'; Error = 'Expected exactly one upstream name expression' }
    )) {
        $testState.Mode = $case.Mode
        Assert-Failure { & $adapter -OutputPath (Join-Path $testRoot $case.Mode) } $case.Error
    }
    if ((Get-Location).Path -ne $originalLocation -or
        $env:TF_CLI_ARGS_init -ne 'original-init-arguments' -or
        $env:ALZ_target_directory -ne 'original-target' -or
        $env:TF_VAR_target_directory -ne $originalBootstrapTarget) {
        throw 'The adapter did not restore the caller environment and working directory.'
    }
    Write-Host 'PASS: bounded module-install retries and backoff, real ALZ target-directory resolution, Bicep handoff, short hub names with unchanged locations, fail-closed upstream matching, no state backend, preflight/build guards, OIDC renewal across expiry/retries/stages, fail-fast authentication errors, failure propagation and cleanup.'
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name])
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
