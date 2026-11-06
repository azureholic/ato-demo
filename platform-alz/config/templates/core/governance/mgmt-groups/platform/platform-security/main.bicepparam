using './main.bicep'
import { settings, groupDefaults } from '../../../smb-settings.bicep'

param parLocations = [settings.location]
param platformSecurityConfig = union(groupDefaults, {
  managementGroupName: 'security'
  managementGroupParentId: 'platform'
  managementGroupDisplayName: 'Security'
})
