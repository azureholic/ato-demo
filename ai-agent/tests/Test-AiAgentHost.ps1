#Requires -Version 7.4
# Offline behavioral tests: every Azure boundary is replaced; no login or resource mutation.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\Invoke-AiAgentHost.ps1')
$script:readSettings = ${function:Get-HostSettings}
$script:realSshKey = ${function:New-HostSshKey}

$script:passed = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}
function Assert-Throws {
    param([scriptblock]$Work, [string]$Pattern)
    try { & $Work } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }
        return
    }
    throw "Expected failure matching $Pattern."
}
function Test-Case {
    param([string]$Name, [scriptblock]$Work)
    Reset-TestHost
    & $Work
    $script:passed++
    Write-Host "PASS $Name"
}
function Copy-TestObject { param($Value) $Value | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable }
function Reset-TestHost {
    $script:s = Get-HostSettings (Join-Path $PSScriptRoot '..\config\deployment.json')
    $script:s.EgressApproved = $true
    $script:resources = @{}
    $script:calls = [Collections.Generic.List[hashtable]]::new()
    $script:power = 'PowerState/deallocated'
    $script:runExit = 0
    $script:runState = 'Succeeded'
    $script:provisionState = 'Succeeded'
    $script:omitExit = $false
    $script:failRole = $false
    $script:failRunPut = $false
    $script:dnsCalls = 0
    $script:keyCalls = 0
    $script:resources[$s.HubId] = @{
        id = $s.HubId; properties = @{
            provisioningState = 'Succeeded'; addressSpace = @{ addressPrefixes = @('10.100.0.0/16') }
            dhcpOptions = @{ dnsServers = @() }
        }
    }
    $firewallId = $s.HubId -replace '/virtualNetworks/[^/]+$', '/azureFirewalls/afw-hub-swe'
    $script:resources[$firewallId] = @{ properties = @{
        firewallPolicy = @{ id = $s.FirewallPolicyId }
        ipConfigurations = @(@{ properties = @{ privateIPAddress = '10.100.0.4' } })
    } }
    $script:resources[$s.FirewallPolicyId] = @{ properties = @{ ruleCollectionGroups = @() } }
    $gov = $s.Governance
    $govScope = "/subscriptions/$($gov.subscriptionId)/resourceGroups/$($gov.resourceGroupName)"
    $subnetId = "$($s.GovernanceVnetId)/subnets/$($gov.networking.privateEndpointSubnetName)"
    $nicId = "$govScope/providers/Microsoft.Network/networkInterfaces/gateway"
    $script:resources[$nicId] = @{ properties = @{ ipConfigurations = @(@{ properties = @{ privateIPAddress = '10.170.0.82' } }) } }
    $script:resources[$subnetId] = @{ id = $subnetId; properties = @{
        addressPrefix = '10.170.0.64/26'; privateEndpointNetworkPolicies = 'Disabled'
        networkSecurityGroup = @{ id = '/existing/nsg' }; delegations = @()
    } }
    $script:resources["$govScope/providers/Microsoft.Network/privateEndpoints"] = @{ value = @(@{
        properties = @{
            subnet = @{ id = $subnetId }; networkInterfaces = @(@{ id = $nicId })
            privateLinkServiceConnections = @(@{ properties = @{
                privateLinkServiceId = "$govScope/providers/Microsoft.ApiManagement/service/$($s.GovernanceGatewayFqdn.Split('.')[0])"
                groupIds = @('Gateway'); privateLinkServiceConnectionState = @{ status = 'Approved' }
            } })
        }
    }) }
    $script:resources["$($s.GovernanceDnsZoneId)/A/$($s.GovernanceGatewayFqdn.Split('.')[0])"] = @{
        properties = @{ aRecords = @(@{ ipv4Address = '10.170.0.82' }) }
    }
    $script:resources["$($s.GovernanceDnsZoneId)/virtualNetworkLinks"] = @{
        value = @(@{ properties = @{ virtualNetwork = @{ id = $s.HubId }; virtualNetworkLinkState = 'Completed' } })
    }
}

