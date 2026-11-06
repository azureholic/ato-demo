using './main.bicep'
import { settings, groupDefaults, monitoringOverrides, workspaceId } from '../../smb-settings.bicep'

param parLocations = [settings.location]
param landingZonesConfig = union(groupDefaults, {
  managementGroupName: 'landingzones'
  managementGroupParentId: settings.intermediateRootManagementGroupId
  managementGroupDisplayName: 'Landing Zones'
  managementGroupExcludedPolicyAssignments: ['Enable-DDoS-VNET']
})
param parPolicyAssignmentParameterOverrides = union(monitoringOverrides, {
  'Deploy-AzSqlDb-Auditing': {
    parameters: { logAnalyticsWorkspaceId: { value: workspaceId } }
  }
})
