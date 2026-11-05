#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$settings = Get-Content (Join-Path $PSScriptRoot '..\config\demo.json') -Raw | ConvertFrom-Json
Get-Command az -ErrorAction Stop | Out-Null

$accountJson = & az account show --output json
if ($LASTEXITCODE -ne 0) { throw 'Sign in with your personal Azure account before bootstrapping.' }
$account = $accountJson | ConvertFrom-Json
if ($account.user.type -ne 'user') {
    throw 'Bootstrap requires a personal Azure user account, not a service principal or managed identity.'
}
if ($account.id -ne $settings.subscriptionId -or $account.tenantId -ne $settings.tenantId) {
    throw 'Azure CLI context does not match config\demo.json. Select the configured tenant and subscription.'
}

$groupJson = & az account management-group show --name $settings.intermediateRootManagementGroupId --output json
if ($LASTEXITCODE -ne 0) { throw 'Cannot access the existing ALZ intermediate root management group.' }
$group = $groupJson | ConvertFrom-Json
$scope = "/providers/Microsoft.Management/managementGroups/$($settings.intermediateRootManagementGroupId)"
if ($group.id -ne $scope) { throw 'Azure returned an unexpected management group scope.' }

$principalJson = & az ad sp show --id $settings.deploymentClientId --output json
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the existing GitHub deployment service principal.' }
$principal = $principalJson | ConvertFrom-Json
$principalId = [guid]::Empty
if ($principal.appId -ne $settings.deploymentClientId -or
    -not [guid]::TryParse($principal.id, [ref]$principalId) -or $principalId -eq [guid]::Empty) {
    throw 'Azure returned an unexpected GitHub deployment service principal.'
}