function Invoke-HostArm {
    param([string]$Method, [string]$Id, [string]$ApiVersion, [hashtable]$Body, [switch]$AllowMissing, [string]$Query, [string]$ETag)
    $script:calls.Add(@{ Method = $Method; Id = $Id; Body = $Body; Query = $Query; ETag = $ETag })
    if ($Method -eq 'GET' -and $Id.EndsWith('/instanceView')) { return @{ statuses = @(@{ code = $script:power }) } }
    if ($Method -eq 'GET') {
        if ($script:resources.ContainsKey($Id)) {
            $value = Copy-TestObject $script:resources[$Id]
            if ($Id -match '/runCommands/') {
                $value.properties.provisioningState = $script:provisionState
                $value.properties.instanceView = @{ executionState = $script:runState; output = 'bounded log'; error = '' }
                if (-not $script:omitExit) { $value.properties.instanceView.exitCode = $script:runExit }
            }
            return $value
        }
        if ($AllowMissing) { return $null }
        throw "Mock resource missing: $Id"
    }
    if ($Method -eq 'PUT') {
        if ($script:failRole -and $Id -match '/roleAssignments/') { throw 'Synthetic role grant failure' }
        if ($script:failRunPut -and $Id -match '/runCommands/') { throw 'Synthetic Run Command submission failure' }
        $value = Copy-TestObject $Body
        $value.id = $Id
        if (-not $value.ContainsKey('properties')) { $value.properties = @{} }
        $value.properties.provisioningState = 'Succeeded'
        if ($Id -eq $s.VnetId) { $value.properties.subnets = @() }
        if ($Id -match '/routeTables/[^/]+$' -and -not $value.properties.ContainsKey('routes')) { $value.properties.routes = @() }
        if ($Id -match '^(.+/routeTables/[^/]+)/routes/[^/]+$') {
            $tableId = $Matches[1]
            $value.name = $Id.Split('/')[-1]
            $script:resources[$tableId].properties.routes = @($script:resources[$tableId].properties.routes) + @($value)
        }
        if ($Id -eq $s.VmId) {
            $value.identity.principalId = '11111111-2222-3333-4444-555555555555'
            $script:power = 'PowerState/running'
        }
        $script:resources[$Id] = $value
        return $value
    }
    if ($Method -eq 'DELETE') { $script:resources.Remove($Id); return }
    throw "Unexpected mock method $Method"
}
function Invoke-HostAz {
    param([string[]]$Arguments, [switch]$AllowMissing)
    $script:calls.Add(@{ Method = 'CLI'; Arguments = $Arguments })
    Assert-Test ($Arguments[0] -eq 'vm') 'Only VM lifecycle uses CLI in this mock.'
    Assert-Test ($Arguments[3] -eq $s.VmId) 'Lifecycle targets exact dedicated VM.'
    if ($Arguments[1] -eq 'start') { $script:power = 'PowerState/running' }
    elseif ($Arguments[1] -eq 'deallocate') { $script:power = 'PowerState/deallocated' }
    else { throw 'Unexpected VM lifecycle command.' }
}
function Invoke-HostDns { $script:dnsCalls++ }
function New-HostSshKey { $script:keyCalls++; 'ssh-rsa offline-test-key' }
function Wait-HostDelay { param([int]$Seconds) }
function Get-HostSettings {
    param([string]$Path)
    if ($script:useFixture) { return $script:s }
    & $script:readSettings $Path
}
$script:useFixture = $false

function Bootstrap-TestHost {
    $script:useFixture = $true
    try { Invoke-AiAgentHost Bootstrap 'offline-config' '' '' Full | Out-Null }
    finally { $script:useFixture = $false }
}
function Run-TestHost {
    $script:useFixture = $true
    try { Invoke-AiAgentHost Run 'offline-config' 'azureholic/ato-demo' ('a' * 40) Full }
    finally { $script:useFixture = $false }
}

Test-Case 'Bootstrap is idempotent, private, narrow-scoped and deallocated' {
    Bootstrap-TestHost
    $firstWrites = @($calls | Where-Object Method -eq PUT).Count
    Bootstrap-TestHost
    Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq $firstWrites) 'Second bootstrap does not rewrite resources.'
    Assert-Test ($keyCalls -eq 1) 'SSH key generated only for first VM creation.'
    Assert-Test ($dnsCalls -eq 2) 'Only platform helper owns central DNS.'
    Assert-Test ($power -eq 'PowerState/deallocated') 'Bootstrap deallocates.'
    Assert-Test (@($calls | Where-Object { $_['Id'] -match '/publicIPAddresses' }).Count -eq 0) 'No public IP resource.'
    $roles = @($calls | Where-Object { $_.Method -eq 'PUT' -and $_.Id -match '/roleAssignments/' })
    Assert-Test ($roles.Count -eq 7) 'Exactly six Agent RG grants and one platform DNS grant.'
    foreach ($grant in $roles) {
        Assert-Test ($grant.Id -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Authorization/roleAssignments/') 'No subscription/MG grants.'
        Assert-Test ($grant.Body.properties.principalId -eq '11111111-2222-3333-4444-555555555555') 'Only host identity receives grants.'
    }
    $peerings = @($calls | Where-Object { $_.Method -eq 'PUT' -and $_.Id -match '/virtualNetworkPeerings/' })
    Assert-Test ($peerings.Count -eq 2) 'Both peering directions.'
    Assert-Test ($peerings[0].Id.StartsWith($s.VnetId) -and $peerings[1].Id.StartsWith($s.HubId)) 'Peering writes have distinct workload/platform scopes.'
    foreach ($peering in $peerings) {
        Assert-Test ($peering.Body.properties.allowForwardedTraffic -and -not $peering.Body.properties.allowGatewayTransit -and -not $peering.Body.properties.useRemoteGateways) 'Forwarding allowed, no gateway transit.'
    }
    Assert-Test (@($calls | Where-Object { $_.Method -ne 'GET' -and
        ($_['Id'] -match '/azureFirewalls/|/privateDnsZones/' -or ($_['Id'] -match '/firewallPolicies/' -and $_['Id'] -ne "$($s.FirewallPolicyId)/ruleCollectionGroups/rcg-ai-agent-private-9fd780c4")) }).Count -eq 0) 'Only the dedicated firewall group may be changed.'
}

