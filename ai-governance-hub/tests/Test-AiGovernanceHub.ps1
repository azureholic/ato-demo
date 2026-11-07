#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$adapter = Join-Path $root 'Invoke-AiGovernanceHub.ps1'
$originalConfig = Get-Content (Join-Path $root 'config\deployment.json') -Raw | ConvertFrom-Json
$platformDns = Get-Content (Join-Path $root '..\platform-alz\config\private-dns.json') -Raw | ConvertFrom-Json
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "ai-governance-hub-tests-$([guid]::NewGuid())"
$configPath = Join-Path $testRoot 'config'
New-Item $configPath -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $root 'config\main.bicepparam') $configPath
$state = @{
    Failure = ''; Calls = [Collections.Generic.List[string]]::new(); ProviderReads = 0
    Exemption = $null; SharedKey = $false
    StorageScope = "/subscriptions/$($originalConfig.subscriptionId)/resourceGroups/$($originalConfig.resourceGroupName)/providers/Microsoft.Storage/storageAccounts/funcusagetest123"
}
$previousLocation = Get-Location
$previousExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
$previousExitCodeValue = if ($previousExitCode) { $previousExitCode.Value } else { $null }

function git {
    $state.Calls.Add("git $($args -join ' ')")
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'clone') {
        $path = $args[-1]
        foreach ($file in 'azure.yaml', 'bicep\infra\main.bicep', 'bicep\infra\resources.bicep', 'bicep\infra\modules\networking\vnet.bicep', 'bicep\infra\modules\apim\apim.bicep', 'bicep\infra\modules\apim\universal-llm-api\AIFoundryOpenAI.json', 'src\usage-ingestion-logicapp\package.json') {
            $destination = Join-Path $path $file
            New-Item (Split-Path $destination -Parent) -ItemType Directory -Force | Out-Null
            if ($file -in 'bicep\infra\main.bicep', 'bicep\infra\resources.bicep') {
                $source = "@allowed([ 'uaenorth', 'southafricanorth', 'westeurope', 'southcentralus', 'australiaeast', 'canadaeast', 'eastus', 'eastus2', 'francecentral', 'japaneast', 'northcentralus', 'swedencentral', 'switzerlandnorth', 'uksouth' ])`nparam location string"
                if ($state.Failure -eq 'changed-location-list') { $source = $source.Replace("'uaenorth'", "'eastasia'") }
                Set-Content $destination $source
            } elseif ($file -eq 'bicep\infra\modules\apim\apim.bicep') {
                $source = "endpointAddress: replace(eventHubEndpoint, 'https://', '')`nendpointAddress: replace(eventHubPIIEndpoint, 'https://', '')"
                if ($state.Failure -eq 'changed-logger-expression') { $source = $source.Replace('eventHubPIIEndpoint', 'newEndpoint') }
                if ($state.Failure -eq 'duplicate-logger-expression') { $source += "`nendpointAddress: replace(eventHubEndpoint, 'https://', '')" }
                Set-Content $destination $source
            } elseif ($file -eq 'bicep\infra\modules\apim\universal-llm-api\AIFoundryOpenAI.json') {
                $pathParameter = @{ name = 'deployment-id'; in = 'path'; required = $true; schema = @{ type = ''; enum = @('') } }
                $apiFixture = @{
                    paths = @{
                        '/deployments/{deployment-id}' = @{
                            get = @{ operationId = 'deployment-by-name'; parameters = @($pathParameter); responses = @{ '200' = @{ description = 'Deployment details' } } }
                        }
                    }
                }
                if ($state.Failure -eq 'changed-openai-schema') { $pathParameter.schema.type = 'string' }
                if ($state.Failure -eq 'duplicate-openai-parameter') { $apiFixture.paths['/deployments/{deployment-id}'].get.parameters += $pathParameter }
                if ($state.Failure -eq 'missing-openai-operation') { $apiFixture.paths['/deployments/{deployment-id}'].Remove('get') }
                $apiFixture | ConvertTo-Json -Depth 15 | Set-Content $destination
            } else {
                Set-Content $destination '{}'
            }
        }
    } elseif ($args[2] -eq 'rev-parse') {
        if ($state.Failure -eq 'wrong-revision') { '0' * 40 } else { $originalConfig.upstreamRevision }
    } elseif ($state.Failure -eq 'checkout') {
        $global:LASTEXITCODE = 23
    }
}
function az {
    $state.Calls.Add("az $($args -join ' ')")
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'account') { 'mock-arm-token'; return }
    if ($args[0] -eq 'storage') {
        if ($args[2] -eq 'update') {
            if ($state.Failure -ne 'waiver-propagation') { $state.SharedKey = $true }
            return
        }
        @{
            id = $state.StorageScope
            publicNetworkAccess = if ($state.Failure -eq 'public-storage') { 'Enabled' } else { 'Disabled' }
            allowSharedKeyAccess = $state.SharedKey
        } | ConvertTo-Json
        return
    }
    if ($args[0] -eq 'resource') {
        ConvertTo-Json -InputObject @(@{
            id = "/subscriptions/$($originalConfig.subscriptionId)/resourceGroups/$($originalConfig.resourceGroupName)/providers/Microsoft.Web/sites/logic-usage-test"
            name = 'logic-usage-test'; kind = 'functionapp,workflowapp'
            tags = @{ 'azd-service-name' = 'usageProcessingLogicApp' }
        })
        return
    }
    if ($args[0] -eq 'policy') {
        if ($args[2] -eq 'list') {
            ConvertTo-Json -InputObject @($(if ($null -ne $state.Exemption) { $state.Exemption }))
        } elseif ($args[2] -eq 'create') {
            if ($state.Failure -eq 'waiver-permission') { $global:LASTEXITCODE = 33; return }
            $state.Exemption = @{
                id = "$($state.StorageScope)/providers/Microsoft.Authorization/policyExemptions/govhub-logic-storage-shared-key"
                name = 'govhub-logic-storage-shared-key'
                policyAssignmentId = $originalConfig.storagePolicyExemption.policyAssignmentId
                policyDefinitionReferenceIds = @('StorageAccountDisableLocalAuth')
                exemptionCategory = 'Waiver'; expiresOn = $null
            }
        } else {
            if ($state.Failure -eq 'waiver-verification') { $state.Exemption.policyDefinitionReferenceIds += 'StorageAccountPublicNetworkModify' }
            $state.Exemption | ConvertTo-Json
        }
        return
    }
    if ($args[0] -eq 'webapp') { return }
    if ($args[0] -eq 'provider') {
        if ($args[1] -eq 'show') {
            if ($state.Failure -eq 'provider-read') { $global:LASTEXITCODE = 17; return }
            if ($state.Failure -eq 'provider-timeout') { 'Registering'; return }
            $state.ProviderReads++
            if ($state.Failure -in 'provider-missing', 'provider-request' -and $state.ProviderReads -eq 1) {
                'NotRegistered'
            } elseif ($state.Failure -eq 'provider-registering' -and $state.ProviderReads -eq 1) {
                'Registering'
            } else {
                'Registered'
            }
        }
        if ($args[1] -eq 'register' -and $state.Failure -eq 'provider-request') { $global:LASTEXITCODE = 18 }
        return
    }
    if ($args[0] -eq 'deployment') {
        if ($args[2] -eq 'show') { 'funcusagetest123'; return }
        if (($state.Failure -eq 'network-deployment' -and $args[1] -eq 'sub') -or
            ($state.Failure -eq 'dns-deployment' -and $args[1] -eq 'group')) {
            $global:LASTEXITCODE = 31
        }
        return
    }
    if ($args[0] -eq 'group') {
        if ($args[1] -ne 'exists') { throw 'GovHub must not create the shared DNS resource group.' }
        if ($state.Failure -eq 'missing-dns-group') { 'false' } else { 'true' }
        return
    }
    if ($args[0] -eq 'network') {
        if ($args[1] -eq 'private-dns') {
            $zones = @($platformDns.zones.PSObject.Properties.Value | ForEach-Object { @{ name = $_ } })
            if ($state.Failure -eq 'missing-dns-zones') { $zones = @() }
            ConvertTo-Json -InputObject $zones
            return
        }
        if ($args[2] -ne 'show') { throw 'GovHub must only look up its own spoke, not inventory platform VNets.' }
        $sub = $args[4]
        $vnets = if ($sub -eq $originalConfig.subscriptionId) {
            @(@{
                id = "/subscriptions/$sub/resourceGroups/$($originalConfig.networking.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($originalConfig.networking.vnetName)"
                dhcpOptions = @{ dnsServers = if ($state.Failure -eq 'custom-dns') { @('10.100.0.4') } else { @() } }
            })
        } else { throw 'GovHub must only read its own spoke subscription.' }
        if ($state.Failure -eq 'implicit-dns') {
            foreach ($vnet in $vnets) { $vnet.Remove('dhcpOptions') }
        }
        @($vnets)[0] | ConvertTo-Json -Depth 10
        return
    }
    if ($state.Failure -eq 'compile') {
        $global:LASTEXITCODE = 17
        return
    }
    if ($args[1] -eq 'build-params') {
        Set-Content $args[-1] '{"parameters":{}}'
    } else {
        $template = @{ resources = @() }
        if ($state.Failure -eq 'oversized' -and $args[-1] -like '*main.json') { $template.metadata = @{ padding = 'x' * (4MB) } }
        $template | ConvertTo-Json -Compress | Set-Content $args[-1]
    }
}
function azd {
    $state.Calls.Add("azd $($args -join ' ')")
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'env') {
        if ($args[4] -ne $originalConfig.subscriptionId -or $args[6] -ne $originalConfig.location) {
            throw 'azd must use the configured subscription and region.'
        }
    }
    if ($state.Failure -eq $args[0]) { $global:LASTEXITCODE = 29 }
}
function Invoke-WebRequest {
    param([string]$Uri, [string]$Method, [hashtable]$Headers, [switch]$SkipHttpErrorCheck, [int]$TimeoutSec)
    $state.Calls.Add("GET $Uri")
    if ($state.Failure -eq 'waiver-read') { return @{ StatusCode = 403; Content = '{}' } }
    if ($null -eq $state.Exemption) { return @{ StatusCode = 404; Content = '{}' } }
    if ($state.Failure -eq 'waiver-verification') {
        $state.Exemption.policyDefinitionReferenceIds = @('StorageAccountDisableLocalAuth', 'StorageAccountPublicNetworkModify')
    }
    return @{
        StatusCode = 200
        Content = @{ id = $state.Exemption.id; properties = $state.Exemption } | ConvertTo-Json -Depth 10
    }
}
function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Invoke-Case {
    param([string]$Name, [string]$Failure = '', [string]$ExpectedError = '', [string]$Mode = 'Deploy')
    $state.Calls.Clear()
    $state.Failure = $Failure
    $state.Exemption = $null
    $state.SharedKey = $false
    $originalConfig | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $configPath 'deployment.json')
    $path = Join-Path $testRoot $Name
    if ($Name -eq 'existing') { New-Item $path -ItemType Directory | Out-Null }
    if ($Name -eq 'unpinned') {
        $changed = $originalConfig | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $changed.upstreamRevision = 'main'
        $changed | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $configPath 'deployment.json')
    }
    $caught = $null
    try {
        & $adapter -OutputPath $path -ConfigPath $configPath -Mode $Mode
    } catch {
        $caught = $_.Exception.Message
    }
    if ($ExpectedError) {
        Assert ($null -ne $caught -and $caught.Contains($ExpectedError)) "$Name should fail with '$ExpectedError', got '$caught'."
    } elseif ($caught) {
        throw "$Name failed: $caught"
    }
    Assert ((Get-Location).Path -eq $previousLocation.Path) "$Name did not restore the caller's directory."
    Write-Host "PASS: $Name"
}

