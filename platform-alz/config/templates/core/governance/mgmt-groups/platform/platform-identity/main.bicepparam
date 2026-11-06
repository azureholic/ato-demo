using './main.bicep'
import { settings, groupDefaults } from '../../../smb-settings.bicep'

param parLocations = [settings.location]
param platformIdentityConfig = union(groupDefaults, {
  managementGroupName: 'identity'
  managementGroupParentId: 'platform'
  managementGroupDisplayName: 'Identity'
})