Test-Case 'Existing BYO VNet and upstream subnets are preserved' {
    $resources[$s.VnetId] = @{
        id = $s.VnetId; location = $s.Config.location; properties = @{
            provisioningState = 'Succeeded'; addressSpace = @{ addressPrefixes = @('10.180.0.0/21') }
            subnets = @(@{ id = "$($s.VnetId)/subnets/upstream"; name = 'upstream'; properties = @{ addressPrefix = '10.180.0.0/24' } })
        }
    }
    $original = $resources[$s.VnetId] | ConvertTo-Json -Depth 20 -Compress
    Ensure-HostNetwork $s
    Assert-Test (($resources[$s.VnetId] | ConvertTo-Json -Depth 20 -Compress) -eq $original) 'Existing VNet body unchanged.'
    Assert-Test (@($calls | Where-Object { $_.Method -eq 'PUT' -and $_.Id -eq $s.VnetId }).Count -eq 0) 'No full VNet PUT.'
}

Test-Case 'Overlapping reserved subnet fails before network mutation' {
    $resources[$s.VnetId] = @{
        properties = @{
            addressSpace = @{ addressPrefixes = @('10.180.0.0/21') }
            subnets = @(@{ id = "$($s.VnetId)/subnets/conflict"; name = 'conflict'; properties = @{ addressPrefix = '10.180.6.0/24' } })
        }
    }
    Assert-Throws { Ensure-HostNetwork $s } 'overlaps conflict'
    Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq 0) 'No mutation on overlap.'
}

Test-Case 'Existing incompatible peering is never overwritten' {
    $id = "$($s.VnetId)/virtualNetworkPeerings/peer-ai-agent-to-hub"
    $resources[$id] = @{ properties = @{ remoteVirtualNetwork = @{ id = '/wrong/vnet' } } }
    Assert-Throws { Ensure-HostNetwork $s } 'refusing to replace'
    Assert-Test (@($calls | Where-Object { $_.Method -eq 'PUT' -and $_.Id -eq $id }).Count -eq 0) 'No incompatible peering PUT.'
}

Test-Case 'Egress approval gate makes no calls' {
    $s.EgressApproved = $false
    Assert-Throws { Bootstrap-TestHost } 'egressApproved'
    Assert-Test ($calls.Count -eq 0) 'Approval gate precedes Azure access.'
}

Test-Case 'Bootstrap role failure still deallocates exact host' {
    $script:failRole = $true
    Assert-Throws { Bootstrap-TestHost } 'Synthetic role grant failure'
    Assert-Test ($power -eq 'PowerState/deallocated') 'Role failure deallocates.'
}

Test-Case 'Run succeeds only with execution exit zero and cleans its command' {
    Bootstrap-TestHost
    Run-TestHost
    Assert-Test ($power -eq 'PowerState/deallocated') 'Run deallocates.'
    Assert-Test (@($resources.Keys | Where-Object { $_ -match '/runCommands/' }).Count -eq 0) 'Run Command deleted.'
    $command = @($calls | Where-Object { $_.Method -eq 'PUT' -and $_.Id -match '/runCommands/' })[0]
    Assert-Test ($command.Body.properties.asyncExecution -and $command.Body.properties.timeoutInSeconds -le 10800) 'Managed command is bounded and async.'
    $remote = $command.Body.properties.source.script
    Assert-Test ($remote -match 'fetch --depth 1 origin ''a{40}''' -and $remote -match 'pwsh .*Invoke-AiAgent.ps1 -Mode Deploy -Phase ''Full''') 'Pinned checkout invokes parent deployment.'
    Assert-Test ($remote -match 'az login --identity' -and $remote -notmatch 'GITHUB_TOKEN|config.sh --url|gh auth') 'No personal token or runner registration.'
    Assert-Test ($remote -match 'exec 3>&1' -and $remote -match '>&3' -and $remote -match 'rm -rf -- "\$work"') 'Bounded logs surfaced while exact private checkout cleaned.'
}

