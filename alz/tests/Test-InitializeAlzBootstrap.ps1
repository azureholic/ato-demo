#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$bootstrapSource = Join-Path $PSScriptRoot '..\scripts\Initialize-AlzBootstrap.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "alz-bootstrap-test-$([guid]::NewGuid().ToString('N'))"
$bootstrap = Join-Path $fixtureRoot 'scripts\Initialize-AlzBootstrap.ps1'
$settings = Get-Content (Join-Path $PSScriptRoot '..\config\demo.json') -Raw | ConvertFrom-Json
$principalId = '11111111-1111-1111-1111-111111111111'
$scope = "/providers/Microsoft.Management/managementGroups/$($settings.intermediateRootManagementGroupId)"
$ownerRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
$writerRoleId = '22222222-2222-2222-2222-222222222222'
$ownerId = "$scope/providers/Microsoft.Authorization/roleAssignments/33333333-3333-3333-3333-333333333333"
$state = @{}
function Reset-State {
    $state.Clear()
    $state.UserType = 'user'
    $state.Tenant = $settings.tenantId
    $state.Subscription = $settings.subscriptionId
    $state.Role = $null
    $state.WriterAssigned = $false
    $state.OwnerAssigned = $true
    $state.Fail = ''
    $state.Groups = @{}
    $state.Calls = [System.Collections.Generic.List[string]]::new()
    $state.Mutations = [System.Collections.Generic.List[string]]::new()
}
function az {
    $command = $args -join ' '
    $state.Calls.Add($command)
    $global:LASTEXITCODE = 0
    switch -Wildcard ($command) {
        'account show *' {
            @{ id = $state.Subscription; tenantId = $state.Tenant; user = @{ type = $state.UserType } } | ConvertTo-Json
        }
        'account management-group show *' {
            $name = $args[4]
            if ($name -eq $settings.intermediateRootManagementGroupId) {
                @{ id = $scope } | ConvertTo-Json
            } elseif ($state.Groups.ContainsKey($name)) {
                @{
                    id = "/providers/Microsoft.Management/managementGroups/$name"
                    details = @{ parent = @{ id = "/providers/Microsoft.Management/managementGroups/$($state.Groups[$name])" } }
                } | ConvertTo-Json -Depth 5
            } else { throw "Bootstrap tried to inspect a group before creating it: $name" }
        }
        'account management-group list *' {
            ConvertTo-Json -InputObject @(
                @{ name = $settings.intermediateRootManagementGroupId }
                foreach ($name in $state.Groups.Keys) { @{ name = $name } }
            )
        }
        'account management-group create *' {
            $name = $args[4]
            $parent = if ($name -eq 'platform') { $settings.intermediateRootManagementGroupId } else { 'platform' }
            if ($name -notin @('platform', 'management') -or
                $command -ne "account management-group create --name $name --display-name $name --parent /providers/Microsoft.Management/managementGroups/$parent --output none" -or
                ($parent -ne $settings.intermediateRootManagementGroupId -and -not $state.Groups.ContainsKey($parent))) {
                throw "Unexpected management group creation or ordering: $command"
            }
            $state.Mutations.Add("create-group:$name")
            if ($state.Fail -eq 'group') { $global:LASTEXITCODE = 1; return }
            $state.Groups[$name] = $parent
        }
        'ad sp show *' { @{ id = $principalId; appId = $settings.deploymentClientId } | ConvertTo-Json }
        'role definition list *' {
            if ($state.Role) { ConvertTo-Json -InputObject @($state.Role) -Depth 6 } else { '[]' }
        }
        'role definition create *' {
            $state.Mutations.Add('create-definition')
            if ($state.Fail -eq 'definition') { $global:LASTEXITCODE = 1; return }
            $definition = Get-Content -LiteralPath $args[4] -Raw | ConvertFrom-Json
            if (@($definition.Actions).Count -ne 1 -or
                $definition.Actions[0] -ne 'Microsoft.Authorization/roleDefinitions/write' -or
                @($definition.AssignableScopes).Count -ne 1 -or $definition.AssignableScopes[0] -ne $scope -or
                @($definition.NotActions).Count -ne 0 -or @($definition.DataActions).Count -ne 0 -or
                @($definition.NotDataActions).Count -ne 0) {
                throw 'Bootstrap requested excessive custom-role permissions or scope.'
            }
            $state.Role = @{
                name = $writerRoleId
                roleName = $definition.Name
                roleType = 'CustomRole'
                assignableScopes = @($scope)
                permissions = @(@{
                    actions = @($definition.Actions); notActions = @(); dataActions = @(); notDataActions = @()
                })
            }
            $state.Role | ConvertTo-Json -Depth 6
        }
        'role assignment list *' {
            if ($command -ne "role assignment list --scope $scope --include-inherited --fill-principal-name false --output json") {
                throw "Unexpected role lookup: $command"
            }
            if ($state.Fail -eq 'list') { $global:LASTEXITCODE = 1; return }
            $assignments = @(
                @{
                    principalId = '44444444-4444-4444-4444-444444444444'; scope = $scope
                    roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/$ownerRoleId"
                    id = "$scope/providers/Microsoft.Authorization/roleAssignments/55555555-5555-5555-5555-555555555555"
                }
                @{
                    principalId = $principalId; scope = '/providers/Microsoft.Management/managementGroups/parent'
                    roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c'
                }
                if ($state.OwnerAssigned) {
                    @{
                        principalId = $principalId; scope = $scope; id = $ownerId
                        roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/$ownerRoleId"
                    }
                }
                if ($state.WriterAssigned -and $state.Fail -ne 'verify') {
                    @{
                        principalId = $principalId; scope = $scope
                        roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/$writerRoleId"
                    }
                }
            )
            ConvertTo-Json -InputObject $assignments -Depth 6
        }
        'role assignment create *' {
            $state.Mutations.Add('assign-writer')
            if ($state.Fail -eq 'assignment') { $global:LASTEXITCODE = 1; return }
            if ($command -ne "role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role $writerRoleId --scope $scope --output json") {
                throw "Unexpected role grant: $command"
            }
            $state.WriterAssigned = $true
            @{ principalId = $principalId; scope = $scope; roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/$writerRoleId" } | ConvertTo-Json
        }
        'role assignment delete *' {
            if ($command -ne "role assignment delete --ids $ownerId") {
                throw "Bootstrap tried to remove an unrelated assignment: $command"
            }
            $state.Mutations.Add('remove-owner')
            if ($state.Fail -eq 'delete') { $global:LASTEXITCODE = 1; return }
            $state.OwnerAssigned = $false
        }
        default { throw "Unexpected Azure command: $command" }
    }
}
function Assert-Rejected {
    param([string]$Message, [switch]$NoMutations)
    $rejected = $false
    try { & $bootstrap -Confirm:$false } catch {
        if ($_.Exception.Message -notlike $Message) { throw }
        $rejected = $true
    }
    if (-not $rejected -or -not $state.OwnerAssigned -or
        ($NoMutations -and $state.Mutations.Count -ne 0)) {
        throw 'Bootstrap did not safely reject the failure while preserving Owner access.'
    }
}

try {
foreach ($directory in 'scripts', 'config', 'bicep', 'output\bicep') {
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $directory) -Force | Out-Null
}
Copy-Item -LiteralPath $bootstrapSource -Destination $bootstrap
$settings | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $fixtureRoot 'config\demo.json')
@'
param($SubscriptionId, $TenantId, $OutputPath)
if ($state.Fail -eq 'build') { throw 'Fixture compilation failed.' }
'@ | Set-Content (Join-Path $fixtureRoot 'scripts\Initialize-Alz.ps1')
$fixtureGroups = @(
    @{ managementGroupName = 'management'; managementGroupParentId = 'platform'; managementGroupDisplayName = 'management'; createOrUpdateManagementGroup = $true },
    @{ managementGroupName = 'platform'; managementGroupParentId = $settings.intermediateRootManagementGroupId; managementGroupDisplayName = 'platform'; createOrUpdateManagementGroup = $true },
    @{ managementGroupName = $settings.intermediateRootManagementGroupId; managementGroupParentId = $settings.tenantId; createOrUpdateManagementGroup = $false }
)
@($fixtureGroups | ForEach-Object { @{ name = "governance-$($_.managementGroupName)"; scope = 'mg' } }) |
    ConvertTo-Json | Set-Content (Join-Path $fixtureRoot 'bicep\deployments.json')
