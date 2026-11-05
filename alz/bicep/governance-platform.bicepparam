using './upstream/templates/core/governance/mgmt-groups/platform/main.bicep'
import { settings, groupDefaults, monitoringOverrides } from './governance-settings.bicep'

param parLocations = [settings.location]
param platformConfig = union(groupDefaults, {
  managementGroupName: 'platform'
  managementGroupParentId: settings.intermediateRootManagementGroupId
  managementGroupDisplayName: 'Platform'
  subscriptionsToPlaceInManagementGroup: [settings.subscriptionId]
})
param parPolicyAssignmentParameterOverrides = monitoringOverrides
