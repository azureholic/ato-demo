#Requires -Version 7.4
<#
.SYNOPSIS
  Deploys the Web IQ prompt agent on the Agent Landing Zone Foundry project with models from the AI Governance Hub.
.DESCRIPTION
  Validate  Compile the pinned Citadel access contract overlay and both project connection templates. No Azure calls.
  Contract  Deploy the Citadel access contract (APIM product/subscription/policy for unified-ai-api), then the Hub model
            project connection with the OpenAI-compatible base URL (https://<apim>/unified-ai/v1).
  WebIq     Deploy the Web IQ MCP project connection. Requires WEBIQ_API_KEY in the environment.
  Agent     Publish a new prompt-agent version, optionally followed by a smoke question that
            auto-approves only the configured Web IQ tools. Needs private data-plane access.
  ModelCheck Publish a tool-less '<agent>-model-check' agent and verify completion and function tool
            calling through the Governance Hub model connection. Works without the Web IQ connection.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath,

    [ValidateSet('Validate', 'Contract', 'WebIq', 'Agent', 'ModelCheck')]
    [string]$Mode = 'Validate',

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config' 'deployment.json'),

    [string]$SmokeQuestion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..' '..' 'infrastructure' 'shared-infrastructure' 'Deployment.ps1')

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$guid = [guid]::Empty
if (-not [guid]::TryParse($config.subscriptionId, [ref]$guid) -or $guid -eq [guid]::Empty) {
    throw 'subscriptionId must be a nonempty Azure subscription GUID.'
}
if ($config.upstreamRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'Pin upstreamRevision to a full lowercase Git SHA.' }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path $OutputPath) { throw "Use a fresh output path; refusing to overwrite $OutputPath." }

function Resolve-SingleName {
    param([string]$Configured, [string[]]$Candidates, [string]$What)
    if ($Configured) { return $Configured }
    $found = @($Candidates | Where-Object { $_ })
    if ($found.Count -ne 1) {
        throw "Expected exactly one $What but found $($found.Count); set it explicitly in config/deployment.json."
    }
    return $found[0]
}

function Resolve-AzureTargets {
    $subscription = $config.subscriptionId
    $hubGroup = $config.governanceHub.resourceGroupName
    $foundryGroup = $config.foundry.resourceGroupName
    $apim = Invoke-CheckedCommand az @('apim', 'list', '--subscription', $subscription, '--resource-group', $hubGroup, '--query', '[].name', '--output', 'json') | ConvertFrom-Json
    $accounts = Invoke-CheckedCommand az @('cognitiveservices', 'account', 'list', '--subscription', $subscription, '--resource-group', $foundryGroup, '--query', "[?kind=='AIServices'].name", '--output', 'json') | ConvertFrom-Json
    $accountName = Resolve-SingleName $config.foundry.accountName $accounts 'Foundry account'
    $projects = Invoke-CheckedCommand az @('resource', 'list', '--subscription', $subscription, '--resource-group', $foundryGroup, '--resource-type', 'Microsoft.CognitiveServices/accounts/projects', '--query', '[].name', '--output', 'json') | ConvertFrom-Json
    $projectNames = @($projects | Where-Object { $_ -like "$accountName/*" } | ForEach-Object { $_.Split('/')[1] })
    $projectName = Resolve-SingleName $config.foundry.projectName $projectNames 'Foundry project'
    $subDomain = Invoke-CheckedCommand az @('cognitiveservices', 'account', 'show', '--subscription', $subscription, '--resource-group', $foundryGroup, '--name', $accountName, '--query', 'properties.customSubDomainName', '--output', 'tsv')
    if (-not $subDomain) { throw "Foundry account $accountName has no custom subdomain." }
    return @{
        ApimName    = Resolve-SingleName $config.governanceHub.apimName $apim 'Governance Hub API Management instance'
        AccountName = $accountName
        ProjectName = $projectName
        Endpoint    = "https://$subDomain.services.ai.azure.com/api/projects/$projectName"
    }
}

function Assert-PolicyMatchesConfiguration {
    $policy = Get-Content (Join-Path $PSScriptRoot 'access-contract' 'ai-product-policy.xml') -Raw
    $expected = @(
        "name=""allowedModels"" value=""$($config.model.name)"""
        "tokens-per-minute=""$($config.model.tokensPerMinute)"""
        "token-quota=""$($config.model.monthlyTokenQuota)"""
    )
    foreach ($fragment in $expected) {
        if (-not $policy.Contains($fragment)) {
            throw "access-contract/ai-product-policy.xml is out of sync with config/deployment.json; expected $fragment."
        }
    }
}

