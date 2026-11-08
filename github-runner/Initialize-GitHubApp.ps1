#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Repository = 'azureholic/ato-demo',
    [string]$EnvironmentName = 'demo',
    [string]$GitHubUser,
    [string]$ResumeAppSlug,
    [ValidateRange(1024, 65535)][int]$Port = 8765
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\shared-infrastructure\Deployment.ps1')

function Invoke-SetupGitHub {
    param([string[]]$Arguments, [string]$InputText)
    $previousToken = $env:GH_TOKEN
    try {
        if ($GitHubUser) {
            $token = & gh auth token --hostname github.com --user $GitHubUser
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) { throw 'Cannot access the selected GitHub CLI account.' }
            $env:GH_TOKEN = $token
        }
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $InputText | & gh @Arguments
            if ($LASTEXITCODE -ne 0) { throw 'Failed to store App private key in the protected GitHub environment.' }
        } else {
            Invoke-CheckedCommand gh $Arguments
        }
    } finally {
        $env:GH_TOKEN = $previousToken
    }
}
function ConvertTo-Base64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
function Save-AppCredentials($App, [long]$ExpiresOn) {
    Invoke-SetupGitHub -Arguments @('secret', 'set', 'GH_RUNNER_APP_PRIVATE_KEY', '--repo', $Repository, '--env', $EnvironmentName) -InputText $App.pem
    Invoke-SetupGitHub @('variable', 'set', 'GH_RUNNER_APP_ID', '--repo', $Repository, '--env', $EnvironmentName, '--body', "$($App.id)")
    Invoke-SetupGitHub @('variable', 'set', 'GH_RUNNER_APP_KEY_EXPIRES_ON', '--repo', $Repository, '--env', $EnvironmentName, '--body', "$ExpiresOn")
}
function Get-AppInstallation {
    param($App, [switch]$AllowMissing)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes((@{ iat = $now - 60; exp = $now + 540; iss = "$($App.id)" } | ConvertTo-Json -Compress)))
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($App.pem)
        $signature = ConvertTo-Base64Url ($rsa.SignData([Text.Encoding]::UTF8.GetBytes("$header.$payload"), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
        try {
            Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/installation" -Headers @{
                Authorization = "Bearer $header.$payload.$signature"
                Accept = 'application/vnd.github+json'
                'X-GitHub-Api-Version' = '2022-11-28'
            }
        } catch {
            if ($AllowMissing -and $_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException] -and $_.Exception.Response.StatusCode -eq [Net.HttpStatusCode]::NotFound) {
                Write-Host 'The App is not installed on this repository yet; complete installation in the browser.'
                return
            }
            throw
        }
    } finally {
        $rsa.Dispose()
    }
}
$canAdminister = Invoke-SetupGitHub @('api', "repos/$Repository", '--jq', '.permissions.admin')
if ($canAdminister.Trim() -ne 'true') { throw 'Select a GitHub CLI account with repository administration permission before creating an App.' }

