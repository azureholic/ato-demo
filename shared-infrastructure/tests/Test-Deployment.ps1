#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "private-deployment-tests-$([guid]::NewGuid())"
New-Item $testRoot -ItemType Directory | Out-Null
$calls = [Collections.Generic.List[string]]::new()
$failure = ''
$config = $null
$oldScope = $env:HOSTED_AGENT_RESOURCE_SCOPE
$oldGhToken = $env:GH_TOKEN
$oldRunnerSettings = @{}
foreach ($name in 'GITHUB_APP_ID', 'GITHUB_INSTALLATION_ID', 'GITHUB_APP_PRIVATE_KEY', 'GITHUB_APP_KEY_EXPIRES_ON') {
    $oldRunnerSettings[$name] = [Environment]::GetEnvironmentVariable($name)
}
$buildContext = ''

function git {
    $calls.Add("git $($args -join ' ')")
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'clone') {
        $path = $args[-1]
        $files = @{
            'Dockerfile.github' = ''
            'github-actions-runner\entrypoint.sh' = ''
            'azure.yaml' = "run: scripts/preUp.sh`nrun: scripts/preProvision.sh`nrun: scripts/preProvision.ps1`nrun: scripts/postProvision.sh`nrun: scripts/postProvision.ps1"
            'manifest.json' = '{}'
            'main.parameters.json' = '{"parameters":{"aiFoundryLocation":{"value":"${AZURE_AI_FOUNDRY_LOCATION}"}}}'
            'infra\bicep\main.bicep' = ''
            'scripts\preProvision.ps1' = ''
            'scripts\postProvision.ps1' = ''
            'infra\bicep\modules\ai-foundry\foundry\modules\keyVault.bicep' = 'enablePurgeProtection: false'
            'infra\bicep\modules\ai-foundry\storage-account.bicep' = 'allowBlobPublicAccess: false'
            'infra\bicep\modules\application\app-configuration-store.bicep' = 'disableLocalAuth: false'
        }
        if ($failure -eq 'changed-contract') { $files['infra\bicep\modules\ai-foundry\foundry\modules\keyVault.bicep'] = 'changed' }
        foreach ($file in $files.Keys) {
            $destination = Join-Path $path $file
            New-Item (Split-Path $destination -Parent) -ItemType Directory -Force | Out-Null
            Set-Content $destination $files[$file]
        }
    } elseif ($args[2] -eq 'rev-parse') {
        if ($failure -eq 'wrong-sha') { '0' * 40 } else { $config.upstreamRevision }
    }
}
function az {
    $calls.Add("az $($args -join ' ')")
    $global:LASTEXITCODE = 0
    if ($failure -in 'runner-deploy', 'runner-build-failed') {
        if ($args[0] -eq 'network' -and $args[1] -eq 'private-dns') {
            $dns = Get-Content (Join-Path $repo 'platform-alz\config\private-dns.json') -Raw | ConvertFrom-Json -AsHashtable
            ConvertTo-Json -InputObject @($dns.zones.Values | ForEach-Object { @{ name = $_ } })
            return
        }
        if ($args[0] -eq 'deployment' -and $args[2] -eq 'show') {
            @{ registryName = @{ value = 'registrytest' }; registryEndpoint = @{ value = 'registrytest.azurecr.io' } } | ConvertTo-Json
            return
        }
        if ($args[0] -eq 'acr' -and $args[1] -eq 'build') {
            $buildContext = $args[-1]
            if (Test-Path (Join-Path $buildContext 'runner.parameters.json')) { throw 'Private key parameter file would be uploaded to ACR.' }
            $dockerfile = $args[[array]::IndexOf($args, '--file') + 1]
            if ($dockerfile -ne (Join-Path $buildContext 'Dockerfile.github') -or -not (Test-Path -LiteralPath $dockerfile)) {
                throw 'ACR build must reference the Dockerfile inside the generated context.'
            }
            if ('--no-wait' -in $args -or '--no-logs' -notin $args) { throw 'ACR build must return its completed run without streaming logs.' }
            if ($failure -eq 'runner-build-failed') { '{"status":"Failed"}'; return }
            @{ status = 'Succeeded'; outputImages = @(@{ repository = 'github-runner'; digest = "sha256:$('a' * 64)" }) } | ConvertTo-Json -Depth 5
            return
        }
        if ($args[0] -eq 'resource') { 'Succeeded'; return }
        if ($args[0] -ne 'bicep') { return }
    } elseif ($args[0] -ne 'bicep') { throw 'Offline validation must not call Azure management APIs.' }
    if ($failure -eq 'compile') { $global:LASTEXITCODE = 17; return }
    $parameterNames = @{}
    $agent = Get-Content (Join-Path $repo 'ai-agent\config\deployment.json') -Raw | ConvertFrom-Json -AsHashtable
    $overlay = Get-Content (Join-Path $repo 'ai-agent\config\parameters.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in @($agent.dnsZoneParameters.Keys) + @($overlay.parameters.Keys) + @('deploymentTags', 'existingVnetResourceId', 'hubIntegrationEgressNextHopIp', 'hubIntegrationHubVnetResourceId')) {
        $parameterNames[$key] = @{}
    }
    $template = @{ parameters = $parameterNames; resources = @() }
    if ($failure -eq 'oversized-template') { $template.variables = @{ padding = 'x' * 4MB } }
    $template | ConvertTo-Json -Depth 10 | Set-Content $args[-1]
}