Test-Case 'Succeeded provisioning with nonzero exit fails and cleans up' {
    Bootstrap-TestHost
    $script:runExit = 42
    Assert-Throws { Run-TestHost } 'exitCode=42'
    Assert-Test ($power -eq 'PowerState/deallocated') 'Failed remote deployment deallocates.'
    Assert-Test (@($resources.Keys | Where-Object { $_ -match '/runCommands/' }).Count -eq 0) 'Failed command deleted.'
}

Test-Case 'Missing exit code is never success' {
    Bootstrap-TestHost
    $script:omitExit = $true
    Assert-Throws { Run-TestHost } 'Managed Run Command failed'
    Assert-Test ($power -eq 'PowerState/deallocated') 'Missing exit code deallocates.'
}

Test-Case 'Failed provisioning is never hidden by a zero script exit' {
    Bootstrap-TestHost
    $script:provisionState = 'Failed'
    Assert-Throws { Run-TestHost } 'provisioningState=Failed'
}

Test-Case 'Submission failure still deallocates' {
    Bootstrap-TestHost
    $script:failRunPut = $true
    Assert-Throws { Run-TestHost } 'submission failure'
    Assert-Test ($power -eq 'PowerState/deallocated') 'Submission failure deallocates.'
}

Test-Case 'Run refuses public NIC and invalid revisions before starting' {
    Bootstrap-TestHost
    $resources[$s.NicId].properties.ipConfigurations[0].properties.publicIPAddress = @{ id = '/public/ip' }
    Assert-Throws { Run-TestHost } 'public IP'
    Assert-Test (@($calls | Where-Object { $_.Method -eq 'CLI' -and $_.Arguments[1] -eq 'start' }).Count -eq 0) 'Unsafe VM never started.'
    Assert-Throws { Get-HostRemoteScript $s 'azureholic/ato-demo' 'main' Full ('a' * 32) } 'full commit'
}

Test-Case 'Deallocate refuses an unowned VM' {
    Bootstrap-TestHost
    $resources[$s.VmId].tags.deploymentHost = 'another-workload'
    $before = @($calls | Where-Object Method -eq CLI).Count
    Assert-Throws { Stop-HostVm $s } 'refusing to replace'
    Assert-Test (@($calls | Where-Object Method -eq CLI).Count -eq $before) 'No lifecycle mutation of unowned VM.'
}

Test-Case 'Run detects routing drift without rewriting network resources' {
    Bootstrap-TestHost
    $resources[$s.RouteId].properties.routes[0].properties.nextHopType = 'Internet'
    $before = @($calls | Where-Object Method -eq PUT).Count
    Assert-Throws { Run-TestHost } 'refusing to replace'
    Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq $before) 'Run validates but never repairs network drift.'
    Assert-Test ($power -eq 'PowerState/deallocated') 'Drifted VM was not started.'
}

Test-Case 'Running command cannot pass an expired polling deadline' {
    $id = "$($s.VmId)/runCommands/offline"
    $resources[$id] = @{ properties = @{} }
    $script:runState = 'Running'
    Assert-Throws { Wait-HostRunCommand $id -TimeoutSeconds 0 } 'bounded three-hour wait'
}

Test-Case 'Timed out script execution fails and deallocates' {
    Bootstrap-TestHost
    $script:runState = 'TimedOut'
    Assert-Throws { Run-TestHost } 'executionState=TimedOut'
    Assert-Test ($power -eq 'PowerState/deallocated') 'Execution timeout deallocates.'
}

Test-Case 'Console output is bounded, redacted and suppresses workflow commands' {
    $output = (Write-HostSafeOutput ("::error::test`nclient_secret=never-print-this`neyJabc.abc.def`nhttps://example.test/?sig=hide-this") 6>&1 | Out-String)
    Assert-Test ($output -notmatch 'never-print-this|hide-this|eyJabc|::error::') 'Secrets and workflow commands suppressed.'
    Assert-Test ((Write-HostSafeOutput ('x' * 8000) 6>&1 | Out-String).Trim().Length -eq 4096) 'Console tail capped at 4KB.'
}

