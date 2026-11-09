using './main.bicep'
import { settings, groupDefaults } from '../../../smb-settings.bicep'

param parLocations = [settings.location]
param platformManagementConfig = union(groupDefaults, {
  managementGroupName: 'management'
  managementGroupParentId: 'platform'
  managementGroupDisplayName: 'Management'
})