function Initialize-Contract {
    Copy-PinnedUpstream $config $OutputPath | Out-Null
    $contracts = Join-Path $OutputPath 'bicep' 'infra' 'citadel-access-contracts'
    foreach ($relative in @('main.bicep', (Join-Path 'modules' 'foundryConnection.bicep'), (Join-Path 'policies' 'default-ai-product-policy.xml'))) {
        if (-not (Test-Path (Join-Path $contracts $relative) -PathType Leaf)) {
            throw "Pinned upstream is missing citadel-access-contracts/$relative; review its contract."
        }
    }
    $overlay = Join-Path $contracts 'contracts' 'platform' 'web-research' 'demo'
    New-Item $overlay -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'access-contract' '*') $overlay
    Copy-Item $ConfigPath (Join-Path $overlay 'deployment.json')
    return @{ Contracts = $contracts; Overlay = $overlay }
}

function Build-Contract {
    param($Paths)
    $template = Join-Path $OutputPath 'access-contract.json'
    $parameters = Join-Path $OutputPath 'access-contract.parameters.json'
    Invoke-CheckedCommand az @('bicep', 'build', '--file', (Join-Path $Paths.Contracts 'main.bicep'), '--outfile', $template) | Out-Null
    Invoke-CheckedCommand az @('bicep', 'build-params', '--file', (Join-Path $Paths.Overlay 'main.bicepparam'), '--outfile', $parameters) | Out-Null
    $bytes = (Get-Item $template).Length + (Get-Item $parameters).Length
    if ($bytes -gt 4MB) { throw "Compiled access-contract request exceeds ARM's 4 MB limit: $bytes bytes." }
    return @{ Template = $template; Parameters = $parameters }
}

Assert-PolicyMatchesConfiguration
$webIqTemplate = Join-Path $PSScriptRoot 'infra' 'webiq-connection.bicep'
$webIqParameters = Join-Path $PSScriptRoot 'infra' 'webiq-connection.bicepparam'
$hubConnectionParameters = Join-Path $PSScriptRoot 'infra' 'hub-model-connection.bicepparam'
$names = @('HUB_APIM_NAME', 'HUB_GATEWAY_URL', 'HUB_API_KEY', 'FOUNDRY_ACCOUNT_NAME', 'FOUNDRY_PROJECT_NAME', 'FOUNDRY_PROJECT_ENDPOINT')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }

