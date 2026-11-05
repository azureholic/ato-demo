using './upstream/templates/core/governance/mgmt-groups/sandbox/main.bicep'
import { settings, groupDefaults } from './governance-settings.bicep'

param parLocations = [settings.location]
param sandboxConfig = union(groupDefaults, {
  managementGroupName: 'sandbox'
  managementGroupParentId: settings.intermediateRootManagementGroupId
  managementGroupDisplayName: 'Sandbox'
})
