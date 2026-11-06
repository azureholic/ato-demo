using './main.bicep'
import { settings, groupDefaults } from '../../smb-settings.bicep'

param parLocations = [settings.location]
param sandboxConfig = union(groupDefaults, {
  managementGroupName: 'sandbox'
  managementGroupParentId: settings.intermediateRootManagementGroupId
  managementGroupDisplayName: 'Sandbox'
})