$alzRoot = Split-Path $PSScriptRoot -Parent
$outputDirectory = Join-Path $alzRoot 'output\bicep'
& {
    # Compilation is local-only and is needed to preview the hierarchy under -WhatIf.
    $WhatIfPreference = $false
    & (Join-Path $PSScriptRoot 'Initialize-Alz.ps1') -SubscriptionId $settings.subscriptionId `
        -TenantId $settings.tenantId -OutputPath $outputDirectory
}
$deployments = Get-Content (Join-Path $alzRoot 'bicep\deployments.json') -Raw | ConvertFrom-Json
$pending = @(
    foreach ($entry in $deployments | Where-Object scope -eq 'mg') {
        $parameters = (Get-Content (Join-Path $outputDirectory "$($entry.name).parameters.json") -Raw | ConvertFrom-Json).parameters
        $configs = @($parameters.PSObject.Properties | Where-Object Name -like '*Config')
        if ($configs.Count -ne 1) { throw "Expected one management group configuration for $($entry.name)." }
        $config = $configs[0].Value.value
        if ($config.createOrUpdateManagementGroup) { $config }
    }
)
if (@($pending.managementGroupName | Sort-Object -Unique).Count -ne $pending.Count) {
    throw 'The compiled hierarchy contains duplicate management group names.'
}
$orderedHierarchy = [System.Collections.Generic.List[object]]::new()
$knownParents = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$knownParents.Add($settings.intermediateRootManagementGroupId) | Out-Null
while ($pending.Count -gt 0) {
    $ready = @($pending | Where-Object { $knownParents.Contains($_.managementGroupParentId) })
    if ($ready.Count -eq 0) { throw 'The compiled hierarchy contains a cycle or a parent outside the configured ALZ hierarchy.' }
    foreach ($config in $ready) {
        if (-not $knownParents.Add($config.managementGroupName)) {
            throw 'The compiled hierarchy attempts to recreate the existing ALZ intermediate root.'
        }
        $orderedHierarchy.Add($config)
    }
    $pending = @($pending | Where-Object { -not $knownParents.Contains($_.managementGroupName) })
}
$groupsJson = & az account management-group list --output json
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the existing management group hierarchy.' }
$existingNames = @($groupsJson | ConvertFrom-Json | ForEach-Object { $_.name })
foreach ($config in $orderedHierarchy | Where-Object { $_.managementGroupName -in $existingNames }) {
    $existingJson = & az account management-group show --name $config.managementGroupName --output json
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect management group $($config.managementGroupName)." }
    $existing = $existingJson | ConvertFrom-Json
    $parentId = "/providers/Microsoft.Management/managementGroups/$($config.managementGroupParentId)"
    if ($existing.id -ne "/providers/Microsoft.Management/managementGroups/$($config.managementGroupName)" -or
        $existing.details.parent.id -ne $parentId) {
        throw "Management group $($config.managementGroupName) has an unexpected parent. Bootstrap will not reparent existing groups."
    }
}

$ownerRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
$roleName = "ALZ Role Definition Writer ($($settings.intermediateRootManagementGroupId))"
$requiredAction = 'Microsoft.Authorization/roleDefinitions/write'
function Assert-RoleDefinition {
    param($Role)
    $roleId = [guid]::Empty
    if (-not [guid]::TryParse($Role.name, [ref]$roleId) -or $roleId -eq [guid]::Empty -or
        $Role.roleName -ne $roleName -or $Role.roleType -ne 'CustomRole' -or
        @($Role.assignableScopes).Count -ne 1 -or $Role.assignableScopes[0] -ne $scope -or
        @($Role.permissions).Count -ne 1 -or
        @($Role.permissions[0].actions).Count -ne 1 -or $Role.permissions[0].actions[0] -ne $requiredAction -or
        @($Role.permissions[0].notActions).Count -ne 0 -or
        @($Role.permissions[0].dataActions).Count -ne 0 -or
        @($Role.permissions[0].notDataActions).Count -ne 0) {
        throw 'The bootstrap custom role does not match the required write-only permissions and alz scope. Inspect Azure RBAC before retrying.'
    }
}
function Get-Assignments {
    $json = & az role assignment list --scope $scope --include-inherited --fill-principal-name false --output json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect existing ALZ role assignments.' }
    $json | ConvertFrom-Json
}
function Test-WriterAssignment {
    param($Assignment)
    $Assignment.principalId -eq $principal.id -and $Assignment.scope -eq $scope -and
    ($Assignment.roleDefinitionId -split '/')[-1] -eq $role.name -and
    (-not $Assignment.PSObject.Properties['condition'] -or [string]::IsNullOrWhiteSpace($Assignment.condition))
}

$rolesJson = & az role definition list --name $roleName --scope $scope --output json
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the ALZ bootstrap custom role.' }
$roles = @($rolesJson | ConvertFrom-Json)
if ($roles.Count -gt 1) { throw 'Multiple bootstrap custom roles were returned. Inspect Azure RBAC before retrying.' }
$role = if ($roles.Count -eq 1) { $roles[0] } else { $null }
if ($null -ne $role) { Assert-RoleDefinition $role }

$assignments = @(Get-Assignments)
$owners = @($assignments | Where-Object {
    $_.principalId -eq $principal.id -and $_.scope -eq $scope -and
    ($_.roleDefinitionId -split '/')[-1] -eq $ownerRoleId
})
foreach ($owner in $owners) {
    $assignmentId = [guid]::Empty
    $prefix = "$scope/providers/Microsoft.Authorization/roleAssignments/"
    if (-not $owner.id.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not [guid]::TryParse($owner.id.Substring($prefix.Length), [ref]$assignmentId)) {
        throw 'Azure returned an unexpected Owner assignment ID. No permissions were changed.'
    }
}
if (@($assignments | Where-Object {
    $_.principalId -eq $principal.id -and $_.scope -ne $scope -and
    ($_.roleDefinitionId -split '/')[-1] -eq $ownerRoleId
}).Count -gt 0) {
    Write-Warning 'The deployment identity also inherits Owner access. This bootstrap will not remove assignments on parent scopes.'
}

if ($PSCmdlet.ShouldProcess("$($principal.appId) at $scope", 'Ensure role-definition write permission and remove direct Owner access')) {
    if ($null -eq $role) {
        $definition = @{
            Name = $roleName
            IsCustom = $true
            Description = 'Allows incremental ALZ deployments to create and update custom role definitions. No role deletion or assignment permissions.'
            Actions = @($requiredAction)
            NotActions = @()
            DataActions = @()
            NotDataActions = @()
            AssignableScopes = @($scope)
        }
        $definitionPath = [IO.Path]::GetTempFileName()
        try {
            $definition | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $definitionPath -Encoding utf8
            $roleJson = & az role definition create --role-definition $definitionPath --output json
            if ($LASTEXITCODE -ne 0) { throw 'Failed to create the ALZ bootstrap custom role. Owner access was not removed.' }
            $role = $roleJson | ConvertFrom-Json
            Assert-RoleDefinition $role
        } finally {
            Remove-Item -LiteralPath $definitionPath -Force
        }
    }
    if (@($assignments | Where-Object { Test-WriterAssignment $_ }).Count -eq 0) {
        $assignmentJson = & az role assignment create --assignee-object-id $principal.id `
            --assignee-principal-type ServicePrincipal --role $role.name --scope $scope --output json
        if ($LASTEXITCODE -ne 0) { throw 'Failed to grant ALZ role-definition write permission. Owner access was not removed.' }
        $assignment = $assignmentJson | ConvertFrom-Json
        if (-not (Test-WriterAssignment $assignment)) {
            throw 'Azure did not return the expected custom-role assignment. Owner access was not removed.'
        }
    }
    $verified = @(Get-Assignments)
    if (@($verified | Where-Object { Test-WriterAssignment $_ }).Count -eq 0) {
        throw 'Cannot verify the persisted custom-role assignment. Owner access was not removed; retry after Azure RBAC propagation.'
    }
    foreach ($owner in $owners) {
        & az role assignment delete --ids $owner.id
        if ($LASTEXITCODE -ne 0) { throw 'Failed to remove direct Owner access. The custom-role assignment remains; inspect Azure RBAC before retrying.' }
    }
    $verified = @(Get-Assignments)
    if (@($verified | Where-Object { Test-WriterAssignment $_ }).Count -eq 0 -or
        @($verified | Where-Object {
            $_.principalId -eq $principal.id -and $_.scope -eq $scope -and
            ($_.roleDefinitionId -split '/')[-1] -eq $ownerRoleId
        }).Count -gt 0) {
        throw 'Cannot verify the final permission state. Inspect Azure RBAC before starting GitHub Actions.'
    }
    Write-Host 'Local permission bootstrap verified: role-definition write permission on alz, with no direct Owner assignment.'
    Write-Host 'Existing Contributor, conditional RBAC Administrator and Resource Policy Contributor assignments were not changed.'
    Write-Host 'Allow time for Azure RBAC propagation before starting GitHub Actions.'
}
foreach ($config in $orderedHierarchy) {
    $name = $config.managementGroupName
    if ($name -in $existingNames) {
        Write-Host "Management group $name already exists under $($config.managementGroupParentId)."
        continue
    }
    $parentId = "/providers/Microsoft.Management/managementGroups/$($config.managementGroupParentId)"
    if ($PSCmdlet.ShouldProcess("$name under $parentId", 'Create empty management group')) {
        & az account management-group create --name $name --display-name $config.managementGroupDisplayName `
            --parent $parentId --output none
        if ($LASTEXITCODE -ne 0) { throw "Failed to create management group $name. Earlier bootstrap changes may already exist; rerun after resolving the error." }
        $createdJson = & az account management-group show --name $name --output json
        if ($LASTEXITCODE -ne 0) { throw "Cannot verify management group $name. Inspect Azure before retrying." }
        $created = $createdJson | ConvertFrom-Json
        if ($created.id -ne "/providers/Microsoft.Management/managementGroups/$name" -or $created.details.parent.id -ne $parentId) {
            throw "Azure did not return the expected management group $name and parent. Inspect Azure before retrying."
        }
        Write-Host "Verified empty management group $name under $($config.managementGroupParentId)."
    }
}
Write-Host 'No subscriptions were moved and no policy assignments or workloads were deployed. GitHub deploy still requires explicit DEPLOY confirmation.'