function Assert-Failure {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure: $Message."
}

try {
    $armParametersPath = Join-Path $testRoot 'arm-parameters.json'
    @{ parameters = @{ additionalAppConfigurationSettings = @{ value = @(
        @{ name = 'json'; value = '[]' },
        @{ name = 'brackets'; value = '[[]' },
        @{ name = 'plain'; value = 'hello' }
    ) } } } | ConvertTo-Json -Depth 10 | Set-Content $armParametersPath
    & (Join-Path $repo 'ai-agent\Protect-ArmParameters.ps1') $armParametersPath
    $values = @((Get-Content $armParametersPath -Raw | ConvertFrom-Json).parameters.additionalAppConfigurationSettings.value | ForEach-Object value)
    if ($values[0] -ne '[[]' -or $values[1] -ne '[[[]' -or $values[2] -ne 'hello') { throw 'ARM setting escaping failed.' }
    $hookRoot = Join-Path $testRoot 'post-hook'
    $hookScripts = Join-Path $hookRoot 'scripts'
    $hookEnv = Join-Path $hookRoot '.azure\fixture'
    New-Item $hookScripts, $hookEnv -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $repo 'ai-agent\Invoke-PostProvision.ps1') $hookScripts
    @('DEPLOY_HOSTED_AGENT="false"', 'OTHER="keep"', 'HOSTED_AGENT_PREPARED="true"') | Set-Content (Join-Path $hookEnv '.env')
    'if ($env:DEPLOY_HOSTED_AGENT -or $env:HOSTED_AGENT_PREPARED) { exit 1 }; exit 0' | Set-Content (Join-Path $hookScripts 'postProvision.ps1')
    @('#!/bin/bash', 'test -z "${DEPLOY_HOSTED_AGENT+x}" && test -z "${HOSTED_AGENT_PREPARED+x}"') | Set-Content (Join-Path $hookScripts 'postProvision.sh')
    $oldEnvironmentName = $env:AZURE_ENV_NAME
    $oldDeployHostedAgent = $env:DEPLOY_HOSTED_AGENT
    $oldHostedAgentPrepared = $env:HOSTED_AGENT_PREPARED
    try {
        $env:AZURE_ENV_NAME = 'fixture'
        $env:DEPLOY_HOSTED_AGENT = 'false'
        $env:HOSTED_AGENT_PREPARED = 'true'
        & pwsh -NoProfile -File (Join-Path $hookScripts 'Invoke-PostProvision.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Postprovision wrapper did not clear obsolete process outputs.' }
        $remaining = @(Get-Content (Join-Path $hookEnv '.env'))
        if ($remaining.Count -ne 1 -or $remaining[0] -ne 'OTHER="keep"') { throw 'Postprovision wrapper changed unrelated azd values.' }
    } finally {
        $env:AZURE_ENV_NAME = $oldEnvironmentName
        $env:DEPLOY_HOSTED_AGENT = $oldDeployHostedAgent
        $env:HOSTED_AGENT_PREPARED = $oldHostedAgentPrepared
    }
    $agentConfig = Get-Content (Join-Path $repo 'ai-agent\config\deployment.json') -Raw | ConvertFrom-Json -AsHashtable
    $runnerConfig = Get-Content (Join-Path $repo 'github-runner\config\deployment.json') -Raw | ConvertFrom-Json -AsHashtable
    $agentTargets = @($runnerConfig.targetNetworks | Where-Object {
        $_.subscriptionId -eq $agentConfig.subscriptionId -and
        $_.resourceGroupName -eq $agentConfig.networking.resourceGroupName -and
        $_.vnetName -eq $agentConfig.networking.vnetName
    })
    if ($agentTargets.Count -ne 1) { throw 'Runner peering must target the configured agent spoke exactly once.' }
    if ($agentConfig.networking.resourceGroupName -eq 'rg-ai-agent-network-ita' -and $agentConfig.networking.vnetName -eq 'vnet-ai-agent-ita') {
        throw 'The previous agent VNet must not be managed by the new spoke deployment.'
    }
    foreach ($scenario in 'ai-agent', 'github-runner') {
        $config = Get-Content (Join-Path $repo "$scenario\config\deployment.json") -Raw | ConvertFrom-Json -AsHashtable
        $script = Join-Path $repo "$scenario\$(if ($scenario -eq 'ai-agent') { 'Invoke-AiAgent.ps1' } else { 'Invoke-GitHubRunner.ps1' })"
        $failure = ''
        & $script -OutputPath (Join-Path $testRoot "$scenario-ok") -Mode Validate
        if ($scenario -eq 'ai-agent') {
            $generatedYaml = Get-Content (Join-Path $testRoot 'ai-agent-ok\azure.yaml') -Raw
            if ($generatedYaml -notmatch 'run: sh scripts/preUp\.sh') { throw 'The upstream non-executable preup hook must run through sh.' }
        }
        $failure = 'wrong-sha'
        $calls.Clear()
        Assert-Failure { & $script -OutputPath (Join-Path $testRoot "$scenario-sha") -Mode Validate } 'pinned SHA'
        if (@($calls | Where-Object { $_ -like 'az *' }).Count) { throw 'A changed upstream revision reached compilation.' }
        $failure = 'compile'
        Assert-Failure { & $script -OutputPath (Join-Path $testRoot "$scenario-compile") -Mode Validate } 'exit code 17'
    }
    $failure = 'changed-contract'
    $config = Get-Content (Join-Path $repo 'ai-agent\config\deployment.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-Failure { & (Join-Path $repo 'ai-agent\Invoke-AiAgent.ps1') -OutputPath (Join-Path $testRoot 'contract') -Mode Validate } 'hardening contract'
    $failure = 'oversized-template'
    Assert-Failure { & (Join-Path $repo 'ai-agent\Invoke-AiAgent.ps1') -OutputPath (Join-Path $testRoot 'oversized') -Mode Validate } '4 MB limit'
    $calls.Clear()
    $env:HOSTED_AGENT_RESOURCE_SCOPE = ''
    Assert-Failure { & (Join-Path $repo 'ai-agent\Invoke-AiAgent.ps1') -OutputPath (Join-Path $testRoot 'audience') -Mode Deploy } 'HOSTED_AGENT_RESOURCE_SCOPE'
    if ($calls.Count) { throw 'Missing hosted audience must fail before cloning or Azure mutations.' }
    $config = Get-Content (Join-Path $repo 'github-runner\config\deployment.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($invalidPrefix in 'kv-ghrunner', 'kv--bad', 'kv-bad-') {
        $invalidConfig = $config.Clone()
        $invalidConfig.keyVaultNamePrefix = $invalidPrefix
        $invalidConfigPath = Join-Path $testRoot 'invalid-runner-config.json'
        $invalidConfig | ConvertTo-Json -Depth 20 | Set-Content $invalidConfigPath
        $calls.Clear()
        Assert-Failure { & (Join-Path $repo 'github-runner\Invoke-GitHubRunner.ps1') -ConfigPath $invalidConfigPath -OutputPath (Join-Path $testRoot 'invalid-vault') -Mode Validate } 'Key Vault name prefix'
        if ($calls.Count) { throw 'Invalid Key Vault prefixes must fail before cloning or Azure mutations.' }
    }
    $validConfig = $config.Clone()
    $validConfig.keyVaultNamePrefix = 'kv-1234567'
    $validConfigPath = Join-Path $testRoot 'valid-runner-config.json'
    $validConfig | ConvertTo-Json -Depth 20 | Set-Content $validConfigPath
    $failure = ''
    & (Join-Path $repo 'github-runner\Invoke-GitHubRunner.ps1') -ConfigPath $validConfigPath -OutputPath (Join-Path $testRoot 'valid-vault') -Mode Validate
    $env:GITHUB_APP_ID = '123'
    $env:GITHUB_INSTALLATION_ID = '456'
    $env:GITHUB_APP_PRIVATE_KEY = 'test-fixture-key'
    $env:GITHUB_APP_KEY_EXPIRES_ON = '1'
    $calls.Clear()
    Assert-Failure { & (Join-Path $repo 'github-runner\Invoke-GitHubRunner.ps1') -OutputPath (Join-Path $testRoot 'expired-key') -Mode Deploy } 'future GITHUB_APP_KEY_EXPIRES_ON'
    if ($calls.Count) { throw 'Expired keys must fail before cloning or Azure mutations.' }
    $env:GITHUB_APP_KEY_EXPIRES_ON = "$([DateTimeOffset]::UtcNow.AddDays(90).ToUnixTimeSeconds())"
    $failure = 'runner-deploy'
    $calls.Clear()
    & (Join-Path $repo 'github-runner\Invoke-GitHubRunner.ps1') -OutputPath (Join-Path $testRoot 'runner-deploy') -Mode Deploy
    if (Test-Path (Join-Path $testRoot 'runner-deploy\runner.parameters.json')) { throw 'Private-key parameter file was not removed.' }
    if (@($calls | Where-Object { $_ -like "az acr build *--agent-pool $($config.buildPoolName) *" }).Count -ne 1) { throw 'Runner images must be built by the private ACR agent pool.' }
    if (-not @($calls | Where-Object { $_ -like 'az acr agentpool update*--count 0*' }).Count) { throw 'Successful builds must scale the pool to zero.' }
    $failure = 'runner-build-failed'
    $calls.Clear()
    Assert-Failure { & (Join-Path $repo 'github-runner\Invoke-GitHubRunner.ps1') -OutputPath (Join-Path $testRoot 'runner-build-failed') -Mode Deploy } 'build failed'
    if (Test-Path (Join-Path $testRoot 'runner-build-failed\runner.parameters.json')) { throw 'Failed builds must remove private-key parameter files.' }
    if (-not @($calls | Where-Object { $_ -like 'az acr agentpool update*--count 0*' }).Count) { throw 'Failed builds must scale the pool to zero.' }
    $ghCalls = [Collections.Generic.List[string]]::new()
    $secretFailure = $false
    function gh {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'auth') { 'fixture-account-token'; return }
        if ($env:GH_TOKEN -ne 'fixture-account-token') { throw 'App setup used the wrong account token.' }
        $ghCalls.Add("$($args -join ' ')")
        if ($args[0] -eq 'api') { 'false'; return }
        if ($args[0] -eq 'secret') {
            if (($input | Out-String).Trim() -ne 'fixture-private-key') { throw 'App key was not supplied through stdin.' }
            if ($secretFailure) { $global:LASTEXITCODE = 1 }
        }
    }
    $env:GH_TOKEN = 'original-token'
    # Import setup helpers while stopping before any browser or network consent flow.
    try {
        . (Join-Path $repo 'github-runner\Initialize-GitHubApp.ps1') -GitHubUser fixture-user
        throw 'Expected repository administration gate.'
    } catch {
        if ($_.Exception.Message -notlike '*repository administration permission*') { throw }
    }
    if ($env:GH_TOKEN -ne 'original-token') { throw 'App preflight changed the caller token.' }
    Save-AppCredentials @{ id = 123; pem = 'fixture-private-key' } 2000000000
    if ($env:GH_TOKEN -ne 'original-token') { throw 'Credential storage changed the caller token.' }
    $secretFailure = $true
    Assert-Failure { Save-AppCredentials @{ id = 123; pem = 'fixture-private-key' } 2000000000 } 'store App private key'
    if ($env:GH_TOKEN -ne 'original-token') { throw 'Failed credential storage changed the caller token.' }
    $httpStatus = [Net.HttpStatusCode]::NotFound
    function Invoke-RestMethod {
        $response = [Net.Http.HttpResponseMessage]::new($httpStatus)
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('HTTP fixture failure', $response)
    }
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $testApp = @{ id = 123; pem = $rsa.ExportRSAPrivateKeyPem() }
        if ($null -ne (Get-AppInstallation $testApp -AllowMissing)) { throw 'Missing installation must wait for browser consent.' }
        Assert-Failure { Get-AppInstallation $testApp } 'HTTP fixture failure'
        $httpStatus = [Net.HttpStatusCode]::Forbidden
        Assert-Failure { Get-AppInstallation $testApp -AllowMissing } 'HTTP fixture failure'
    } finally {
        $rsa.Dispose()
    }
    Write-Host 'PASS: adapters, safety gates, private build/digest, secret cleanup, App account isolation and installation error handling.'
} finally {
    $env:HOSTED_AGENT_RESOURCE_SCOPE = $oldScope
    $env:GH_TOKEN = $oldGhToken
    foreach ($name in $oldRunnerSettings.Keys) { [Environment]::SetEnvironmentVariable($name, $oldRunnerSettings[$name]) }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
# Expected mock command failures must not make a passing Actions step fail.
$global:LASTEXITCODE = 0
