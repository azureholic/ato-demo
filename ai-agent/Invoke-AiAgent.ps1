[CmdletBinding()]
param(
    [ValidateSet('Validate', 'Prepare', 'Build', 'Deploy', 'Governance')]
    [string] $Mode = 'Validate',
    [ValidateSet('Full', 'Provision', 'Publish', 'Verify')]
    [string] $Phase = 'Full',
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config\deployment.json'),
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Tool {
    param([string] $Command, [string[]] $Arguments)
    $result = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE." }
    return $result
}

function Resolve-ConfigurationPath {
    param([string] $Relative)
    $native = $Relative.Replace('\', [IO.Path]::DirectorySeparatorChar)
    return [IO.Path]::GetFullPath((Join-Path (Split-Path $ConfigPath) $native))
}

function Get-FrontendOrigin {
    param([hashtable] $Environment)
    if (-not $Environment.ContainsKey('RESOURCE_TOKEN') -or -not $Environment.RESOURCE_TOKEN) {
        throw 'Native frontend resource token is missing.'
    }
    $fqdn = Invoke-Tool az @('containerapp', 'show', '--subscription', $config.subscriptionId,
        '--resource-group', $config.applicationResourceGroupName, '--name', "ca-$($Environment.RESOURCE_TOKEN)-frontend",
        '--query', 'properties.configuration.ingress.fqdn', '-o', 'tsv')
    if (-not $fqdn -or $fqdn -notmatch '^[a-z0-9.-]+\.azurecontainerapps\.io$') {
        throw 'Native frontend has no valid Azure Container Apps ingress hostname.'
    }
    return "https://$fqdn"
}

function Get-PinnedCheckout {
    param([string] $Repository, [string] $Revision, [string] $Directory)
    if ($Revision -notmatch '^[a-f0-9]{40}$') { throw 'Use a full upstream commit, never a mutable tag.' }
    if (-not (Test-Path (Join-Path $Directory '.git'))) {
        if ((Test-Path $Directory) -and @(Get-ChildItem $Directory -Force).Count -gt 0) {
            throw "Refusing to clone into a nonempty unmanaged directory: $Directory"
        }
        $null = Invoke-Tool git @('clone', '--filter=blob:none', '--no-checkout', $Repository, $Directory)
        $null = Invoke-Tool git @('-C', $Directory, 'checkout', '--detach', $Revision)
    }
    $origin = Invoke-Tool git @('-C', $Directory, 'remote', 'get-url', 'origin')
    $head = Invoke-Tool git @('-C', $Directory, 'rev-parse', 'HEAD')
    if ($origin -ne $Repository -or $head -ne $Revision) {
        throw 'Existing deployment checkout does not match the configured repository and immutable pin.'
    }
    return $Directory
}

function Set-ScenarioEnvironment {
    param([string] $PrincipalId)
    $vnetId = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.networking.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($config.networking.vnetName)"
    $hub = $config.networking.hub
    $variant = [ordered]@{
        adapter = (Invoke-Tool python @((Join-Path $PSScriptRoot 'Patch-AiAgent.py'), 'fingerprint'))
        endpoint = $config.governance.endpoint
        privatePrefix = $govhub.vnetAddressPrefix
        model = $govhub.model.name
        apiVersion = $govhub.model.apiVersion
        vault = $config.keyVaultName
        environment = $config.environmentName
        resourceGroup = $config.resourceGroupName
        applicationResourceGroup = $config.applicationResourceGroupName
    } | ConvertTo-Json -Compress
    $variantHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($variant))).ToLowerInvariant().Substring(0, 16)
    $values = [ordered]@{
        AZURE_ENV_NAME = $config.environmentName
        AZURE_SUBSCRIPTION_ID = $config.subscriptionId
        AZURE_TENANT_ID = $config.authentication.tenantId
        AZURE_LOCATION = $config.location
        AZURE_AI_FOUNDRY_LOCATION = $config.location
        AZURE_COSMOS_LOCATION = $config.location
        AZURE_SEARCH_LOCATION = $config.location
        AZURE_RESOURCE_GROUP = $config.resourceGroupName
        AZURE_APP_RESOURCE_GROUP = $config.applicationResourceGroupName
        AZURE_NETWORK_RESOURCE_GROUP = $config.networking.resourceGroupName
        CREATE_RESOURCE_GROUPS = 'false'
        AZURE_PRINCIPAL_ID = $PrincipalId
        AZURE_PRINCIPAL_TYPE = 'ServicePrincipal'
        NETWORK_ISOLATION = 'true'
        USE_EXISTING_VNET = 'true'
        EXISTING_VNET_RESOURCE_ID = $vnetId
        DEPLOY_SUBNETS = 'true'
        DEPLOYMENT_MODE = 'ailz-integrated'
        HUB_INTEGRATION_EGRESS_NEXT_HOP_IP = '10.100.0.4'
        HUB_INTEGRATION_HUB_VNET_RESOURCE_ID = "/subscriptions/$($hub.subscriptionId)/resourceGroups/$($hub.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($hub.vnetName)"
        HUB_INTEGRATION_CREATE_HUB_PEERING = 'false'
        USE_UAI = 'true'
        ORCHESTRATION_HOST = 'hosted'
        APPLICATION_MODE = 'conversational'
        HOSTED_AGENT_AUTH_MODE = 'user_delegated'
        HOSTED_AGENT_RESOURCE_SCOPE = $config.authentication.hostedAgentResourceScope
        DEPLOY_AZURE_FIREWALL = 'false'
        DEPLOY_BASTION = 'false'
        DEPLOY_JUMPBOX = 'false'
        DEPLOY_NAT_GATEWAY = 'false'
        DEPLOY_AZURE_BASTION_SUBNET = 'false'
        DEPLOY_AZURE_FIREWALL_SUBNET = 'false'
        DEPLOY_AZURE_FIREWALL_MANAGEMENT_SUBNET = 'false'
        DEPLOY_APP_GATEWAY_SUBNET = 'false'
        DEPLOY_JUMPBOX_SUBNET = 'false'
        DEPLOY_POWER_PLATFORM_SUBNET = 'false'
        DEPLOY_AI_GATEWAY_SUBNET = 'false'
        DEPLOY_SEARCH_SERVICE = 'false'
        ENABLE_AGENTIC_RETRIEVAL = 'false'
        DEPLOY_GROUNDING_WITH_BING = 'false'
        DEPLOY_ACR_TASK_AGENT_POOL = 'false'
        DEPLOY_DEVOPS_BUILD_AGENTS_SUBNET = 'false'
        BUILD_MODE = 'local'
        USE_DOCKER = 'false'
        ATO_ADAPTER_ROOT = $PSScriptRoot
        HOSTED_AGENT_STARTUP_COMMAND = 'python -m native.hosted'
        DEPLOY_INGESTION_CONTAINER_APP = 'false'
        NATIVE_TOOL_SECRET_NAMES = (ConvertTo-Json -InputObject @($config.governance.secretName) -Compress)
        ATO_GOVHUB_ADAPTER_HASH = $variantHash
    }
    foreach ($entry in $values.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
    }
    return $values
}

