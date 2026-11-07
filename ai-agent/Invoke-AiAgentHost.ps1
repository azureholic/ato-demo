#Requires -Version 7.4
<#
.SYNOPSIS
Creates and operates a private Container Apps Job; never a registered GitHub runner.
.DESCRIPTION
Bootstrap requires deploymentHost.egressApproved=true in deployment.json: an operator
approval of the narrowly source/FQDN-scoped rules installed by Bootstrap in its own
firewall rule collection group, and Agent forward routing. GovHub uses application-rule
SNAT for flow symmetry; its route tables and private endpoint policies are never changed.
No existing
firewall group is replaced. Invoke-PlatformDns.ps1 alone creates DNS zones and links.
The /27 uses a workload-profile environment with only Consumption, not the legacy
Consumption-only environment (which needs /23 and cannot enforce these UDRs).
Run requires a full public-repository commit SHA and an ephemeral process GH_TOKEN,
except explicit Handoff: Azure-only administrator execution with no GitHub credentials/check.
SecretParameters keys become secret-ref environment variables, never plaintext start values.
Cleanup requires GitHubRunId and removes only that run's secrets after executions stop.
Repeat Bootstrap with the GitHub identity after Provision to append discovered private
registry rules and native subnet routes before Publish. Run only validates shared rules.
ACR task platform dependencies (Storage/EventHub/KeyVault/Monitor) are NOT implicitly
allowed: approve exact required endpoints separately; no blanket blob/service-tag rule.
Workflow concurrency must serialize Bootstrap/Run/Cleanup for this dedicated executor.
#>
[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'Run', 'Cleanup')]
    [string]$Action = 'Bootstrap',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\deployment.json'),
    [string]$Repository = 'azureholic/ato-demo',
    [string]$Revision,
    [ValidateSet('Provision', 'Publish', 'Verify', 'Handoff')]
    [string]$Phase = 'Provision',
    [string]$GitHubRunId,
    [hashtable]$SecretParameters = @{},
    [string[]]$ArtifactHosts = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:HostOwner = 'ai-agent-private-deployment-host'
