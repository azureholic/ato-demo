#Requires -Version 7.4
<#
.SYNOPSIS
Creates and operates the isolated, managed-identity deployment VM; never a GitHub runner.
.DESCRIPTION
Bootstrap requires deploymentHost.egressApproved=true in deployment.json: an operator
approval of the narrowly source/FQDN-scoped rules installed by Bootstrap in its own
firewall rule collection group, and Agent forward routing. GovHub uses application-rule
SNAT for flow symmetry; its route tables and private endpoint policies are never changed.
No existing
firewall group is replaced. Invoke-PlatformDns.ps1 alone creates DNS zones and links.
Bootstrap checks the exact deploymentHost.vmSize (default Standard_D4s_v5) against
subscription/location SKU restrictions before any resource mutation. No size or region
fallback is attempted; Compute region access is separate from unused vCPU quota.
Run requires a full commit SHA of a PUBLIC repository and always deallocates the VM.
Repeat Bootstrap with the GitHub identity after Provision to append discovered private
registry rules and native subnet routes before Publish. Run only validates shared rules.
ACR task platform dependencies (Storage/EventHub/KeyVault/Monitor) are NOT implicitly
allowed: approve exact required endpoints separately; no blanket blob/service-tag rule.
Workflow concurrency must serialize Bootstrap/Run/Deallocate for this dedicated host.
#>
[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'Run', 'Deallocate')]
    [string]$Action = 'Bootstrap',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\deployment.json'),
    [string]$Repository = 'azureholic/ato-demo',
    [string]$Revision,
    [ValidateSet('Full', 'Provision', 'Publish', 'Verify')]
    [string]$Phase = 'Full'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:HostOwner = 'ai-agent-private-deployment-host'

function Invoke-HostNativeAz {
    param([string[]]$Arguments)
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    @{ Text = ($output | Out-String); ExitCode = $exitCode }
}

function Get-HostAzureError {
    param([string]$Text)
    $code = $null
    $message = $null
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -ge 0 -and $end -ge $start) {
        try {
            $json = $Text.Substring($start, $end - $start + 1) | ConvertFrom-Json -AsHashtable
            $errorObject = if ($json['error'] -is [System.Collections.IDictionary]) { $json['error'] } else { $json }
            $code = $errorObject['code']
            $message = $errorObject['message']
        } catch { } # Unstructured stderr is never echoed or classified by message substrings.
    }
    if (-not $code -and $Text -match '^\s*(?:ERROR:\s*)?\(([A-Za-z][A-Za-z0-9_.-]{0,127})\)') { $code = $Matches[1] }
    if ($code -isnot [string] -or $code -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,127}$') { $code = 'UnclassifiedCliError' }
    $status = $null
    $statuses = @{ 'Not Found' = 404; 'Forbidden' = 403; 'Unauthorized' = 401; 'Bad Request' = 400; 'Conflict' = 409; 'Too Many Requests' = 429; 'Internal Server Error' = 500; 'Service Unavailable' = 503 }
    if ($Text -match '(?im)^\s*(?:ERROR:\s*)?(Not Found|Forbidden|Unauthorized|Bad Request|Conflict|Too Many Requests|Internal Server Error|Service Unavailable)(?=\s*(?:\(|\r?$))') {
        $status = $statuses[$Matches[1]]
    }
    $requestId = $null
    if ($Text -match '(?im)(?:x-ms-request-id|x-ms-correlation-request-id|correlation(?:id| id))\s*[:=]\s*([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})') { $requestId = $Matches[1] }
    @{ Code = $code; Status = $status; Message = $message; RequestId = $requestId }
}

function Get-HostCommandContext {
    param([string[]]$Arguments)
    $method = $null
    $target = $null
    if ($Arguments[0] -eq 'rest') {
        $methodIndex = [Array]::IndexOf($Arguments, '--method')
        $urlIndex = [Array]::IndexOf($Arguments, '--url')
        if ($methodIndex -ge 0 -and $methodIndex + 1 -lt $Arguments.Count) { $method = $Arguments[$methodIndex + 1].ToUpperInvariant() }
        $uri = $null
        if ($urlIndex -ge 0 -and $urlIndex + 1 -lt $Arguments.Count -and
            [Uri]::TryCreate($Arguments[$urlIndex + 1], [UriKind]::Absolute, [ref]$uri) -and $uri.Host -eq 'management.azure.com') {
            $target = $uri.AbsolutePath
            if ($uri.Query -match '(?:^\?|&)api-version=([0-9-]+)') { $target += " (api-version=$($Matches[1]))" }
        }
    }
    $label = if ($method) { "ARM $method" } else { "Azure CLI $($Arguments[0])" }
    if ($target) { $label += " $target" }
    @{ Method = $method; Label = $label }
}

function Invoke-HostAz {
    param([string[]]$Arguments, [switch]$AllowMissing)
    $result = Invoke-HostNativeAz ($Arguments + @('--only-show-errors', '--output', 'json'))
    $text = $result.Text
    $context = Get-HostCommandContext $Arguments
    if ($result.ExitCode -ne 0) {
        $errorInfo = Get-HostAzureError $text
        if ($AllowMissing -and $context.Method -eq 'GET' -and
            $errorInfo.Code -in @('ResourceNotFound', 'ResourceGroupNotFound', 'ParentResourceNotFound', 'NotFound') -and
            ($null -eq $errorInfo.Status -or $errorInfo.Status -eq 404)) {
            # Actions' pwsh wrapper exits with LASTEXITCODE even after a handled
            # native error. Only accepted absence is a semantic success.
            $global:LASTEXITCODE = 0
            return $null
        }
        $diagnostic = "$($context.Label) failed (exit $($result.ExitCode); Azure code=$($errorInfo.Code)"
        if ($errorInfo.Status) { $diagnostic += "; HTTP $($errorInfo.Status)" }
        if ($errorInfo.RequestId) { $diagnostic += "; requestId=$($errorInfo.RequestId)" }
        $diagnostic += ').'
        # Write errors can echo submitted scripts/protected values. Show code/context,
        # never their response message, request body or unstructured CLI stderr.
        if ($context.Method -eq 'GET' -and $errorInfo.Message -is [string]) {
            $message = $errorInfo.Message -replace '(?s)[{\[].*', '[structured payload omitted]'
            $message = $message -replace '(?i)\b(?:request\s+(?:body|payload)|protectedParameters|sourceScript)\b.*', '[request payload omitted]'
            $diagnostic += " $(ConvertTo-HostSafeText $message -Limit 512)"
        } else { $diagnostic += ' Inspect Azure activity logs for response details.' }
        throw $diagnostic
    }
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        try {
            $value = $text | ConvertFrom-Json -AsHashtable
            if ($null -eq $value -and $context.Method -eq 'GET') { throw 'Empty GET response.' }
            return $value
        }
        catch { throw "$($context.Label) returned invalid JSON; response omitted." }
    }
    if ($context.Method -eq 'GET') { throw "$($context.Label) returned an empty response; resource absence requires a definitive not-found error." }
}

function Invoke-HostArm {
    param([string]$Method, [string]$Id, [string]$ApiVersion, [hashtable]$Body, [switch]$AllowMissing, [string]$Query, [string]$ETag)
    $url = "https://management.azure.com${Id}?api-version=$ApiVersion"
    if ($Query) { $url += "&$Query" }
    $arguments = @('rest', '--method', $Method, '--url', $url)
    $bodyPath = $null
    try {
        if ($null -ne $Body) {
            $bodyPath = Join-Path (Get-Location) ".ai-agent-host-$([guid]::NewGuid().ToString('N')).json"
            $Body | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $bodyPath -Encoding utf8
            $arguments += @('--body', "@$bodyPath", '--headers', 'Content-Type=application/json')
            if ($ETag) { $arguments += "If-Match=$ETag" }
        }
        Invoke-HostAz $arguments -AllowMissing:$AllowMissing
    } finally {
        if ($bodyPath -and (Test-Path -LiteralPath $bodyPath)) { Remove-Item -LiteralPath $bodyPath -Force }
    }
}