Test-Case 'Ephemeral SSH cleanup removes only its exact two files' {
    $directory = Join-Path (Get-Location) ".ai-agent-key-test-$([guid]::NewGuid().ToString('N'))"
    $originalRunnerTemp = $env:RUNNER_TEMP
    New-Item -ItemType Directory -Path $directory | Out-Null
    $sentinel = Join-Path $directory 'unrelated-key.pub'
    Set-Content -LiteralPath $sentinel 'preserve'
    $env:RUNNER_TEMP = $directory
    function ssh-keygen {
        $path = $args[$args.IndexOf('-f') + 1]
        Set-Content -LiteralPath $path 'offline-private'
        Set-Content -LiteralPath "$path.pub" 'offline-public'
        $global:LASTEXITCODE = 0
    }
    try {
        $key = & $script:realSshKey
        Assert-Test ($key.Trim() -eq 'offline-public') 'Returns public material only.'
        $files = @(Get-ChildItem -LiteralPath $directory)
        Assert-Test ($files.Count -eq 1 -and $files[0].FullName -eq $sentinel) 'Only unrelated sentinel remains.'
    } finally {
        $env:RUNNER_TEMP = $originalRunnerTemp
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}

Test-Case 'Firewall source scopes and destinations are strictly allowlisted' {
    $collections = @(Get-HostFirewallCollections $s @('10.170.0.82'))
    $gateway = $collections[0].rules[0]
    Assert-Test ($gateway.sourceAddresses.Count -eq 1 -and $gateway.sourceAddresses[0] -eq '10.180.0.0/21') 'GovHub source is Agent CIDR only.'
    Assert-Test ($gateway.ruleType -eq 'ApplicationRule' -and $gateway.targetFqdns.Count -eq 1 -and $gateway.targetFqdns[0] -eq $s.GovernanceGatewayFqdn) 'GovHub application rule targets the exact configured private-proven FQDN.'
    Assert-Test ($gateway.protocols[0].protocolType -eq 'Https' -and $gateway.protocols[0].port -eq 443) 'HTTPS application SNAT preserves flow symmetry.'
    Assert-Test (@($collections.rules | Where-Object { $_.ruleType -eq 'NetworkRule' }).Count -eq 0) 'No own network rule can capture traffic ahead of application SNAT.'
    $rules = $collections[1].rules
    Assert-Test ($rules[0].sourceAddresses.Count -eq 1 -and $rules[0].sourceAddresses[0] -eq '10.180.6.0/27') 'Local build packages are scoped only to the private host.'
    Assert-Test ($rules[1].sourceAddresses[0] -eq '10.180.0.0/21' -and $rules[1].targetFqdns.Count -eq 2) 'Agent-wide egress is control/identity only.'
    foreach ($rule in $rules) {
        Assert-Test ($rule.protocols[0].protocolType -eq 'Https' -and $rule.protocols[0].port -eq 443) 'No HTTP Internet exception.'
        foreach ($destination in $rule.targetFqdns) {
            Assert-Test ($destination -notin @('*', 'Any', 'Internet', '*.blob.core.windows.net')) 'No blanket destinations.'
            Assert-Test ($destination -notmatch '\*' -or $destination -eq '*.data.mcr.microsoft.com') 'Only approved MCR artifact wildcard.'
        }
    }
}

Test-Case 'New firewall group preserves every existing shared group and rule' {
    $oldId = "$($s.FirewallPolicyId)/ruleCollectionGroups/existing-platform"
    $old = @{ properties = @{ priority = 1000; ruleCollections = @(@{ name = 'keep'; rules = @(@{ name = 'keep-rule'; targetFqdns = @('existing.example.test') }) }) } }
    $resources[$oldId] = Copy-TestObject $old
    $resources[$s.FirewallPolicyId].properties.ruleCollectionGroups = @(@{ id = $oldId })
    Ensure-HostFirewall $s @('10.170.0.82')
    Assert-Test (($resources[$oldId] | ConvertTo-Json -Depth 30 -Compress) -eq ($old | ConvertTo-Json -Depth 30 -Compress)) 'Existing platform group untouched.'
    Assert-Test (@($calls | Where-Object { $_.Method -eq 'PUT' -and $_.Id -in @($oldId, $s.FirewallPolicyId) }).Count -eq 0) 'No shared parent/group PUT.'
    $ownId = $s.FirewallRuleCollectionGroupId
    $resources[$ownId].properties.ruleCollections += @{ name = 'retain-extra'; priority = 900; rules = @(@{ name = 'preserve-extra' }) }
    $before = $resources[$ownId] | ConvertTo-Json -Depth 30 -Compress
    Ensure-HostFirewall $s @('10.170.0.82')
    Assert-Test (($resources[$ownId] | ConvertTo-Json -Depth 30 -Compress) -eq $before) 'Existing rules in own group also retained.'
}

Test-Case 'Bootstrap preserves all GovHub networking without return routes or policy changes' {
    $id = "$($s.GovernanceVnetId)/subnets/$($s.Governance.networking.privateEndpointSubnetName)"
    $tableId = "$($s.GovernanceVnetId -replace '/virtualNetworks/[^/]+$', '')/routeTables/existing-table"
    $resources[$id].properties.routeTable = @{ id = $tableId }
    $resources[$id].etag = 'subnet-etag'
    $routes = @(
        @{ name = 'default-existing'; properties = @{ addressPrefix = '0.0.0.0/0'; nextHopType = 'Internet' } },
        @{ name = 'apim-management'; properties = @{ addressPrefix = 'ApiManagement'; nextHopType = 'Internet' } }
    )
    $resources[$tableId] = @{ properties = @{ routes = (Copy-TestObject $routes); disableBgpRoutePropagation = $false } }
    $originalSubnet = $resources[$id] | ConvertTo-Json -Depth 30 -Compress
    $originalTable = $resources[$tableId] | ConvertTo-Json -Depth 30 -Compress
    Bootstrap-TestHost
    Assert-Test (($resources[$id] | ConvertTo-Json -Depth 30 -Compress) -eq $originalSubnet) 'GovHub subnet, NSG and disabled PE policy untouched.'
    Assert-Test (($resources[$tableId] | ConvertTo-Json -Depth 30 -Compress) -eq $originalTable) 'GovHub management/default routes untouched.'
    Assert-Test (@($calls | Where-Object { $_.Method -in @('PUT', 'DELETE') -and $_.Id -match '/resourceGroups/rg-ai-governance' }).Count -eq 0) 'No GovHub routing or resource writes.'
    Assert-Test (@($resources.Keys | Where-Object { $_ -match 'govhub-return' }).Count -eq 0) 'No GovHub return table created.'
    Assert-Throws { Ensure-HostSubnetRoute $id '/unused/table' italynorth '10.180.0.0/21' '10.100.0.4' -AgentVnetId $s.VnetId } 'GovHub networking cannot be modified'
}

Test-Case 'Conflicting more-specific Agent forward route fails before mutation' {
    $id = '/subscriptions/example/resourceGroups/example/providers/Microsoft.Network/routeTables/existing'
    $resources[$id] = @{ properties = @{ routes = @(
        @{ name = 'already-present'; properties = @{ addressPrefix = '10.170.0.0/24'; nextHopType = 'VirtualAppliance'; nextHopIpAddress = '10.100.0.4' } },
        @{ name = 'conflict'; properties = @{ addressPrefix = '10.170.0.82/32'; nextHopType = 'Internet' } }
    ) } }
    Assert-Throws { Ensure-HostScopedRoute $id 'private' '10.170.0.0/24' '10.100.0.4' } 'Conflicting private route'
    Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq 0) 'Conflict does not overwrite routes.'
}

