using './upstream/templates/core/governance/mgmt-groups/platform/platform-management/main.bicep'
import { settings, groupDefaults } from './governance-settings.bicep'

param parLocations = [settings.location]
param platformManagementConfig = union(groupDefaults, {
  managementGroupName: 'management'
  managementGroupParentId: 'platform'
  managementGroupDisplayName: 'Management'
})