$script:HostAppApi = '2025-07-01'
$script:HostSensitiveValues = @()
$script:HostWorkerImage = 'mcr.microsoft.com/devcontainers/python:1-3.12-bookworm@sha256:7876580dc67fd460fd962f004cbeb480027e9bbc0657096f1087db11f9eaff39'

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
    $details = @()
    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -ge 0 -and $end -ge $start) {
        try {
            $json = $Text.Substring($start, $end - $start + 1) | ConvertFrom-Json -AsHashtable
            $errorObject = if ($json['error'] -is [System.Collections.IDictionary]) { $json['error'] } else { $json }
            $code = $errorObject['code']
            $message = $errorObject['message']
            $details = @($errorObject['details'] | Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -First 6)
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
    @{ Code = $code; Status = $status; Message = $message; RequestId = $requestId; Details = $details }
}

function ConvertTo-HostAzureMessage {
    param([AllowNull()][string]$Message)
    $message = $Message -replace '(?s)[{\[].*', '[structured payload omitted]'
    $message = $message -replace '(?i)\b(?:request\s+(?:body|payload)|protectedParameters|sourceScript)\b.*', '[request payload omitted]'
    ConvertTo-HostSafeText $message -Limit 512
}

function Test-HostPublicEnvironmentBody {
    param([string]$Id, [hashtable]$Body)
    if ($Id -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/rg-ai-agent-app-ita/providers/Microsoft.App/managedEnvironments/cae-ai-agent-deploy-ita$' -or
        $null -eq $Body -or $Body.Count -ne 3 -or $Body['location'] -ne 'italynorth') { return $false }
    $tags = $Body['tags']; $p = $Body['properties']
    if ($tags -isnot [System.Collections.IDictionary] -or $tags.Count -ne 1 -or $tags['deploymentHost'] -ne $script:HostOwner -or
        $p -isnot [System.Collections.IDictionary] -or $p.Count -ne 4 -or
        $p['publicNetworkAccess'] -ne 'Disabled' -or $p['zoneRedundant'] -isnot [bool] -or $p['zoneRedundant']) { return $false }
    $vnet = $p['vnetConfiguration']; $profiles = $p['workloadProfiles']
    $subnetId = "/subscriptions/$($Id.Split('/')[2])/resourceGroups/rg-ai-agent-network-ita/providers/Microsoft.Network/virtualNetworks/vnet-ai-agent-ita/subnets/snet-deployment-host"
    if ($vnet -isnot [System.Collections.IDictionary] -or $vnet.Count -ne 2 -or $vnet['internal'] -isnot [bool] -or
        -not $vnet['internal'] -or $vnet['infrastructureSubnetId'] -ne $subnetId -or
        $profiles -isnot [array] -or $profiles.Count -ne 1) { return $false }
    $profile = $profiles[0]
    $profile -is [System.Collections.IDictionary] -and $profile.Count -eq 2 -and
        $profile['name'] -eq 'Consumption' -and $profile['workloadProfileType'] -eq 'Consumption'
}

function Get-HostCommandContext {
    param([string[]]$Arguments)
    $method = $null
    $target = $null
    $resourcePath = $null
    if ($Arguments[0] -eq 'rest') {
        $methodIndex = [Array]::IndexOf($Arguments, '--method')
        $urlIndex = [Array]::IndexOf($Arguments, '--url')
        if ($methodIndex -ge 0 -and $methodIndex + 1 -lt $Arguments.Count) { $method = $Arguments[$methodIndex + 1].ToUpperInvariant() }
        $uri = $null
        if ($urlIndex -ge 0 -and $urlIndex + 1 -lt $Arguments.Count -and
            [Uri]::TryCreate($Arguments[$urlIndex + 1], [UriKind]::Absolute, [ref]$uri) -and $uri.Host -eq 'management.azure.com') {
            $target = $uri.AbsolutePath
            $resourcePath = $uri.AbsolutePath
            if ($uri.Query -match '(?:^\?|&)api-version=([0-9-]+)') { $target += " (api-version=$($Matches[1]))" }
        }
    }
    $label = if ($method) { "ARM $method" } else { "Azure CLI $($Arguments[0])" }
    if ($target) { $label += " $target" }
    @{ Method = $method; Label = $label; ResourcePath = $resourcePath }
}

function Invoke-HostAz {
    param([string[]]$Arguments, [switch]$AllowMissing, [switch]$PublicEnvironmentErrors)
    $result = Invoke-HostNativeAz ($Arguments + @('--only-show-errors', '--output', 'json'))
    $text = $result.Text
    $context = Get-HostCommandContext $Arguments
    if ($result.ExitCode -ne 0) {
        $errorInfo = Get-HostAzureError $text
        $guidPattern = '[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}'
        $missingRoleLookup = $errorInfo.Code -ceq 'RoleAssignmentNotFound' -and $errorInfo.Status -eq 404 -and
            $context.ResourcePath -match "^/subscriptions/$guidPattern/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft.Authorization/roleAssignments/$guidPattern$"
        if ($AllowMissing -and $context.Method -eq 'GET' -and
            (($errorInfo.Code -in @('ResourceNotFound', 'ResourceGroupNotFound', 'ParentResourceNotFound', 'NotFound') -and
                ($null -eq $errorInfo.Status -or $errorInfo.Status -eq 404)) -or $missingRoleLookup)) {
            # Actions' pwsh wrapper exits with LASTEXITCODE even after a handled
            # native error. Only accepted absence is a semantic success.
            $global:LASTEXITCODE = 0
            return $null
        }
        $diagnostic = "$($context.Label) failed (exit $($result.ExitCode); Azure code=$($errorInfo.Code)"
        if ($errorInfo.Status) { $diagnostic += "; HTTP $($errorInfo.Status)" }
        if ($errorInfo.RequestId) { $diagnostic += "; requestId=$($errorInfo.RequestId)" }
        $diagnostic += ').'
        # Only GETs and the narrowly whitelisted, credential-free environment-create
        # body may expose sanitized structured messages. Secret writes remain opaque.
        if (($context.Method -eq 'GET' -and $errorInfo.Message -is [string]) -or $PublicEnvironmentErrors) {
            if ($errorInfo.Message -is [string]) { $diagnostic += " $(ConvertTo-HostAzureMessage $errorInfo.Message)" }
            if ($PublicEnvironmentErrors) {
                foreach ($detail in $errorInfo.Details) {
                    if ($detail['code'] -is [string] -and $detail.code -match '^[a-zA-Z][a-zA-Z0-9_.-]{0,127}$') { $diagnostic += " Detail code=$($detail.code)." }
                    if ($detail['target'] -is [string] -and $detail.target -match '^[a-zA-Z][a-zA-Z0-9_.\[\]-]{0,127}$') { $diagnostic += " Field=$($detail.target)." }
                    if ($detail['message'] -is [string]) { $diagnostic += " $(ConvertTo-HostAzureMessage $detail.message)" }
                }
            }
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
    if ($ETag) {
        # az rest's header parser can corrupt weak ETag quotes. Conditional
        # writes use the HTTP header directly, without CLI/shell interpolation.
        return (Invoke-HostMemoryArm $Method $Id $Body -Url $url -IfMatch $ETag).Value
    }
    $arguments = @('rest', '--method', $Method, '--url', $url)
    $bodyPath = $null
    try {
        if ($null -ne $Body) {
            $bodyPath = Join-Path (Get-Location) ".ai-agent-host-$([guid]::NewGuid().ToString('N')).json"
            $Body | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $bodyPath -Encoding utf8
            $arguments += @('--body', "@$bodyPath", '--headers', 'Content-Type=application/json')
        }
        $publicErrors = $Method -eq 'PUT' -and (Test-HostPublicEnvironmentBody $Id $Body)
        Invoke-HostAz $arguments -AllowMissing:$AllowMissing -PublicEnvironmentErrors:$publicErrors
    } finally {
        if ($bodyPath -and (Test-Path -LiteralPath $bodyPath)) { Remove-Item -LiteralPath $bodyPath -Force }
    }
}

function New-HostHttpRequest {
    param([string]$Method, [string]$Url, [string]$Token, [AllowNull()][string]$Json, [string]$IfMatch)
    if ($IfMatch -and $IfMatch -cnotmatch '^(?:W/)?"[^"\r\n]+"$' -and
        $IfMatch -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'If-Match must be an exact quoted strong/weak ETag or provider GUID, never a wildcard.'
    }
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Url)
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $request.Headers.UserAgent.ParseAdd('ato-private-job-controller/1.0')
    $request.Headers.Accept.ParseAdd('application/json')
    # Firewall ruleCollectionGroups return bare GUID ETags; Network subnets use
    # quoted weak ETags. Preserve either provider value without normalization.
    if ($IfMatch -and -not $request.Headers.TryAddWithoutValidation('If-Match', $IfMatch)) { throw 'Could not attach the exact If-Match header.' }
    if ($Url.StartsWith('https://api.github.com/')) { $request.Headers.Add('X-GitHub-Api-Version', '2022-11-28') }
    if (-not [string]::IsNullOrEmpty($Json)) { $request.Content = [Net.Http.StringContent]::new($Json, [Text.Encoding]::UTF8, 'application/json') }
    $request
}

function New-HostHttpClient {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    $client
}

function Get-HostTransportFailure {
    param([string]$Method, [string]$Url, [Exception]$Exception, [string]$Stage, [long]$ElapsedMilliseconds)
    $uri = $null
    $endpoint = '[invalid endpoint]'
    if ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        $endpoint = ConvertTo-HostSafeText "$($uri.Host)$($uri.AbsolutePath)" -Limit 1024
    }
    $types = [Collections.Generic.List[string]]::new()
    $current = $Exception
    for ($depth = 0; $current -and $depth -lt 6; $depth++) {
        $types.Add("$($current.GetType().FullName) HResult=0x$($current.HResult.ToString('X8'))")
        $current = $current.InnerException
    }
    # Exception messages, stacks, Data, URLs' query strings and response bodies
    # can contain credentials. Only structural metadata crosses this boundary.
    "HTTPS $Method $endpoint failed at $Stage after ${ElapsedMilliseconds}ms; exception chain: $($types -join ' -> '). Messages, query, response and credentials omitted."
}

function Invoke-HostHttp {
    param([string]$Method, [string]$Url, [string]$Token, [AllowNull()][string]$Json, [string]$IfMatch)
    $client = $null
    $request = $null
    $response = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $stage = 'create-client'
    try {
        $client = New-HostHttpClient
        $stage = 'create-request'
        $request = New-HostHttpRequest $Method $Url $Token $Json $IfMatch
        $stage = 'send-request'
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $stage = 'read-response'
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $stage = 'read-location'
        $location = if ($response.Headers.Location) { $response.Headers.Location.ToString() } else { $null }
        @{
            StatusCode = [int]$response.StatusCode
            Text = $text; Location = $location
        }
    } catch { throw (Get-HostTransportFailure $Method $Url $_.Exception $stage $clock.ElapsedMilliseconds) }
    finally {
        $clock.Stop()
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Invoke-HostMemoryRequest {
    param([string]$Method, [string]$Url, [string]$Token, [hashtable]$Body, [string]$IfMatch)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or
        $uri.Host -notin @('management.azure.com', 'api.github.com') -or $uri.Port -ne 443 -or $uri.UserInfo) {
        throw 'Credential-bearing request requires an approved HTTPS ARM/GitHub endpoint.'
    }
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 40 -Compress } else { $null }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $response = Invoke-HostHttp $Method $Url $Token $json -IfMatch $IfMatch
        if ($response.StatusCode -in @(429, 500, 502, 503, 504) -and $Method -in @('GET', 'PATCH') -and $attempt -lt 4) {
            Wait-HostDelay (5 * ($attempt + 1))
            continue
        }
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            $errorInfo = Get-HostAzureError $response.Text
            throw "HTTPS $Method $($uri.AbsolutePath) failed: HTTP $($response.StatusCode), code=$($errorInfo.Code). Response omitted."
        }
        $value = $null
        if (-not [string]::IsNullOrWhiteSpace($response.Text)) {
            try { $value = $response.Text | ConvertFrom-Json -AsHashtable }
            catch { throw "HTTPS $Method returned invalid JSON; response omitted." }
        }
        if ($Method -eq 'GET' -and $null -eq $value) { throw 'HTTPS GET returned no definitive resource/status data.' }
        return @{ Value = $value; StatusCode = $response.StatusCode; Location = $response.Location }
    }
}