Test-Case 'Native outbound subnet gets only private GovHub route' {
    $id = "$($s.VnetId)/subnets/native-hosted"
    $resources[$id] = @{ properties = @{ addressPrefix = '10.180.4.0/26'; delegations = @(@{ name = 'preserve-delegation' }); privateEndpointNetworkPolicies = 'Disabled' } }
    $table = "$($s.ResourceGroupId)/providers/Microsoft.Network/routeTables/native-private"
    Ensure-HostSubnetRoute $id $table italynorth '10.170.0.0/24' '10.100.0.4' -AgentVnetId $s.VnetId
    Assert-Test ($resources[$table].properties.routes.Count -eq 1 -and $resources[$table].properties.routes[0].properties.addressPrefix -eq '10.170.0.0/24') 'No new 0/0 route for native/GovHub subnets.'
    Assert-Test ($resources[$id].properties.delegations[0].name -eq 'preserve-delegation') 'Native delegation preserved.'
}

Test-Case 'Missing private gateway never falls back to public GovHub' {
    $gov = $s.Governance
    $id = "/subscriptions/$($gov.subscriptionId)/resourceGroups/$($gov.resourceGroupName)/providers/Microsoft.Network/privateEndpoints"
    $resources[$id].value = @()
    Assert-Throws { Get-HostGovHubEndpoints $s } 'Public fallback is forbidden'
    Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq 0) 'No public fallback resources/rules.'
}

Test-Case 'Discovered private registry adds only an exact login and approved data wildcard' {
    $listId = "/subscriptions/$($s.Config.subscriptionId)/resourceGroups/$($s.Config.applicationResourceGroupName)/providers/Microsoft.ContainerRegistry/registries"
    $resources[$listId] = @{ value = @(@{ name = 'nativeagent'; location = 'italynorth'; properties = @{ loginServer = 'nativeagent.azurecr.io'; publicNetworkAccess = 'Disabled' } }) }
    $collections = @(Get-HostFirewallCollections $s @('10.170.0.82'))
    $rule = $collections[-1].rules[0]
    Assert-Test ($rule.targetFqdns.Count -eq 2 -and $rule.targetFqdns[0] -eq 'nativeagent.azurecr.io' -and $rule.targetFqdns[1] -eq '*.italynorth.data.azurecr.io') 'Registry endpoint matches approved exact/wildcard pattern.'
    Assert-Test ($rule.sourceAddresses.Count -eq 1 -and $rule.sourceAddresses[0] -eq '10.180.6.0/27') 'Registry build egress scoped only to private host.'
    $resources[$listId].value[0].properties.publicNetworkAccess = 'Enabled'
    Assert-Throws { Get-HostFirewallCollections $s @('10.170.0.82') } 'publicNetworkAccess=Disabled'
}

