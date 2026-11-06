using './main-rbac.bicep'

param parPlatformManagementGroupName = 'platform'
param parConnectivityManagementGroupName = 'connectivity'
param parManagementGroupExcludedPolicyAssignments = ['Enable-DDoS-VNET']