function Set-ScenarioParameters {
    param([string] $Checkout)
    $original = Invoke-Tool git @('-C', $Checkout, 'show', 'HEAD:main.parameters.json')
    $document = ($original -join "`n") | ConvertFrom-Json -AsHashtable
    $parameters = $document.parameters
    $parameters.vnetAddressPrefixes.value = @($config.networking.addressPrefix)
    $parameters.keyVaultName.value = $config.keyVaultName
    $parameters.modelDeploymentList.value = @()
    foreach ($name in @($parameters.Keys)) {
        if ($name -like '*SubnetPrefix') {
            $parameters[$name].value = $parameters[$name].value.Replace('192.168.', '10.180.')
        }
    }
    $mapping = @{
        CogSvcs = 'cognitiveServices'; OpenAi = 'openai'; AiServices = 'aiServices'
        Cosmos = 'cosmosDb'; Blob = 'storageBlob'; KeyVault = 'keyVault'
        AppConfig = 'appConfiguration'; ContainerApps = 'containerAppsItalyNorth'
        Acr = 'containerRegistry'; AzureMonitor = 'azureMonitor'
        OmsOpsInsights = 'logAnalyticsOms'; OdsOpsInsights = 'logAnalyticsOds'
        AzureAutomation = 'azureAutomation'; AppInsights = 'applicationInsights'
    }
    foreach ($entry in $mapping.GetEnumerator()) {
        $name = "existingPrivateDnsZone$($entry.Key)ResourceId"
        if (-not $parameters.ContainsKey($name)) { throw "Upstream DNS parameter changed: $name" }
        $zone = $dns.zones[$entry.Value]
        if (-not $zone) { throw "Platform DNS is missing the enabled Agent zone: $($entry.Value)" }
        $parameters[$name].value = "/subscriptions/$($dns.subscriptionId)/resourceGroups/$($dns.resourceGroupName)/providers/Microsoft.Network/privateDnsZones/$zone"
    }
    $settings = @(
        @{ name = 'GOVHUB_ENDPOINT'; value = $config.governance.endpoint; label = 'agent-lz' },
        @{ name = 'GOVHUB_API_VERSION'; value = $govhub.model.apiVersion; label = 'agent-lz' },
        @{ name = 'GOVHUB_SUBSCRIPTION_SECRET_URI'; value = "https://$($config.keyVaultName).vault.azure.net/secrets/$($config.governance.secretName)"; label = 'agent-lz' },
        @{ name = 'GOVHUB_PRIVATE_ADDRESS_PREFIX'; value = $govhub.vnetAddressPrefix; label = 'agent-lz' },
        @{ name = 'CHAT_DEPLOYMENT_NAME'; value = $govhub.model.name; label = 'agent-lz' },
        @{ name = 'SEARCH_RETRIEVAL_ENABLED'; value = 'false'; label = 'agent-lz' },
        @{ name = 'FOUNDRY_IQ_ENABLED'; value = 'false'; label = 'agent-lz' },
        @{ name = 'MCP_ENABLED'; value = 'false'; label = 'agent-lz' },
        @{ name = 'MULTIMODAL_ENABLED'; value = 'false'; label = 'agent-lz' },
        @{ name = 'ALLOW_ANONYMOUS'; value = 'false'; label = 'agent-lz' },
        @{ name = 'OAUTH_AZURE_AD_CLIENT_ID'; value = $config.authentication.uiClientId; label = 'agent-lz' },
        @{ name = 'OAUTH_AZURE_AD_TENANT_ID'; value = $config.authentication.tenantId; label = 'agent-lz' },
        @{ name = 'OAUTH_AZURE_AD_ENABLE_SINGLE_TENANT'; value = 'true'; label = 'agent-lz' },
        @{ name = 'OAUTH_AZURE_AD_SCOPES'; value = "$($config.authentication.uiApiScope) openid profile offline_access"; label = 'agent-lz' },
        @{ name = 'OAUTH_AZURE_AD_CLIENT_SECRET'; value = (@{ uri = $config.authentication.uiClientSecretReference } | ConvertTo-Json -Compress); label = 'agent-lz'; contentType = 'application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8' },
        @{ name = 'CHAINLIT_AUTH_SECRET'; value = (@{ uri = "https://$($config.keyVaultName).vault.azure.net/secrets/chainlit-auth-secret" } | ConvertTo-Json -Compress); label = 'agent-lz'; contentType = 'application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8' }
    )
    $parameters.additionalAppConfigurationSettings.value += $settings
    $document | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $Checkout 'main.parameters.json') -Encoding utf8NoBOM
    $null = Invoke-Tool python @((Join-Path $PSScriptRoot 'Patch-AiAgent.py'), 'template', $Checkout)
}