foreach ($config in $fixtureGroups) {
    @{ parameters = @{ groupConfig = @{ value = $config } } } | ConvertTo-Json -Depth 6 |
        Set-Content (Join-Path $fixtureRoot "output\bicep\governance-$($config.managementGroupName).parameters.json")
}

Reset-State
$state.UserType = 'servicePrincipal'
Assert-Rejected '*requires a personal Azure user*' -NoMutations
Reset-State
$state.Tenant = '66666666-6666-6666-6666-666666666666'
Assert-Rejected '*context does not match*' -NoMutations
Reset-State
$state.Subscription = '66666666-6666-6666-6666-666666666666'
Assert-Rejected '*context does not match*' -NoMutations
Reset-State
$state.Fail = 'list'
Assert-Rejected '*Cannot inspect existing ALZ role assignments*' -NoMutations
Reset-State
$state.Fail = 'build'
Assert-Rejected '*Fixture compilation failed*' -NoMutations
Reset-State
$state.Groups['platform'] = 'unexpected-parent'
Assert-Rejected '*Bootstrap will not reparent existing groups*' -NoMutations

Reset-State
& $bootstrap -WhatIf
if ($state.Mutations.Count -ne 0) { throw 'WhatIf changed Azure permissions or management groups.' }

foreach ($failure in @(
    @{ Step = 'definition'; Message = '*Failed to create the ALZ bootstrap custom role*' },
    @{ Step = 'assignment'; Message = '*Failed to grant ALZ role-definition write permission*' },
    @{ Step = 'verify'; Message = '*Cannot verify the persisted custom-role assignment*' },
    @{ Step = 'delete'; Message = '*Failed to remove direct Owner access*' }
)) {
    Reset-State
    $state.Fail = $failure.Step
    Assert-Rejected $failure.Message
    if ($failure.Step -ne 'delete' -and $state.Mutations.Contains('remove-owner')) {
        throw 'Owner access was removed before the replacement was verified.'
    }
}