function Wait-HostDelay { param([int]$Seconds) Start-Sleep -Seconds $Seconds }

function Wait-HostResource {
    param([string]$Id, [string]$ApiVersion, [int]$TimeoutSeconds = 900)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $resource = Invoke-HostArm GET $Id $ApiVersion
        $state = $resource.properties.provisioningState
        if ($state -eq 'Succeeded') { return $resource }
        if ($state -in @('Failed', 'Canceled')) { throw "Provisioning $Id ended in $state." }
        Wait-HostDelay 10
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out provisioning $Id."
}

function Assert-HostSubset {
    param($Actual, $Expected, [string]$Path = 'resource')
    if ($Expected -is [System.Collections.IDictionary]) {
        foreach ($key in $Expected.Keys) {
            if ($null -eq $Actual -or -not $Actual.Contains($key)) { throw "$Path.$key is missing; refusing to replace existing resource." }
            Assert-HostSubset $Actual[$key] $Expected[$key] "$Path.$key"
        }
    } elseif ($Expected -is [array]) {
        if (@($Actual).Count -ne $Expected.Count) { throw "$Path differs; refusing to replace existing resource." }
        for ($i = 0; $i -lt $Expected.Count; $i++) {
            if ($Expected[$i] -is [System.Collections.IDictionary] -and $Expected[$i].Contains('name')) {
                $match = @($Actual | Where-Object { $_['name'] -eq $Expected[$i].name })
                if ($match.Count -ne 1) { throw "$Path named entry differs; refusing to replace existing resource." }
                Assert-HostSubset $match[0] $Expected[$i] "$Path[$i]"
            } else { Assert-HostSubset $Actual[$i] $Expected[$i] "$Path[$i]" }
        }
    } elseif ($Actual -ne $Expected) { throw "$Path differs; refusing to replace existing resource." }
}

function Ensure-HostResource {
    param([string]$Id, [string]$ApiVersion, [hashtable]$Body, [hashtable]$Expected = $Body, [switch]$ValidateOnly)
    $existing = Invoke-HostArm GET $Id $ApiVersion -AllowMissing
    if ($existing) {
        Assert-HostSubset $existing $Expected $Id
        return (Wait-HostResource $Id $ApiVersion)
    }
    if ($ValidateOnly) { throw "Required private host resource is missing: $Id. Bootstrap first." }
    $null = Invoke-HostArm PUT $Id $ApiVersion $Body
    Wait-HostResource $Id $ApiVersion
}

function Get-HostCidrRange {
    param([string]$Prefix)
    $parts = $Prefix.Split('/')
    $ip = $null
    if ($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or
        $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $parts[1] -notmatch '^\d+$' -or [int]$parts[1] -gt 32) {
        throw "Invalid IPv4 prefix: $Prefix"
    }
    $bytes = $ip.GetAddressBytes()
    $number = ([long]$bytes[0] -shl 24) + ([long]$bytes[1] -shl 16) + ([long]$bytes[2] -shl 8) + $bytes[3]
    $size = [long][Math]::Pow(2, 32 - [int]$parts[1])
    if ($number % $size -ne 0) { throw "Prefix is not network-aligned: $Prefix" }
    @($number, ($number + $size - 1))
}

