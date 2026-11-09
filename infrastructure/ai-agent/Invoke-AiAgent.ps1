#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config'),
    [ValidateSet('Validate', 'Network', 'Deploy')][string]$Mode = 'Validate'
)
. (Join-Path $PSScriptRoot '..\shared-infrastructure\Deployment.ps1')
$config = Read-ScenarioConfig (Join-Path $ConfigPath 'deployment.json')
if ($Mode -eq 'Network') { Invoke-ScenarioNetwork $config $OutputPath; return }
if ($Mode -eq 'Deploy' -and $env:HOSTED_AGENT_RESOURCE_SCOPE -notmatch '^[^\s]+/\.default$') {
    throw 'Set the approved HOSTED_AGENT_RESOURCE_SCOPE in demo environment variables before provisioning.'
}
Copy-PinnedUpstream $config $OutputPath
foreach ($file in 'azure.yaml', 'manifest.json', 'main.parameters.json', 'infra\bicep\main.bicep', 'scripts\preProvision.ps1') {
    if (-not (Test-Path (Join-Path $OutputPath $file))) { throw "Pinned foundation is missing $file; review the upstream contract." }
}

$azureYamlPath = Join-Path $OutputPath 'azure.yaml'
$azureYaml = Get-Content $azureYamlPath -Raw
$preUpHook = 'run: scripts/preUp.sh'
if ([regex]::Matches($azureYaml, [regex]::Escape($preUpHook)).Count -ne 1) { throw 'Review changed upstream preup hook.' }
$azureYaml = $azureYaml.Replace($preUpHook, 'run: sh scripts/preUp.sh')
foreach ($shell in 'sh', 'ps1') {
    $hook = "run: scripts/preProvision.$shell"
    if ([regex]::Matches($azureYaml, [regex]::Escape($hook)).Count -ne 1) { throw "Review changed upstream $shell preprovision hook." }
    $command = if ($shell -eq 'sh') { 'scripts/preProvision.sh' } else { 'pwsh -NoProfile -File scripts/preProvision.ps1' }
    $azureYaml = $azureYaml.Replace($hook, "run: $command && pwsh -NoProfile -File scripts/Protect-ArmParameters.ps1 infra/bicep/main.parameters.json")
}
# This scenario provisions infrastructure only: upstream postprovision publishes application settings and roles.
$azureYaml = [regex]::Replace($azureYaml, '(?ms)^  postprovision:\r?\n.*?(?=^  \w)', '')
if ($azureYaml -match 'postprovision') { throw 'Review changed upstream postprovision hook.' }
Set-Content $azureYamlPath $azureYaml -NoNewline
Copy-Item (Join-Path $PSScriptRoot 'Protect-ArmParameters.ps1') (Join-Path $OutputPath 'scripts\Protect-ArmParameters.ps1')

# Harden gaps in the pinned foundation only in the generated runner checkout.
$vaultPath = Join-Path $OutputPath 'infra\bicep\modules\ai-foundry\foundry\modules\keyVault.bicep'
$vaultSource = Get-Content $vaultPath -Raw
if ([regex]::Matches($vaultSource, 'enablePurgeProtection: false').Count -ne 1) { throw 'Review changed upstream Foundry Key Vault hardening contract.' }
Set-Content $vaultPath ($vaultSource.Replace('enablePurgeProtection: false', 'enablePurgeProtection: true')) -NoNewline
$storagePath = Join-Path $OutputPath 'infra\bicep\modules\ai-foundry\storage-account.bicep'
$storageSource = Get-Content $storagePath -Raw
if ([regex]::Matches($storageSource, 'allowBlobPublicAccess: false').Count -ne 1) { throw 'Review changed upstream Foundry Storage hardening contract.' }
Set-Content $storagePath ($storageSource.Replace('allowBlobPublicAccess: false', "allowBlobPublicAccess: false`n    allowSharedKeyAccess: false")) -NoNewline
$appConfigPath = Join-Path $OutputPath 'infra\bicep\modules\application\app-configuration-store.bicep'
$appConfigSource = Get-Content $appConfigPath -Raw
if ([regex]::Matches($appConfigSource, 'disableLocalAuth: false').Count -ne 1) { throw 'Review changed upstream App Configuration authentication contract.' }
Set-Content $appConfigPath ($appConfigSource.Replace('disableLocalAuth: false', 'disableLocalAuth: true')) -NoNewline

