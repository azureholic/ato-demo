#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config'),

    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 900,

    [ValidateRange(1, 60)]
    [int]$PollIntervalSeconds = 20
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = Get-Content (Join-Path $ConfigPath 'deployment.json') -Raw | ConvertFrom-Json
$waiver = $config.storagePolicyExemption
$exemptionName = 'govhub-logic-storage-shared-key'
if ($waiver.policyAssignmentId -notmatch '^/providers/Microsoft.Management/managementGroups/[^/]+/providers/Microsoft.Authorization/policyAssignments/[^/]+$' -or
    $waiver.policyDefinitionReferenceId -cne 'StorageAccountDisableLocalAuth') {
    throw 'Configure the management-group policy assignment and only StorageAccountDisableLocalAuth for the runtime storage waiver.'
}

function Invoke-StorageCommand {
    param([string[]]$Arguments)
    $global:LASTEXITCODE = 0
    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Storage waiver operation 'az $($Arguments -join ' ')' failed with exit code $LASTEXITCODE. Exemption creation requires policyExemptions/write on the account and policyAssignments/exempt/action on the configured assignment; grant permissions administratively, not through this workflow."
    }
}

$subscription = [guid]$config.subscriptionId
if ($subscription -eq [guid]::Empty) { throw 'Configure a nonempty workload subscription.' }
$common = @('--subscription', "$subscription", '--resource-group', $config.resourceGroupName)
$accountName = Invoke-StorageCommand (@('deployment', 'group', 'show') + $common + @(
    '--name', 'storage', '--query', 'properties.outputs.storageAccountName.value', '--output', 'tsv'
))
if ($accountName -cnotmatch '^[a-z0-9]{3,24}$') {
    throw 'The upstream storage deployment returned no valid runtime storage account name.'
}
$scope = "/subscriptions/$subscription/resourceGroups/$($config.resourceGroupName)/providers/Microsoft.Storage/storageAccounts/$accountName"
function Get-RuntimeStorage {
    $result = Invoke-StorageCommand (@('storage', 'account', 'show') + $common + @(
        '--name', $accountName, '--query', '{id:id,publicNetworkAccess:publicNetworkAccess,allowSharedKeyAccess:allowSharedKeyAccess}', '--output', 'json'
    )) | ConvertFrom-Json
    if ($result.id -ine $scope -or $result.publicNetworkAccess -cne 'Disabled') {
        throw 'Runtime storage must match the deployed account and retain disabled public network access.'
    }
    return $result
}
$storage = Get-RuntimeStorage
$apps = @(Invoke-StorageCommand (@('resource', 'list') + $common + @(
    '--resource-type', 'Microsoft.Web/sites',
    '--query', '[].{id:id,name:name,kind:kind,tags:tags}', '--output', 'json'
)) | ConvertFrom-Json | Where-Object {
    $null -ne $_.tags -and
    $null -ne $_.tags.PSObject.Properties['azd-service-name'] -and
    $_.tags.PSObject.Properties['azd-service-name'].Value -ceq 'usageProcessingLogicApp'
})
if ($apps.Count -ne 1 -or $apps[0].kind -notmatch '(^|,)workflowapp(,|$)' -or
    $apps[0].id -ine "/subscriptions/$subscription/resourceGroups/$($config.resourceGroupName)/providers/Microsoft.Web/sites/$($apps[0].name)") {
    throw 'Expected exactly one upstream usage-processing Logic App in the configured resource group.'
}

function Assert-StorageExemption {
    param($Exemption)
    $expiry = $Exemption.PSObject.Properties['expiresOn']
    if ($Exemption.policyAssignmentId -ine $waiver.policyAssignmentId -or
        @($Exemption.policyDefinitionReferenceIds).Count -ne 1 -or
        $Exemption.policyDefinitionReferenceIds[0] -cne $waiver.policyDefinitionReferenceId -or
        $Exemption.exemptionCategory -cne 'Waiver' -or
        ($null -ne $expiry -and $null -ne $expiry.Value)) {
        throw 'Existing storage exemption differs from the approved single-policy, no-expiry waiver; review it rather than overwriting it.'
    }
}
$exemptions = @(Invoke-StorageCommand @(
    'policy', 'exemption', 'list', '--subscription', "$subscription", '--scope', $scope, '--output', 'json'
) | ConvertFrom-Json | Where-Object { $_.name -ceq $exemptionName })
if ($exemptions.Count -gt 1) { throw 'Multiple runtime storage exemptions have the configured name.' }
$created = $exemptions.Count -eq 0
if (-not $created) {
    Assert-StorageExemption $exemptions[0]
} else {
    Invoke-StorageCommand @(
        'policy', 'exemption', 'create', '--subscription', "$subscription",
        '--name', $exemptionName, '--scope', $scope,
        '--policy-assignment', $waiver.policyAssignmentId,
        '--policy-definition-reference-ids', $waiver.policyDefinitionReferenceId,
        '--exemption-category', 'Waiver', '--assignment-scope-validation', 'Default',
        '--display-name', 'GovHub Logic App runtime storage key access',
        '--description', 'WorkflowStandard hosting requires storage account keys. Waiver applies only to runtime storage local-auth policy; public network access remains disabled. No expiry is intentional.',
        '--output', 'none'
    )
}
$verified = Invoke-StorageCommand @(
    'policy', 'exemption', 'show', '--subscription', "$subscription",
    '--name', $exemptionName, '--scope', $scope, '--output', 'json'
) | ConvertFrom-Json
if ($verified.id -ine "$scope/providers/Microsoft.Authorization/policyExemptions/$exemptionName") {
    throw 'Storage exemption verification returned an unexpected resource scope.'
}
Assert-StorageExemption $verified

# A modify policy has already changed the account; an exemption alone does not undo that change.
$storage = Get-RuntimeStorage
$changed = $false
$timer = [Diagnostics.Stopwatch]::StartNew()
while ($storage.allowSharedKeyAccess -ne $true) {
    Invoke-StorageCommand (@('storage', 'account', 'update') + $common + @(
        '--name', $accountName, '--allow-shared-key-access', 'true', '--output', 'none'
    ))
    $changed = $true
    $storage = Get-RuntimeStorage
    if ($storage.allowSharedKeyAccess -eq $true) { break }
    if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        throw 'Runtime storage key access remains disabled after the waiver propagation timeout; application deployment must not continue.'
    }
    Write-Warning 'Storage key access is still disabled; waiting for the scoped policy exemption to propagate.'
    Start-Sleep -Seconds $PollIntervalSeconds
}
if ($created -or $changed) {
    Invoke-StorageCommand (@('webapp', 'restart') + $common + @('--name', $apps[0].name, '--output', 'none'))
}
Write-Host "Verified no-expiry, single-policy waiver on $scope. Storage key access is enabled; public access remains disabled."
