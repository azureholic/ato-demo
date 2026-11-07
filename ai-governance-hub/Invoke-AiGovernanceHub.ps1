#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config'),

    [ValidateSet('Validate', 'Network', 'Deploy')]
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

$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$configFile = Join-Path $ConfigPath 'deployment.json'
$parameterFile = Join-Path $ConfigPath 'main.bicepparam'
$config = Get-Content $configFile -Raw | ConvertFrom-Json
$dnsConfigFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'platform-alz\config\private-dns.json'
$dns = Get-Content $dnsConfigFile -Raw | ConvertFrom-Json
if ($config.upstreamRevision -cnotmatch '^[0-9a-f]{40}$') {
    throw 'Pin upstreamRevision to a full lowercase Git commit SHA.'
}
$subscriptionId = [guid]::Empty
if (-not [guid]::TryParse($config.subscriptionId, [ref]$subscriptionId) -or
    $subscriptionId -eq [guid]::Empty) {
    throw 'subscriptionId must be a nonempty Azure subscription GUID.'
}
if ($config.environmentName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$' -or
    $config.location -notmatch '^[a-z]+$') {
    throw 'Configure a valid environmentName and Azure location.'
}
if (@($config.aiFoundryInstances).Count -ne 2) {
    throw 'This scenario requires exactly two Foundry instances for the shared model endpoint.'
}
if (-not (Test-Path $parameterFile -PathType Leaf)) {
    throw "Missing parameter overlay: $parameterFile."
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path $OutputPath) {
    throw "Use a fresh output directory; refusing to overwrite $OutputPath."
}

Invoke-CheckedCommand git @(
    'clone', '--quiet', '--no-checkout', '--filter=blob:none',
    'https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator.git', $OutputPath
)
Invoke-CheckedCommand git @('-C', $OutputPath, 'checkout', '--quiet', '--detach', $config.upstreamRevision)
$revision = Invoke-CheckedCommand git @('-C', $OutputPath, 'rev-parse', 'HEAD')
if ($revision -cne $config.upstreamRevision) {
    throw "Upstream checkout does not match $($config.upstreamRevision)."
}
$infraPath = Join-Path $OutputPath 'bicep\infra'
foreach ($relativePath in 'azure.yaml', 'bicep\infra\main.bicep', 'bicep\infra\resources.bicep', 'bicep\infra\modules\networking\vnet.bicep', 'bicep\infra\modules\apim\apim.bicep', 'bicep\infra\modules\apim\universal-llm-api\AIFoundryOpenAI.json', 'src\usage-ingestion-logicapp\package.json') {
    if (-not (Test-Path (Join-Path $OutputPath $relativePath) -PathType Leaf)) {
        throw "Pinned upstream is missing $relativePath; review its deployment contract."
    }
}

$apimPath = Join-Path $infraPath 'modules\apim\apim.bicep'
$apimSource = Get-Content $apimPath -Raw
foreach ($endpoint in 'eventHubEndpoint', 'eventHubPIIEndpoint') {
    $original = "endpointAddress: replace($endpoint, 'https://', '')"
    if ([regex]::Matches($apimSource, [regex]::Escape($original)).Count -ne 1) {
        throw "Unexpected upstream Event Hubs logger expression for $endpoint; review hostname handling before deploying."
    }
    $canonical = "endpointAddress: split(split(split($endpoint, '://')[1], '/')[0], ':')[0]"
    $apimSource = $apimSource.Replace($original, $canonical)
}
Set-Content $apimPath $apimSource -NoNewline

