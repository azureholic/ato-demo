#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\scripts\Initialize-Alz.ps1'
$deploymentScript = Join-Path $PSScriptRoot '..\scripts\Invoke-AlzDeployment.ps1'
$settings = Get-Content (Join-Path $PSScriptRoot '..\config\demo.json') -Raw | ConvertFrom-Json
$output = Join-Path ([IO.Path]::GetTempPath()) "alz-bicep-test-$([guid]::NewGuid().ToString('N'))"
try {
    foreach ($invalid in @(
        @{ SubscriptionId = ''; TenantId = $settings.tenantId },
        @{ SubscriptionId = $settings.subscriptionId; TenantId = 'not-a-guid' },
        @{ SubscriptionId = '11111111-1111-1111-1111-111111111111'; TenantId = $settings.tenantId }
    )) {
        $rejected = $false
        try {
            & $script @invalid -OutputPath $output
        } catch {
            if ($_.Exception.Message -notmatch 'must be a non-empty GUID|target does not match') { throw }
            $rejected = $true
        }
        if (-not $rejected -or (Test-Path $output)) {
            throw 'Invalid configuration was accepted or wrote output.'
        }
    }
    $rejected = $false
    try {
        & $deploymentScript -Operation Deploy -Confirmation 'deploy' -OutputPath $output
    } catch {
        if ($_.Exception.Message -notlike '*requires explicit DEPLOY confirmation*') { throw }
        $rejected = $true
    }
    if (-not $rejected -or (Test-Path $output)) {
        throw 'Deployment was not rejected before any preparation or Azure calls.'
    }

    & $script -SubscriptionId $settings.subscriptionId -TenantId $settings.tenantId -OutputPath $output
    $deployments = Get-Content (Join-Path $PSScriptRoot '..\bicep\deployments.json') -Raw | ConvertFrom-Json
    foreach ($entry in $deployments) {
        $name = $entry.name
        $template = Get-Item -LiteralPath (Join-Path $output "$name.template.json")
        if ($template.Length -gt 4MB) { throw "$name exceeds the ARM 4 MB template limit." }
        $parameters = Get-Item -LiteralPath (Join-Path $output "$name.parameters.json")
        if ($parameters.Length -gt 4MB) { throw "$name exceeds the ARM 4 MB parameter limit." }
    }
    $logging = (Get-Content (Join-Path $output 'logging.parameters.json') -Raw | ConvertFrom-Json).parameters
    if ($logging.parLocations.value.Count -ne 1 -or
        $logging.parLocations.value[0] -ne 'belgiumcentral' -or
        $logging.parLogAnalyticsWorkspaceLogRetentionInDays.value -ne 30 -or
        $logging.parDeployAutomationAccount.value) {
        throw 'Logging configuration changed the single-region SMB baseline.'
    }
    $network = (Get-Content (Join-Path $output 'hub-network.parameters.json') -Raw | ConvertFrom-Json).parameters
    $hub = $network.hubNetworks.value[0]
    if ($network.hubNetworks.value.Count -ne 1 -or
        $hub.location -ne 'belgiumcentral' -or
        $hub.addressPrefixes[0] -ne '10.100.0.0/16' -or
        $hub.azureFirewallSettings.azureSkuTier -ne 'Basic' -or
        -not $hub.azureFirewallSettings.deployAzureFirewall -or
        $hub.deployPeering -or
        $hub.bastionHostSettings.deployBastion -or
        $hub.vpnGatewaySettings.deployVpnGateway -or
        $hub.expressRouteGatewaySettings.deployExpressRouteGateway -or
        $hub.privateDnsSettings.deployPrivateDnsZones -or
        $hub.privateDnsSettings.deployDnsPrivateResolver -or
        $hub.ddosProtectionPlanSettings.deployDdosProtectionPlan) {
        throw 'Hub configuration changed the intended SMB topology.'
    }
    $root = (Get-Content (Join-Path $output 'governance-int-root.parameters.json') -Raw | ConvertFrom-Json).parameters
    $defender = $root.parPolicyAssignmentParameterOverrides.value.'Deploy-MDFC-Config-H224'.parameters
    if ($root.intRootConfig.value.createOrUpdateManagementGroup -or
        $root.intRootConfig.value.managementGroupName -ne 'alz' -or
        $defender.emailSecurityContact.value -ne $settings.securityContactEmail -or
        $defender.enableAscForServers.value -ne 'DeployIfNotExists') {
        throw 'Governance targets or security contact are incorrect.'
    }
    $placements = @()
    foreach ($file in Get-ChildItem -LiteralPath $output -Filter 'governance-*.parameters.json') {
        $parameters = (Get-Content $file.FullName -Raw | ConvertFrom-Json).parameters
        foreach ($parameter in $parameters.PSObject.Properties) {
            if ($parameter.Name -like '*Config') {
                $config = $parameter.Value.value
                $placement = $config.PSObject.Properties['subscriptionsToPlaceInManagementGroup']
                if ($placement) {
                    foreach ($id in $placement.Value) {
                        $placements += @{ SubscriptionId = $id; ManagementGroup = $config.managementGroupName }
                    }
                }
            }
        }
    }
    if ($placements.Count -ne 1 -or $placements[0].SubscriptionId -ne $settings.subscriptionId -or
        $placements[0].ManagementGroup -ne 'platform') {
        throw 'The shared subscription must be placed exactly once, in platform.'
    }
    foreach ($name in 'governance-connectivity', 'governance-landingzones', 'governance-corp') {
        $parameters = (Get-Content (Join-Path $output "$name.parameters.json") -Raw | ConvertFrom-Json).parameters
        $config = ($parameters.PSObject.Properties | Where-Object Name -like '*Config').Value.value
        $expected = if ($name -eq 'governance-corp') { 'Deploy-Private-DNS-Zones' } else { 'Enable-DDoS-VNET' }
        if ($config.managementGroupExcludedPolicyAssignments -notcontains $expected) {
            throw "$name is missing the $expected policy exclusion."
        }
    }
    Write-Host 'Bicep build, baseline configuration, invalid-target and deployment-confirmation tests passed. No Azure resources changed.'
} finally {
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
}
