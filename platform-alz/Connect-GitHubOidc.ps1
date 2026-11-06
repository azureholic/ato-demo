#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($name in 'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID',
    'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN') {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Cannot renew GitHub OIDC authentication: missing environment variable $name."
    }
}

$requestUri = [uri]$env:ACTIONS_ID_TOKEN_REQUEST_URL
if (-not $requestUri.IsAbsoluteUri -or $requestUri.Scheme -ne 'https') {
    throw 'The GitHub OIDC request URL must be an absolute HTTPS URL.'
}
$separator = if ($requestUri.Query) { '&' } else { '?' }
$response = Invoke-RestMethod -Uri "$requestUri${separator}audience=api%3A%2F%2FAzureADTokenExchange" `
    -Headers @{ Authorization = "Bearer $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN" } `
    -TimeoutSec 30 -MaximumRetryCount 2 -RetryIntervalSec 2
if ($null -eq $response -or $null -eq $response.PSObject.Properties['value'] -or
    $response.value -isnot [string] -or [string]::IsNullOrWhiteSpace($response.value)) {
    throw 'GitHub did not return an OIDC token; Azure authentication was not renewed.'
}

Write-Host "::add-mask::$($response.value)"
Import-Module Az.Accounts -RequiredVersion 5.5.4
Connect-AzAccount -ServicePrincipal -ApplicationId $env:ARM_CLIENT_ID `
    -Tenant $env:ARM_TENANT_ID -Subscription $env:ARM_SUBSCRIPTION_ID `
    -FederatedToken $response.value -Scope Process -Force -SkipContextPopulation | Out-Null
Write-Host 'Renewed Azure PowerShell authentication with a fresh GitHub OIDC assertion.'
