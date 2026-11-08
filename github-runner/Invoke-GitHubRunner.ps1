#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\deployment.json'),
    [ValidateSet('Validate', 'Deploy')][string]$Mode = 'Validate'
)
. (Join-Path $PSScriptRoot '..\shared-infrastructure\Deployment.ps1')
$config = Read-ScenarioConfig $ConfigPath
if ($config.location -ne 'swedencentral') { throw 'The private ACR build pool is configured for Sweden Central.' }
if ($config.keyVaultNamePrefix -notmatch '^[A-Za-z](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,9}$') {
    throw 'The Key Vault name prefix must start with a letter, contain at most 10 alphanumeric or nonconsecutive hyphen characters, and end with an alphanumeric character.'
}
if ($Mode -eq 'Deploy') {
    foreach ($name in 'GITHUB_APP_ID', 'GITHUB_INSTALLATION_ID') {
        if ([Environment]::GetEnvironmentVariable($name) -notmatch '^[1-9][0-9]*$') { throw "Set $name using Initialize-GitHubApp.ps1." }
    }
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_APP_PRIVATE_KEY)) { throw 'Missing protected GITHUB_APP_PRIVATE_KEY secret.' }
    $keyExpiresOn = 0L
    if (-not [long]::TryParse($env:GITHUB_APP_KEY_EXPIRES_ON, [ref]$keyExpiresOn) -or $keyExpiresOn -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
        throw 'Set a future GITHUB_APP_KEY_EXPIRES_ON Unix timestamp when creating or rotating the GitHub App key.'
    }
}
Copy-PinnedUpstream $config $OutputPath
foreach ($file in 'Dockerfile.github', 'github-actions-runner\entrypoint.sh') {
    if (-not (Test-Path (Join-Path $OutputPath $file))) { throw "Pinned runner sample is missing $file." }
}
Copy-Item (Join-Path $PSScriptRoot 'image\Dockerfile') (Join-Path $OutputPath 'Dockerfile.github') -Force
Copy-Item (Join-Path $PSScriptRoot 'image\entrypoint.sh'), (Join-Path $PSScriptRoot 'image\register.py') (Join-Path $OutputPath 'github-actions-runner') -Force
$template = Join-Path $OutputPath 'runner.template.json'
Invoke-CheckedCommand az @('bicep', 'build', '--file', (Join-Path $PSScriptRoot 'infra\main.bicep'), '--outfile', $template)
Invoke-ScenarioNetwork $config (Join-Path $OutputPath 'network') -ValidateOnly:($Mode -eq 'Validate')
if ($Mode -eq 'Validate') { Write-Host 'Runner overlay and Bicep compiled; no Azure resources changed.'; return }
$dns = Get-Content (Join-Path $PSScriptRoot '..\platform-alz\config\private-dns.json') -Raw | ConvertFrom-Json -AsHashtable
$parameters = Join-Path $OutputPath 'runner.parameters.json'
$registry = $null
try {
    $values = @{
        config = $config; dns = $dns; deployJob = $false; runnerImage = ''
        githubAppId = $env:GITHUB_APP_ID; githubInstallationId = $env:GITHUB_INSTALLATION_ID
        githubAppPrivateKey = $env:GITHUB_APP_PRIVATE_KEY
        githubAppKeyExpiresOn = $keyExpiresOn
    }
    Write-ArmParameters $values $parameters
    Invoke-CheckedCommand az @('deployment', 'group', 'create', '--subscription', $config.subscriptionId, '--resource-group', $config.resourceGroupName, '--name', 'github-runner', '--template-file', $template, '--parameters', "@$parameters", '--mode', 'Incremental', '--output', 'none')
    Remove-Item -LiteralPath $parameters -Force
    $outputs = Invoke-CheckedCommand az @('deployment', 'group', 'show', '--subscription', $config.subscriptionId, '--resource-group', $config.resourceGroupName, '--name', 'github-runner', '--query', 'properties.outputs', '--output', 'json') | ConvertFrom-Json
    $registry = $outputs.registryName.value
    if ([string]::IsNullOrWhiteSpace($registry)) { throw 'Deployment returned no registry name.' }
    foreach ($target in $config.targetNetworks) {
        Invoke-CheckedCommand az @('network', 'vnet', 'show', '--subscription', $target.subscriptionId, '--resource-group', $target.resourceGroupName, '--name', $target.vnetName, '--output', 'none')
    }
    $connections = Join-Path $OutputPath 'connections.parameters.json'
    Write-ArmParameters @{ config = $config } $connections
    Invoke-CheckedCommand az @('deployment', 'sub', 'create', '--subscription', $config.subscriptionId, '--location', $config.location, '--name', 'github-runner-connections', '--template-file', (Join-Path $PSScriptRoot '..\shared-infrastructure\infra\connections.bicep'), '--parameters', "@$connections", '--output', 'none')

    $tag = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { Invoke-CheckedCommand git @('-C', (Split-Path $PSScriptRoot -Parent), 'rev-parse', 'HEAD') }
    $run = Invoke-CheckedCommand az @('acr', 'build', '--subscription', $config.subscriptionId, '--registry', $registry, '--agent-pool', $config.buildPoolName, '--image', "github-runner:$tag", '--file', (Join-Path $OutputPath 'Dockerfile.github'), '--build-arg', "RUNNER_BASE_IMAGE=$($config.runnerBaseImage)", '--timeout', '3600', '--no-logs', '--output', 'json', $OutputPath) | ConvertFrom-Json
    if (-not $run -or $run.status -ne 'Succeeded') { throw 'Private ACR build failed or did not return a successful run.' }
    $digest = @($run.outputImages | Where-Object { $_.repository -eq 'github-runner' })[0].digest
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw 'ACR build returned no immutable runner image digest.' }
    $values.deployJob = $true
    $values.runnerImage = "$($outputs.registryEndpoint.value)/github-runner@$digest"
    Write-ArmParameters $values $parameters
    Invoke-CheckedCommand az @('deployment', 'group', 'create', '--subscription', $config.subscriptionId, '--resource-group', $config.resourceGroupName, '--name', 'github-runner', '--template-file', $template, '--parameters', "@$parameters", '--mode', 'Incremental', '--output', 'none')
    $state = Invoke-CheckedCommand az @('resource', 'show', '--subscription', $config.subscriptionId, '--resource-group', $config.resourceGroupName, '--resource-type', 'Microsoft.App/jobs', '--name', $config.jobName, '--query', 'properties.provisioningState', '--output', 'tsv')
    if ($state -ne 'Succeeded') { throw "Runner job is not provisioned: $state." }
    Write-Host "Provisioned private runner image $($values.runnerImage). Run the private runner smoke workflow before agent provisioning."
} finally {
    if (Test-Path $parameters) { Remove-Item $parameters -Force }
    if ($registry) {
        Invoke-CheckedCommand az @('acr', 'agentpool', 'update', '--subscription', $config.subscriptionId, '--registry', $registry, '--name', $config.buildPoolName, '--count', '0', '--output', 'none')
    }
}