Test-Case 'APT mirrors are exact HTTPS destinations limited to the local build host' {
    $collections = @(Get-HostFirewallCollections $s @('10.170.0.82'))
    $rule = @($collections | Where-Object name -eq 'ai-agent-apt-mirrors-https')[0].rules[0]
    Assert-HostSubset $rule.sourceAddresses @('10.180.6.0/27')
    Assert-HostSubset $rule.targetFqdns @('archive.ubuntu.com', 'azure.archive.ubuntu.com', 'security.ubuntu.com', 'deb.debian.org', 'security.debian.org')
    Assert-Test ($rule.protocols.Count -eq 1 -and $rule.protocols[0].protocolType -eq 'Https' -and $rule.protocols[0].port -eq 443) 'Pinned Dockerfiles have no APT command requiring HTTP.'
}

Test-Case 'Mirror refresh preserves earlier firewall collections and registry priority' {
    $listId = "/subscriptions/$($s.Config.subscriptionId)/resourceGroups/$($s.Config.applicationResourceGroupName)/providers/Microsoft.ContainerRegistry/registries"
    $resources[$listId] = @{ value = @(@{ name = 'nativeagent'; location = 'italynorth'; properties = @{ loginServer = 'nativeagent.azurecr.io'; publicNetworkAccess = 'Disabled' } }) }
    $previous = @(Get-HostFirewallCollections $s @('10.170.0.82') | Where-Object name -ne 'ai-agent-apt-mirrors-https')
    $id = "$($s.FirewallPolicyId)/ruleCollectionGroups/rcg-ai-agent-private-9fd780c4"
    $resources[$id] = @{ etag = 'existing-etag'; properties = @{ priority = 3500; provisioningState = 'Succeeded'; ruleCollections = (Copy-TestObject $previous) } }
    Ensure-HostFirewall $s @('10.170.0.82')
    foreach ($original in $previous) {
        $after = @($resources[$id].properties.ruleCollections | Where-Object name -eq $original.name)[0]
        Assert-HostSubset $after $original
    }
    $registry = @($resources[$id].properties.ruleCollections | Where-Object name -eq 'ai-agent-registry-nativeagent')[0]
    Assert-Test ($registry.priority -eq 302) 'Original registry priority remains stable when adding mirror collection.'
    Assert-Test ($resources[$id].properties.ruleCollections.Count -eq ($previous.Count + 1)) 'Only the mirror collection was appended.'
}

Test-Case 'All current platform DNS zones inherit join permission without global grants' {
    $dnsRoles = @(Get-HostRoleScopes $s | Where-Object Role -eq 'b12aa53e-6015-4669-85d0-8515ebb3ae7f')
    Assert-Test ($dnsRoles.Count -eq 1 -and $dnsRoles[0].Scope -eq $s.DnsScope) 'One central DNS RG-scoped contributor grant.'
    Assert-Test ('privatelink.azurecr.io' -in $s.DnsZoneNames -and 'privatelink.monitor.azure.com' -in $s.DnsZoneNames) 'New parent DNS mappings are loaded.'
    foreach ($zone in $s.DnsZoneNames) {
        $zoneId = "$($s.DnsScope)/providers/Microsoft.Network/privateDnsZones/$zone"
        Assert-Test ($zoneId.StartsWith("$($dnsRoles[0].Scope)/providers/")) 'Zone join/action inherits from the granted DNS RG.'
    }
    Assert-Test (@(Get-HostRoleScopes $s | Where-Object { $_.Scope -match '^/subscriptions/[^/]+$|/managementGroups/' }).Count -eq 0) 'No global subscription/MG grant for DNS joins.'
}