function Invoke-HostMemoryArm {
    param([string]$Method, [string]$Id, [hashtable]$Body, [string]$Url, [string]$IfMatch)
    $token = Invoke-HostAz @('account', 'get-access-token', '--resource', 'https://management.azure.com/')
    if (-not $token['accessToken']) { throw 'Azure controller access token is unavailable.' }
    if (-not $Url) { $Url = "https://management.azure.com${Id}?api-version=$script:HostAppApi" }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Host -ne 'management.azure.com') {
        throw 'ARM credentials must never be sent to a non-ARM operation URL.'
    }
    try { Invoke-HostMemoryRequest $Method $Url $token.accessToken $Body -IfMatch $IfMatch }
    finally { $token = $null }
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
    if ($config.location -ne 'italynorth') { throw 'Deployment Job must remain in explicitly approved Italy North; no region fallback.' }
    $appRg = "/subscriptions/$($config.subscriptionId)/resourceGroups/$($config.applicationResourceGroupName)"
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
        EnvironmentId = "$appRg/providers/Microsoft.App/managedEnvironments/cae-ai-agent-deploy-ita"
        JobId = "$appRg/providers/Microsoft.App/jobs/job-ai-agent-deploy-ita"
        IdentityId = "$appRg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-ai-agent-deploy-ita"
        LegacyVmId = "$rg/providers/Microsoft.Compute/virtualMachines/vm-ai-agent-deploy-ita"
        LegacyNicId = "$rg/providers/Microsoft.Network/networkInterfaces/nic-ai-agent-deploy-ita"
        LegacyNsgId = "$rg/providers/Microsoft.Network/networkSecurityGroups/nsg-ai-agent-deploy-ita"
        RouteId = "$rg/providers/Microsoft.Network/routeTables/rt-ai-agent-deploy-ita"
        SubnetId = "$rg/providers/Microsoft.Network/virtualNetworks/$($net.vnetName)/subnets/snet-deployment-host"
        SubnetPrefix = '10.180.6.0/27'; EgressApproved = ($hostConfig['egressApproved'] -eq $true)
        ArtifactHosts = @()
        Governance = $gov
        GovernanceVnetId = "/subscriptions/$($gov.subscriptionId)/resourceGroups/$($gov.networking.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($gov.networking.vnetName)"
        FirewallPolicyId = "/subscriptions/$($net.hub.subscriptionId)/resourceGroups/$($net.hub.resourceGroupName)/providers/Microsoft.Network/firewallPolicies/afwp-alz-swe"
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

