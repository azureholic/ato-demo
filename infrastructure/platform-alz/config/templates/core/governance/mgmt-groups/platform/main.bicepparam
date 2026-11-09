using './main.bicep'
import { settings, groupDefaults, monitoringOverrides } from '../../smb-settings.bicep'

param parLocations = [settings.location]
param platformConfig = union(groupDefaults, {
  managementGroupName: 'platform'
  managementGroupParentId: settings.intermediateRootManagementGroupId
  managementGroupDisplayName: 'Platform'
  subscriptionsToPlaceInManagementGroup: [settings.subscriptionId]
})
param parPolicyAssignmentParameterOverrides = monitoringOverrides