function Set-GovernanceContract {
    param([string] $Directory)
    $checkout = Get-PinnedCheckout 'https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator.git' $govhub.upstreamRevision (Join-Path $Directory 'govhub')
    $gatewayName = ([uri]$config.governance.endpoint).Host.Split('.')[0]
    $gatewayId = "/subscriptions/$($govhub.subscriptionId)/resourceGroups/$($govhub.resourceGroupName)/providers/Microsoft.ApiManagement/service/$gatewayName"
    $gateway = (Invoke-Tool az @('resource', 'show', '--ids', $gatewayId, '--api-version', '2024-05-01', '-o', 'json')) | ConvertFrom-Json
    if ($gateway.properties.gatewayUrl.TrimEnd('/') + '/openai/' -ne $config.governance.endpoint) {
        throw 'GovHub scenario endpoint does not match the deployed gateway.'
    }
    $model = $govhub.model.name
    if ($model -notmatch '^[a-zA-Z0-9._-]+$') { throw 'GovHub model name cannot safely be used in the product policy.' }
    $policy = @"
<policies><inbound><base /><include-fragment fragment-id="set-llm-requested-model" /><set-variable name="allowedModels" value="$model" /><llm-token-limit counter-key="@(context.Subscription.Id)" tokens-per-minute="$($config.governance.tokensPerMinute)" estimate-prompt-tokens="false" token-quota="$($config.governance.monthlyTokenQuota)" token-quota-period="Monthly" /><set-variable name="enableResponseHeaders" value="@(true)" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>
"@
    $values = @{
        apim = @{ subscriptionId = $govhub.subscriptionId; resourceGroupName = $govhub.resourceGroupName; name = $gatewayName }
        keyVault = @{ subscriptionId = $config.subscriptionId; resourceGroupName = $config.applicationResourceGroupName; name = $config.keyVaultName }
        useTargetAzureKeyVault = $true
        useTargetFoundry = $false
        keyRotationEnabled = $false
        useCase = @{ businessUnit = $config.governance.businessUnit; useCaseName = $config.governance.useCaseName; environment = $config.governance.environment }
        apiNameMapping = @{ LLM = @($config.governance.apiName) }
        services = @(@{ code = 'LLM'; apiKeySecretName = $config.governance.secretName; endpointSecretName = $config.governance.endpointSecretName; policyXml = $policy })
    }
    $parameters = @{}
    foreach ($entry in $values.GetEnumerator()) { $parameters[$entry.Key] = @{ value = $entry.Value } }
    $file = Join-Path $Directory 'govhub-contract.parameters.json'
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 30 | Set-Content $file -Encoding utf8NoBOM
    $state = Invoke-Tool az @('deployment', 'sub', 'create', '--subscription', $config.subscriptionId,
        '--location', $config.location, '--name', 'ai-agent-govhub-contract',
        '--template-file', (Join-Path $checkout 'bicep\infra\citadel-access-contracts\main.bicep'),
        '--parameters', "@$file", '--query', 'properties.provisioningState', '-o', 'tsv')
    if ($state -ne 'Succeeded') { throw "Agent-specific GovHub access contract did not succeed: $state" }
    Write-Host 'Agent-specific model product deployed; subscription key stored directly in the private Agent vault.'
}