function New-HostArtifactRule {
    param([hashtable]$Settings, [string]$HostName)
    if ($HostName -notmatch '^(?:productionresultssa[0-9]+|pipelinesghub[a-z0-9]+)\.blob\.core\.windows\.net$') {
        throw 'ArtifactHosts requires exact approved GitHub artifact storage hostnames, never URLs/SAS/wildcards.'
    }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($HostName))).Substring(0, 12).ToLowerInvariant()
    @{
        name = "github-artifact-$hash"; ruleType = 'ApplicationRule'; sourceAddresses = @($Settings.SubnetPrefix)
        targetFqdns = @($HostName); protocols = @(@{ protocolType = 'Https'; port = 443 })
    }
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
    # Preserve existing HTTPS mirrors; the Debian Job HTTP exception is separate.
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
    # Required ACA workload-profile infrastructure/identity FQDNs, per
    # https://learn.microsoft.com/azure/container-apps/use-azure-firewall .
    $collections.Add(@{
        name = 'ai-agent-job-platform-https'; priority = 280; ruleCollectionType = 'FirewallPolicyFilterRuleCollection'; action = @{ type = 'Allow' }
        rules = @(@{
            name = 'private-job-platform'; ruleType = 'ApplicationRule'; sourceAddresses = @($Settings.SubnetPrefix)
            targetFqdns = @('packages.aks.azure.com', 'acs-mirror.azureedge.net', '*.identity.azure.net', '*.login.microsoftonline.com', '*.login.microsoft.com')
            protocols = @(@{ protocolType = 'Https'; port = 443 })
        })
    })
    $collections.Add(@{
        name = 'ai-agent-job-cli-packages'; priority = 282; ruleCollectionType = 'FirewallPolicyFilterRuleCollection'; action = @{ type = 'Allow' }
        rules = @(@{
            name = 'exact-azure-cli-package-stores'; ruleType = 'ApplicationRule'; sourceAddresses = @($Settings.SubnetPrefix)
            targetFqdns = @('azcliextensionsync.blob.core.windows.net', 'azcliprod.blob.core.windows.net')
            protocols = @(@{ protocolType = 'Https'; port = 443 })
        })
    })
    $collections.Add(@{
        name = 'ai-agent-job-debian-apt-http'; priority = 285; ruleCollectionType = 'FirewallPolicyFilterRuleCollection'; action = @{ type = 'Allow' }
        rules = @(@{
            name = 'signed-debian-packages-only'; ruleType = 'ApplicationRule'; sourceAddresses = @($Settings.SubnetPrefix)
            targetFqdns = @('deb.debian.org', 'security.debian.org'); protocols = @(@{ protocolType = 'Http'; port = 80 })
        })
    })
    if ($Settings.ArtifactHosts.Count -gt 0) {
        $collections.Add(@{
            name = 'ai-agent-job-artifacts'; priority = 290; ruleCollectionType = 'FirewallPolicyFilterRuleCollection'; action = @{ type = 'Allow' }
            rules = @($Settings.ArtifactHosts | ForEach-Object { New-HostArtifactRule $Settings $_ })
        })
    }
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
        if ($match.Count -eq 1 -and $collection.name -eq 'ai-agent-job-artifacts') {
            foreach ($rule in $match[0].rules) {
                if (@($rule.targetFqdns).Count -ne 1) { throw 'Unexpected existing artifact rule destinations.' }
                Assert-HostSubset $rule (New-HostArtifactRule $Settings $rule.targetFqdns[0])
            }
            Assert-HostSubset $match[0] @{ priority = 290; ruleCollectionType = 'FirewallPolicyFilterRuleCollection'; action = @{ type = 'Allow' } }
            foreach ($rule in $collection.rules) {
                if ($rule.name -notin @($match[0].rules | ForEach-Object { $_.name })) {
                    if ($ValidateOnly) { throw 'Exact same-run artifact host is not yet approved. Bootstrap with ArtifactHosts first.' }
                    $match[0].rules = @($match[0].rules) + @($rule); $changed = $true
                }
            }
        } elseif ($match.Count -eq 1) { Assert-HostSubset $match[0] $collection $id } else {
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
    Ensure-HostDeploymentSubnet $s -ValidateOnly:$ValidateOnly
    $s.HubFirewallPrivateIp = $firewallIp
}