$parameters = Get-Content (Join-Path $OutputPath 'main.parameters.json') -Raw | ConvertFrom-Json -AsHashtable
$overrides = Get-Content (Join-Path $ConfigPath 'parameters.json') -Raw | ConvertFrom-Json -AsHashtable
foreach ($key in $overrides.parameters.Keys) { $parameters.parameters[$key] = $overrides.parameters[$key] }
# The pinned root seed retains this legacy alias; Bicep uses location for Foundry.
$parameters.parameters.Remove('aiFoundryLocation')
$parameters.parameters.deploymentTags = @{ value = $config.tags }
$dns = Get-Content (Join-Path $PSScriptRoot '..\platform-alz\config\private-dns.json') -Raw | ConvertFrom-Json -AsHashtable
foreach ($key in $config.dnsZoneParameters.Keys) {
    $zone = $dns.zones[$config.dnsZoneParameters[$key]]
    if (-not $zone) { throw "Missing platform DNS mapping for $key." }
    $parameters.parameters[$key] = @{ value = "/subscriptions/$($dns.subscriptionId)/resourceGroups/$($dns.resourceGroupName)/providers/Microsoft.Network/privateDnsZones/$zone" }
}
$network = $config.networking
$parameters.parameters.existingVnetResourceId = @{ value = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($network.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($network.vnetName)" }
$parameters.parameters.hubIntegrationEgressNextHopIp = @{ value = $network.egressNextHopIp }
$parameters.parameters.hubIntegrationHubVnetResourceId = @{ value = "/subscriptions/$($network.hub.subscriptionId)/resourceGroups/$($network.hub.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($network.hub.vnetName)" }
$runner = Read-ScenarioConfig (Join-Path $PSScriptRoot '..\github-runner\config\deployment.json')
if ($Mode -eq 'Deploy') {
    $outputs = Invoke-CheckedCommand az @('deployment', 'group', 'show', '--subscription', $runner.subscriptionId, '--resource-group', $runner.resourceGroupName, '--name', 'github-runner', '--query', 'properties.outputs', '--output', 'json') | ConvertFrom-Json
    if (-not $outputs.registryId.value -or -not $outputs.registryEndpoint.value) { throw 'Deploy the reusable runner and private registry first.' }
    $parameters.parameters.hostedAgentContainerRegistryResourceId = @{ value = $outputs.registryId.value }
    $parameters.parameters.hostedAgentContainerRegistryEndpoint = @{ value = $outputs.registryEndpoint.value }
    $parameters.parameters.existingLogAnalyticsWorkspaceResourceId = @{ value = $outputs.workspaceId.value }
    $parameters.parameters.existingApplicationInsightsResourceId = @{ value = $outputs.appInsightsId.value }
    $insights = Invoke-CheckedCommand az @('resource', 'show', '--ids', $outputs.appInsightsId.value, '--output', 'json') | ConvertFrom-Json
    if (-not $insights.properties.ConnectionString) { throw 'Shared private Application Insights returned no connection string.' }
    $parameters.parameters.existingApplicationInsightsConnectionString = @{ value = $insights.properties.ConnectionString }
}
$parameters | ConvertTo-Json -Depth 100 -WarningAction Stop | Set-Content (Join-Path $OutputPath 'main.parameters.json')
Invoke-CheckedCommand az @('bicep', 'build', '--file', (Join-Path $OutputPath 'infra\bicep\main.bicep'), '--outfile', (Join-Path $OutputPath 'foundation.template.json'))
$template = Get-Content (Join-Path $OutputPath 'foundation.template.json') -Raw | ConvertFrom-Json -AsHashtable
$unknown = @($parameters.parameters.Keys | Where-Object { -not $template.parameters.ContainsKey($_) })
if ($unknown.Count) { throw "Overlay contains unsupported Bicep parameters: $($unknown -join ', ')." }
$payload = @{ properties = @{ mode = 'Incremental'; template = $template; parameters = $parameters.parameters } } | ConvertTo-Json -Depth 100 -Compress -WarningAction Stop
$payloadBytes = [Text.Encoding]::UTF8.GetByteCount($payload)
if ($payloadBytes -gt 4MB) { throw "Compiled foundation request exceeds ARM's 4 MB limit: $payloadBytes bytes." }
Write-Host "Compiled foundation request: $payloadBytes bytes."
if ($Mode -eq 'Validate') {
    Invoke-ScenarioNetwork $config (Join-Path $OutputPath 'network') -ValidateOnly
    Write-Host 'Pinned Bicep foundation and repository overlays compiled; no Azure resources changed.'
    return
}

$previous = Get-Location
try {
    Set-Location $OutputPath
    Invoke-CheckedCommand python @('-m', 'venv', '.venv')
    $python = if ($IsWindows) { Join-Path $OutputPath '.venv\Scripts\python.exe' } else { Join-Path $OutputPath '.venv\bin\python' }
    Invoke-CheckedCommand $python @('-m', 'pip', 'install', '-r', (Join-Path $OutputPath 'config\requirements.txt'))
    $oldPath = $env:PATH
    $env:PATH = "$(Split-Path $python -Parent)$([IO.Path]::PathSeparator)$oldPath"
    Invoke-CheckedCommand azd @('env', 'new', $config.environmentName, '--subscription', $config.subscriptionId, '--location', $config.location, '--no-prompt')
    $binding = Join-Path $ConfigPath 'resource-groups.json'
    if (-not (Test-Path -LiteralPath $binding -PathType Leaf)) { throw 'The recorded resource-group binding is required for ephemeral runners.' }
    Copy-Item -LiteralPath $binding -Destination (Join-Path $OutputPath ".azure\$($config.environmentName)\resource-groups.json")
    $environment = $config.environment.Clone()
    $environment.AZURE_RESOURCE_GROUP = $config.resourceGroupName
    $environment.AZURE_APP_RESOURCE_GROUP = $config.applicationResourceGroupName
    $environment.AZURE_NETWORK_RESOURCE_GROUP = $network.resourceGroupName
    $environment.AZURE_AI_FOUNDRY_LOCATION = $config.location
    $environment.AZURE_COSMOS_LOCATION = $config.location
    $environment.AZURE_SEARCH_LOCATION = $config.location
    $environment.HOSTED_AGENT_RESOURCE_SCOPE = $env:HOSTED_AGENT_RESOURCE_SCOPE
    $environment.ACR_TASK_AGENT_POOL = $runner.buildPoolName
    foreach ($key in $environment.Keys) { Invoke-CheckedCommand azd @('env', 'set', $key, $environment[$key], '--no-prompt') }
    Invoke-CheckedCommand azd @('hooks', 'run', 'preup', '--no-prompt')
    Invoke-CheckedCommand azd @('provision', '--no-prompt')
    & (Join-Path $PSScriptRoot 'Set-FoundryTraceIngestion.ps1') -ConfigPath $ConfigPath
    Write-Host 'Provisioned agent foundation and completed private post-provision configuration; no application images deployed.'
} finally {
    if (Get-Variable oldPath -ErrorAction SilentlyContinue) { $env:PATH = $oldPath }
    Set-Location $previous
}
