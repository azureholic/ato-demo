using './upstream/templates/core/governance/mgmt-groups/decommissioned/main.bicep'
import { settings, groupDefaults } from './governance-settings.bicep'

param parLocations = [settings.location]
param decommissionedConfig = union(groupDefaults, {
  managementGroupName: 'decommissioned'
  managementGroupParentId: settings.intermediateRootManagementGroupId
  managementGroupDisplayName: 'Decommissioned'
})