function Ensure-HostDeploymentSubnet {
    param([hashtable]$Settings, [switch]$ValidateOnly)
    $s = $Settings
    $desired = @{
        addressPrefix = $s.SubnetPrefix; defaultOutboundAccess = $false; routeTable = @{ id = $s.RouteId }
        delegations = @(@{ name = 'aca-deployment'; properties = @{ serviceName = 'Microsoft.App/environments' } })
    }
    $subnet = Invoke-HostArm GET $s.SubnetId '2024-05-01' -AllowMissing
    if (-not $subnet) {
        $null = Ensure-HostResource $s.SubnetId '2024-05-01' @{ properties = $desired } -ValidateOnly:$ValidateOnly
        return
    }
    $p = $subnet.properties
    foreach ($field in @('natGateway', 'serviceEndpoints', 'privateEndpoints')) {
        if ($p[$field]) { throw "Deployment subnet has unexpected $field; refusing migration." }
    }
    Assert-HostSubset $p @{ addressPrefix = $s.SubnetPrefix; defaultOutboundAccess = $false; routeTable = @{ id = $s.RouteId } }
    if ($p['delegations']) {
        Assert-HostSubset $p @{ delegations = $desired.delegations }
        if ($p['networkSecurityGroup'] -and $p.networkSecurityGroup.id -eq $s.LegacyNsgId) { throw 'Legacy VM NSG remains attached to ACA subnet.' }
        return
    }
    if ($ValidateOnly) { throw 'Deployment subnet is not delegated to Microsoft.App/environments. Bootstrap first.' }
    if (-not $subnet['etag'] -or $subnet.etag -eq '*') { throw 'Existing deployment subnet lacks a usable ETag; refusing unconditional migration.' }
    if (Invoke-HostArm GET $s.LegacyVmId '2024-07-01' -AllowMissing) { throw 'Legacy deployment VM exists; refusing subnet migration or VM deletion.' }
    $nic = Invoke-HostArm GET $s.LegacyNicId '2024-05-01' -AllowMissing
    if ($nic) {
        Assert-HostSubset $nic @{ tags = @{ deploymentHost = $script:HostOwner } }
        if ($nic.properties['virtualMachine'] -or $nic.properties['privateEndpoint']) { throw 'Legacy NIC is referenced by a VM/private endpoint; refusing deletion.' }
        Assert-HostSubset $nic.properties @{
            enableIPForwarding = $false
            ipConfigurations = @(@{ name = 'private'; properties = @{ subnet = @{ id = $s.SubnetId } } })
        }
        if ($nic.properties.ipConfigurations[0].properties['publicIPAddress']) { throw 'Legacy NIC has a public IP; refusing migration.' }
    }
    foreach ($reference in @($p['ipConfigurations'] | Where-Object { $_ })) {
        if (-not $reference.id.StartsWith("$($s.LegacyNicId)/ipConfigurations/", [StringComparison]::OrdinalIgnoreCase) -or -not $nic) {
            throw 'Deployment subnet contains an unknown NIC reference; refusing migration.'
        }
    }
    $copy = $p | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    if ($p['networkSecurityGroup']) {
        if ($p.networkSecurityGroup.id -ne $s.LegacyNsgId) { throw 'Unknown subnet NSG association; refusing to detach it.' }
        $nsg = Invoke-HostArm GET $s.LegacyNsgId '2024-05-01'
        Assert-HostSubset $nsg @{ tags = @{ deploymentHost = $script:HostOwner } }
        $copy.Remove('networkSecurityGroup')
    }
    if ($nic) {
        $null = Invoke-HostArm DELETE $s.LegacyNicId '2024-05-01'
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        while (Invoke-HostArm GET $s.LegacyNicId '2024-05-01' -AllowMissing) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Legacy unused NIC deletion did not complete.' }
            Wait-HostDelay 10
        }
        # Removing a NIC also changes its subnet/VNet ETag. Use the completed
        # post-delete snapshot, not the pre-delete body or optimistic-lock token.
        $subnet = Wait-HostResource $s.SubnetId '2024-05-01' -TimeoutSeconds 300
        $p = $subnet.properties
        Assert-HostSubset $p @{ addressPrefix = $s.SubnetPrefix; defaultOutboundAccess = $false; routeTable = @{ id = $s.RouteId } }
        foreach ($field in @('natGateway', 'serviceEndpoints', 'privateEndpoints', 'delegations', 'ipConfigurations')) {
            if ($p[$field]) { throw "Deployment subnet changed after legacy NIC deletion ($field); refusing migration." }
        }
        if (-not $subnet['etag'] -or $subnet.etag -eq '*') { throw 'Refreshed deployment subnet lacks a usable ETag; refusing unconditional migration.' }
        $copy = $p | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        if ($p['networkSecurityGroup']) {
            if ($p.networkSecurityGroup.id -ne $s.LegacyNsgId) { throw 'Subnet NSG association changed after NIC deletion; refusing to detach it.' }
            $nsg = Invoke-HostArm GET $s.LegacyNsgId '2024-05-01'
            Assert-HostSubset $nsg @{ tags = @{ deploymentHost = $script:HostOwner } }
            $copy.Remove('networkSecurityGroup')
        }
    }
    foreach ($field in @('provisioningState', 'ipConfigurations', 'serviceAssociationLinks', 'resourceNavigationLinks')) { $copy.Remove($field) }
    $copy.delegations = $desired.delegations
    $null = Invoke-HostArm PUT $s.SubnetId '2024-05-01' @{ properties = $copy } -ETag $subnet['etag']
    $null = Wait-HostResource $s.SubnetId '2024-05-01'
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
    if ($PrincipalId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Deployment UAI principalId is missing.' }
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

function Get-HostJobContainer {
    param([string]$Repository, [string]$Revision, [hashtable[]]$Environment)
    # Download the pinned public bootstrap without Authorization or a token-bearing URL.
    $url = "https://raw.githubusercontent.com/$Repository/$Revision/ai-agent/Run-AiAgentJob.sh"
    @{
        name = 'deployment'; image = $script:HostWorkerImage; command = @('/bin/bash')
        args = @('-c', "set -Eeuo pipefail; umask 077; script=`"`$(curl --proto '=https' --tlsv1.2 --fail --silent --show-error --retry 3 '$url')`"; exec /bin/bash -c `"`$script`"")
        resources = @{ cpu = 2.0; memory = '4Gi' }; env = @($Environment)
    }
}

function ConvertTo-HostSafeText {
    param([AllowNull()][string]$Text, [int]$Limit = 4096)
    if (-not $Text) { return '' }
    foreach ($secret in $script:HostSensitiveValues) {
        if ($secret) { $Text = $Text.Replace($secret, '[REDACTED]') }
    }
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

function Get-HostJobBody {
    param([hashtable]$Settings, [string]$ClientId)
    @{
        location = $Settings.Config.location; tags = @{ deploymentHost = $script:HostOwner }
        identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $Settings.IdentityId = @{} } }
        properties = @{
            environmentId = $Settings.EnvironmentId; workloadProfileName = 'Consumption'
            configuration = @{
                triggerType = 'Manual'; replicaTimeout = 10500; replicaRetryLimit = 0
                manualTriggerConfig = @{ replicaCompletionCount = 1; parallelism = 1 }
            }
            template = @{ containers = @(@{
                name = 'deployment'; image = $script:HostWorkerImage; command = @('/bin/bash')
                args = @('-c', 'echo "Use Run with a pinned repository revision" >&2; exit 78')
                resources = @{ cpu = 2.0; memory = '4Gi' }; env = @(@{ name = 'AZURE_CLIENT_ID'; value = $ClientId })
            }) }
        }
    }
}

