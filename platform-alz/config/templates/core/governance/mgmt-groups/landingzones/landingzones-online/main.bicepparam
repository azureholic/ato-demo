using './main.bicep'
import { settings, groupDefaults } from '../../../smb-settings.bicep'

param parLocations = [settings.location]
param landingZonesOnlineConfig = union(groupDefaults, {
  managementGroupName: 'online'
  managementGroupParentId: 'landingzones'
  managementGroupDisplayName: 'Online'
})
