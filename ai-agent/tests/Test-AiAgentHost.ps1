#Requires -Version 7.4
# All Azure/GitHub boundaries are mocked; this suite cannot mutate live resources.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\Invoke-AiAgentHost.ps1')
$script:readSettings = ${function:Get-HostSettings}
$script:realHostArm = ${function:Invoke-HostArm}
$script:passed = 0
$script:useFixture = $false
$savedToken = $env:GH_TOKEN
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
function Copy-TestObject { param($Value) $Value | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable }
function Reset-TestHost {
    $script:s = & $script:readSettings (Join-Path $PSScriptRoot '..\config\deployment.json')
    $s.EgressApproved = $true
    $script:resources = @{}
    $script:calls = [Collections.Generic.List[hashtable]]::new()
    $script:requests = [Collections.Generic.List[hashtable]]::new()
    $script:nativeCalls = [Collections.Generic.List[hashtable]]::new()
    $script:secrets = @()
    $script:executionState = 'Succeeded'
    $script:asyncStart = $false
    $script:badStart = $false
    $script:failStart = $false
    $script:failCleanup = $false
    $script:badExecutionListing = $false
    $script:changeAfterNicDelete = $null
    $script:httpQueue = [Collections.Generic.Queue[hashtable]]::new()
    $script:nextState = $null
    $script:checkText = ''
    $script:dnsCalls = 0
    $script:cliReply = $null
    $script:HostSensitiveValues = @()
    $env:GH_TOKEN = 'ghs_offlineToken123456'
    $global:LASTEXITCODE = 0
    $resources[$s.HubId] = @{ properties = @{ provisioningState = 'Succeeded'; addressSpace = @{ addressPrefixes = @('10.100.0.0/16') }; dhcpOptions = @{ dnsServers = @() } } }
    $firewallId = $s.HubId -replace '/virtualNetworks/[^/]+$', '/azureFirewalls/afw-hub-swe'
    $resources[$firewallId] = @{ properties = @{ firewallPolicy = @{ id = $s.FirewallPolicyId }; ipConfigurations = @(@{ properties = @{ privateIPAddress = '10.100.0.4' } }) } }
    $resources[$s.FirewallPolicyId] = @{ properties = @{ ruleCollectionGroups = @() } }
    $gov = $s.Governance
    $scope = "/subscriptions/$($gov.subscriptionId)/resourceGroups/$($gov.resourceGroupName)"
    $subnetId = "$($s.GovernanceVnetId)/subnets/$($gov.networking.privateEndpointSubnetName)"
    $nicId = "$scope/providers/Microsoft.Network/networkInterfaces/gateway"
    $resources[$nicId] = @{ properties = @{ ipConfigurations = @(@{ properties = @{ privateIPAddress = '10.170.0.82' } }) } }
    $resources[$subnetId] = @{ properties = @{ addressPrefix = '10.170.0.64/26'; privateEndpointNetworkPolicies = 'Disabled' } }
    $resources["$scope/providers/Microsoft.Network/privateEndpoints"] = @{ value = @(@{
        properties = @{
            subnet = @{ id = $subnetId }; networkInterfaces = @(@{ id = $nicId })
            privateLinkServiceConnections = @(@{ properties = @{
                privateLinkServiceId = "$scope/providers/Microsoft.ApiManagement/service/$($s.GovernanceGatewayFqdn.Split('.')[0])"
                groupIds = @('Gateway'); privateLinkServiceConnectionState = @{ status = 'Approved' }
            } })
        }
    }) }
    $resources["$($s.GovernanceDnsZoneId)/A/$($s.GovernanceGatewayFqdn.Split('.')[0])"] = @{ properties = @{ aRecords = @(@{ ipv4Address = '10.170.0.82' }) } }
    $resources["$($s.GovernanceDnsZoneId)/virtualNetworkLinks"] = @{ value = @(@{ properties = @{ virtualNetwork = @{ id = $s.HubId }; virtualNetworkLinkState = 'Completed' } }) }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Work)
    Reset-TestHost
    & $Work
    $script:passed++
    Write-Host "PASS $Name"
}
function Get-HostSettings {
    param([string]$Path)
    if ($script:useFixture) { return $s }
    & $script:readSettings $Path
}
function Invoke-HostDns { $script:dnsCalls++ }
function Wait-HostDelay {
    param([int]$Seconds)
    if ($script:nextState) {
        foreach ($id in @($resources.Keys | Where-Object { $_ -match '/executions/[^/]+$' })) { $resources[$id].properties.status = $script:nextState }
    }
}
function Invoke-HostArm {
    param([string]$Method, [string]$Id, [string]$ApiVersion, [hashtable]$Body, [switch]$AllowMissing, [string]$Query, [string]$ETag)
    $calls.Add(@{ Method = $Method; Id = $Id; Body = $Body; ETag = $ETag })
    if ($Method -eq 'GET') {
        if ($Id -eq "$($s.JobId)/executions") {
            if ($script:badExecutionListing) { return @{ value = $null } }
            return @{ value = @($resources.Keys | Where-Object { $_ -match "^$([regex]::Escape($s.JobId))/executions/[^/]+$" } | ForEach-Object { Copy-TestObject $resources[$_] }) }
        }
        if ($resources.ContainsKey($Id)) { return (Copy-TestObject $resources[$Id]) }
        if ($AllowMissing) { return $null }
        throw "Mock resource missing: $Id"
    }
    if ($Method -eq 'PUT') {
        if ($ETag -and $resources.ContainsKey($Id) -and $resources[$Id]['etag'] -ne $ETag) { throw 'Synthetic HTTP 412 PreconditionFailedEtagMismatch' }
        $value = Copy-TestObject $Body
        $value.id = $Id
        $value.etag = 'W/"f5edc543-86f7-4ff8-95ed-44d11e54ac82"'
        if (-not $value.ContainsKey('properties')) { $value.properties = @{} }
        $value.properties.provisioningState = 'Succeeded'
        if ($Id -eq $s.IdentityId) {
            $value.properties.principalId = '11111111-2222-3333-4444-555555555555'
            $value.properties.clientId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        }
        if ($Id -eq $s.VnetId) { $value.properties.subnets = @() }
        if ($Id -match '/routeTables/[^/]+$' -and -not $value.properties.ContainsKey('routes')) { $value.properties.routes = @() }
        if ($Id -match '^(.+/routeTables/[^/]+)/routes/[^/]+$') {
            $tableId = $Matches[1]; $value.name = $Id.Split('/')[-1]
            $resources[$tableId].properties.routes = @($resources[$tableId].properties.routes) + @($value)
        }
        $resources[$Id] = $value
        return $value
    }
    if ($Method -eq 'DELETE') {
        $resources.Remove($Id)
        if ($Id -eq $s.LegacyNicId) {
            $resources[$s.SubnetId].properties.ipConfigurations = @()
            if ($script:changeAfterNicDelete) { & $script:changeAfterNicDelete }
        }
        return
    }
    throw "Unexpected ARM method $Method."
}
function Invoke-HostNativeAz {
    param([string[]]$Arguments)
    $nativeCalls.Add(@{ Arguments = $Arguments })
    if ($script:cliReply) { $global:LASTEXITCODE = $cliReply.ExitCode; return $cliReply }
    Assert-Test ($Arguments[0] -eq 'account' -and $Arguments[1] -eq 'get-access-token') 'Only controller token retrieval uses CLI during Job lifecycle.'
    @{ ExitCode = 0; Text = '{"accessToken":"offlineArmToken"}' }
}
function Invoke-HostHttp {
    param([string]$Method, [string]$Url, [string]$Token, [AllowNull()][string]$Json, [string]$IfMatch)
    $body = if ($null -ne $Json) { $Json | ConvertFrom-Json -AsHashtable } else { $null }
    $request = New-HostHttpRequest $Method $Url $Token $Json $IfMatch
    try {
        $header = if ($request.Headers.Contains('If-Match')) { @($request.Headers.GetValues('If-Match'))[0] } else { $null }
        $requests.Add(@{ Method = $Method; Url = $Url; Token = $Token; Body = $body; Json = $Json; IfMatch = $header })
    } finally { $request.Dispose() }
    if ($httpQueue.Count) { return $httpQueue.Dequeue() }
    $uri = [Uri]$Url
    $id = $uri.AbsolutePath
    if ($IfMatch -and $resources.ContainsKey($id) -and $header -ne $resources[$id]['etag']) {
        return @{ StatusCode = 412; Text = '{"error":{"code":"PreconditionFailedEtagMismatch"}}'; Location = $null }
    }
    if ($uri.Host -eq 'api.github.com') {
        $value = @{ id = 987; output = @{ summary = 'private bounded tail'; text = $script:checkText } }
        return @{ StatusCode = 200; Text = ($value | ConvertTo-Json -Depth 20); Location = $null }
    }
    if ($Method -eq 'PUT' -and $id -eq $s.SubnetId) { $value = Copy-TestObject $body; $resources[$id] = $value }
    elseif ($Method -eq 'DELETE' -and $id -eq $s.LegacyNicId) {
        $resources.Remove($id)
        return @{ StatusCode = 204; Text = ''; Location = $null }
    }
    elseif ($id -eq "$($s.JobId)/listSecrets") { $value = @{ value = @($script:secrets) } }
    elseif ($id -eq $s.JobId -and $Method -eq 'PATCH') {
        if ($script:failCleanup -and $body.properties.configuration.secrets.Count -eq 0) {
            return @{ StatusCode = 403; Text = '{"error":{"code":"AuthorizationFailed"}}'; Location = $null }
        }
        $script:secrets = @($body.properties.configuration.secrets)
        $resources[$s.JobId].properties.configuration = Copy-TestObject $body.properties.configuration
        $value = $resources[$s.JobId]
    } elseif ($id -eq "$($s.JobId)/start") {
        if ($script:failStart) { return @{ StatusCode = 503; Text = '{"error":{"code":"ServiceUnavailable","message":"protected payload"}}'; Location = $null } }
        $executionId = "$($s.JobId)/executions/job-ai-agent-deploy-ita-abc123"
        $resources[$executionId] = @{ id = $executionId; properties = @{ status = $script:executionState; provisioningState = 'Succeeded' } }
        if ($script:badStart) { return @{ StatusCode = 202; Text = ''; Location = $null } }
        if ($script:asyncStart) { return @{ StatusCode = 202; Text = ''; Location = "https://management.azure.com$($s.JobId)/operations/start?api-version=2025-07-01" } }
        $value = @{ id = $executionId; name = 'job-ai-agent-deploy-ita-abc123' }
    } elseif ($id -eq "$($s.JobId)/operations/start") {
        $value = @{ id = "$($s.JobId)/executions/job-ai-agent-deploy-ita-abc123" }
    } elseif ($id.EndsWith('/stop')) {
        $executionId = $id.Substring(0, $id.Length - 5)
        $resources[$executionId].properties.status = 'Stopped'
        $value = $null
    } else { throw "Unexpected HTTPS $Method $id." }
    @{ StatusCode = 200; Text = if ($null -ne $value) { $value | ConvertTo-Json -Depth 40 } else { '' }; Location = $null }
}
function Invoke-TestHost {
    param([string]$Action = 'Bootstrap', [hashtable]$Parameters = @{})
    $script:useFixture = $true
    $arguments = @{ Action = $Action; ConfigPath = 'offline'; Repository = 'azureholic/ato-demo'; Revision = ('a' * 40); Phase = 'Provision'; GitHubRunId = '456' }
    foreach ($key in $Parameters.Keys) { $arguments[$key] = $Parameters[$key] }
    try { Invoke-AiAgentHost @arguments }
    finally { $script:useFixture = $false }
}
function Bootstrap-TestHost { Invoke-TestHost | Out-Null }
function New-TestLegacySubnet {
    Ensure-HostNetwork $s
    $resources[$s.SubnetId].properties.delegations = @()
    $resources[$s.SubnetId].properties.networkSecurityGroup = @{ id = $s.LegacyNsgId }
    $resources[$s.SubnetId].properties.ipConfigurations = @(@{ id = "$($s.LegacyNicId)/ipConfigurations/private" })
    $resources[$s.LegacyNsgId] = @{ tags = @{ deploymentHost = $script:HostOwner } }
    $resources[$s.LegacyNicId] = @{ tags = @{ deploymentHost = $script:HostOwner }; properties = @{
        enableIPForwarding = $false; ipConfigurations = @(@{ name = 'private'; properties = @{ subnet = @{ id = $s.SubnetId } } })
    } }
    $calls.Clear()
}

