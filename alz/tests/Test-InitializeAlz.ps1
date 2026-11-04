#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\scripts\Initialize-Alz.ps1'
$output = Join-Path ([IO.Path]::GetTempPath()) "alz-config-test-$([guid]::NewGuid().ToString('N'))"
$subscriptionId = '11111111-1111-1111-1111-111111111111'
$tenantId = '22222222-2222-2222-2222-222222222222'
$settings = @{
    SecurityContactEmail = 'security@example.test'
    OutputPath           = $output
}

try {
    foreach ($invalid in @(
        @{ SubscriptionId = ''; TenantId = $tenantId },
        @{ SubscriptionId = $subscriptionId; TenantId = 'not-a-guid' }
    )) {
        $rejected = $false
        try {
            & $script @settings @invalid
        } catch {
            if ($_.Exception.Message -notlike '*must be a non-empty GUID*') { throw }
            $rejected = $true
        }
        if (-not $rejected -or (Test-Path $output)) {
            throw 'Invalid configuration was accepted or wrote output.'
        }
    }

    & $script @settings -SubscriptionId $subscriptionId -TenantId $tenantId
    $inputs = Get-Content (Join-Path $output 'config\inputs.json') -Raw | ConvertFrom-Json
    if ($inputs.bootstrap_subscription_id -ne $subscriptionId -or
        $inputs.subscription_ids.management -ne $subscriptionId -or
        $inputs.subscription_ids.connectivity -ne $subscriptionId -or
        $inputs.root_parent_management_group_id -ne $tenantId -or
        $inputs.environment_name -ne 'demo') {
        throw 'Resolved subscription, tenant or environment configuration is incorrect.'
    }
    Write-Host 'Configuration rendering and invalid-input tests passed. No Azure changes.'
} finally {
    if (Test-Path $output) {
        Remove-Item -LiteralPath $output -Recurse -Force
    }
}