function Get-HostSettings {
    param([string]$Path)
    $path = (Resolve-Path -LiteralPath $Path).Path
    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    $net = $config.networking
    if ($net.networkIsolation -ne $true) { throw 'Private deployment requires networking.networkIsolation=true.' }
    foreach ($id in @($config.subscriptionId, $net.hub.subscriptionId)) {
        if ($id -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Invalid configured subscription ID.' }
    }
    foreach ($name in @($config.resourceGroupName, $config.applicationResourceGroupName, $net.resourceGroupName, $net.vnetName, $net.hub.resourceGroupName, $net.hub.vnetName)) {
        if (-not $name -or $name -notmatch '^[a-zA-Z0-9_.()-]+$') { throw 'Invalid configured resource name.' }
    }
    $rg = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($net.resourceGroupName)"
    $hub = "/subscriptions/$($net.hub.subscriptionId)/resourceGroups/$($net.hub.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($net.hub.vnetName)"
    $dnsPath = (Resolve-Path -LiteralPath (Join-Path (Split-Path $path) $config.privateDnsConfiguration)).Path
    if ($dnsPath -ne (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\platform-alz\config\private-dns.json')).Path) {
        throw 'Private DNS configuration must match the central platform helper configuration.'
    }
    $dns = Get-Content -LiteralPath $dnsPath -Raw | ConvertFrom-Json -AsHashtable
    if ($dns.subscriptionId -ne $net.hub.subscriptionId -or $dns.resourceGroupName -ne 'rg-dns') { throw 'Expected central platform rg-dns scope.' }
    if ($config.resourceGroupName -eq $config.applicationResourceGroupName -or
        $net.resourceGroupName -in @($config.resourceGroupName, $config.applicationResourceGroupName)) { throw 'Agent resource groups must be distinct.' }
    $hostConfig = if ($config.ContainsKey('deploymentHost')) { $config.deploymentHost } else { @{} }
    $vmSize = if ($hostConfig.ContainsKey('vmSize')) { $hostConfig.vmSize } else { 'Standard_D4s_v5' }
    if ($vmSize -isnot [string] -or $vmSize -notmatch '^[a-zA-Z0-9_-]{1,80}$') { throw 'deploymentHost.vmSize must be an exact approved VM SKU name.' }
    $govPath = (Resolve-Path -LiteralPath (Join-Path (Split-Path $path) $config.governanceHubConfiguration)).Path
    $gov = Get-Content -LiteralPath $govPath -Raw | ConvertFrom-Json -AsHashtable
    if ($net.addressPrefix -ne '10.180.0.0/21' -or $gov.vnetAddressPrefix -ne '10.170.0.0/24' -or
        $gov.privateEndpointSubnetPrefix -ne '10.170.0.64/26' -or $gov.subscriptionId -ne $config.subscriptionId) {
        throw 'Approved firewall/routing sources require the configured Agent/GovHub prefixes and workload subscription.'
    }
    $endpoint = $null
    if (-not [Uri]::TryCreate($config.governance.endpoint, [UriKind]::Absolute, [ref]$endpoint) -or
        $endpoint.Scheme -ne 'https' -or $endpoint.Port -ne 443 -or $endpoint.UserInfo -or
        $endpoint.Host -notmatch '^[a-zA-Z0-9-]+\.azure-api\.net$' -or $dns.zones.apimGateway -ne 'privatelink.azure-api.net') {
        throw 'GovHub requires an exact HTTPS API Management hostname and central private DNS mapping.'
    }
    @{
        Config = $config; ConfigPath = $path; ResourceGroupId = $rg
        VnetId = "$rg/providers/Microsoft.Network/virtualNetworks/$($net.vnetName)"
        HubId = $hub; DnsScope = "/subscriptions/$($dns.subscriptionId)/resourceGroups/$($dns.resourceGroupName)"
        DnsZoneNames = @($dns.zones.Values | Sort-Object -Unique)
        GovernanceGatewayFqdn = $endpoint.Host.ToLowerInvariant()
        GovernanceDnsZoneId = "/subscriptions/$($dns.subscriptionId)/resourceGroups/$($dns.resourceGroupName)/providers/Microsoft.Network/privateDnsZones/$($dns.zones.apimGateway)"
        VmName = 'vm-ai-agent-deploy-ita'; VmId = "$rg/providers/Microsoft.Compute/virtualMachines/vm-ai-agent-deploy-ita"
        VmSize = $vmSize
        NicId = "$rg/providers/Microsoft.Network/networkInterfaces/nic-ai-agent-deploy-ita"
        NsgId = "$rg/providers/Microsoft.Network/networkSecurityGroups/nsg-ai-agent-deploy-ita"
        RouteId = "$rg/providers/Microsoft.Network/routeTables/rt-ai-agent-deploy-ita"
        SubnetId = "$rg/providers/Microsoft.Network/virtualNetworks/$($net.vnetName)/subnets/snet-deployment-host"
        SubnetPrefix = '10.180.6.0/27'; EgressApproved = ($hostConfig['egressApproved'] -eq $true)
        Governance = $gov
        GovernanceVnetId = "/subscriptions/$($gov.subscriptionId)/resourceGroups/$($gov.networking.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($gov.networking.vnetName)"
        FirewallPolicyId = "/subscriptions/$($net.hub.subscriptionId)/resourceGroups/$($net.hub.resourceGroupName)/providers/Microsoft.Network/firewallPolicies/afwp-alz-swe"
    }
}

function Assert-HostVmAvailability {
    param([hashtable]$Settings)
    $c = $Settings.Config
    $skus = @(Invoke-HostAz @(
        'vm', 'list-skus', '--subscription', $c.subscriptionId, '--location', $c.location,
        '--resource-type', 'virtualMachines', '--size', $Settings.VmSize, '--all'
    ))
    $selected = @($skus | Where-Object { $_['name'] -eq $Settings.VmSize -and $_['resourceType'] -eq 'virtualMachines' })
    $context = "Private host SKU '$($Settings.VmSize)' in '$($c.location)' for subscription '$($c.subscriptionId)'"
    $action = 'Request Italy North Microsoft.Compute regional/SKU access from Azure Support. Unused family vCPU quota does not remove subscription/location restrictions. No other size, public host or region will be selected; another private-host region requires explicit user approval.'
    if ($selected.Count -ne 1) { throw "$context was not returned as one exact SKU. Availability is unknown; verify the configured SKU and regional Compute access. $action" }
    $sku = $selected[0]
    if ($c.location -notin @($sku['locations'])) { throw "$context is not available in the explicitly configured location. $action" }
    if (-not $sku.ContainsKey('restrictions') -or $null -eq $sku['restrictions']) { throw "$context has no definitive restriction data. Availability is unknown. $action" }
    foreach ($restriction in $sku.restrictions) {
        # This host is deliberately nonzonal: zone-only exclusions do not prohibit it.
        if ($restriction['type'] -eq 'Zone') { continue }
        if ($restriction['type'] -ne 'Location') { throw "$context has an unknown restriction type; refusing to assume availability. $action" }
        $locations = @($restriction['values'] | Where-Object { $_ })
        if ($restriction['restrictionInfo']) { $locations += @($restriction.restrictionInfo['locations'] | Where-Object { $_ }) }
        if ($locations.Count -eq 0 -or $c.location -in $locations) {
            $reason = if ($restriction['reasonCode']) { $restriction.reasonCode } else { 'unspecified' }
            throw "$context is blocked by a Location restriction ($reason). $action"
        }
    }
}

function Get-HostGovHubEndpoints {
    param([hashtable]$Settings)
    $gov = $Settings.Governance
    $listId = "/subscriptions/$($gov.subscriptionId)/resourceGroups/$($gov.resourceGroupName)/providers/Microsoft.Network/privateEndpoints"
    $list = Invoke-HostArm GET $listId '2024-05-01'
    $ips = [Collections.Generic.List[string]]::new()
    $allowed = Get-HostCidrRange $gov.privateEndpointSubnetPrefix
    $serviceName = $Settings.GovernanceGatewayFqdn.Split('.')[0]
    foreach ($pe in $list.value) {
        $connections = @($pe.properties['privateLinkServiceConnections']) + @($pe.properties['manualPrivateLinkServiceConnections'])
        $gateway = @($connections | Where-Object {
            $_ -and $_.properties.privateLinkServiceId -match '/providers/Microsoft.ApiManagement/service/' -and
            $_.properties.privateLinkServiceId.EndsWith("/$serviceName", [StringComparison]::OrdinalIgnoreCase) -and
            'Gateway' -in $_.properties.groupIds -and $_.properties.privateLinkServiceConnectionState.status -eq 'Approved'
        })
        if ($gateway.Count -eq 0) { continue }
        $subnetId = $pe.properties.subnet.id
        if (-not $subnetId.StartsWith("$($Settings.GovernanceVnetId)/subnets/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'GovHub gateway PE is outside the approved GovHub VNet.'
        }
        $subnet = Invoke-HostArm GET $subnetId '2024-05-01'
        if ($subnet.properties.addressPrefix -ne $gov.privateEndpointSubnetPrefix) { throw 'GovHub gateway must remain in the approved private endpoint subnet.' }
        foreach ($reference in $pe.properties.networkInterfaces) {
            $nic = Invoke-HostArm GET $reference.id '2024-05-01'
            foreach ($configuration in $nic.properties.ipConfigurations) {
                $ip = $configuration.properties.privateIPAddress
                $range = Get-HostCidrRange "$ip/32"
                if ($range[0] -lt $allowed[0] -or $range[0] -gt $allowed[1]) { throw 'GovHub gateway IP is outside the approved private endpoint subnet.' }
                $ips.Add($ip)
            }
        }
    }
    if ($ips.Count -eq 0) { throw 'No approved private GovHub gateway endpoint exists. Public fallback is forbidden.' }
    $addresses = @($ips | Sort-Object -Unique)
    if ($addresses.Count -ne 1 -or $addresses[0] -ne '10.170.0.82') { throw 'Configured GovHub gateway does not match expected private PE 10.170.0.82.' }
    # ARM DNS state proves Azure-provided hub DNS maps this standard APIM hostname
    # through its private-link alias to the exact approved PE, not a public endpoint.
    $record = Invoke-HostArm GET "$($Settings.GovernanceDnsZoneId)/A/$serviceName" '2020-06-01'
    $dnsIps = @($record.properties.aRecords | ForEach-Object { $_.ipv4Address } | Sort-Object -Unique)
    if ($dnsIps.Count -ne 1 -or $dnsIps[0] -ne $addresses[0]) { throw 'GovHub private DNS does not resolve exclusively to the expected private gateway PE.' }
    $links = Invoke-HostArm GET "$($Settings.GovernanceDnsZoneId)/virtualNetworkLinks" '2020-06-01'
    $hubLinks = @($links.value | Where-Object {
        $_.properties.virtualNetwork.id -eq $Settings.HubId -and $_.properties.virtualNetworkLinkState -eq 'Completed'
    })
    if ($hubLinks.Count -ne 1) { throw 'GovHub private DNS zone is not visible from the firewall hub VNet.' }
    @{ Ips = $addresses; Fqdn = $Settings.GovernanceGatewayFqdn }
}

function Get-HostFirewallCollections {
    param([hashtable]$Settings, [string[]]$GatewayIps)
    $packages = @(
        'github.com', 'api.github.com', 'objects.githubusercontent.com', 'raw.githubusercontent.com', 'release-assets.githubusercontent.com',
        'packages.microsoft.com', 'aka.ms', 'pypi.org', 'files.pythonhosted.org', 'archive.ubuntu.com', 'security.ubuntu.com',
        'mcr.microsoft.com', '*.data.mcr.microsoft.com'
    )
    $collections = [Collections.Generic.List[hashtable]]::new()
    $collections.Add(@{
        name = 'ai-agent-private-govhub'; priority = 100; ruleCollectionType = 'FirewallPolicyFilterRuleCollection'; action = @{ type = 'Allow' }
        rules = @(@{ name = 'private-gateway-443'; ruleType = 'ApplicationRule'
            sourceAddresses = @($Settings.Config.networking.addressPrefix); targetFqdns = @($Settings.GovernanceGatewayFqdn)
            protocols = @(@{ protocolType = 'Https'; port = 443 }) })
    })
    $collections.Add(@{
        name = 'ai-agent-scoped-https'; priority = 200; ruleCollectionType = 'FirewallPolicyFilterRuleCollection'; action = @{ type = 'Allow' }
        rules = @(
            @{ name = 'deployment-host-packages'; ruleType = 'ApplicationRule'; sourceAddresses = @($Settings.SubnetPrefix); targetFqdns = $packages; protocols = @(@{ protocolType = 'Https'; port = 443 }) },
            @{ name = 'agent-azure-control'; ruleType = 'ApplicationRule'; sourceAddresses = @($Settings.Config.networking.addressPrefix); targetFqdns = @('management.azure.com', 'login.microsoftonline.com'); protocols = @(@{ protocolType = 'Https'; port = 443 }) }
        )
    })
    # Append a distinct collection so previously bootstrapped rules stay unchanged.
    # The pinned custom-app Dockerfiles contain no APT command, so HTTP is not needed.
    $collections.Add(@{
        name = 'ai-agent-apt-mirrors-https'; priority = 250; ruleCollectionType = 'FirewallPolicyFilterRuleCollection'; action = @{ type = 'Allow' }
        rules = @(@{
            name = 'apt-mirrors-only'; ruleType = 'ApplicationRule'
            sourceAddresses = @($Settings.SubnetPrefix)
            targetFqdns = @('archive.ubuntu.com', 'azure.archive.ubuntu.com', 'security.ubuntu.com', 'deb.debian.org', 'security.debian.org')
            protocols = @(@{ protocolType = 'Https'; port = 443 })
        })
    })
    $collections.Add(@{
        name = 'ai-agent-public-tokenizer-artifact'; priority = 275; ruleCollectionType = 'FirewallPolicyFilterRuleCollection'; action = @{ type = 'Allow' }
        rules = @(@{
            name = 'fixed-public-tiktoken-data'; ruleType = 'ApplicationRule'; sourceAddresses = @($Settings.SubnetPrefix)
            targetFqdns = @('openaipublic.blob.core.windows.net'); protocols = @(@{ protocolType = 'Https'; port = 443 })
        })
    })
    $registryIndex = 0
    foreach ($rg in @($Settings.Config.resourceGroupName, $Settings.Config.applicationResourceGroupName, $Settings.Config.networking.resourceGroupName)) {
        $id = "/subscriptions/$($Settings.Config.subscriptionId)/resourceGroups/$rg/providers/Microsoft.ContainerRegistry/registries"
        $registries = Invoke-HostArm GET $id '2023-07-01' -AllowMissing
        if (-not $registries) { continue }
        foreach ($registry in $registries.value) {
            $server = $registry.properties.loginServer
            if ($server -notmatch '^[a-zA-Z0-9-]+\.azurecr\.io$' -or $registry.location -ne 'italynorth') {
                throw 'Discovered registry is outside the approved Italy North registry endpoint pattern.'
            }
            if ($registry.properties['publicNetworkAccess'] -ne 'Disabled') {
                throw 'Native registry must have publicNetworkAccess=Disabled; no public private-service fallback is allowed.'
            }
            $collections.Add(@{
                name = "ai-agent-registry-$($registry.name)"; priority = 302 + $registryIndex
                ruleCollectionType = 'FirewallPolicyFilterRuleCollection'; action = @{ type = 'Allow' }
                rules = @(@{ name = 'private-registry-https'; ruleType = 'ApplicationRule'
                    sourceAddresses = @($Settings.SubnetPrefix)
                    targetFqdns = @($server, '*.italynorth.data.azurecr.io')
                    protocols = @(@{ protocolType = 'Https'; port = 443 }) })
            })
            $registryIndex++
        }
    }
    $collections.ToArray()
}

function Ensure-HostFirewall {
    param([hashtable]$Settings, [string[]]$GatewayIps, [switch]$ValidateOnly)
    $verified = Get-HostGovHubEndpoints $Settings
    Assert-HostSubset $GatewayIps $verified.Ips 'GovHub private addresses'
    $id = "$($Settings.FirewallPolicyId)/ruleCollectionGroups/rcg-ai-agent-private-9fd780c4"
    $desired = @(Get-HostFirewallCollections $Settings $GatewayIps)
    $policy = Invoke-HostArm GET $Settings.FirewallPolicyId '2024-05-01'
    if ($policy.properties['basePolicy'] -or ($policy.properties['dnsSettings'] -and $policy.properties.dnsSettings['servers'])) {
        throw 'Inherited/custom firewall DNS requires separate private-resolution verification; no DNS/SNAT settings are changed here.'
    }
    foreach ($reference in $policy.properties.ruleCollectionGroups) {
        if ($reference.id -eq $id) { continue }
        $other = Invoke-HostArm GET $reference.id '2024-05-01'
        if ($other.properties.priority -eq 3500) { throw 'Dedicated firewall group priority 3500 conflicts with an existing group; refusing to alter it.' }
    }
    $existing = Invoke-HostArm GET $id '2024-05-01' -AllowMissing
    $merged = if ($existing) { $existing.properties.ruleCollections } else { @() }
    foreach ($collection in $merged) {
        if (@($collection.rules | Where-Object { $_['ruleType'] -eq 'NetworkRule' }).Count -gt 0) {
            throw 'Dedicated firewall group contains a network rule that can bypass application SNAT. Refusing to retain or silently migrate it.'
        }
    }
    if ($existing -and $existing.properties.priority -ne 3500) { throw 'Dedicated firewall group priority conflicts.' }
    $changed = -not $existing
    foreach ($collection in $desired) {
        $match = @($merged | Where-Object { $_.name -eq $collection.name })
        if ($match.Count -gt 1) { throw 'Duplicate collection name in dedicated firewall group.' }
        if ($match.Count -eq 1) { Assert-HostSubset $match[0] $collection $id } else {
            if ($ValidateOnly) { throw 'Required scoped firewall rules are missing. Rerun Bootstrap from the GitHub identity after Provision, before Publish.' }
            $merged = @($merged) + @($collection)
            $changed = $true
        }
    }
    if ($changed) {
        if ($ValidateOnly) { throw 'Dedicated firewall group is missing; Bootstrap first.' }
        $etag = if ($existing) { $existing['etag'] } else { $null }
        $null = Invoke-HostArm PUT $id '2024-05-01' @{
            properties = @{ priority = 3500; ruleCollections = @($merged) }
        } -ETag $etag
        $null = Wait-HostResource $id '2024-05-01'
    }
    $Settings.FirewallRuleCollectionGroupId = $id
}

function Ensure-HostScopedRoute {
    param([string]$TableId, [string]$Name, [string]$Prefix, [string]$NextHop, [switch]$ValidateOnly)
    $table = Invoke-HostArm GET $TableId '2024-05-01'
    $target = Get-HostCidrRange $Prefix
    $alreadyPresent = $false
    foreach ($route in $table.properties.routes) {
        $properties = $route.properties
        if ($properties.addressPrefix -match '^\d+\.\d+\.\d+\.\d+/\d+$') {
            $range = Get-HostCidrRange $properties.addressPrefix
            if ($range[0] -ge $target[0] -and $range[1] -le $target[1]) {
                if ($properties.nextHopType -ne 'VirtualAppliance' -or $properties['nextHopIpAddress'] -ne $NextHop) {
                    throw "Conflicting private route $($route.name) in $TableId."
                }
                if ($properties.addressPrefix -eq $Prefix) { $alreadyPresent = $true }
            }
        }
        if ($route.name -eq $Name -and $properties.addressPrefix -ne $Prefix) { throw "Conflicting dedicated route name in $TableId." }
    }
    if ($alreadyPresent) { return }
    if ($ValidateOnly) { throw "Required private route is missing in $TableId. Bootstrap again after Provision." }
    $null = Ensure-HostResource "$TableId/routes/$Name" '2024-05-01' @{
        properties = @{ addressPrefix = $Prefix; nextHopType = 'VirtualAppliance'; nextHopIpAddress = $NextHop }
    }
}

function Ensure-HostSubnetRoute {
    param([string]$SubnetId, [string]$FallbackTableId, [string]$Location, [string]$Prefix, [string]$NextHop,
        [Parameter(Mandatory)][string]$AgentVnetId, [switch]$ValidateOnly)
    if (-not $SubnetId.StartsWith("$AgentVnetId/subnets/", [StringComparison]::OrdinalIgnoreCase) -or $Prefix -ne '10.170.0.0/24') {
        throw 'Only Agent subnet forward routing to GovHub is approved; GovHub networking cannot be modified.'
    }
    $subnet = Invoke-HostArm GET $SubnetId '2024-05-01'
    $properties = $subnet.properties
    $tableId = if ($properties['routeTable']) { $properties.routeTable.id } else { $FallbackTableId }
    $providerScope = $AgentVnetId -replace '/virtualNetworks/[^/]+$', ''
    if (-not $tableId.StartsWith("$providerScope/routeTables/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Agent route table must remain workload-scoped.' }
    if (-not $properties['routeTable']) {
        $null = Ensure-HostResource $tableId '2024-05-01' @{
            location = $Location; tags = @{ deploymentHost = $script:HostOwner }
            properties = @{ disableBgpRoutePropagation = $false }
        } -ValidateOnly:$ValidateOnly
    }
    Ensure-HostScopedRoute $tableId 'ai-agent-private-path' $Prefix $NextHop -ValidateOnly:$ValidateOnly
    if (-not $properties['routeTable']) {
        if ($ValidateOnly) { throw 'Required subnet private routing is missing; Bootstrap again.' }
        $copy = $properties | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        foreach ($field in @('provisioningState', 'ipConfigurations', 'privateEndpoints', 'serviceAssociationLinks', 'resourceNavigationLinks')) { $copy.Remove($field) }
        $copy.routeTable = @{ id = $tableId }
        $null = Invoke-HostArm PUT $SubnetId '2024-05-01' @{ properties = $copy } -ETag $subnet['etag']
        $null = Wait-HostResource $SubnetId '2024-05-01'
    }
}

function Ensure-HostPrivatePaths {
    param([hashtable]$Settings, [switch]$ValidateOnly)
    if ($Settings.HubFirewallPrivateIp -ne '10.100.0.4') { throw 'Hub firewall differs from the explicitly approved next hop 10.100.0.4.' }
    $gateway = Get-HostGovHubEndpoints $Settings
    Ensure-HostFirewall $Settings $gateway.Ips -ValidateOnly:$ValidateOnly
    $vnet = Invoke-HostArm GET $Settings.VnetId '2024-05-01'
    $forwardTable = "$($Settings.ResourceGroupId)/providers/Microsoft.Network/routeTables/rt-ai-agent-govhub-forward-ita"
    foreach ($subnet in $vnet.properties['subnets']) {
        if ($subnet.id -eq $Settings.SubnetId) { continue }
        Ensure-HostSubnetRoute $subnet.id $forwardTable $Settings.Config.location $Settings.Governance.vnetAddressPrefix $Settings.HubFirewallPrivateIp -AgentVnetId $Settings.VnetId -ValidateOnly:$ValidateOnly
    }
    $Settings.GovernanceGatewayPrivateIps = $gateway.Ips
}

function Ensure-HostNetwork {
    param([hashtable]$Settings, [switch]$ValidateOnly)
    $s = $Settings
    $c = $s.Config
    $tags = @{ deploymentHost = $script:HostOwner }
    $hub = Invoke-HostArm GET $s.HubId '2024-05-01'
    if ($hub.properties.ContainsKey('dhcpOptions') -and @($hub.properties.dhcpOptions['dnsServers'] | Where-Object { $_ }).Count -gt 0) { throw 'Custom hub DNS requires a separate approved resolver design.' }
    $firewallId = "/subscriptions/$($c.networking.hub.subscriptionId)/resourceGroups/$($c.networking.hub.resourceGroupName)/providers/Microsoft.Network/azureFirewalls/afw-hub-swe"
    $firewall = Invoke-HostArm GET $firewallId '2024-05-01'
    if ($firewall.properties['dnsSettings'] -and $firewall.properties.dnsSettings['servers']) {
        throw 'Custom firewall DNS requires separate private-resolution verification; settings are not modified.'
    }
    if (-not $firewall.properties['firewallPolicy'] -or $firewall.properties.firewallPolicy.id -ne $s.FirewallPolicyId) {
        throw 'Hub firewall is not attached to the approved existing firewall policy.'
    }
    $firewallIps = @($firewall.properties.ipConfigurations | Where-Object { $_.properties['privateIPAddress'] })
    if ($firewallIps.Count -ne 1) { throw 'Expected one existing hub firewall private IP configuration.' }
    $firewallIp = $firewallIps[0].properties.privateIPAddress
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($firewallIp, [ref]$ip)) { throw 'Existing hub firewall has no usable private IP.' }
    $hubRanges = @($hub.properties.addressSpace.addressPrefixes | ForEach-Object { ,(Get-HostCidrRange $_) })
    $address = Get-HostCidrRange $c.networking.addressPrefix
    foreach ($range in $hubRanges) {
        if ($address[0] -le $range[1] -and $range[0] -le $address[1]) { throw 'Agent VNet overlaps the existing hub.' }
    }
    $reserved = Get-HostCidrRange $s.SubnetPrefix
    if ($reserved[0] -lt $address[0] -or $reserved[1] -gt $address[1]) { throw 'Reserved deployment subnet is outside the configured VNet.' }
    $vnet = Invoke-HostArm GET $s.VnetId '2024-05-01' -AllowMissing
    if ($vnet) {
        if ($c.networking.addressPrefix -notin $vnet.properties.addressSpace.addressPrefixes) { throw 'Existing VNet address space differs; no automatic replacement.' }
        if ($vnet.properties.ContainsKey('dhcpOptions') -and @($vnet.properties.dhcpOptions['dnsServers'] | Where-Object { $_ }).Count -gt 0) { throw 'Existing VNet uses custom DNS; central direct links are insufficient.' }
        foreach ($subnet in $vnet.properties['subnets']) {
            if ($subnet.id -eq $s.SubnetId) { continue }
            $prefixes = if ($subnet.properties.ContainsKey('addressPrefixes')) { $subnet.properties.addressPrefixes } else { @($subnet.properties.addressPrefix) }
            foreach ($prefix in $prefixes) {
                $range = Get-HostCidrRange $prefix
                if ($reserved[0] -le $range[1] -and $range[0] -le $reserved[1]) { throw "Reserved deployment subnet overlaps $($subnet.name)." }
            }
        }
    } else {
        $null = Ensure-HostResource $s.VnetId '2024-05-01' @{
            location = $c.location; properties = @{ addressSpace = @{ addressPrefixes = @($c.networking.addressPrefix) }; dhcpOptions = @{ dnsServers = @() } }
        } -ValidateOnly:$ValidateOnly
    }
    foreach ($pair in @(
        @{ Local = $s.VnetId; Remote = $s.HubId; Name = 'peer-ai-agent-to-hub' },
        @{ Local = $s.HubId; Remote = $s.VnetId; Name = 'peer-hub-to-ai-agent' }
    )) {
        $null = Ensure-HostResource "$($pair.Local)/virtualNetworkPeerings/$($pair.Name)" '2024-05-01' @{
            properties = @{
                remoteVirtualNetwork = @{ id = $pair.Remote }; allowVirtualNetworkAccess = $true
                allowForwardedTraffic = $true; allowGatewayTransit = $false; useRemoteGateways = $false
            }
        } -ValidateOnly:$ValidateOnly
    }
    $null = Ensure-HostResource $s.RouteId '2024-05-01' @{
        location = $c.location; tags = $tags; properties = @{
            disableBgpRoutePropagation = $true
            routes = @(
                @{ name = 'controlled-hub-egress'; properties = @{ addressPrefix = '0.0.0.0/0'; nextHopType = 'VirtualAppliance'; nextHopIpAddress = $firewallIp } },
                @{ name = 'private-govhub'; properties = @{ addressPrefix = $s.Governance.vnetAddressPrefix; nextHopType = 'VirtualAppliance'; nextHopIpAddress = $firewallIp } }
            )
        }
    } -ValidateOnly:$ValidateOnly
    # The UDR forces HTTP(S) through the shared firewall's EXISTING approved rules.
    # Azure-provided DNS bypasses ordinary NSG rules. AzurePlatformDNS is a
    # deny-only override tag, so an Allow rule for it is invalid.
    $rules = @(
        @{ name = 'deny-all-inbound'; properties = @{ priority = 100; direction = 'Inbound'; access = 'Deny'; protocol = '*'; sourcePortRange = '*'; destinationPortRange = '*'; sourceAddressPrefix = '*'; destinationAddressPrefix = '*' } },
        @{ name = 'vm-agent'; properties = @{ priority = 100; direction = 'Outbound'; access = 'Allow'; protocol = 'Tcp'; sourcePortRange = '*'; destinationPortRanges = @('80', '32526'); sourceAddressPrefix = '*'; destinationAddressPrefix = '168.63.129.16' } },
        @{ name = 'managed-identity'; properties = @{ priority = 120; direction = 'Outbound'; access = 'Allow'; protocol = 'Tcp'; sourcePortRange = '*'; destinationPortRange = '80'; sourceAddressPrefix = '*'; destinationAddressPrefix = '169.254.169.254' } },
        @{ name = 'firewall-controlled-web'; properties = @{ priority = 130; direction = 'Outbound'; access = 'Allow'; protocol = 'Tcp'; sourcePortRange = '*'; destinationPortRange = '443'; sourceAddressPrefix = '*'; destinationAddressPrefix = '*' } },
        @{ name = 'deny-other-outbound'; properties = @{ priority = 4000; direction = 'Outbound'; access = 'Deny'; protocol = '*'; sourcePortRange = '*'; destinationPortRange = '*'; sourceAddressPrefix = '*'; destinationAddressPrefix = '*' } }
    )
    $null = Ensure-HostResource $s.NsgId '2024-05-01' @{ location = $c.location; tags = $tags; properties = @{ securityRules = $rules } } -ValidateOnly:$ValidateOnly
    $null = Ensure-HostResource $s.SubnetId '2024-05-01' @{
        properties = @{ addressPrefix = $s.SubnetPrefix; defaultOutboundAccess = $false; networkSecurityGroup = @{ id = $s.NsgId }; routeTable = @{ id = $s.RouteId } }
    } -ValidateOnly:$ValidateOnly
    $subnet = Invoke-HostArm GET $s.SubnetId '2024-05-01'
    foreach ($field in @('natGateway', 'serviceEndpoints', 'delegations')) {
        if ($subnet.properties[$field]) { throw "Deployment subnet has unexpected $field; isolation cannot be guaranteed." }
    }
    $null = Ensure-HostResource $s.NicId '2024-05-01' @{
        location = $c.location; tags = $tags; properties = @{
            enableIPForwarding = $false
            ipConfigurations = @(@{ name = 'private'; properties = @{ privateIPAllocationMethod = 'Dynamic'; subnet = @{ id = $s.SubnetId } } })
        }
    } -ValidateOnly:$ValidateOnly
    Assert-HostPrivateNic $s
    $s.HubFirewallPrivateIp = $firewallIp
}

function Assert-HostPrivateNic {
    param([hashtable]$Settings)
    $nic = Invoke-HostArm GET $Settings.NicId '2024-05-01'
    foreach ($ip in $nic.properties.ipConfigurations) {
        if ($ip.properties.ContainsKey('publicIPAddress') -and $ip.properties.publicIPAddress) { throw 'Dedicated NIC has a public IP; refusing operation.' }
    }
    Assert-HostSubset $nic.properties @{
        enableIPForwarding = $false
        ipConfigurations = @(@{ name = 'private'; properties = @{ subnet = @{ id = $Settings.SubnetId } } })
    }
}

function New-HostSshKey {
    $keyRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { (Get-Location).Path }
    $keyPath = Join-Path $keyRoot "ai-agent-host-$([guid]::NewGuid().ToString('N'))"
    try {
        & ssh-keygen -q -t rsa -b 3072 -N '' -f $keyPath
        if ($LASTEXITCODE -ne 0) { throw 'Failed generating ephemeral SSH public key.' }
        Get-Content -LiteralPath "$keyPath.pub" -Raw
    } finally {
        foreach ($file in @($keyPath, "$keyPath.pub")) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
    }
}

function Ensure-HostVm {
    param([hashtable]$Settings)
    $s = $Settings
    $expected = @{
        location = $s.Config.location; tags = @{ deploymentHost = $script:HostOwner }
        identity = @{ type = 'SystemAssigned' }
        properties = @{
            hardwareProfile = @{ vmSize = $s.VmSize }
            securityProfile = @{ securityType = 'TrustedLaunch'; uefiSettings = @{ secureBootEnabled = $true; vTpmEnabled = $true } }
            networkProfile = @{ networkInterfaces = @(@{ id = $s.NicId }) }
            osProfile = @{ linuxConfiguration = @{ disablePasswordAuthentication = $true; provisionVMAgent = $true } }
        }
    }
    $vm = Invoke-HostArm GET $s.VmId '2024-07-01' -AllowMissing
    if ($vm) {
        Assert-HostSubset $vm $expected $s.VmId
        return (Wait-HostResource $s.VmId '2024-07-01')
    }
    $body = $expected | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $body.properties.storageProfile = @{
        imageReference = @{ publisher = 'Canonical'; offer = 'ubuntu-24_04-lts'; sku = 'server'; version = 'latest' }
        osDisk = @{ createOption = 'FromImage'; diskSizeGB = 128; managedDisk = @{ storageAccountType = 'Premium_LRS' }; deleteOption = 'Detach' }
    }
    $body.properties.osProfile.computerName = 'ai-agent-deploy'
    $body.properties.osProfile.adminUsername = 'deployadmin'
    $body.properties.osProfile.linuxConfiguration.ssh = @{
        publicKeys = @(@{ path = '/home/deployadmin/.ssh/authorized_keys'; keyData = (New-HostSshKey).Trim() })
    }
    $null = Invoke-HostArm PUT $s.VmId '2024-07-01' $body
    Wait-HostResource $s.VmId '2024-07-01'
}

function Get-HostRoleScopes {
    param([hashtable]$Settings)
    $c = $Settings.Config
    foreach ($rg in @($c.resourceGroupName, $c.applicationResourceGroupName, $c.networking.resourceGroupName)) {
        foreach ($role in @('b24988ac-6180-42a0-ab88-20f7382dd24c', 'f58310d9-a9f6-439a-9e8d-f62e7b41a168')) {
            @{ Scope = "/subscriptions/$($c.subscriptionId)/resourceGroups/$rg"; Role = $role }
        }
    }
    @{ Scope = $Settings.DnsScope; Role = 'b12aa53e-6015-4669-85d0-8515ebb3ae7f' }
    # Private DNS Zone Contributor at rg-dns inherits zone join/action for all current
    # and newly added platform zones; no subscription role or extra zone grants are needed.
    # Contributor on the network RG already includes Network Contributor on this VNet.
}

function Ensure-HostRoles {
    param([hashtable]$Settings, [string]$PrincipalId)
    if ($PrincipalId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'VM managed identity principalId is missing.' }
    foreach ($assignment in @(Get-HostRoleScopes $Settings)) {
        $scope = $assignment.Scope
        $subscription = $scope.Split('/')[2]
        $roleId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$($assignment.Role)"
        $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$scope|$PrincipalId|$roleId".ToLowerInvariant()))
        $name = [guid]::new([byte[]]$hash[0..15]).ToString()
        $id = "$scope/providers/Microsoft.Authorization/roleAssignments/$name"
        $expected = @{ properties = @{ principalId = $PrincipalId; roleDefinitionId = $roleId; principalType = 'ServicePrincipal' } }
        $existing = Invoke-HostArm GET $id '2022-04-01' -AllowMissing
        if ($existing) { Assert-HostSubset $existing $expected } else {
            $null = Invoke-HostArm PUT $id '2022-04-01' $expected
        }
        $deadline = [DateTime]::UtcNow.AddMinutes(10)
        do {
            $visible = Invoke-HostArm GET $id '2022-04-01' -AllowMissing
            if ($visible) { Assert-HostSubset $visible $expected; break }
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for MI role visibility at $scope." }
            Wait-HostDelay 15
        } while ($true)
    }
}

function Invoke-HostDns {
    $output = Join-Path (Get-Location) ".ai-agent-host-dns-$([guid]::NewGuid().ToString('N'))"
    try {
        & (Join-Path $PSScriptRoot '..\platform-alz\Invoke-PlatformDns.ps1') -OutputPath $output | Out-Host
    } finally {
        if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
    }
}

function Get-HostRemoteScript {
    param([hashtable]$Settings, [string]$Repository, [string]$Revision, [string]$Phase, [string]$RunId)
    if ($Repository -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*$' -or
        $Revision -notmatch '^[0-9a-fA-F]{40}$' -or $RunId -notmatch '^[0-9a-f]{32}$' -or
        $Phase -notin @('Full', 'Provision', 'Publish', 'Verify')) { throw 'Run requires a valid public owner/repo, full commit SHA and deployment phase.' }
    $scopes = @(Get-HostRoleScopes $Settings | ForEach-Object { $_.Scope } | Select-Object -Unique)
    $scopeText = ($scopes | ForEach-Object { "'$_'" }) -join ' '
    # No token is passed to GitHub. Azure tokens remain in the VM's root-only run directory.
    $template = @'
#!/bin/bash
set -Eeuo pipefail
umask 077
base=/var/lib/ai-agent-deployment
mkdir -p "$base/logs" "$base/runs"
exec 9>"$base/deployment.lock"
flock -n 9 || { echo "Another deployment is active" >&2; exit 75; }
run='__RUN__'
log="$base/logs/$run.log"
work="$base/runs/$run"
mkdir -p "$work"
finish() {
  rc=$?
  trap - EXIT
  set +e
  # ARM only receives a bounded, redacted tail; complete logs remain root-only on disk.
  tail -c 12000 "$log" | sed -E \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[REDACTED JWT]/g' \
    -e 's/((access_token|refresh_token|client_secret|password|AccountKey|SharedAccessSignature)[=:][[:space:]]*)[^ ,;]+/\1[REDACTED]/Ig' \
    -e 's/([?&](sig|token)=)[^&[:space:]]+/\1[REDACTED]/Ig' >&3
  echo "Private host log: $log" >&3
  rm -rf -- "$work"
  exit "$rc"
}
touch "$log"
exec 3>&1 4>&2
trap finish EXIT
exec >"$log" 2>&1
export DEBIAN_FRONTEND=noninteractive
export AZURE_CONFIG_DIR="$work/azure"
export AZD_CONFIG_DIR="$work/azd"
export GIT_TERMINAL_PROMPT=0
missing_tools=false
for tool in pwsh az azd git jq curl python3.12 docker dockerd; do
  command -v "$tool" >/dev/null || missing_tools=true
done
if [ "$missing_tools" = true ] || ! python3.12 -c 'import ensurepip' >/dev/null 2>&1; then
  # Ubuntu Azure images otherwise select HTTP/azure.archive mirrors not in the HTTPS allowlist.
  for source in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do
    if [ -f "$source" ]; then
      sed -i -E \
        -e 's|https?://([[:alnum:]-]+\.)?archive.ubuntu.com/ubuntu/?|https://archive.ubuntu.com/ubuntu/|g' \
        -e 's|http://security.ubuntu.com/ubuntu/?|https://security.ubuntu.com/ubuntu/|g' "$source"
    fi
  done
  apt-get update
  apt-get install -y ca-certificates curl git jq unzip python3.12 python3.12-venv nodejs npm docker.io
  curl --fail --silent --show-error --location --retry 3 https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -o "$work/microsoft.deb"
  dpkg -i "$work/microsoft.deb"
  apt-get update
  apt-get install -y powershell
  curl --fail --silent --show-error --location --retry 3 https://aka.ms/InstallAzureCLIDeb -o "$work/install-az.sh"
  bash "$work/install-az.sh"
  curl --fail --silent --show-error --location --retry 3 https://aka.ms/install-azd.sh -o "$work/install-azd.sh"
  bash "$work/install-azd.sh"
fi
python3.12 -m venv "$work/python"
export VIRTUAL_ENV="$work/python"
export PATH="$VIRTUAL_ENV/bin:$PATH"
python -c 'import sys; assert sys.version_info[:2] == (3, 12), "Deployment requires Python 3.12"'
export DOCKER_CONFIG="$work/docker-config"
export DOCKER_HOST=unix:///run/ai-agent-docker.sock
mkdir -p "$DOCKER_CONFIG" "$base/docker"
if [ -f /etc/docker/daemon.json ]; then
  jq -e '((.hosts // []) | length) == 0' /etc/docker/daemon.json >/dev/null || {
    echo "Unexpected Docker listener configuration; TCP daemon exposure is forbidden" >&2; exit 78;
  }
fi
# This VM is dedicated to deployment. Disable the distribution socket/daemon and
# run its private builder with one root-only Unix socket, never a TCP listener.
systemctl disable --now docker.service docker.socket
dockerd_path="$(command -v dockerd)"
printf '%s\n' \
  '[Unit]' 'Description=AI Agent private local builder' \
  'After=network-online.target containerd.service' 'Requires=containerd.service' \
  '[Service]' 'Type=notify' \
  "ExecStart=$dockerd_path --host=unix:///run/ai-agent-docker.sock --group=root --data-root=$base/docker --exec-root=/run/ai-agent-docker --pidfile=/run/ai-agent-docker.pid --containerd=/run/containerd/containerd.sock" \
  'ExecStartPost=/usr/bin/chmod 0600 /run/ai-agent-docker.sock' \
  'TimeoutStartSec=180' 'Delegate=yes' 'KillMode=process' \
  'LimitNOFILE=1048576' 'TasksMax=infinity' \
  > /etc/systemd/system/ai-agent-docker.service
systemctl daemon-reload
systemctl restart ai-agent-docker.service
[ "$(stat -c '%u:%g:%a' /run/ai-agent-docker.sock)" = '0:0:600' ] || {
  echo "Private Docker socket is not root-only" >&2; exit 78;
}
docker info >/dev/null
az login --identity --output none
az account set --subscription '__SUBSCRIPTION__'
# Assignment visibility is not token propagation: test actual ARM access with fresh MI tokens.
ready=false
for attempt in $(seq 1 40); do
  ready=true
  for scope in __SCOPES__; do
    if ! az rest --method get --url "https://management.azure.com${scope}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" --output json >"$work/permissions.json"; then
      ready=false; break
    fi
    if ! jq -e '[.value[].actions[]] | any(. == "*" or . == "Microsoft.Resources/*")' "$work/permissions.json" >/dev/null; then
      # DNS contributor is deliberately narrower than resource-group Contributor.
      if ! jq -e '[.value[].actions[]] | any(. == "Microsoft.Network/privateDnsZones/*")' "$work/permissions.json" >/dev/null; then ready=false; break; fi
    fi
    if [ "$scope" != '__DNSSCOPE__' ]; then
      if ! jq -e 'any(.value[]; (.actions | any(. == "*" or . == "Microsoft.Authorization/roleAssignments/write" or . == "Microsoft.Authorization/roleAssignments/*")) and (.notActions | map(ascii_downcase) | all(. != "microsoft.authorization/*/write" and . != "microsoft.authorization/roleassignments/write" and . != "*")))' "$work/permissions.json" >/dev/null; then ready=false; break; fi
    fi
  done
  if [ "$ready" = true ]; then break; fi
  sleep 15
  az account clear
  az login --identity --output none
  az account set --subscription '__SUBSCRIPTION__'
done
[ "$ready" = true ] || { echo "MI role propagation timed out" >&2; exit 77; }
checkout="$work/checkout"
git init "$checkout"
git -C "$checkout" remote add origin 'https://github.com/__REPOSITORY__.git'
git -C "$checkout" fetch --depth 1 origin '__REVISION__'
git -C "$checkout" checkout --detach FETCH_HEAD
[ "$(git -C "$checkout" rev-parse HEAD)" = '__REVISION__' ]
cd "$checkout"
pwsh -NoLogo -NoProfile -File ./ai-agent/Invoke-AiAgent.ps1 -Mode Deploy -Phase '__PHASE__' -OutputPath "$work/output"
'@
    $template.Replace('__RUN__', $RunId).Replace('__SUBSCRIPTION__', $Settings.Config.subscriptionId).
        Replace('__SCOPES__', $scopeText).Replace('__DNSSCOPE__', $Settings.DnsScope).Replace('__REPOSITORY__', $Repository).
        Replace('__REVISION__', $Revision.ToLowerInvariant()).Replace('__PHASE__', $Phase)
}

function ConvertTo-HostSafeText {
    param([AllowNull()][string]$Text, [int]$Limit = 4096)
    if (-not $Text) { return '' }
    $text = $Text -replace '(?m)^\s*::', '[workflow command suppressed] '
    $text = $text -replace '\x1b\[[0-?]*[ -/]*[@-~]', ''
    $text = $text -replace '[\x00-\x08\x0b-\x1f\x7f]', ''
    $text = $text -replace 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[REDACTED JWT]'
    $text = $text -replace '(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----', '[REDACTED PRIVATE KEY]'
    $text = $text -replace '(?i)\b(?:gh[pousr]_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+)\b', '[REDACTED GITHUB TOKEN]'
    $text = $text -replace '(?i)\bBearer\s+\S+', 'Bearer [REDACTED]'
    $text = $text -replace '(?i)((?:access[_ ]?token|refresh[_ ]?token|client[_ ]?secret|password|AccountKey|SharedAccessSignature)["'']?\s*[:=]\s*["'']?)[^"''\s,;]+', '$1[REDACTED]'
    $text = $text -replace '(?i)([?&](?:sig|token)=)[^&\s]+', '$1[REDACTED]'
    if ($text.Length -gt $Limit) { $text = $text.Substring($text.Length - $Limit) }
    $text
}

function Write-HostSafeOutput {
    param([AllowNull()][string]$Text)
    if ($Text) { Write-Host (ConvertTo-HostSafeText $Text) }
}

function Wait-HostRunCommand {
    param([string]$Id, [int]$TimeoutSeconds = 10800)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $resource = Invoke-HostArm GET $Id '2024-07-01' -Query '$expand=instanceView'
        $properties = $resource.properties
        $iv = if ($properties.ContainsKey('instanceView')) { $properties.instanceView } else { @{} }
        if ($properties['provisioningState'] -in @('Failed', 'Canceled') -or
            $iv['executionState'] -in @('Failed', 'TimedOut', 'Canceled') -or
            ($properties['provisioningState'] -eq 'Succeeded' -and $iv['executionState'] -eq 'Succeeded')) {
            Write-HostSafeOutput $iv['output']
            Write-HostSafeOutput $iv['error']
            if ($properties['provisioningState'] -ne 'Succeeded' -or $iv['executionState'] -ne 'Succeeded' -or
                -not $iv.ContainsKey('exitCode') -or $null -eq $iv['exitCode'] -or $iv['exitCode'] -ne 0) {
                throw "Managed Run Command failed: provisioningState=$($properties['provisioningState']), executionState=$($iv['executionState']), exitCode=$($iv['exitCode']). Logs remain on the dedicated VM."
            }
            return
        }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Managed Run Command exceeded its bounded three-hour wait. Logs remain on the dedicated VM.' }
        Wait-HostDelay 15
    } while ($true)
}

function Assert-HostVm {
    param([hashtable]$Settings, [switch]$AllowMissing)
    $vm = Invoke-HostArm GET $Settings.VmId '2024-07-01' -AllowMissing:$AllowMissing
    if (-not $vm) { return $null }
    Assert-HostSubset $vm @{
        tags = @{ deploymentHost = $script:HostOwner }; identity = @{ type = 'SystemAssigned' }
        properties = @{
            networkProfile = @{ networkInterfaces = @(@{ id = $Settings.NicId }) }
            securityProfile = @{ securityType = 'TrustedLaunch'; uefiSettings = @{ secureBootEnabled = $true; vTpmEnabled = $true } }
        }
    }
    $vm
}

function Stop-HostVm {
    param([hashtable]$Settings)
    if (-not (Assert-HostVm $Settings -AllowMissing)) {
        Write-Host "Dedicated VM does not exist: $($Settings.VmId). No deallocation operation needed."
        return
    }
    $null = Invoke-HostAz @('vm', 'deallocate', '--ids', $Settings.VmId, '--no-wait')
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    do {
        $view = Invoke-HostArm GET "$($Settings.VmId)/instanceView" '2024-07-01'
        if ('PowerState/deallocated' -in @($view.statuses | ForEach-Object { $_.code })) { return }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Dedicated VM deallocation timed out.' }
        Wait-HostDelay 10
    } while ($true)
}

function Invoke-AiAgentHost {
    param([string]$Action, [string]$ConfigPath, [string]$Repository, [string]$Revision, [string]$Phase)
    $s = Get-HostSettings $ConfigPath
    if ($Action -eq 'Deallocate') { Stop-HostVm $s; return }
    if (-not $s.EgressApproved) { throw 'Set deploymentHost.egressApproved=true only after approving this Bootstrap scoped firewall group and private routes.' }
    if ($Action -eq 'Bootstrap') {
        Assert-HostVmAvailability $s
        foreach ($rg in @($s.Config.resourceGroupName, $s.Config.applicationResourceGroupName, $s.Config.networking.resourceGroupName)) {
            $id = "/subscriptions/$($s.Config.subscriptionId)/resourceGroups/$rg"
            if (-not (Invoke-HostArm GET $id '2022-09-01' -AllowMissing)) {
                $null = Invoke-HostArm PUT $id '2022-09-01' @{ location = $s.Config.location }
            }
        }
        Ensure-HostNetwork $s
        Invoke-HostDns
        Ensure-HostPrivatePaths $s
        try {
            $vm = Ensure-HostVm $s
            Ensure-HostRoles $s $vm.identity.principalId
        } finally {
            if (Invoke-HostArm GET $s.VmId '2024-07-01' -AllowMissing) { Stop-HostVm $s }
        }
        @{
            hostId = $s.VmId; managedIdentityObjectId = $vm.identity.principalId
            hubFirewallPrivateIp = $s.HubFirewallPrivateIp; existingVnetResourceId = $s.VnetId
            deploymentHostSubnetPrefix = $s.SubnetPrefix
            firewallRuleCollectionGroupId = $s.FirewallRuleCollectionGroupId
            governanceGatewayPrivateIps = $s.GovernanceGatewayPrivateIps
            governanceGatewayFqdn = $s.GovernanceGatewayFqdn
            privateDnsScope = $s.DnsScope; privateDnsZoneNames = $s.DnsZoneNames
        } | ConvertTo-Json -Compress
        return
    }
    if ($Action -ne 'Run') { throw 'Unknown host action.' }
    $runId = [guid]::NewGuid().ToString('N')
    $remote = Get-HostRemoteScript $s $Repository $Revision $Phase $runId
    $null = Assert-HostVm $s
    Ensure-HostNetwork $s -ValidateOnly
    Ensure-HostPrivatePaths $s -ValidateOnly
    $id = "$($s.VmId)/runCommands/ai-agent-$runId"
    try {
        $null = Invoke-HostAz @('vm', 'start', '--ids', $s.VmId, '--no-wait')
        $deadline = [DateTime]::UtcNow.AddMinutes(15)
        do {
            $view = Invoke-HostArm GET "$($s.VmId)/instanceView" '2024-07-01'
            if ('PowerState/running' -in @($view.statuses | ForEach-Object { $_.code })) { break }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Dedicated VM start timed out.' }
            Wait-HostDelay 10
        } while ($true)
        $null = Invoke-HostArm PUT $id '2024-07-01' @{
            location = $s.Config.location
            properties = @{ source = @{ script = $remote }; asyncExecution = $true; timeoutInSeconds = 10500 }
        }
        Wait-HostRunCommand $id
    } finally {
        try {
            # Deleting this exact invocation cancels a still-running command and avoids the 25-command limit.
            if (Invoke-HostArm GET $id '2024-07-01' -AllowMissing) { $null = Invoke-HostArm DELETE $id '2024-07-01' }
        } finally { Stop-HostVm $s }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AiAgentHost $Action $ConfigPath $Repository $Revision $Phase
}
