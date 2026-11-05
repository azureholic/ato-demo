using './upstream/templates/core/governance/mgmt-groups/landingzones/landingzones-local/main.bicep'
import { settings, groupDefaults } from './governance-settings.bicep'

param parLocations = [settings.location]
param landingZonesLocalConfig = union(groupDefaults, {
  managementGroupName: 'local'
  managementGroupParentId: 'landingzones'
  managementGroupDisplayName: 'Local'
})