try {
    Test-Case 'Bootstrap is idempotent, Italy-only, private Consumption and narrowly scoped' {
        Bootstrap-TestHost
        $writes = @($calls | Where-Object Method -eq PUT).Count
        Bootstrap-TestHost
        Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq $writes) 'Repeat bootstrap does not rewrite infrastructure.'
        Assert-Test ($dnsCalls -eq 2) 'Platform helper alone owns zones/links.'
        $p = $resources[$s.EnvironmentId].properties
        Assert-Test ($p.vnetConfiguration.internal -and $p.publicNetworkAccess -eq 'Disabled' -and $p.vnetConfiguration.infrastructureSubnetId -eq $s.SubnetId) 'Environment has no public access and uses reserved subnet.'
        Assert-Test ($p.workloadProfiles.Count -eq 1 -and $p.workloadProfiles[0].workloadProfileType -eq 'Consumption') 'Workload-profile Consumption supports /27 and UDRs, no dedicated Compute.'
        Assert-Test ($resources[$s.JobId].properties.configuration.triggerType -eq 'Manual' -and $resources[$s.JobId].properties.configuration.replicaRetryLimit -eq 0) 'No schedules/duplicate retries.'
        Assert-Test (@($calls | Where-Object { $_.Method -ne 'GET' -and $_.Id -match '/Microsoft.Compute/|/networkInterfaces/|/networkSecurityGroups/|/publicIPAddresses/' }).Count -eq 0) 'No VM, NIC, NSG, public IP or Run Command lifecycle.'
        Assert-Test ($nativeCalls.Count -eq 0 -and $requests.Count -eq 0) 'No Docker, Compute SKU check, token or secret provisioning during Bootstrap.'
        $roles = @($calls | Where-Object { $_.Method -eq 'PUT' -and $_.Id -match '/roleAssignments/' })
        Assert-Test ($roles.Count -eq 7) 'Six native RG grants plus central DNS grant.'
        foreach ($grant in $roles) {
            Assert-Test ($grant.Id -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Authorization/roleAssignments/') 'No global/MG/Graph privileges.'
            Assert-Test ($grant.Body.properties.principalId -eq $s.ManagedIdentityObjectId) 'Only deployment UAI receives grants.'
        }
        $peers = @($calls | Where-Object { $_.Method -eq 'PUT' -and $_.Id -match '/virtualNetworkPeerings/' })
        Assert-Test ($peers.Count -eq 2 -and $peers[0].Id.StartsWith($s.VnetId) -and $peers[1].Id.StartsWith($s.HubId)) 'Both peering scopes.'
        foreach ($peer in $peers) { Assert-Test ($peer.Body.properties.allowForwardedTraffic -and -not $peer.Body.properties.allowGatewayTransit -and -not $peer.Body.properties.useRemoteGateways) 'Forwarding without gateway transit.' }
    }
    Test-Case 'BYO VNet and overlapping/foreign subnet protections survive replacement' {
        $resources[$s.VnetId] = @{ properties = @{ addressSpace = @{ addressPrefixes = @('10.180.0.0/21') }; subnets = @(
            @{ id = "$($s.VnetId)/subnets/native"; name = 'native'; properties = @{ addressPrefix = '10.180.0.0/24' } }
        ) } }
        $before = $resources[$s.VnetId] | ConvertTo-Json -Depth 20 -Compress
        Ensure-HostNetwork $s
        Assert-Test (($resources[$s.VnetId] | ConvertTo-Json -Depth 20 -Compress) -eq $before) 'No full VNet rewrite.'
        $resources[$s.VnetId].properties.subnets[0].properties.addressPrefix = '10.180.6.0/24'
        $calls.Clear()
        Assert-Throws { Ensure-HostNetwork $s } 'overlaps native'
        Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq 0) 'Overlap fails before mutation.'
    }
    Test-Case 'Unapproved egress and incompatible peering never get overwritten' {
        $s.EgressApproved = $false
        Assert-Throws { Bootstrap-TestHost } 'egressApproved'
        Assert-Test ($calls.Count -eq 0) 'Unapproved Bootstrap has no resource calls.'
        $s.EgressApproved = $true
        $resources["$($s.VnetId)/virtualNetworkPeerings/peer-ai-agent-to-hub"] = @{ properties = @{ remoteVirtualNetwork = @{ id = '/other/vnet' } } }
        Assert-Throws { Ensure-HostNetwork $s } 'refusing to replace'
    }
    Test-Case 'Scoped firewall preserves shared rules and routes through SNAT without GovHub writes' {
        $shared = "$($s.FirewallPolicyId)/ruleCollectionGroups/shared"
        $resources[$s.FirewallPolicyId].properties.ruleCollectionGroups = @(@{ id = $shared })
        $resources[$shared] = @{ properties = @{ priority = 100; ruleCollections = @(@{ name = 'existing'; rules = @(@{ source = 'keep' }) }) } }
        $before = $resources[$shared] | ConvertTo-Json -Depth 20 -Compress
        Bootstrap-TestHost
        Assert-Test (($resources[$shared] | ConvertTo-Json -Depth 20 -Compress) -eq $before) 'Shared policy untouched.'
        Assert-Test (@($calls | Where-Object { $_.Method -ne 'GET' -and $_.Id.StartsWith($s.GovernanceVnetId) }).Count -eq 0) 'No GovHub routes/subnet/network-policy mutation.'
        $rule = (Get-HostFirewallCollections $s @('10.170.0.82'))[0].rules[0]
        Assert-Test ($rule.ruleType -eq 'ApplicationRule' -and $rule.targetFqdns[0] -eq $s.GovernanceGatewayFqdn -and $rule.sourceAddresses[0] -eq '10.180.0.0/21') 'Private FQDN application SNAT rule.'
        Assert-Test ($resources[$s.RouteId].properties.routes[1].properties.nextHopIpAddress -eq '10.100.0.4') 'Explicit GovHub forward path via firewall.'
    }
    Test-Case 'Source-limited package and identity rules never permit blanket Internet or blob access' {
        $collections = @(Get-HostFirewallCollections $s @('10.170.0.82'))
        foreach ($collection in $collections) {
            foreach ($rule in $collection.rules) {
                Assert-Test ($rule.ruleType -eq 'ApplicationRule') 'No own network rule bypasses SNAT.'
                foreach ($fqdn in $rule.targetFqdns) { Assert-Test ($fqdn -notin @('*', 'Internet', '*.blob.core.windows.net', 'graph.microsoft.com')) 'No broad destination or Graph.' }
                if ($rule.name -notin @('private-gateway-443', 'agent-azure-control')) { Assert-Test ($rule.sourceAddresses.Count -eq 1 -and $rule.sourceAddresses[0] -eq $s.SubnetPrefix) 'Packages/artifacts/platform limited to job subnet.' }
                foreach ($protocol in $rule.protocols) {
                    if ($protocol.port -eq 80) { Assert-Test ($rule.targetFqdns.Count -eq 2 -and $rule.targetFqdns[0] -eq 'deb.debian.org' -and $rule.targetFqdns[1] -eq 'security.debian.org') 'HTTP only signed Debian APT mirrors; no identity/model traffic.' }
                }
            }
        }
        $identity = @($collections.rules | Where-Object name -eq 'agent-azure-control')[0]
        Assert-Test ($identity.targetFqdns -contains 'login.microsoftonline.com' -and $identity.sourceAddresses[0] -eq '10.180.0.0/21') 'Native OAuth/OBO remains permitted, packages not expanded to runtime.'
    }
    Test-Case 'Artifact hosts are exact validated HTTPS rules and append idempotently' {
        Invoke-TestHost -Parameters @{ ArtifactHosts = @('productionresultssa7.blob.core.windows.net') } | Out-Null
        Invoke-TestHost -Parameters @{ ArtifactHosts = @('pipelinesghubabc123.blob.core.windows.net') } | Out-Null
        $group = $resources["$($s.FirewallPolicyId)/ruleCollectionGroups/rcg-ai-agent-private-9fd780c4"]
        $artifact = @($group.properties.ruleCollections | Where-Object name -eq 'ai-agent-job-artifacts')[0]
        Assert-Test ($artifact.rules.Count -eq 2) 'Previous exact artifact host retained.'
        foreach ($rule in $artifact.rules) { Assert-Test ($rule.sourceAddresses[0] -eq $s.SubnetPrefix -and $rule.protocols[0].port -eq 443) 'Artifact HTTPS only from Job subnet.' }
        $count = @($calls | Where-Object Method -eq PUT).Count
        Invoke-TestHost -Parameters @{ ArtifactHosts = @('pipelinesghubabc123.blob.core.windows.net') } | Out-Null
        Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq $count) 'Repeated artifact approval does not rewrite.'
        foreach ($bad in @('*.blob.core.windows.net', 'https://productionresultssa7.blob.core.windows.net/?sig=secret', 'other.blob.core.windows.net', 'pipelinesghubx.blob.core.windows.net.evil')) {
            Assert-Throws { Invoke-TestHost -Parameters @{ ArtifactHosts = @($bad) } } 'ArtifactHosts'
        }
    }
    Test-Case 'Private gateway DNS proof rejects public fallback and network-rule SNAT bypass' {
        $record = "$($s.GovernanceDnsZoneId)/A/$($s.GovernanceGatewayFqdn.Split('.')[0])"
        $resources[$record].properties.aRecords[0].ipv4Address = '20.1.2.3'
        Assert-Throws { Bootstrap-TestHost } 'private DNS'
        $resources[$record].properties.aRecords[0].ipv4Address = '10.170.0.82'
        $resources["$($s.FirewallPolicyId)/ruleCollectionGroups/rcg-ai-agent-private-9fd780c4"] = @{ properties = @{ priority = 3500; ruleCollections = @(@{ name = 'old'; rules = @(@{ ruleType = 'NetworkRule' }) }) } }
        Assert-Throws { Bootstrap-TestHost } 'network rule.*bypass'
    }
    Test-Case 'Native existing routing associations are preserved and conflicts fail' {
        Ensure-HostNetwork $s
        $native = "$($s.VnetId)/subnets/native"
        $table = "$($s.ResourceGroupId)/providers/Microsoft.Network/routeTables/native"
        $resources[$native] = @{ properties = @{ addressPrefix = '10.180.1.0/24'; routeTable = @{ id = $table } } }
        $resources[$table] = @{ properties = @{ routes = @(@{ name = 'management'; properties = @{ addressPrefix = 'ApiManagement'; nextHopType = 'Internet' } }) } }
        Ensure-HostSubnetRoute $native '/unused' italynorth '10.170.0.0/24' '10.100.0.4' -AgentVnetId $s.VnetId
        Assert-Test ($resources[$native].properties.routeTable.id -eq $table -and $resources[$table].properties.routes[0].name -eq 'management') 'Association/management exception unchanged.'
        $resources[$table].properties.routes += @{ name = 'conflict'; properties = @{ addressPrefix = '10.170.0.82/32'; nextHopType = 'Internet' } }
        Assert-Throws { Ensure-HostSubnetRoute $native '/unused' italynorth '10.170.0.0/24' '10.100.0.4' -AgentVnetId $s.VnetId } 'Conflicting private route'
    }
    Test-Case 'Legacy unused owned NIC alone can be deleted to permit delegation' {
        New-TestLegacySubnet
        Ensure-HostDeploymentSubnet $s
        $deletes = @($calls | Where-Object Method -eq DELETE)
        Assert-Test ($deletes.Count -eq 1 -and $deletes[0].Id -eq $s.LegacyNicId) 'Only exact owned unused NIC removed.'
        Assert-Test ($resources.ContainsKey($s.LegacyNsgId)) 'Old NSG/infrastructure not deleted.'
        Assert-Test (-not $resources[$s.SubnetId].properties.ContainsKey('networkSecurityGroup') -and $resources[$s.SubnetId].properties.delegations[0].properties.serviceName -eq 'Microsoft.App/environments') 'Only incompatible owned association detached; subnet delegated.'
    }
    Test-Case 'Conditional PUT and bodyless DELETE preserve the real weak ETag in HTTP headers' {
        New-TestLegacySubnet
        $etag = 'W/"f5edc543-86f7-4ff8-95ed-44d11e54ac82"'
        $body = @{ properties = (Copy-TestObject $resources[$s.SubnetId].properties) }
        $null = & $script:realHostArm PUT $s.SubnetId '2024-05-01' $body -ETag $etag
        $resources[$s.LegacyNicId].etag = $etag
        $null = & $script:realHostArm DELETE $s.LegacyNicId '2024-05-01' -ETag $etag
        Assert-Test ($requests.Count -eq 2 -and $requests[0].IfMatch -ceq $etag -and $requests[1].IfMatch -ceq $etag) 'Actual HttpRequestMessage preserves W/"GUID" exactly, without duplicate W/ or quote stripping.'
        Assert-Test ($requests[0].Url.EndsWith('?api-version=2024-05-01') -and $requests[1].Method -eq 'DELETE') 'Conditional network API/version and bodyless DELETE are preserved.'
        Assert-Test (-not $requests[1].Json) 'DELETE needs no body to carry its optimistic-lock header.'
        Assert-Test (@($nativeCalls | Where-Object { $_.Arguments[0] -eq 'rest' }).Count -eq 0) 'Conditional headers never pass through Azure CLI parsing.'
        Assert-Test (@(Get-ChildItem (Get-Location) -Filter '.ai-agent-host-*.json').Count -eq 0) 'Conditional bodies stay in memory.'
    }
    Test-Case 'HTTP 412 remains an explicit failure without wildcard or blind retries' {
        $httpQueue.Enqueue(@{ StatusCode = 412; Text = '{"error":{"code":"PreconditionFailedEtagMismatch"}}'; Location = $null })
        Assert-Throws { & $script:realHostArm PUT $s.SubnetId '2024-05-01' @{ properties = @{} } -ETag 'W/"f5edc543-86f7-4ff8-95ed-44d11e54ac82"' } 'HTTP 412, code=PreconditionFailedEtagMismatch'
        Assert-Test ($requests.Count -eq 1) 'No 412 retry or unconditional success fallback.'
        Assert-Throws { New-HostHttpRequest PUT 'https://management.azure.com/owned' private '{}' '*' } 'never a wildcard'
    }
    Test-Case 'NIC deletion ETag changes are refetched with a fully revalidated subnet snapshot' {
        New-TestLegacySubnet
        $script:changeAfterNicDelete = { $resources[$s.SubnetId].etag = 'W/"22222222-2222-2222-2222-222222222222"' }
        Ensure-HostDeploymentSubnet $s
        $put = @($calls | Where-Object { $_.Method -eq 'PUT' -and $_.Id -eq $s.SubnetId })[0]
        Assert-Test ($put.ETag -ceq 'W/"22222222-2222-2222-2222-222222222222"') 'Post-delete ETag is used without relaxing optimistic concurrency.'
        Assert-Test (@($calls | Where-Object { $_.Method -eq 'DELETE' }).Count -eq 1) 'Still removes only exact safe owned NIC.'
    }
    Test-Case 'Concurrent subnet reassociation after NIC deletion is never discarded' {
        New-TestLegacySubnet
        $script:changeAfterNicDelete = {
            $resources[$s.SubnetId].etag = 'W/"22222222-2222-2222-2222-222222222222"'
            $resources[$s.SubnetId].properties.routeTable.id = '/foreign/route-table'
        }
        Assert-Throws { Ensure-HostDeploymentSubnet $s } 'routeTable.*differs'
        Assert-Test (@($calls | Where-Object Method -eq PUT).Count -eq 0) 'Fresh unexpected association blocks delegation PUT.'
    }
    Test-Case 'Live VM reference or foreign NIC prevents legacy deletion' {
        New-TestLegacySubnet
        $resources[$s.LegacyVmId] = @{ properties = @{} }
        Assert-Throws { Ensure-HostDeploymentSubnet $s } 'Legacy deployment VM exists'
        $resources.Remove($s.LegacyVmId)
        $resources[$s.LegacyNicId].properties.virtualMachine = @{ id = '/different/vm' }
        Assert-Throws { Ensure-HostDeploymentSubnet $s } 'referenced by a VM'
        $resources[$s.LegacyNicId].properties.Remove('virtualMachine')
        $resources[$s.LegacyNicId].tags.deploymentHost = 'another-owner'
        Assert-Throws { Ensure-HostDeploymentSubnet $s } 'refusing to replace'
        Assert-Test (@($calls | Where-Object Method -eq DELETE).Count -eq 0) 'No deletion on absent ownership/unused proof.'
    }
    Test-Case 'Unknown subnet references or NSG cannot be silently discarded' {
        New-TestLegacySubnet
        $resources[$s.SubnetId].properties.ipConfigurations[0].id = '/another/nic/ipConfigurations/private'
        Assert-Throws { Ensure-HostDeploymentSubnet $s } 'unknown NIC reference'
        $resources[$s.SubnetId].properties.ipConfigurations = @()
        $resources[$s.SubnetId].properties.networkSecurityGroup.id = '/foreign/nsg'
        Assert-Throws { Ensure-HostDeploymentSubnet $s } 'Unknown subnet NSG'
        Assert-Test (@($calls | Where-Object Method -eq DELETE).Count -eq 0) 'No broad cleanup.'
    }
    Test-Case 'Run transports GH token and Handoff secrets only as encrypted Job secrets' {
        Bootstrap-TestHost
        $params = @{ UI_OAUTH_CLIENT_SECRET = 'privateOAuthValue'; UI_OAUTH_EXPIRES = '2099-01-01'; CHAINLIT_AUTH_SECRET = 'privateChainlitValue' }
        Invoke-TestHost Run @{ SecretParameters = $params; Phase = 'Provision' } | Out-Null
        $start = @($requests | Where-Object { $_.Url -match '/start\?' })[0]
        $container = $start.Body.containers[0]
        Assert-Test ($container.image -eq $script:HostWorkerImage -and $container.command[0] -eq '/bin/bash') 'Immutable public MCR Python worker, no custom Docker builder.'
        Assert-Test ($container.args[1] -match 'raw.githubusercontent.com/azureholic/ato-demo/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/ai-agent/Run-AiAgentJob.sh' -and $container.args[1] -notmatch 'Authorization|GH_TOKEN|docker') 'Public script pinned by SHA and fetched without credentials.'
        foreach ($key in @('ATO_REPOSITORY', 'ATO_REVISION', 'ATO_PHASE', 'ATO_GITHUB_RUN_ID', 'ATO_CHECK_RUN_ID', 'AZURE_CLIENT_ID')) { Assert-Test (@($container.env | Where-Object name -eq $key).Count -eq 1) "Parent-required env $key exists." }
        Assert-Test (@($container.env | Where-Object name -eq 'ATO_PHASE')[0].value -eq 'Provision') 'Normal phases retain GitHub checks and token.'
        foreach ($key in @('GH_TOKEN') + @($params.Keys)) {
            $entry = @($container.env | Where-Object name -eq $key)[0]
            Assert-Test ($entry.ContainsKey('secretRef') -and -not $entry.ContainsKey('value')) "$key is a secret reference, never a plain start environment value."
        }
        Assert-Test ($start.Json -notmatch 'privateOAuthValue|privateChainlitValue|ghs_offlineToken') 'Start JSON contains no secret values.'
        $secretWrite = @($requests | Where-Object { $_.Method -eq 'PATCH' -and $_.Url -match '/jobs/' -and $_.Json -match 'privateOAuthValue' })
        Assert-Test ($secretWrite.Count -eq 1 -and $secretWrite[0].Token -eq 'offlineArmToken') 'Secret values submitted only in memory to authenticated HTTPS Job PATCH.'
        Assert-Test ($script:secrets.Count -eq 0 -and $script:HostSensitiveValues.Count -eq 0) 'Own secrets and redaction references cleared.'
        foreach ($native in $nativeCalls) { Assert-Test (($native.Arguments -join ' ') -notmatch 'privateOAuthValue|ghs_offlineToken|--body') 'No token/secret command-line transport or body files.' }
        Assert-Test (@(Get-ChildItem (Get-Location) -Filter '.ai-agent-host-*.json').Count -eq 0) 'No secret-bearing temporary JSON files.'
    }
    Test-Case 'Explicit administrator Handoff needs no GitHub token, API or check-run' {
        Bootstrap-TestHost
        $env:GH_TOKEN = ''
        $parameters = @{ UI_OAUTH_CLIENT_SECRET = 'privateAdminOAuth'; UI_OAUTH_EXPIRES = '2099-01-01'; CHAINLIT_AUTH_SECRET = 'privateAdminChainlit' }
        $result = Invoke-TestHost Run @{ SecretParameters = $parameters; Phase = 'Handoff' } | ConvertFrom-Json -AsHashtable
        Assert-Test ($result.status -eq 'Succeeded' -and $null -eq $result.checkRunId) 'Azure execution status proves successful Handoff without GitHub check fallback.'
        $start = @($requests | Where-Object { $_.Url -match '/start\?' })[0]
        Assert-Test (@($start.Body.containers[0].env | Where-Object { $_.name -in @('GH_TOKEN', 'ATO_CHECK_RUN_ID') }).Count -eq 0) 'No token or check reference enters Handoff execution.'
        foreach ($name in $parameters.Keys) {
            Assert-Test (@($start.Body.containers[0].env | Where-Object name -eq $name)[0].ContainsKey('secretRef')) 'Handoff secrets remain encrypted ACA references.'
        }
        Assert-Test (@($requests | Where-Object { $_.Url.StartsWith('https://api.github.com/') }).Count -eq 0 -and $script:secrets.Count -eq 0) 'No GitHub API calls; mandatory cleanup completed.'
        $env:GH_TOKEN = 'oauthLocalUserToken'
        Invoke-TestHost Run @{ SecretParameters = $parameters; Phase = 'Handoff' } | Out-Null
        Assert-Test (@($requests | Where-Object { $_.Json -match 'oauthLocalUserToken' -or $_.Token -eq 'oauthLocalUserToken' }).Count -eq 0) 'Even a present OAuth token is not transported or used in Handoff.'
    }
    Test-Case 'Azure-only Handoff failure still validates real execution and cleans credentials' {
        Bootstrap-TestHost
        $env:GH_TOKEN = ''
        $script:executionState = 'Failed'
        Assert-Throws { Invoke-TestHost Run @{ Phase = 'Handoff'; SecretParameters = @{ UI_OAUTH_CLIENT_SECRET = 'privateAdminOAuth' } } } 'status=Failed'
        Assert-Test ($script:secrets.Count -eq 0 -and @($requests | Where-Object { $_.Url.StartsWith('https://api.github.com/') }).Count -eq 0) 'Failed Handoff removes only its secrets without attempting OAuth check-run creation.'
    }
    Test-Case 'Real execution failure cannot pass because ARM provisioning succeeded' {
        Bootstrap-TestHost
        $script:executionState = 'Failed'
        Assert-Throws { Invoke-TestHost Run } 'status=Failed.*provisioning success'
        Assert-Test ($script:secrets.Count -eq 0) 'Failed completed execution still cleans own encrypted secrets.'
        $last = @($requests | Where-Object { $_.Url -match 'check-runs/987' -and $_.Method -eq 'PATCH' })[-1]
        Assert-Test ($last.Body.conclusion -eq 'failure') 'Phase check concludes failure.'
    }
    Test-Case 'Successful execution cannot hide encrypted-secret cleanup failure' {
        Bootstrap-TestHost
        $script:failCleanup = $true
        Assert-Throws { Invoke-TestHost Run } 'HTTP 403'
        $last = @($requests | Where-Object { $_.Url -match 'check-runs/987' -and $_.Method -eq 'PATCH' })[-1]
        Assert-Test ($last.Body.conclusion -eq 'failure') 'Cleanup failure cannot publish a successful controller check.'
        Assert-Test ($script:secrets.Count -gt 0) 'Failed cleanup explicitly leaves encrypted secrets for retry, never claims removal.'
    }
    Test-Case 'Unknown execution status fails, stops only exact execution, then cleans secrets' {
        Bootstrap-TestHost
        $script:executionState = 'Unknown'
        Assert-Throws { Invoke-TestHost Run } 'unknown/missing status'
        $stop = @($requests | Where-Object { $_.Url -match '/stop\?' })
        Assert-Test ($stop.Count -eq 1 -and $stop[0].Url -match '/executions/job-ai-agent-deploy-ita-abc123/stop') 'Exact execution stop, no infrastructure or bulk stop.'
        Assert-Test ($script:secrets.Count -eq 0) 'Cleanup follows verified stopped execution.'
    }
    Test-Case 'Missing execution status is never replaced with provisioning success' {
        Bootstrap-TestHost
        $id = "$($s.JobId)/executions/missing-status"
        $resources[$id] = @{ id = $id; properties = @{ provisioningState = 'Succeeded' } }
        Assert-Throws { Wait-HostJobExecution $id } 'unknown/missing status'
    }
    Test-Case 'Processing waits for real Succeeded and bounded timeout is explicit' {
        Bootstrap-TestHost
        $script:executionState = 'Processing'; $script:nextState = 'Succeeded'
        Invoke-TestHost Run | Out-Null
        Assert-Throws { Wait-HostJobExecution "$($s.JobId)/executions/job-ai-agent-deploy-ita-abc123" -TimeoutSeconds 0 } 'bounded wait'
    }
    Test-Case 'Asynchronous start resolves exact returned operation, never guesses latest' {
        Bootstrap-TestHost
        $script:asyncStart = $true
        Invoke-TestHost Run | Out-Null
        Assert-Test (@($requests | Where-Object { $_.Method -eq 'GET' -and $_.Url -match '/operations/start' }).Count -eq 1) '202 Location polled to exact execution.'
        $script:asyncStart = $false; $script:badStart = $true
        Assert-Throws { Invoke-TestHost Run } 'did not identify.*no latest'
    }
    Test-Case 'Uncertain start is never retried and cannot clear credentials while active' {
        Bootstrap-TestHost
        $script:failStart = $true
        Assert-Throws { Invoke-TestHost Run } 'HTTP 503'
        Assert-Test (@($requests | Where-Object { $_.Url -match '/start\?' }).Count -eq 1) 'No double-deploy POST retries.'
        Assert-Test ($script:secrets.Count -eq 0) 'No submitted execution allows credential cleanup.'
        $script:failStart = $false; $script:badStart = $true; $script:executionState = 'Running'
        Assert-Throws { Invoke-TestHost Run } 'active or unknown execution'
        Assert-Test ($script:secrets.Count -gt 0) 'Ambiguous running execution retains encrypted secrets until it stops; no success fallback.'
    }
    Test-Case 'Cleanup preserves unrelated secrets and never deletes infrastructure' {
        Bootstrap-TestHost
        $script:secrets = @(@{ name = 'ato-456-abcdef-gh'; value = 'own' }, @{ name = 'ato-4567-other'; value = 'other-run' }, @{ name = 'operator-secret'; value = 'preserve' })
        Invoke-TestHost Cleanup | Out-Null
        Assert-Test ($script:secrets.Count -eq 2 -and $script:secrets[0].value -eq 'other-run' -and $script:secrets[1].value -eq 'preserve') 'Exact run-prefix cleanup preserves values of others.'
        Assert-Test (@($calls | Where-Object Method -eq DELETE).Count -eq 0) 'Cleanup deletes no infrastructure.'
        $count = @($requests | Where-Object Method -eq PATCH).Count
        Invoke-TestHost Cleanup | Out-Null
        Assert-Test (@($requests | Where-Object Method -eq PATCH).Count -eq $count) 'Repeated cleanup is idempotent.'
        Assert-Throws { Clear-HostRunSecrets $s '456*' } 'exact numeric'
    }
    Test-Case 'Active executions block cleanup and new runs before credentials/check creation' {
        Bootstrap-TestHost
        $resources["$($s.JobId)/executions/active"] = @{ id = "$($s.JobId)/executions/active"; properties = @{ status = 'Running' } }
        $script:secrets = @(@{ name = 'ato-456-own'; value = 'still-needed' })
        Assert-Throws { Invoke-TestHost Cleanup } 'active or unknown'
        Assert-Throws { Invoke-TestHost Run } 'active or unknown'
        Assert-Test ($requests.Count -eq 0 -and $script:secrets.Count -eq 1) 'No credential deletion or new check/start while active.'
    }
    Test-Case 'Incomplete execution or secret listing prevents destructive cleanup' {
        Bootstrap-TestHost
        $script:badExecutionListing = $true
        Assert-Throws { Invoke-TestHost Cleanup } 'definitive status data'
        Assert-Test ($requests.Count -eq 0) 'Null execution list cannot imply idle.'
        $script:badExecutionListing = $false
        $httpQueue.Enqueue(@{ StatusCode = 200; Text = '{"value":[{"name":"operator-secret"}]}'; Location = $null })
        Assert-Throws { Invoke-TestHost Cleanup } 'values/references were not returned'
        Assert-Test (@($requests | Where-Object Method -eq PATCH).Count -eq 0) 'Redacted/missing existing values cannot be silently replaced.'
    }
    Test-Case 'Foreign job and public environment are never adopted' {
        Bootstrap-TestHost
        $resources[$s.EnvironmentId].properties.publicNetworkAccess = 'Enabled'
        Assert-Throws { Invoke-TestHost Run } 'refusing to replace'
        $resources[$s.EnvironmentId].properties.publicNetworkAccess = 'Disabled'
        $resources[$s.JobId].tags.deploymentHost = 'foreign'
        Assert-Throws { Invoke-TestHost Cleanup } 'refusing to replace'
    }
    Test-Case 'Phase failure fetches bounded check logs with token and supplied-secret redaction' {
        Bootstrap-TestHost
        $script:executionState = 'Failed'
        $script:checkText = ("x" * 6000) + "`nprivateOAuthValue $env:GH_TOKEN`n::error::untrusted`nBearer private-token"
        $output = [Collections.Generic.List[string]]::new()
        try { & { Invoke-TestHost Run @{ SecretParameters = @{ UI_OAUTH_CLIENT_SECRET = 'privateOAuthValue' } } } 6>&1 | ForEach-Object { $output.Add("$_") } } catch { }
        $text = $output -join "`n"
        Assert-Test ($text -notmatch 'privateOAuthValue|ghs_offlineToken|Bearer private-token|(?m)^::') 'Sensitive values and workflow commands never reach caller.'
        Assert-Test ($text -match 'REDACTED' -and $text.Length -lt 5000) 'Actionable bounded failure tail retained.'
    }
    Test-Case 'Invalid pinned revision, phase, token and reserved secrets fail before mutation' {
        $script:useFixture = $true
        try {
            Assert-Throws { Invoke-AiAgentHost Run offline azureholic/ato-demo main Provision 456 } 'Revision40'
            Assert-Throws { Invoke-AiAgentHost Run offline azureholic/ato-demo ('a' * 40) Full 456 } 'supported Phase'
            Assert-Throws { Invoke-AiAgentHost Run offline azureholic/ato-demo ('a' * 40) Handoff 456 @{ GH_TOKEN = 'override' } } 'reserved'
            $env:GH_TOKEN = ''
            Assert-Throws { Invoke-AiAgentHost Run offline azureholic/ato-demo ('a' * 40) Provision 456 } 'ephemeral GH_TOKEN'
        } finally { $script:useFixture = $false }
        Assert-Test ($calls.Count -eq 0 -and $requests.Count -eq 0) 'Invalid inputs do not touch resources.'
    }
    Test-Case 'Memory transport rejects credential redirects, redacts write errors and bounds retries' {
        Assert-Throws { Invoke-HostMemoryRequest POST 'http://management.azure.com/' private @{ secret = 'value' } } 'approved HTTPS'
        Assert-Throws { Invoke-HostMemoryRequest POST 'https://evil.example/' private @{} } 'approved HTTPS'
        $httpQueue.Enqueue(@{ StatusCode = 400; Text = '{"error":{"code":"InvalidRequest","message":"privateSecretValue"}}'; Location = $null })
        Assert-Throws { Invoke-HostMemoryRequest PATCH 'https://management.azure.com/owned' private @{ secret = 'privateSecretValue' } } 'HTTP 400, code=InvalidRequest'
        $httpQueue.Enqueue(@{ StatusCode = 429; Text = ''; Location = $null })
        $httpQueue.Enqueue(@{ StatusCode = 200; Text = '{"status":"Succeeded"}'; Location = $null })
        $result = Invoke-HostMemoryRequest GET 'https://management.azure.com/owned' private
        Assert-Test ($result.Value.status -eq 'Succeeded') 'Bounded safe GET retry handles throttling.'
    }
    Test-Case 'ARM asynchronous operation cannot redirect an Azure credential to GitHub' {
        Assert-Throws { Invoke-HostMemoryArm GET -Url "https://api.github.com/subscriptions/$($s.Config.subscriptionId)/operation" } 'non-ARM operation URL'
        Assert-Test ($requests.Count -eq 0) 'Azure credential never leaves ARM.'
    }
    Test-Case 'Recognized initial absence has successful semantic exit while forbidden stays fatal' {
        $script:cliReply = @{ ExitCode = 1; Text = 'ERROR: Not Found({"error":{"code":"ResourceGroupNotFound","message":"missing"}})' }
        $result = & $script:realHostArm GET $s.JobId '2025-07-01' -AllowMissing
        Assert-Test ($null -eq $result -and $global:LASTEXITCODE -eq 0) 'Cleanup missing Job is semantic success for Actions wrapper.'
        $script:cliReply = @{ ExitCode = 1; Text = 'ERROR: Forbidden({"error":{"code":"AuthorizationFailed","message":"privateSecretValue"}})' }
        Assert-Throws { & $script:realHostArm GET $s.JobId '2025-07-01' -AllowMissing } 'HTTP 403'
        Assert-Test ($global:LASTEXITCODE -eq 1) 'Real permissions failure remains failure.'
    }
    Test-Case 'Absent Cleanup is a no-op and deallocation interface is removed' {
        Invoke-TestHost Cleanup | Out-Null
        Assert-Test ($requests.Count -eq 0 -and @($calls | Where-Object Method -ne GET).Count -eq 0) 'Absent infrastructure not recreated for cleanup.'
        Assert-Throws { Invoke-TestHost Deallocate } 'ValidateSet|does not belong'
    }
    Write-Host "$script:passed offline host tests passed."
} finally { $env:GH_TOKEN = $savedToken }