function Get-HostEnvironmentBody {
    param([hashtable]$Settings)
    @{
        location = $Settings.Config.location; tags = @{ deploymentHost = $script:HostOwner }
        properties = @{
            publicNetworkAccess = 'Disabled'; zoneRedundant = $false
            vnetConfiguration = @{ internal = $true; infrastructureSubnetId = $Settings.SubnetId }
            workloadProfiles = @(@{ name = 'Consumption'; workloadProfileType = 'Consumption' })
            # The service's no-logs value is omitted/null, not destination="none".
        }
    }
}

function Ensure-HostJobInfrastructure {
    param([hashtable]$Settings, [switch]$ValidateOnly)
    $s = $Settings
    $identity = Invoke-HostArm GET $s.IdentityId '2023-01-31' -AllowMissing
    $identityExpected = @{ location = $s.Config.location; tags = @{ deploymentHost = $script:HostOwner } }
    if (-not $identity) {
        if ($ValidateOnly) { throw 'Deployment UAI missing; Bootstrap first.' }
        $null = Invoke-HostArm PUT $s.IdentityId '2023-01-31' $identityExpected
    } else { Assert-HostSubset $identity $identityExpected }
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        $identity = Invoke-HostArm GET $s.IdentityId '2023-01-31'
        if ($identity.properties['principalId'] -match '^[0-9a-fA-F-]{36}$' -and $identity.properties['clientId'] -match '^[0-9a-fA-F-]{36}$') { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Deployment UAI identifiers did not become available.' }
        Wait-HostDelay 10
    } while ($true)
    $s.ManagedIdentityObjectId = $identity.properties.principalId
    $s.ManagedIdentityClientId = $identity.properties.clientId
    $null = Ensure-HostResource $s.EnvironmentId $script:HostAppApi (Get-HostEnvironmentBody $s) -ValidateOnly:$ValidateOnly
    $body = Get-HostJobBody $s $s.ManagedIdentityClientId
    $null = Ensure-HostResource $s.JobId $script:HostAppApi $body -ValidateOnly:$ValidateOnly
    $job = Invoke-HostArm GET $s.JobId $script:HostAppApi
    if ($job.identity.userAssignedIdentities.Count -ne 1 -or $job.properties.configuration['registries']) {
        throw 'Deployment Job has unexpected identity/registry credentials; refusing operation.'
    }
    if (-not $ValidateOnly) { Ensure-HostRoles $s $s.ManagedIdentityObjectId }
}

