using './main.bicep'
import { settings, groupDefaults, monitoringOverrides } from '../../smb-settings.bicep'

var workspaceId = '/subscriptions/${settings.subscriptionId}/resourceGroups/rg-management-${settings.location}/providers/Microsoft.OperationalInsights/workspaces/law-management-${settings.location}'

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
