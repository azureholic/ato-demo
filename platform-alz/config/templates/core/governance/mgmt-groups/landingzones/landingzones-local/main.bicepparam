using './main.bicep'
import { settings, groupDefaults } from '../../../smb-settings.bicep'

param parLocations = [settings.location]
param landingZonesLocalConfig = union(groupDefaults, {
  managementGroupName: 'local'
  managementGroupParentId: 'landingzones'
  managementGroupDisplayName: 'Local'
})