function Get-HostJobExecutions {
    param([hashtable]$Settings)
    $response = Invoke-HostArm GET "$($Settings.JobId)/executions" $script:HostAppApi
    for ($page = 0; $page -lt 100; $page++) {
        if (-not $response.ContainsKey('value') -or $response['value'] -isnot [array]) { throw 'Execution listing omitted definitive status data.' }
        foreach ($execution in $response.value) {
            if (-not $execution['id'] -or -not $execution.id.StartsWith("$($Settings.JobId)/executions/", [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Execution listing returned an unexpected resource scope.'
            }
            $execution
        }
        if (-not $response['nextLink']) { return }
        $uri = $null
        if (-not [Uri]::TryCreate($response.nextLink, [UriKind]::Absolute, [ref]$uri) -or $uri.Host -ne 'management.azure.com' -or
            $uri.AbsolutePath -ne "$($Settings.JobId)/executions") { throw 'Unexpected execution pagination URL.' }
        $response = (Invoke-HostMemoryArm GET -Url $response.nextLink).Value
    }
    throw 'Execution listing exceeded bounded pagination; refusing secret cleanup.'
}

function Assert-HostNoActiveExecution {
    param([hashtable]$Settings)
    foreach ($execution in @(Get-HostJobExecutions $Settings)) {
        if ($execution.properties['status'] -notin @('Succeeded', 'Failed', 'Stopped')) {
            throw 'Deployment Job has an active or unknown execution. Serialize runs; secrets cannot be changed/removed yet.'
        }
    }
}

function Set-HostJobSecrets {
    param([hashtable]$Settings, [hashtable[]]$Secrets, [string]$RemovePrefix)
    Assert-HostNoActiveExecution $Settings
    $job = Invoke-HostArm GET $Settings.JobId $script:HostAppApi
    Assert-HostSubset $job @{ tags = @{ deploymentHost = $script:HostOwner }; properties = @{ environmentId = $Settings.EnvironmentId } }
    # listSecrets returns existing values; keep them in memory so unrelated encrypted
    # secrets survive the replacement array. GET only returns redacted secret metadata.
    $listed = (Invoke-HostMemoryArm POST "$($Settings.JobId)/listSecrets").Value
    if ($null -eq $listed -or -not $listed.ContainsKey('value') -or $listed['value'] -isnot [array]) { throw 'Job secret listing is incomplete; refusing replacement.' }
    foreach ($existing in $listed.value) {
        if ($existing -isnot [System.Collections.IDictionary] -or -not $existing['name'] -or
            (-not $existing.Contains('value') -and -not $existing['keyVaultUrl'])) {
            throw 'Existing Job secret values/references were not returned; refusing destructive replacement.'
        }
    }
    $merged = @($listed.value | Where-Object { -not $RemovePrefix -or -not $_.name.StartsWith($RemovePrefix, [StringComparison]::Ordinal) })
    if ($RemovePrefix -and $merged.Count -eq @($listed.value).Count -and -not $Secrets) { return }
    foreach ($secret in @($Secrets | Where-Object { $_ })) {
        if ($secret.name -in @($merged | ForEach-Object { $_.name })) { throw 'Per-run Job secret name conflicts; refusing overwrite.' }
        $merged += $secret
    }
    $configuration = $job.properties.configuration | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    $configuration.secrets = @($merged)
    $null = Invoke-HostMemoryArm PATCH $Settings.JobId @{ properties = @{ configuration = $configuration } }
    $null = Wait-HostResource $Settings.JobId $script:HostAppApi
}

function Clear-HostRunSecrets {
    param([hashtable]$Settings, [string]$GitHubRunId)
    if ($GitHubRunId -notmatch '^[1-9][0-9]{0,19}$') { throw 'Cleanup requires the exact numeric GitHubRunId.' }
    $job = Invoke-HostArm GET $Settings.JobId $script:HostAppApi -AllowMissing
    if (-not $job) { Write-Host 'Dedicated Job does not exist. No secret cleanup needed.'; return }
    Set-HostJobSecrets $Settings -RemovePrefix "ato-$GitHubRunId-"
}

function Wait-HostJobExecution {
    param([string]$Id, [int]$TimeoutSeconds = 10800, [bool]$RequireSuccess = $true)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Container Apps Job execution exceeded its bounded wait.' }
        $execution = Invoke-HostArm GET $Id $script:HostAppApi
        $state = $execution.properties['status']
        if ($state -in @('Succeeded', 'Failed', 'Stopped')) {
            if ($RequireSuccess -and $state -ne 'Succeeded') { throw "Container Apps Job execution failed: status=$state (ARM provisioning success is not execution success)." }
            return $state
        }
        if ($state -notin @('Running', 'Processing', 'Degraded')) { throw 'Container Apps Job execution returned unknown/missing status; refusing success fallback.' }
        Wait-HostDelay 15
    } while ($true)
}

function Resolve-HostJobStart {
    param([hashtable]$Settings, [hashtable]$Response)
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    do {
        if ($Response.Value -and $Response.Value['id']) {
            $id = $Response.Value.id
            if ($id -notmatch "^$([regex]::Escape($Settings.JobId))/executions/[a-zA-Z0-9_-]+$") { throw 'Job start returned an unexpected execution resource ID.' }
            return $id
        }
        if (-not $Response.Location) { throw 'Job start did not identify its execution or asynchronous operation; no latest-execution fallback.' }
        $uri = $null
        if (-not [Uri]::TryCreate($Response.Location, [UriKind]::Absolute, [ref]$uri) -or
            -not $uri.AbsolutePath.StartsWith("/subscriptions/$($Settings.Config.subscriptionId)/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Job start returned an out-of-subscription operation URL.'
        }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Job start operation exceeded bounded ten-minute wait.' }
        Wait-HostDelay 5
        $location = $Response.Location
        $Response = Invoke-HostMemoryArm GET -Url $location
        if (-not $Response.Location) { $Response.Location = $location }
        if ($Response.Value -and $Response.Value['status'] -in @('Failed', 'Canceled')) { throw 'Job start asynchronous operation failed.' }
    } while ($true)
}

function Invoke-HostGitHub {
    param([string]$Method, [string]$Repository, [string]$Path, [hashtable]$Body)
    if ($Path -notmatch '^check-runs(?:/[0-9]+)?$') { throw 'Only repository check-run API operations are permitted.' }
    (Invoke-HostMemoryRequest $Method "https://api.github.com/repos/$Repository/$Path" $env:GH_TOKEN $Body).Value
}

function Invoke-AiAgentHost {
    param([ValidateSet('Bootstrap', 'Run', 'Cleanup')][string]$Action, [string]$ConfigPath, [string]$Repository,
        [string]$Revision, [string]$Phase = 'Provision', [string]$GitHubRunId, [hashtable]$SecretParameters = @{}, [string[]]$ArtifactHosts = @())
    $s = Get-HostSettings $ConfigPath
    $s.ArtifactHosts = @($ArtifactHosts | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    foreach ($hostName in $s.ArtifactHosts) { $null = New-HostArtifactRule $s $hostName }
    if ($Action -eq 'Cleanup') { Clear-HostRunSecrets $s $GitHubRunId; return }
    if (-not $s.EgressApproved) { throw 'Set deploymentHost.egressApproved=true only after approving this Bootstrap scoped firewall group and private routes.' }
    if ($Action -eq 'Bootstrap') {
        foreach ($rg in @($s.Config.resourceGroupName, $s.Config.applicationResourceGroupName, $s.Config.networking.resourceGroupName)) {
            $id = "/subscriptions/$($s.Config.subscriptionId)/resourceGroups/$rg"
            if (-not (Invoke-HostArm GET $id '2022-09-01' -AllowMissing)) {
                $null = Invoke-HostArm PUT $id '2022-09-01' @{ location = $s.Config.location }
            }
        }
        Ensure-HostNetwork $s
        Invoke-HostDns
        Ensure-HostPrivatePaths $s
        Ensure-HostJobInfrastructure $s
        @{
            hostId = $s.JobId; jobId = $s.JobId; environmentId = $s.EnvironmentId
            managedIdentityResourceId = $s.IdentityId; managedIdentityObjectId = $s.ManagedIdentityObjectId
            managedIdentityClientId = $s.ManagedIdentityClientId
            hubFirewallPrivateIp = $s.HubFirewallPrivateIp; existingVnetResourceId = $s.VnetId
            deploymentHostSubnetPrefix = $s.SubnetPrefix
            firewallRuleCollectionGroupId = $s.FirewallRuleCollectionGroupId
            governanceGatewayPrivateIps = $s.GovernanceGatewayPrivateIps
            governanceGatewayFqdn = $s.GovernanceGatewayFqdn
            privateDnsScope = $s.DnsScope; privateDnsZoneNames = $s.DnsZoneNames
            artifactHosts = $s.ArtifactHosts
        } | ConvertTo-Json -Compress
        return
    }
    if ($Action -ne 'Run') { throw 'Unknown host action.' }
    if ($Repository -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*$' -or
        $Revision -notmatch '^[0-9a-fA-F]{40}$' -or $Phase -notin @('Provision', 'Publish', 'Verify', 'Handoff') -or
        $GitHubRunId -notmatch '^[1-9][0-9]{0,19}$') { throw 'Run requires public owner/repo, full Revision40, supported Phase and exact numeric GitHubRunId.' }
    $handoff = $Phase -eq 'Handoff'
    if (-not $handoff -and -not $env:GH_TOKEN) { throw 'Run requires ephemeral GH_TOKEN with same-repository checks:write and actions:read permissions.' }
    $reserved = @('GH_TOKEN', 'ATO_REPOSITORY', 'ATO_REVISION', 'ATO_PHASE', 'ATO_GITHUB_RUN_ID', 'ATO_CHECK_RUN_ID', 'AZURE_CLIENT_ID', 'PATH', 'BASH_ENV', 'ENV', 'LD_PRELOAD', 'PYTHONPATH', 'PYTHONHOME')
    foreach ($key in $SecretParameters.Keys) {
        if ($key -isnot [string] -or $key -cnotmatch '^[A-Z][A-Z0-9_]{0,63}$' -or $key -in $reserved -or
            $SecretParameters[$key] -isnot [string] -or -not $SecretParameters[$key]) { throw 'Invalid/reserved SecretParameters environment name or empty/nonstring secret value.' }
    }
    Ensure-HostNetwork $s -ValidateOnly
    Ensure-HostPrivatePaths $s -ValidateOnly
    Ensure-HostJobInfrastructure $s -ValidateOnly
    Assert-HostNoActiveExecution $s
    $oldSensitive = $script:HostSensitiveValues
    $script:HostSensitiveValues = @($env:GH_TOKEN) + @($SecretParameters.Values)
    $id = $null; $check = $null; $succeeded = $false
    try {
        if (-not $handoff) {
            $check = Invoke-HostGitHub POST $Repository 'check-runs' @{
                name = "Private deployment: $Phase"; head_sha = $Revision.ToLowerInvariant(); status = 'in_progress'
                external_id = "ato-$GitHubRunId-$Phase"
                details_url = "https://github.com/$Repository/actions/runs/$GitHubRunId"
            }
            if ($null -eq $check -or "$($check['id'])" -notmatch '^[1-9][0-9]*$') { throw 'GitHub did not return a definitive per-phase check-run ID.' }
        }
        $prefix = "ato-$GitHubRunId-$([guid]::NewGuid().ToString('N').Substring(0, 8))-"
        $secrets = @()
        $environment = @(
            @{ name = 'ATO_REPOSITORY'; value = $Repository }, @{ name = 'ATO_REVISION'; value = $Revision.ToLowerInvariant() },
            @{ name = 'ATO_PHASE'; value = $Phase }, @{ name = 'ATO_GITHUB_RUN_ID'; value = $GitHubRunId },
            @{ name = 'AZURE_CLIENT_ID'; value = $s.ManagedIdentityClientId }
        )
        if (-not $handoff) {
            $secrets += @{ name = "${prefix}github"; value = $env:GH_TOKEN }
            $environment += @{ name = 'GH_TOKEN'; secretRef = "${prefix}github" }
            $environment += @{ name = 'ATO_CHECK_RUN_ID'; value = "$($check.id)" }
        }
        $index = 0
        foreach ($key in @($SecretParameters.Keys | Sort-Object)) {
            $name = "${prefix}secret-$index"; $index++
            $secrets += @{ name = $name; value = $SecretParameters[$key] }
            $environment += @{ name = $key; secretRef = $name }
        }
        Set-HostJobSecrets $s $secrets
        $container = Get-HostJobContainer $Repository $Revision.ToLowerInvariant() $environment
        # POST is deliberately never retried: an uncertain response must not double-deploy.
        $start = Invoke-HostMemoryArm POST "$($s.JobId)/start" @{ containers = @($container) }
        $id = Resolve-HostJobStart $s $start
        if ($check) { Write-Host "Private Job execution: $id; check-run $($check.id)." }
        else { Write-Host "Private Azure-only Handoff execution: $id." }
        $null = Wait-HostJobExecution $id
        $succeeded = $true
    } catch {
        if ($check) {
            try {
                $details = Invoke-HostGitHub GET $Repository "check-runs/$($check.id)"
                if ($details['output']) {
                    Write-HostSafeOutput $details.output['summary']
                    Write-HostSafeOutput $details.output['text']
                }
            } catch { Write-Warning 'Private check-run failure tail unavailable; inspect the phase check and exact Job execution.' }
        }
        throw
    } finally {
        try {
            if ($id) {
                $execution = Invoke-HostArm GET $id $script:HostAppApi
                if ($execution.properties['status'] -notin @('Succeeded', 'Failed', 'Stopped')) {
                    $null = Invoke-HostMemoryArm POST "$id/stop"
                    $null = Wait-HostJobExecution $id -TimeoutSeconds 300 -RequireSuccess $false
                }
            }
            Clear-HostRunSecrets $s $GitHubRunId
        } catch {
            $succeeded = $false
            throw
        } finally {
            try {
                if ($check) {
                    $null = Invoke-HostGitHub PATCH $Repository "check-runs/$($check.id)" @{
                        status = 'completed'; conclusion = if ($succeeded) { 'success' } else { 'failure' }
                    }
                }
            } finally { $script:HostSensitiveValues = $oldSensitive }
        }
    }
    @{ jobId = $s.JobId; executionId = $id; checkRunId = if ($check) { $check.id } else { $null }; status = 'Succeeded' } | ConvertTo-Json -Compress
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AiAgentHost $Action $ConfigPath $Repository $Revision $Phase $GitHubRunId $SecretParameters $ArtifactHosts
}
