using './upstream/templates/core/governance/mgmt-groups/landingzones/landingzones-online/main.bicep'
import { settings, groupDefaults } from './governance-settings.bicep'

param parLocations = [settings.location]
param landingZonesOnlineConfig = union(groupDefaults, {
  managementGroupName: 'online'
  managementGroupParentId: 'landingzones'
  managementGroupDisplayName: 'Online'
})
