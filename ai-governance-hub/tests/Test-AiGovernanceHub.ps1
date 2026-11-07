#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$adapter = Join-Path $root 'Invoke-AiGovernanceHub.ps1'
$originalConfig = Get-Content (Join-Path $root 'config\deployment.json') -Raw | ConvertFrom-Json
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "ai-governance-hub-tests-$([guid]::NewGuid())"
$configPath = Join-Path $testRoot 'config'
New-Item $configPath -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $root 'config\main.bicepparam') $configPath
$state = @{ Failure = ''; Calls = [Collections.Generic.List[string]]::new(); ProviderReads = 0 }
$previousLocation = Get-Location
$previousExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
$previousExitCodeValue = if ($previousExitCode) { $previousExitCode.Value } else { $null }

function git {
    $state.Calls.Add("git $($args -join ' ')")
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'clone') {
        $path = $args[-1]
        foreach ($file in 'azure.yaml', 'bicep\infra\main.bicep', 'bicep\infra\resources.bicep', 'bicep\infra\modules\networking\vnet.bicep', 'src\usage-ingestion-logicapp\package.json') {
            $destination = Join-Path $path $file
            New-Item (Split-Path $destination -Parent) -ItemType Directory -Force | Out-Null
            if ($file -in 'bicep\infra\main.bicep', 'bicep\infra\resources.bicep') {
                $source = "@allowed([ 'uaenorth', 'southafricanorth', 'westeurope', 'southcentralus', 'australiaeast', 'canadaeast', 'eastus', 'eastus2', 'francecentral', 'japaneast', 'northcentralus', 'swedencentral', 'switzerlandnorth', 'uksouth' ])`nparam location string"
                if ($state.Failure -eq 'changed-location-list') { $source = $source.Replace("'uaenorth'", "'eastasia'") }
                Set-Content $destination $source
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
        if (($state.Failure -eq 'network-deployment' -and $args[1] -eq 'sub') -or
            ($state.Failure -eq 'dns-deployment' -and $args[1] -eq 'group')) {
            $global:LASTEXITCODE = 31
        }
        return
    }
    if ($args[0] -eq 'group') { return }
    if ($args[0] -eq 'network') {
        $sub = $args[4]
        $vnets = if ($sub -eq $originalConfig.subscriptionId) {
            @(@{
                id = "/subscriptions/$sub/resourceGroups/$($originalConfig.networking.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($originalConfig.networking.vnetName)"
                dhcpOptions = @{ dnsServers = if ($state.Failure -eq 'custom-dns') { @('10.100.0.4') } else { @() } }
            })
        } else {
            @(
                @{ id = "/subscriptions/$sub/resourceGroups/rg-hub-swe/providers/Microsoft.Network/virtualNetworks/vnet-hub-swe"; dhcpOptions = @{ dnsServers = @() } },
                @{ id = "/subscriptions/$sub/resourceGroups/rg-other/providers/Microsoft.Network/virtualNetworks/vnet-other"; dhcpOptions = @{ dnsServers = @() } }
            )
        }
        if ($state.Failure -eq 'implicit-dns') {
            foreach ($vnet in $vnets) { $vnet.Remove('dhcpOptions') }
        }
        ConvertTo-Json -InputObject $vnets -Depth 10
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
function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Invoke-Case {
    param([string]$Name, [string]$Failure = '', [string]$ExpectedError = '', [string]$Mode = 'Deploy')
    $state.Calls.Clear()
    $state.Failure = $Failure
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
    $patched = Get-Content (Join-Path $testRoot 'validate\bicep\infra\main.bicep') -Raw
    Assert ($patched.Contains("'italynorth', 'uaenorth'")) 'Italy North must be added to the runner-only upstream location allow-list.'

    Invoke-Case -Name 'network' -Mode Network
    Assert (@($state.Calls | Where-Object { $_ -like 'azd *' }).Count -eq 0) 'Network-only mode must not deploy GovHub services.'
    $dnsParameters = Get-Content (Join-Path $testRoot 'network\networking\private-dns.parameters.json') -Raw | ConvertFrom-Json
    Assert ($dnsParameters.parameters.virtualNetworkIds.value.Count -eq 3) 'Central zones must link all VNets in both subscriptions, not only the hub and new spoke.'
    Assert ($dnsParameters.parameters.zoneNames.value.Count -eq @($originalConfig.networking.dns.zones.PSObject.Properties).Count) 'Central DNS must use the configured required zone inventory.'
    $networkCalls = @($state.Calls | Where-Object { $_ -like 'az deployment *' })
    Assert ($networkCalls.Count -eq 2 -and $networkCalls[0] -like "az deployment sub create --subscription $($originalConfig.subscriptionId)*" -and $networkCalls[1] -like "az deployment group create --subscription $($originalConfig.networking.dns.subscriptionId)*") 'Spoke and DNS must deploy to their explicitly configured subscriptions.'

    Invoke-Case -Name 'network-failure' -Failure network-deployment -ExpectedError 'exit code 31'
    Assert (@($state.Calls | Where-Object { $_ -like 'az deployment group *' -or $_ -like 'azd *' }).Count -eq 0) 'A failed spoke deployment must stop DNS and GovHub deployment.'
    Invoke-Case -Name 'dns-failure' -Failure dns-deployment -ExpectedError 'exit code 31'
    Assert (@($state.Calls | Where-Object { $_ -like 'azd *' }).Count -eq 0) 'A failed central DNS deployment must stop GovHub deployment.'
    Invoke-Case -Name 'custom-dns' -Failure custom-dns -ExpectedError 'uses custom DNS'
    Invoke-Case -Name 'implicit-dns' -Failure implicit-dns -Mode Network

    Invoke-Case -Name 'deploy'
    $azdCalls = @($state.Calls | Where-Object { $_ -like 'azd *' })
    Assert ($azdCalls.Count -eq 3 -and $azdCalls[1] -like 'azd provision *' -and $azdCalls[2] -like 'azd deploy *') 'Provisioning must precede deployment of upstream application code.'

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