$definitionPath = Join-Path $infraPath 'modules\apim\universal-llm-api\AIFoundryOpenAI.json'
$definition = Get-Content $definitionPath -Raw | ConvertFrom-Json -AsHashtable
$paths = $definition['paths']
if ($paths -isnot [Collections.IDictionary] -or
    $paths['/deployments/{deployment-id}'] -isnot [Collections.IDictionary] -or
    $paths['/deployments/{deployment-id}']['get'] -isnot [Collections.IDictionary]) {
    throw 'Unexpected upstream OpenAI deployment parameter schema; review the API definition before deploying.'
}
$deploymentGet = $paths['/deployments/{deployment-id}']['get']
$pathParameters = @($deploymentGet['parameters'] | Where-Object {
    $_['name'] -ceq 'deployment-id' -and $_['in'] -ceq 'path' -and $_['required'] -eq $true
})
if ($pathParameters.Count -ne 1 -or $deploymentGet['operationId'] -cne 'deployment-by-name') {
    throw 'Unexpected upstream OpenAI deployment parameter schema; review the API definition before deploying.'
}
$parameterSchema = $pathParameters[0]['schema']
if ($parameterSchema -isnot [Collections.IDictionary] -or
    $parameterSchema['type'] -isnot [string] -or $parameterSchema['type'] -cne '' -or
    $parameterSchema['enum'] -isnot [array] -or $parameterSchema['enum'].Count -ne 1 -or
    $parameterSchema['enum'][0] -cne '') {
    throw 'Unexpected upstream OpenAI deployment parameter schema; review the API definition before deploying.'
}
$parameterSchema['type'] = 'string'
$parameterSchema.Remove('enum')
$definition | ConvertTo-Json -Depth 100 -WarningAction Stop | Set-Content $definitionPath

if ($config.location -eq 'italynorth') {
    $allowedLocations = "@allowed([ 'uaenorth', 'southafricanorth', 'westeurope', 'southcentralus', 'australiaeast', 'canadaeast', 'eastus', 'eastus2', 'francecentral', 'japaneast', 'northcentralus', 'swedencentral', 'switzerlandnorth', 'uksouth' ])"
    foreach ($file in 'main.bicep', 'resources.bicep') {
        $path = Join-Path $infraPath $file
        $source = Get-Content $path -Raw
        $pattern = [regex]::Escape($allowedLocations) + '\r?\nparam location string'
        if ([regex]::Matches($source, $pattern).Count -ne 1) {
            throw "Unexpected upstream location allow-list in $file; review Italy North support before deploying."
        }
        $replacement = $allowedLocations.Replace("'uaenorth'", "'italynorth', 'uaenorth'")
        Set-Content $path ($source.Replace($allowedLocations, $replacement)) -NoNewline
    }
}

Copy-Item $configFile (Join-Path $OutputPath 'deployment.json')
Copy-Item $configFile (Join-Path $infraPath 'deployment.json')
Copy-Item $dnsConfigFile (Join-Path $infraPath 'private-dns.json')
Copy-Item $parameterFile (Join-Path $infraPath 'main.bicepparam') -Force
$networkPath = Join-Path $OutputPath 'networking'
New-Item $networkPath -ItemType Directory | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'networking\spoke.bicep'), (Join-Path $PSScriptRoot 'networking\peering.bicep') $networkPath
Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'platform-alz\config\private-dns-links.bicep') $networkPath
foreach ($file in 'spoke', 'private-dns-links') {
    Invoke-CheckedCommand az @(
        'bicep', 'build', '--file', (Join-Path $networkPath "$file.bicep"),
        '--outfile', (Join-Path $networkPath "$file.json")
    )
}
Invoke-CheckedCommand az @(
    'bicep', 'build-params', '--file', (Join-Path $infraPath 'main.bicepparam'),
    '--outfile', (Join-Path $OutputPath 'main.parameters.json')
)
Invoke-CheckedCommand az @(
    'bicep', 'build', '--file', (Join-Path $infraPath 'main.bicep'),
    '--outfile', (Join-Path $OutputPath 'main.json')
)
$template = Get-Content (Join-Path $OutputPath 'main.json') -Raw | ConvertFrom-Json -AsHashtable
$parameters = Get-Content (Join-Path $OutputPath 'main.parameters.json') -Raw | ConvertFrom-Json -AsHashtable
if (-not $template.ContainsKey('resources') -or -not $parameters.ContainsKey('parameters')) {
    throw 'Bicep did not produce a valid ARM template and parameter document.'
}
$payload = @{
    properties = @{
        mode = 'Incremental'
        template = $template
        parameters = $parameters.parameters
    }
} | ConvertTo-Json -Depth 100 -Compress -WarningAction Stop
$payloadBytes = [Text.Encoding]::UTF8.GetByteCount($payload)
if ($payloadBytes -gt 4MB) {
    throw "Compiled ARM request exceeds the 4 MB limit ($payloadBytes bytes)."
}
Write-Host "Compiled ARM request: $payloadBytes bytes."
Write-Host "Validated upstream $revision with repository configuration."
if ($Mode -eq 'Validate') { return }