function Build-WorkflowImages {
    param([string] $Checkout)
    $manifest = Get-Content (Join-Path $Checkout 'manifest.json') -Raw | ConvertFrom-Json
    $directory = Join-Path $OutputPath 'images'
    $null = New-Item $directory -ItemType Directory -Force
    $images = @()
    foreach ($name in 'agent-app-orchestrator', 'agent-app-ui') {
        $components = @($manifest.components | Where-Object name -eq $name)
        $expected = if ($name -eq 'agent-app-orchestrator') { '666d39862590cfb165097ee55737a1ef66fd2afc' } else { '8a45595aa321d8841e7a4555d542b890beebf1b0' }
        if ($components.Count -ne 1 -or $components[0].commit -ne $expected) {
            throw "Immutable component manifest changed: $name"
        }
        $component = $components[0]
        $source = Get-PinnedCheckout $component.repo $component.commit (Join-Path $OutputPath $name)
        if ($name -eq 'agent-app-orchestrator') {
            $null = Invoke-Tool python @((Join-Path $PSScriptRoot 'Patch-AiAgent.py'), 'runtime', $source)
        }
        $tag = "ato-$($component.commit.Substring(0, 12))-$env:ATO_GOVHUB_ADAPTER_HASH"
        $arguments = @('build', '--platform', 'linux/amd64', '--label', "ato.configuration=$env:ATO_GOVHUB_ADAPTER_HASH", '--tag', "${name}:$tag")
        if ($name -eq 'agent-app-orchestrator') { $arguments += @('--target', 'hosted') }
        $null = Invoke-Tool docker ($arguments + @($source))
        $file = "$name.tar"
        $null = Invoke-Tool docker @('save', '--output', (Join-Path $directory $file), "${name}:$tag")
        $images += @{ name = $name; sourceCommit = $component.commit; tag = $tag; file = $file; sha256 = (Get-FileHash (Join-Path $directory $file) -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $revision = Invoke-Tool git @('-C', (Split-Path $PSScriptRoot), 'rev-parse', 'HEAD')
    @{ schemaVersion = 1; revision = $revision; configurationHash = $env:ATO_GOVHUB_ADAPTER_HASH; components = $images } |
        ConvertTo-Json -Depth 10 | Set-Content (Join-Path $directory 'manifest.json') -Encoding utf8NoBOM
    Write-Host 'Pinned container images exported as checksummed workflow artifacts; no private registry access from the hosted builder.'
}

function Set-WorkflowImages {
    param([hashtable] $Environment)
    if (-not $env:ATO_IMAGE_ARTIFACT_PATH -or -not $env:ATO_REVISION) {
        throw 'Publication requires the same-run immutable workflow image artifacts.'
    }
    $manifest = (Invoke-Tool python @((Join-Path $PSScriptRoot 'Agent-Images.py'), 'verify',
        '--directory', $env:ATO_IMAGE_ARTIFACT_PATH, '--revision', $env:ATO_REVISION,
        '--configuration-hash', $env:ATO_GOVHUB_ADAPTER_HASH)) | ConvertFrom-Json
    $endpoint = $Environment.AZURE_CONTAINER_REGISTRY_ENDPOINT.TrimEnd('/')
    if ($endpoint -notmatch '^[a-z0-9]+\.azurecr\.io$') { throw 'Provisioned private registry endpoint is invalid.' }
    $registry = $endpoint.Split('.')[0]
    $directory = "/dev/shm/ai-agent-acr-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item $directory -ItemType Directory
    $auth = Join-Path $directory 'auth.json'
    try {
        $loginToken = Invoke-Tool az @('acr', 'login', '--name', $registry, '--expose-token', '--query', 'accessToken', '-o', 'tsv', '--only-show-errors')
        $loginToken | & skopeo login --authfile $auth --username 00000000-0000-0000-0000-000000000000 --password-stdin $endpoint
        if ($LASTEXITCODE -ne 0) { throw 'Private managed-identity registry login failed.' }
        $loginToken = $null
        foreach ($component in $manifest.components) {
            $imageName = $component.name
            $image = "$endpoint/${imageName}:$($component.tag)"
            $archive = Join-Path $env:ATO_IMAGE_ARTIFACT_PATH $component.file
            $null = Invoke-Tool skopeo @('copy', '--authfile', $auth, '--format', 'v2s2', "docker-archive:$archive", "docker://$image")
            $digest = Invoke-Tool az @('acr', 'repository', 'show', '--name', $registry,
                '--image', "${imageName}:$($component.tag)", '--query', 'digest', '-o', 'tsv')
            if ($digest -notmatch '^sha256:[a-f0-9]{64}$') { throw 'Private artifact import did not yield an immutable digest.' }
            if ($imageName -eq 'agent-app-ui') {
                $null = Invoke-Tool azd @('env', 'set', 'ATO_UI_IMAGE', "$endpoint/$imageName@$digest")
            } else {
                $startupHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes('python -m native.hosted'))).ToLowerInvariant()
                foreach ($entry in @{
                    HOSTED_AGENT_IMAGE = $imageName
                    HOSTED_AGENT_IMAGE_VERSION = $digest
                    HOSTED_AGENT_IMAGE_SOURCE_COMMIT = $component.sourceCommit
                    HOSTED_AGENT_IMAGE_STARTUP_COMMAND_SHA256 = $startupHash
                }.GetEnumerator()) { $null = Invoke-Tool azd @('env', 'set', $entry.Key, $entry.Value) }
            }
            Write-Host "Verified private image imported: $imageName@$digest"
        }
    } finally {
        $loginToken = $null
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}

$ConfigPath = (Resolve-Path $ConfigPath).Path
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$govhub = Get-Content (Resolve-ConfigurationPath $config.governanceHubConfiguration) -Raw | ConvertFrom-Json -AsHashtable
$dns = Get-Content (Resolve-ConfigurationPath $config.privateDnsConfiguration) -Raw | ConvertFrom-Json -AsHashtable
if ($config.upstreamRepository -ne 'https://github.com/Azure/agent-landing-zone.git' -or
    $config.upstreamRevision -ne 'a75485015afeddc8b9221538778ef918718ed51f') {
    throw 'This adapter is tested only against the declared immutable native template pin.'
}
if ($config.subscriptionId -ne $govhub.subscriptionId -or $config.location -ne 'italynorth' -or
    $config.location -ne $govhub.location -or $config.networking.addressPrefix -ne '10.180.0.0/21') {
    throw 'Agent must use the validated Italy North subscription and non-overlapping dedicated address plan.'
}
if ($config.application.mode -ne 'conversational' -or $config.application.orchestrationHost -ne 'hosted' -or
    $config.application.enableRetrieval -or $config.application.enableMcp -or $config.application.deployLocalModels) {
    throw 'This scenario explicitly supports hosted conversation through GovHub, not optional retrieval or local model deployments.'
}
if ($config.authentication.hostedAgentAuthMode -ne 'user_delegated' -or
    $config.authentication.hostedAgentResourceScope -ne 'https://ai.azure.com/.default' -or
    $config.authentication.uiClientSecretReference -ne "https://$($config.keyVaultName).vault.azure.net/secrets/ui-oauth-client-secret") {
    throw 'Preserve the real Foundry hosting audience and the configured private UI credential reference.'
}
if ($config.governance.tokensPerMinute -le 0 -or $config.governance.monthlyTokenQuota -le 0) {
    throw 'GovHub access contract requires explicit positive token limits.'
}
if ($config.deploymentHost.buildMode -ne 'workflow-artifact' -or $config.deploymentHost.type -ne 'container-app-job') {
    throw 'Use the private Container Apps Job with checked workflow image artifacts; no private Docker or public ACR build fallback.'
}
if ($Mode -eq 'Validate') {
    Write-Host 'Agent scenario validated: pinned template, Italy, isolated spoke, central DNS, delegated hosting, GovHub-only inference.'
    return
}
if (-not $OutputPath) { throw 'Provide a deployment output directory outside the configuration repository.' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot))
if ($OutputPath.Equals($repositoryRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $OutputPath.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Upstream checkouts and deployment state must remain outside this repository.'
}
$null = New-Item $OutputPath -ItemType Directory -Force
if ($Mode -eq 'Governance') { Set-GovernanceContract $OutputPath; return }
$checkout = Get-PinnedCheckout $config.upstreamRepository $config.upstreamRevision (Join-Path $OutputPath 'agent-landing-zone')
$null = Set-ScenarioEnvironment ([guid]::Empty.ToString())
Set-ScenarioParameters $checkout
if ($Mode -eq 'Prepare') {
    Write-Host "Pinned native template configured outside the repository: $checkout"
    return
}
if ($Mode -eq 'Build') { Build-WorkflowImages $checkout; return }

Push-Location $checkout
try {
    $pythonProbe = & python -c 'import azure.identity; import azure.appconfiguration; import azure.mgmt.appcontainers; import azure.ai.projects; import jsonschema; import yaml' 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (($pythonProbe -join "`n") -notmatch 'ModuleNotFoundError') { throw ($pythonProbe -join "`n") }
        $null = Invoke-Tool python @('-m', 'venv', (Join-Path $OutputPath '.venv'))
        $bin = if ($IsWindows) { Join-Path $OutputPath '.venv\Scripts' } else { Join-Path $OutputPath '.venv\bin' }
        $env:PATH = $bin + [IO.Path]::PathSeparator + $env:PATH
        $null = Invoke-Tool python @('-m', 'pip', 'install', '-r', (Join-Path $checkout 'config\requirements.txt'))
    }
    $token = (Invoke-Tool az @('account', 'get-access-token', '--resource', 'https://management.azure.com/', '-o', 'json')) | ConvertFrom-Json
    $payload = $token.accessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight([int]([Math]::Ceiling($payload.Length / 4.0) * 4), '=')
    $principal = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json).oid
    $token = $null
    $payload = $null
    $principalGuid = [guid]::Empty
    if (-not [guid]::TryParse($principal, [ref]$principalGuid) -or $principalGuid -eq [guid]::Empty) {
        throw 'Cannot resolve the actual private deployment host principal.'
    }
    $values = Set-ScenarioEnvironment $principal
    $null = Invoke-Tool azd @('config', 'set', 'auth.useAzCliAuth', 'true')
    $environments = (Invoke-Tool azd @('env', 'list', '-o', 'json')) | ConvertFrom-Json
    if (@($environments | Where-Object Name -eq $config.environmentName).Count -eq 0) {
        $null = Invoke-Tool azd @('env', 'new', $config.environmentName, '--subscription', $config.subscriptionId, '--location', $config.location, '--no-prompt')
    }
    $null = Invoke-Tool azd @('env', 'select', $config.environmentName)
    $existing = (Invoke-Tool azd @('env', 'get-values', '-o', 'json')) | ConvertFrom-Json -AsHashtable
    if (-not $existing.ContainsKey('ATO_GOVHUB_ADAPTER_HASH') -or $existing.ATO_GOVHUB_ADAPTER_HASH -ne $values.ATO_GOVHUB_ADAPTER_HASH) {
        $null = Invoke-Tool azd @('env', 'set', 'HOSTED_AGENT_IMAGE_VERSION', '')
    }
    foreach ($entry in $values.GetEnumerator()) { $null = Invoke-Tool azd @('env', 'set', $entry.Key, [string]$entry.Value) }
    if ($Phase -in 'Publish', 'Verify') {
        $null = Invoke-Tool azd @('env', 'refresh', '--no-prompt')
    }
    if ($Phase -in 'Full', 'Provision') {
        $null = Invoke-Tool azd @('provision', '--no-prompt')
    }
    if ($Phase -in 'Full', 'Publish') {
        $secrets = (Invoke-Tool az @('keyvault', 'secret', 'list', '--vault-name', $config.keyVaultName,
            '--query', '[].{name:name,enabled:attributes.enabled,expires:attributes.expires}', '-o', 'json')) | ConvertFrom-Json
        foreach ($name in 'ui-oauth-client-secret', 'chainlit-auth-secret', $config.governance.secretName) {
            $matching = @($secrets | Where-Object { $_.name -eq $name -and $_.enabled })
            if ($matching.Count -ne 1) {
                throw "Required enabled private-vault secret missing: $name. Complete the one-time UI administrator handoff / GovHub contract, then run Publish again."
            }
            if ($matching[0].expires -and [DateTimeOffset]::Parse($matching[0].expires) -le [DateTimeOffset]::UtcNow) {
                throw "Required private-vault secret has expired: $name. Rotate it before publishing."
            }
        }
        $publishedEnvironment = (Invoke-Tool azd @('env', 'get-values', '-o', 'json')) | ConvertFrom-Json -AsHashtable
        foreach ($name in 'APP_CONFIG_ENDPOINT', 'AZURE_AI_PROJECT_ENDPOINT', 'AZURE_CONTAINER_REGISTRY_ENDPOINT') {
            if (-not $publishedEnvironment.ContainsKey($name) -or -not $publishedEnvironment[$name]) {
                throw "Private build endpoint missing: $name"
            }
            [Environment]::SetEnvironmentVariable($name, [string]$publishedEnvironment[$name], 'Process')
        }
        $origin = Get-FrontendOrigin $publishedEnvironment
        $null = Invoke-Tool az @('appconfig', 'kv', 'set', '--endpoint', $publishedEnvironment.APP_CONFIG_ENDPOINT,
            '--auth-mode', 'login', '--label', 'agent-lz', '--key', 'CHAINLIT_URL', '--value', $origin,
            '--yes', '--only-show-errors', '-o', 'none')
        $null = Invoke-Tool python @('-m', 'config.deployment.private_network', '--stage', 'pre-deploy')
        Set-WorkflowImages $publishedEnvironment
        $null = Invoke-Tool azd @('deploy', '--no-prompt')
    }
    if ($Phase -in 'Full', 'Verify') {
        $environment = (Invoke-Tool azd @('env', 'get-values', '-o', 'json')) | ConvertFrom-Json -AsHashtable
        foreach ($name in 'APP_CONFIG_ENDPOINT', 'AZURE_AI_PROJECT_ENDPOINT', 'AZURE_CONTAINER_REGISTRY_ENDPOINT') {
            if (-not $environment.ContainsKey($name) -or -not $environment[$name]) { throw "Missing private endpoint binding: $name" }
            [Environment]::SetEnvironmentVariable($name, [string]$environment[$name], 'Process')
        }
        $null = Invoke-Tool python @('-m', 'config.deployment.private_network', '--stage', 'pre-deploy')
        foreach ($name in 'AZURE_AI_PROJECT_ENDPOINT', 'KEY_VAULT_URI', 'APP_CONFIG_ENDPOINT', 'HOSTED_AGENT_IMAGE_VERSION') {
            if (-not $environment.ContainsKey($name) -or -not $environment[$name]) { throw "Missing effective publication evidence: $name" }
        }
        if ($environment.HOSTED_AGENT_IMAGE_VERSION -notmatch '^sha256:[a-f0-9]{64}$') {
            throw 'Published hosted-agent image must be immutable.'
        }
        $origin = Get-FrontendOrigin $environment
        $expectedSettings = @{
            GOVHUB_ENDPOINT = $config.governance.endpoint
            GOVHUB_API_VERSION = $govhub.model.apiVersion
            CHAT_DEPLOYMENT_NAME = $govhub.model.name
            AI_FOUNDRY_PROJECT_ENDPOINT = $environment.AZURE_AI_PROJECT_ENDPOINT
            CHAINLIT_URL = $origin
        }
        foreach ($entry in $expectedSettings.GetEnumerator()) {
            $actual = Invoke-Tool az @('appconfig', 'kv', 'show', '--endpoint', $environment.APP_CONFIG_ENDPOINT,
                '--auth-mode', 'login', '--label', 'agent-lz', '--key', $entry.Key, '--query', 'value', '-o', 'tsv')
            if ($actual -ne $entry.Value) { throw "Effective native runtime setting differs from the scenario: $($entry.Key)" }
        }
        $null = Invoke-Tool python @((Join-Path $PSScriptRoot 'Verify-GovHub.py'), '--config', $ConfigPath,
            '--governance-config', (Resolve-ConfigurationPath $config.governanceHubConfiguration))
        $anonymous = Invoke-WebRequest "$origin/user" -SkipHttpErrorCheck -TimeoutSec 60
        if ($anonymous.StatusCode -notin 401, 403) { throw 'Signed-out UI identity endpoint did not deny anonymous access.' }
        Write-Host 'Private native endpoints, immutable hosted publication, real GovHub product invocation and signed-out UI denial verified.'
    }
}
finally {
    Pop-Location
}