try {
    Invoke-Case -Name 'validate' -Mode Validate
    Assert (@($state.Calls | Where-Object { $_ -like 'azd *' }).Count -eq 0) 'Validation must not authenticate or provision/deploy.'
    Assert (@($state.Calls | Where-Object { $_ -like 'az deployment *' -or $_ -like 'az group *' -or $_ -like 'az provider *' }).Count -eq 0) 'Validation must not register providers or deploy networking/DNS.'
    $overlay = Get-Content (Join-Path $testRoot 'validate\bicep\infra\main.bicepparam') -Raw
    Assert ($overlay -ceq (Get-Content (Join-Path $configPath 'main.bicepparam') -Raw)) 'The exact scenario parameters must replace upstream defaults.'
    $copied = Get-Content (Join-Path $testRoot 'validate\bicep\infra\deployment.json') -Raw | ConvertFrom-Json
    Assert ($copied.model.name -eq $originalConfig.model.name) 'The model configuration must accompany the parameter overlay.'
    $copiedDns = Get-Content (Join-Path $testRoot 'validate\bicep\infra\private-dns.json') -Raw
    Assert ($copiedDns -ceq (Get-Content (Join-Path $root '..\platform-alz\config\private-dns.json') -Raw)) 'GovHub must use the exact shared platform DNS configuration.'
    $patched = Get-Content (Join-Path $testRoot 'validate\bicep\infra\main.bicep') -Raw
    Assert ($patched.Contains("'italynorth', 'uaenorth'")) 'Italy North must be added to the runner-only upstream location allow-list.'
    $loggers = Get-Content (Join-Path $testRoot 'validate\bicep\infra\modules\apim\apim.bicep') -Raw
    foreach ($endpoint in 'eventHubEndpoint', 'eventHubPIIEndpoint') {
        Assert ($loggers.Contains("endpointAddress: split(split(split($endpoint, '://')[1], '/')[0], ':')[0]")) 'Both Event Hubs loggers must use canonical hostnames, not URLs with port/path suffixes.'
    }
    $apiDefinition = Get-Content (Join-Path $testRoot 'validate\bicep\infra\modules\apim\universal-llm-api\AIFoundryOpenAI.json') -Raw | ConvertFrom-Json -AsHashtable
    $deploymentGet = $apiDefinition.paths['/deployments/{deployment-id}'].get
    Assert ($deploymentGet.parameters[0].schema.type -ceq 'string' -and -not $deploymentGet.parameters[0].schema.Contains('enum')) 'Deployment IDs must be strings without an empty-only enum.'
    Assert ($deploymentGet.operationId -ceq 'deployment-by-name' -and $deploymentGet.responses['200'].description -ceq 'Deployment details') 'The schema repair must preserve operation IDs and unrelated API definitions.'

    Invoke-Case -Name 'network' -Mode Network
    Assert (@($state.Calls | Where-Object { $_ -like 'azd *' }).Count -eq 0) 'Network-only mode must not deploy GovHub services.'
    $dnsParameters = Get-Content (Join-Path $testRoot 'network\networking\private-dns-links.parameters.json') -Raw | ConvertFrom-Json
    Assert ($dnsParameters.parameters.virtualNetworkIds.value.Count -eq 1 -and $dnsParameters.parameters.virtualNetworkIds.value[0] -like "*/virtualNetworks/$($originalConfig.networking.vnetName)") 'GovHub must link only its spoke to existing central zones.'
    Assert ($dnsParameters.parameters.zoneNames.value.Count -eq @($platformDns.zones.PSObject.Properties).Count) 'GovHub DNS links must use the platform zone inventory.'
    $networkCalls = @($state.Calls | Where-Object { $_ -like 'az deployment *' })
    Assert ($networkCalls.Count -eq 2 -and $networkCalls[0] -like "az deployment sub create --subscription $($originalConfig.subscriptionId)*" -and $networkCalls[1] -like "az deployment group create --subscription $($platformDns.subscriptionId)*govhub-spoke-dns-links*") 'Spoke and link-only deployments must target their explicitly configured subscriptions.'
    foreach ($failure in 'missing-dns-group', 'missing-dns-zones') {
        Invoke-Case -Name $failure -Failure $failure -ExpectedError 'deploy the ALZ platform first'
        Assert (@($state.Calls | Where-Object { $_ -like 'az deployment *' -or $_ -like 'azd *' }).Count -eq 0) 'Missing platform DNS must stop before any spoke or GovHub deployment.'
    }

    Invoke-Case -Name 'network-failure' -Failure network-deployment -ExpectedError 'exit code 31'
    Assert (@($state.Calls | Where-Object { $_ -like 'az deployment group *' -or $_ -like 'azd *' }).Count -eq 0) 'A failed spoke deployment must stop DNS and GovHub deployment.'
    Invoke-Case -Name 'dns-failure' -Failure dns-deployment -ExpectedError 'exit code 31'
    Assert (@($state.Calls | Where-Object { $_ -like 'azd *' }).Count -eq 0) 'A failed central DNS deployment must stop GovHub deployment.'
    Invoke-Case -Name 'custom-dns' -Failure custom-dns -ExpectedError 'uses custom DNS'
    Invoke-Case -Name 'implicit-dns' -Failure implicit-dns -Mode Network

    Invoke-Case -Name 'deploy'
    $azdCalls = @($state.Calls | Where-Object { $_ -like 'azd *' })
    Assert ($azdCalls.Count -eq 3 -and $azdCalls[1] -like 'azd provision *' -and $azdCalls[2] -like 'azd deploy *') 'Provisioning must precede deployment of upstream application code.'
    $calls = @($state.Calls)
    $provisionIndex = [array]::FindIndex($calls, [Predicate[string]]{ param($call) $call -like 'azd provision *' })
    $waiverIndex = [array]::FindIndex($calls, [Predicate[string]]{ param($call) $call -like 'az policy exemption create *' })
    $updateIndex = [array]::FindIndex($calls, [Predicate[string]]{ param($call) $call -like 'az storage account update *' })
    $restartIndex = [array]::FindIndex($calls, [Predicate[string]]{ param($call) $call -like 'az webapp restart *' })
    $deployIndex = [array]::FindIndex($calls, [Predicate[string]]{ param($call) $call -like 'azd deploy *' })
    Assert ($provisionIndex -lt $waiverIndex -and $waiverIndex -lt $updateIndex -and $updateIndex -lt $restartIndex -and $restartIndex -lt $deployIndex) 'Create the waiver, restore keys and restart only between provisioning and application deployment.'
    Assert ($calls[$waiverIndex].Contains("--scope $($state.StorageScope) ") -and $calls[$waiverIndex].Contains('--policy-definition-reference-ids StorageAccountDisableLocalAuth ') -and -not $calls[$waiverIndex].Contains('--expires-on')) 'The approved no-expiry waiver must target only the runtime account and shared-key policy.'
    Assert (-not $calls[$updateIndex].Contains('--public-network-access')) 'Repair must not enable public storage access.'

    $state.Calls.Clear()
    $state.Exemption.name = "$($state.StorageScope)/providers/Microsoft.Authorization/policyExemptions/govhub-logic-storage-shared-key"
    & (Join-Path $root 'Set-LogicAppStorageExemption.ps1') -ConfigPath $configPath
    Assert (@($state.Calls | Where-Object { $_ -like 'az policy exemption create *' -or $_ -like 'az storage account update *' -or $_ -like 'az webapp restart *' }).Count -eq 0) 'An existing matching waiver and healthy account must cause no writes or restarts.'
    Assert (@($state.Calls | Where-Object { $_ -like 'az policy exemption list *' }).Count -eq 0) 'Existing waivers must be read by exact ID, independent of list naming or visibility.'
    $state.Exemption.expiresOn = '2026-12-07T23:59:59Z'
    $state.Calls.Clear()
    $caught = $null
    try {
        & (Join-Path $root 'Set-LogicAppStorageExemption.ps1') -ConfigPath $configPath
    } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught.Contains('review it rather than overwriting')) 'Do not silently replace an existing time-limited waiver with a permanent one.'
    Assert (@($state.Calls | Where-Object { $_ -like 'az policy exemption create *' -or $_ -like 'az storage account update *' }).Count -eq 0) 'Conflicting waivers must stop before writes.'

    foreach ($failure in 'waiver-permission', 'waiver-verification', 'waiver-read', 'public-storage') {
        $expected = switch ($failure) {
            waiver-permission { 'policyAssignments/exempt/action' }
            waiver-verification { 'review it rather than overwriting' }
            waiver-read { 'do not treat a permission or service error as a missing waiver' }
            public-storage { 'retain disabled public network access' }
        }
        Invoke-Case -Name $failure -Failure $failure -ExpectedError $expected
        Assert (@($state.Calls | Where-Object { $_ -like 'az storage account update *' -or $_ -like 'az webapp restart *' -or $_ -like 'azd deploy *' }).Count -eq 0) 'Unsafe or unverified exemptions must stop storage changes and application deployment.'
        if ($failure -eq 'waiver-read') {
            Assert (@($state.Calls | Where-Object { $_ -like 'az policy exemption create *' }).Count -eq 0) 'A forbidden read must not trigger exemption creation.'
        }
    }
    $state.Failure = 'waiver-propagation'
    $state.Exemption = $null
    $state.SharedKey = $false
    $state.Calls.Clear()
    $caught = $null
    try {
        & (Join-Path $root 'Set-LogicAppStorageExemption.ps1') -ConfigPath $configPath -TimeoutSeconds 1 -PollIntervalSeconds 1
    } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught.Contains('propagation timeout')) 'Policy propagation must have a bounded wait with an explicit failure.'
    Assert (@($state.Calls | Where-Object { $_ -like 'az webapp restart *' }).Count -eq 0) 'Do not restart the Logic App while key access remains disabled.'

    Invoke-Case -Name 'provision-failure' -Failure provision -ExpectedError 'exit code 29'
    Assert (@($state.Calls | Where-Object { $_ -like 'azd deploy *' }).Count -eq 0) 'Failed provisioning must stop application deployment.'
    Invoke-Case -Name 'deploy-failure' -Failure deploy -ExpectedError 'exit code 29'
    Invoke-Case -Name 'compile-failure' -Failure compile -ExpectedError 'exit code 17'
    Assert (@($state.Calls | Where-Object { $_ -like 'azd *' }).Count -eq 0) 'Invalid parameters must stop before provisioning.'
    Invoke-Case -Name 'oversized' -Failure oversized -ExpectedError '4 MB limit'
    Assert (@($state.Calls | Where-Object { $_ -like 'azd *' }).Count -eq 0) 'Oversized deployments must stop before provisioning.'
    Invoke-Case -Name 'checkout-failure' -Failure checkout -ExpectedError 'exit code 23'
    Invoke-Case -Name 'wrong-revision' -Failure wrong-revision -ExpectedError 'does not match'
    Invoke-Case -Name 'changed-location-list' -Failure changed-location-list -ExpectedError 'Unexpected upstream location allow-list'
    Assert (@($state.Calls | Where-Object { $_ -like 'az deployment *' -or $_ -like 'azd *' }).Count -eq 0) 'Unexpected upstream regional restrictions must stop before deployment.'
    foreach ($failure in 'changed-logger-expression', 'duplicate-logger-expression') {
        Invoke-Case -Name $failure -Failure $failure -ExpectedError 'Unexpected upstream Event Hubs logger expression'
        Assert (@($state.Calls | Where-Object { $_ -like 'az *' -or $_ -like 'azd *' }).Count -eq 0) 'Logger expression drift must stop before compilation or Azure changes.'
    }
    foreach ($failure in 'changed-openai-schema', 'duplicate-openai-parameter', 'missing-openai-operation') {
        Invoke-Case -Name $failure -Failure $failure -ExpectedError 'Unexpected upstream OpenAI deployment parameter schema'
        Assert (@($state.Calls | Where-Object { $_ -like 'az *' -or $_ -like 'azd *' }).Count -eq 0) 'API schema drift must stop before compilation or Azure changes.'
    }
    Invoke-Case -Name 'unpinned' -ExpectedError 'full lowercase Git commit SHA'
    Assert ($state.Calls.Count -eq 0) 'An unpinned revision must fail before cloning.'
    Invoke-Case -Name 'existing' -ExpectedError 'fresh output directory'
    Assert ($state.Calls.Count -eq 0) 'Existing output must not be overwritten.'

    foreach ($failure in '', 'provider-missing', 'provider-registering', 'provider-read', 'provider-request', 'provider-timeout') {
        $state.Calls.Clear()
        $state.Failure = $failure
        $state.ProviderReads = 0
        $caught = $null
        try {
            & (Join-Path $root 'Register-ResourceProviders.ps1') -SubscriptionId $originalConfig.subscriptionId `
                -Namespaces Microsoft.AlertsManagement -TimeoutSeconds 1 -PollIntervalSeconds 1
        } catch {
            $caught = $_.Exception.Message
        }
        if ($failure -eq 'provider-read') {
            Assert ($null -ne $caught -and $caught.Contains('Unable to read registration state')) 'Provider read failures must surface explicitly.'
        } elseif ($failure -eq 'provider-request') {
            Assert ($null -ne $caught -and $caught.Contains('Registration request failed')) 'Provider registration failures must surface explicitly.'
        } elseif ($failure -eq 'provider-timeout') {
            Assert ($null -ne $caught -and $caught.Contains('timed out')) 'Provider registration must have a bounded wait.'
        } else {
            Assert ($null -eq $caught) "Provider registration case '$failure' failed: $caught."
            $requests = @($state.Calls | Where-Object { $_ -like 'az provider register *' })
            Assert ($requests.Count -eq $(if ($failure -eq 'provider-missing') { 1 } else { 0 })) 'Only unregistered providers should receive a registration request.'
            Assert (@($state.Calls | Where-Object { $_ -like "az provider *--subscription $($originalConfig.subscriptionId)*" }).Count -eq $state.Calls.Count) 'Every provider operation must target the configured subscription.'
        }
        Write-Host "PASS: provider registration '$failure'"
    }
} finally {
    Set-Location $previousLocation
    if ($previousExitCode) {
        $global:LASTEXITCODE = $previousExitCodeValue
    } else {
        Remove-Variable LASTEXITCODE -Scope Global
    }
    Remove-Item $testRoot -Recurse -Force
}
Write-Host 'All AI governance hub adapter tests passed.'
