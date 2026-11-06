using './main-rbac.bicep'

param parLandingZonesManagementGroupName = 'landingzones'
param parPlatformManagementGroupName = 'platform'
param parConnectivityManagementGroupName = 'connectivity'
param parManagementGroupExcludedPolicyAssignments = ['Enable-DDoS-VNET']