$exists = Invoke-CheckedCommand az @(
    'group', 'exists', '--subscription', $dns.subscriptionId, '--name', $dns.resourceGroupName, '--output', 'tsv'
)
if ($exists -ne 'true') {
    throw "Shared DNS resource group $($dns.resourceGroupName) is missing; deploy the ALZ platform first."
}
$existingZones = Invoke-CheckedCommand az @(
    'network', 'private-dns', 'zone', 'list', '--subscription', $dns.subscriptionId,
    '--resource-group', $dns.resourceGroupName, '--output', 'json'
)
$zoneNames = @($dns.zones.PSObject.Properties.Value | Select-Object -Unique)
$existingZoneNames = @($existingZones | ConvertFrom-Json | ForEach-Object { $_.name })
$missingZones = @($zoneNames | Where-Object { $_ -notin $existingZoneNames })
if ($missingZones.Count -gt 0) {
    throw "Shared DNS zones are missing: $($missingZones -join ', '); deploy the ALZ platform first."
}
Invoke-CheckedCommand az @(
    'deployment', 'sub', 'create', '--subscription', $config.subscriptionId,
    '--name', "govhub-spoke-$($config.location)", '--location', $config.location,
    '--template-file', (Join-Path $networkPath 'spoke.json'), '--output', 'none'
)
$vnetJson = Invoke-CheckedCommand az @(
    'network', 'vnet', 'show', '--subscription', $config.subscriptionId,
    '--resource-group', $config.networking.resourceGroupName, '--name', $config.networking.vnetName, '--output', 'json'
)
$vnet = $vnetJson | ConvertFrom-Json
$dhcpOptions = $vnet.PSObject.Properties['dhcpOptions']
if ($null -ne $dhcpOptions -and $null -ne $dhcpOptions.Value) {
    $dnsServers = $dhcpOptions.Value.PSObject.Properties['dnsServers']
    if ($null -ne $dnsServers -and $null -ne $dnsServers.Value -and @($dnsServers.Value).Count -gt 0) {
        throw "VNet $($vnet.id) uses custom DNS; direct zone links alone cannot provide the requested resolver-free DNS."
    }
}
if ([string]::IsNullOrWhiteSpace($vnet.id)) { throw 'GovHub spoke lookup returned no VNet ID.' }
$dnsParameters = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        zoneNames = @{ value = $zoneNames }
        virtualNetworkIds = @{ value = @($vnet.id) }
    }
}
$dnsParameterPath = Join-Path $networkPath 'private-dns-links.parameters.json'
$dnsParameters | ConvertTo-Json -Depth 10 | Set-Content $dnsParameterPath
Invoke-CheckedCommand az @(
    'deployment', 'group', 'create', '--subscription', $dns.subscriptionId,
    '--resource-group', $dns.resourceGroupName, '--name', 'govhub-spoke-dns-links',
    '--template-file', (Join-Path $networkPath 'private-dns-links.json'),
    '--parameters', "@$dnsParameterPath", '--mode', 'Incremental', '--output', 'none'
)
Write-Host 'Prepared GovHub spoke peerings and links to existing platform DNS zones.'
if ($Mode -eq 'Network') { return }

$previousLocation = Get-Location
try {
    Set-Location $OutputPath
    Invoke-CheckedCommand azd @(
        'env', 'new', $config.environmentName, '--subscription', $config.subscriptionId,
        '--location', $config.location, '--no-prompt'
    )
    Invoke-CheckedCommand azd @('provision', '--environment', $config.environmentName, '--no-prompt')
    & (Join-Path $PSScriptRoot 'Set-LogicAppStorageExemption.ps1') -ConfigPath $ConfigPath
    Invoke-CheckedCommand azd @('deploy', '--environment', $config.environmentName, '--no-prompt')
} finally {
    Set-Location $previousLocation
}
