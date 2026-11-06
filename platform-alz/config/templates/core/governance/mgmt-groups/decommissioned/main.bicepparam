using './main.bicep'
import { settings, groupDefaults } from '../../smb-settings.bicep'

param parLocations = [settings.location]
param decommissionedConfig = union(groupDefaults, {
  managementGroupName: 'decommissioned'
  managementGroupParentId: settings.intermediateRootManagementGroupId
  managementGroupDisplayName: 'Decommissioned'
})