try {
    if ($Mode -eq 'Validate') {
        $env:HUB_APIM_NAME = 'validate-apim'
        $env:FOUNDRY_ACCOUNT_NAME = 'validate-account'
        $env:FOUNDRY_PROJECT_NAME = 'validate-project'
        $paths = Initialize-Contract
        Build-Contract $paths | Out-Null
        # Compiled parameters embed secure values, so use placeholders and keep the output out of the repository.
        $savedKey = $env:WEBIQ_API_KEY
        $env:WEBIQ_API_KEY = 'validate-only'
        $env:HUB_GATEWAY_URL = 'https://validate.example'
        $env:HUB_API_KEY = 'validate-only'
        try {
            Invoke-CheckedCommand az @('bicep', 'build-params', '--file', $webIqParameters, '--outfile', (Join-Path $OutputPath 'webiq.parameters.json')) | Out-Null
            Invoke-CheckedCommand az @('bicep', 'build-params', '--file', $hubConnectionParameters, '--outfile', (Join-Path $OutputPath 'hub-connection.parameters.json')) | Out-Null
        } finally {
            $env:WEBIQ_API_KEY = $savedKey
            Remove-Item (Join-Path $OutputPath 'webiq.parameters.json'), (Join-Path $OutputPath 'hub-connection.parameters.json') -Force -ErrorAction SilentlyContinue
        }
        Write-Host 'Access contract overlay and both project connection templates compiled; no Azure resources changed.'
        return
    }

    $targets = Resolve-AzureTargets
    $env:HUB_APIM_NAME = $targets.ApimName
    $env:FOUNDRY_ACCOUNT_NAME = $targets.AccountName
    $env:FOUNDRY_PROJECT_NAME = $targets.ProjectName
    $env:FOUNDRY_PROJECT_ENDPOINT = $targets.Endpoint

    switch ($Mode) {
        'Contract' {
            $paths = Initialize-Contract
            $built = Build-Contract $paths
            $deployment = "web-research-access-contract-$($config.accessContract.environment.ToLowerInvariant())"
            try {
                Invoke-CheckedCommand az @('deployment', 'sub', 'create', '--subscription', $config.subscriptionId, '--location', $config.location, '--name', $deployment, '--template-file', $built.Template, '--parameters', "@$($built.Parameters)", '--output', 'none')
            } finally {
                # With Key Vault publishing off, the upstream template returns the subscription key as a deployment output.
                $global:LASTEXITCODE = 0
                az deployment sub delete --subscription $config.subscriptionId --name $deployment --output none 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Could not remove deployment record $deployment; its outputs may expose the APIM subscription key. Delete it and rotate the key."
                }
            }
            $gatewayUrl = (Invoke-CheckedCommand az @('apim', 'show', '--subscription', $config.subscriptionId, '--resource-group', $config.governanceHub.resourceGroupName, '--name', $targets.ApimName, '--query', 'gatewayUrl', '--output', 'tsv') | Out-String).Trim()
            if ($gatewayUrl -notmatch '^https://[^/\s]+$') { throw "Unexpected gateway URL '$gatewayUrl' for $($targets.ApimName)." }
            $subscriptionName = "LLM-$($config.accessContract.businessUnit)-$($config.accessContract.useCaseName)-$($config.accessContract.environment)-SUB-01"
            $key = (Invoke-CheckedCommand az @('rest', '--method', 'post', '--query', 'primaryKey', '--output', 'tsv', '--url', "https://management.azure.com/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.governanceHub.resourceGroupName)/providers/Microsoft.ApiManagement/service/$($targets.ApimName)/subscriptions/$subscriptionName/listSecrets?api-version=2024-05-01") | Out-String).Trim()
            if (-not $key) { throw "The access contract subscription $subscriptionName returned no key." }
            $env:HUB_GATEWAY_URL = $gatewayUrl
            $env:HUB_API_KEY = $key
            Invoke-CheckedCommand az @('deployment', 'group', 'create', '--subscription', $config.subscriptionId, '--resource-group', $config.foundry.resourceGroupName, '--name', 'hub-model-connection', '--parameters', $hubConnectionParameters, '--output', 'none')
            Write-Host "Deployed access contract and project connection $($config.accessContract.connectionNamePrefix)-LLM -> $gatewayUrl/$($config.accessContract.foundryBasePath)."
        }
        'WebIq' {
            if (-not $env:WEBIQ_API_KEY) { throw 'Set WEBIQ_API_KEY to the approved Web IQ API key.' }
            Invoke-CheckedCommand az @('deployment', 'group', 'create', '--subscription', $config.subscriptionId, '--resource-group', $config.foundry.resourceGroupName, '--name', 'web-iq-connection', '--parameters', $webIqParameters, '--output', 'none')
            Write-Host "Deployed Web IQ project connection $($config.webIq.connectionName)."
        }
        { $_ -in 'Agent', 'ModelCheck' } {
            New-Item $OutputPath -ItemType Directory | Out-Null
            $venv = Join-Path $OutputPath '.venv'
            Invoke-CheckedCommand python @('-m', 'venv', $venv)
            $python = if ($IsWindows) { Join-Path $venv 'Scripts' 'python.exe' } else { Join-Path $venv 'bin' 'python' }
            Invoke-CheckedCommand $python @('-m', 'pip', 'install', '--quiet', '-r', (Join-Path $PSScriptRoot 'requirements.txt'))
            $env:PYTHONPATH = Join-Path $PSScriptRoot 'src'
            if ($Mode -eq 'ModelCheck') {
                Invoke-CheckedCommand $python @('-m', 'webiq_agent.model_check', '--config', $ConfigPath)
                return
            }
            Invoke-CheckedCommand $python @('-m', 'webiq_agent.publish', '--config', $ConfigPath)
            if ($SmokeQuestion) {
                Invoke-CheckedCommand $python @('-m', 'webiq_agent.invoke', '--config', $ConfigPath, '--auto-approve-allowed-tools', $SmokeQuestion)
            }
        }
    }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