# GitHub has no REST endpoint to create an App without the manifest consent flow.
$state = [guid]::NewGuid().ToString('N')
$baseUrl = "http://localhost:$Port"
$manifest = @{
    name = "private-runner-$($Repository.Replace('/', '-'))-$($state.Substring(0, 6))"
    url = "https://github.com/$Repository"
    redirect_url = "$baseUrl/callback"
    setup_url = "$baseUrl/installed"
    public = $false
    hook_attributes = @{ url = 'https://example.invalid/github'; active = $false }
    default_permissions = @{ actions = 'read'; administration = 'write'; contents = 'read'; metadata = 'read' }
    default_events = @()
} | ConvertTo-Json -Depth 10 -Compress
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("$baseUrl/")
$listener.Start()
$deadline = [DateTime]::UtcNow.AddMinutes(15)
$app = $null
$installationId = $null
$installation = $null
try {
    Start-Process "$baseUrl/start"
    Write-Host 'Complete the local browser form. Credentials remain in memory; resume mode does not create another App.'
    while (-not $installationId) {
        $pending = $listener.GetContextAsync()
        while (-not $pending.IsCompleted) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'GitHub App consent timed out.' }
            Start-Sleep -Milliseconds 200
        }
        $context = $pending.GetAwaiter().GetResult()
        $path = $context.Request.Url.AbsolutePath
        $text = 'Continue in the GitHub browser tab.'
        if ($path -eq '/start') {
            $encoded = [Net.WebUtility]::HtmlEncode($manifest)
            $text = "<html><body><form method='post' action='https://github.com/settings/apps/new?state=$state'><input type='hidden' name='manifest' value='$encoded'><button type='submit'>Create private deployment runner App</button></form></body></html>"
            if ($ResumeAppSlug) {
                $text = "<html><body>Paste the original localhost callback URL here, not in chat. No new App will be created.<form method='post' action='/resume'><input type='hidden' name='state' value='$state'><input type='url' name='callback' required size='100'><button type='submit'>Resume existing App credential setup</button></form></body></html>"
            }
        } elseif ($path -eq '/callback' -or ($path -eq '/resume' -and $ResumeAppSlug)) {
            if ($path -eq '/resume') {
                if ($context.Request.HttpMethod -ne 'POST') { throw 'Resume requires the local POST form.' }
                $reader = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding)
                try { $form = [Web.HttpUtility]::ParseQueryString($reader.ReadToEnd()) } finally { $reader.Dispose() }
                if ($form['state'] -cne $state) { throw 'Resume form state did not match.' }
                $callback = [uri]$form['callback']
                if (-not $callback.IsAbsoluteUri -or $callback.Scheme -ne 'http' -or $callback.Host -ne 'localhost' -or $callback.Port -ne $Port -or $callback.AbsolutePath -ne '/callback') { throw 'Expected the original localhost callback URL.' }
                $code = [Web.HttpUtility]::ParseQueryString($callback.Query)['code']
            } else {
                if ($ResumeAppSlug) { throw 'Use the local resume form rather than opening an old callback directly.' }
                if ($context.Request.QueryString['state'] -cne $state) { throw 'GitHub App callback state did not match.' }
                $code = $context.Request.QueryString['code']
            }
            if ($code -notmatch '^[A-Za-z0-9_-]+$') { throw 'Missing or invalid manifest conversion code.' }
            $app = Invoke-SetupGitHub @('api', '--method', 'POST', "/app-manifests/$code/conversions") | ConvertFrom-Json
            if (-not $app.pem -or -not $app.id) { throw 'GitHub returned no App key or App ID.' }
            $keyExpiresOn = [DateTimeOffset]::UtcNow.AddDays(90).ToUnixTimeSeconds()
            if ($ResumeAppSlug -and $app.slug -cne $ResumeAppSlug) { throw 'Converted manifest does not match the requested existing App.' }
            Save-AppCredentials $app $keyExpiresOn
            if ($ResumeAppSlug) {
                $installation = Get-AppInstallation $app -AllowMissing
                if ($null -ne $installation) {
                    $installationId = "$($installation.id)"
                    $text = '<html><body>Existing App installation verified. Return to PowerShell for credential storage confirmation.</body></html>'
                }
            }
            if (-not $installationId) {
                $text = '<html><body>App created. Install it on the scenario repository in the next browser tab.</body></html>'
                Start-Process "https://github.com/apps/$($app.slug)/installations/new"
            }
        } elseif ($path -eq '/installed') {
            if ($null -eq $app) { throw 'Installation callback arrived before App creation.' }
            $installationId = $context.Request.QueryString['installation_id']
            if ($installationId -notmatch '^[1-9][0-9]*$') { throw 'Missing GitHub App installation ID.' }
            $text = '<html><body>Installation received. Return to PowerShell for verification.</body></html>'
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $context.Response.ContentType = 'text/html; charset=utf-8'
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.Close()
    }
} finally {
    $listener.Stop()
    $listener.Close()
}

try {
    if ($null -eq $installation) { $installation = Get-AppInstallation $app }
    if ("$($installation.id)" -ne $installationId) { throw 'App was not installed on the configured repository.' }
    Invoke-SetupGitHub @('variable', 'set', 'GH_RUNNER_INSTALLATION_ID', '--repo', $Repository, '--env', $EnvironmentName, '--body', $installationId)
    Write-Host 'GitHub App verified. IDs and encrypted private-key secret stored in the deployment environment; no secret files created.'
} finally {
    $app = $null
}