Test-Case 'Remote deployment activates private Python 3.12 and Unix-only Docker before parent' {
    $remote = Get-HostRemoteScript $s azureholic/ato-demo ('a' * 40) Provision ('a' * 32)
    Assert-Test ($remote -match 'python3\.12 -m venv "\$work/python"' -and $remote -match 'export PATH="\$VIRTUAL_ENV/bin:\$PATH"') 'Private venv supplies python command.'
    Assert-Test ($remote.IndexOf('export PATH="$VIRTUAL_ENV/bin:$PATH"') -lt $remote.IndexOf('pwsh -NoLogo')) 'Python environment inherited by parent Invoke-AiAgent.'
    Assert-Test ($remote -match 'sys\.version_info\[:2\] == \(3, 12\)') 'Wrong Python version fails explicitly.'
    Assert-Test ($remote -match 'apt-get install .*docker\.io' -and $remote -match 'docker info >/dev/null') 'Local Docker builder is installed and readiness is checked.'
    Assert-Test ($remote.IndexOf('docker info >/dev/null') -lt $remote.IndexOf('pwsh -NoLogo')) 'Docker readiness precedes parent image preparation.'
    Assert-Test ($remote -match '--host=unix:///run/ai-agent-docker\.sock --group=root' -and $remote -match 'chmod 0600 /run/ai-agent-docker\.sock') 'Private daemon has only a root-owned Unix socket.'
    Assert-Test ($remote -notmatch '--host=tcp://|DOCKER_HOST=tcp://|2375|2376') 'No TCP daemon listener is configured.'
    Assert-Test ($remote -match 'https://archive\.ubuntu\.com/ubuntu/' -and $remote -match 'https://security\.ubuntu\.com/ubuntu/') 'Host normalizes APT sources to HTTPS.'
}

Test-Case 'Public or stale DNS prevents private application rule creation' {
    $id = "$($s.GovernanceDnsZoneId)/A/$($s.GovernanceGatewayFqdn.Split('.')[0])"
    $resources[$id].properties.aRecords[0].ipv4Address = '203.0.113.10'
    Assert-Throws { Ensure-HostFirewall $s @('10.170.0.82') } 'private DNS does not resolve exclusively'
    Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq 0) 'No firewall rule before private DNS proof.'
}

Test-Case 'Missing hub private DNS visibility prevents application rule creation' {
    $resources["$($s.GovernanceDnsZoneId)/virtualNetworkLinks"].value = @()
    Assert-Throws { Ensure-HostFirewall $s @('10.170.0.82') } 'not visible from the firewall hub'
    Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq 0) 'No rule when firewall cannot resolve the private endpoint.'
}

Test-Case 'Legacy own network rule is never retained ahead of application SNAT' {
    $id = "$($s.FirewallPolicyId)/ruleCollectionGroups/rcg-ai-agent-private-9fd780c4"
    $collections = @(Get-HostFirewallCollections $s @('10.170.0.82'))
    $collections[0].rules[0].ruleType = 'NetworkRule'
    $resources[$id] = @{ properties = @{ priority = 3500; ruleCollections = $collections } }
    $before = $resources[$id] | ConvertTo-Json -Depth 30 -Compress
    Assert-Throws { Ensure-HostFirewall $s @('10.170.0.82') } 'network rule that can bypass application SNAT'
    Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq 0) 'No partial or silent unsafe migration.'
    Assert-Test (($resources[$id] | ConvertTo-Json -Depth 30 -Compress) -eq $before) 'Existing group remains unchanged on explicit failure.'
}

Test-Case 'Host forward route explicitly directs private GovHub traffic through firewall' {
    Bootstrap-TestHost
    $routes = $resources[$s.RouteId].properties.routes
    $private = @($routes | Where-Object { $_.properties.addressPrefix -eq '10.170.0.0/24' })
    Assert-Test ($private.Count -eq 1 -and $private[0].properties.nextHopType -eq 'VirtualAppliance' -and $private[0].properties.nextHopIpAddress -eq '10.100.0.4') 'Explicit private prefix avoids reliance on a default route.'
}

Test-Case 'Only the private local builder can fetch the exact public tokenizer artifact' {
    $collections = @(Get-HostFirewallCollections $s @('10.170.0.82'))
    $rule = @($collections | Where-Object name -eq 'ai-agent-public-tokenizer-artifact')[0].rules[0]
    Assert-HostSubset $rule.sourceAddresses @('10.180.6.0/27')
    Assert-HostSubset $rule.targetFqdns @('openaipublic.blob.core.windows.net')
    Assert-Test ($rule.protocols.Count -eq 1 -and $rule.protocols[0].protocolType -eq 'Https' -and $rule.protocols[0].port -eq 443) 'Fixed public tokenizer data is HTTPS only.'
    $allRules = @($collections.rules)
    Assert-Test (@($allRules | Where-Object { '10.180.3.96/27' -in $_.sourceAddresses }).Count -eq 0) 'No disabled agent-pool subnet source is required.'
    Assert-Test (@($allRules | Where-Object { '*.blob.core.windows.net' -in $_.targetFqdns }).Count -eq 0) 'No wildcard blob permission.'
}

Write-Host "$script:passed offline host tests passed."
