using './main.bicep'
import { settings, groupDefaults } from '../../../smb-settings.bicep'

param parLocations = [settings.location]
param platformConnectivityConfig = union(groupDefaults, {
  managementGroupName: 'connectivity'
  managementGroupParentId: 'platform'
  managementGroupDisplayName: 'Connectivity'
  managementGroupExcludedPolicyAssignments: ['Enable-DDoS-VNET']
})
