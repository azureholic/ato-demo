using './main-rbac.bicep'

param parCorpManagementGroupName = 'corp'
param parConnectivityManagementGroupName = 'connectivity'
param parManagementGroupExcludedPolicyAssignments = ['Deploy-Private-DNS-Zones']