Reset-State
& $bootstrap -Confirm:$false
if ($state.OwnerAssigned -or -not $state.WriterAssigned -or
    ($state.Mutations -join ',') -ne 'create-definition,assign-writer,remove-owner,create-group:platform,create-group:management') {
    throw 'Bootstrap did not replace Owner and create the compiled hierarchy in the required order.'
}
$state.Mutations.Clear()
& $bootstrap -Confirm:$false
if ($state.Mutations.Count -ne 0) { throw 'Bootstrap was not idempotent.' }
$state.Calls.Clear()
& $bootstrap -WhatIf
if (-not $state.Calls.Contains('account management-group show --name management --output json') -or
    $state.Mutations.Count -ne 0) {
    throw 'WhatIf did not validate existing management groups without changing Azure.'
}
$state.OwnerAssigned = $true
$state.Role.permissions[0].actions = @('*')
Assert-Rejected '*does not match the required write-only permissions*' -NoMutations
Reset-State
$state.Fail = 'group'
$rejected = $false
try { & $bootstrap -Confirm:$false } catch {
    if ($_.Exception.Message -notlike '*Failed to create management group platform*') { throw }
    $rejected = $true
}
if (-not $rejected -or $state.Mutations.Contains('create-group:management')) {
    throw 'A failed parent creation was ignored or its child was created.'
}
Reset-State
$fixtureGroups[1].managementGroupParentId = 'management'
@{ parameters = @{ groupConfig = @{ value = $fixtureGroups[1] } } } | ConvertTo-Json -Depth 6 |
    Set-Content (Join-Path $fixtureRoot 'output\bicep\governance-platform.parameters.json')
Assert-Rejected '*contains a cycle*' -NoMutations
Write-Host 'Bootstrap permissions, hierarchy ordering, no-reparent safety, WhatIf, failures and idempotence tests passed. No Azure resources changed.'
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
}
