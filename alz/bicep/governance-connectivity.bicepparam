using './upstream/templates/core/governance/mgmt-groups/platform/platform-connectivity/main.bicep'
import { settings, groupDefaults } from './governance-settings.bicep'

param parLocations = [settings.location]
param platformConnectivityConfig = union(groupDefaults, {
  managementGroupName: 'connectivity'
  managementGroupParentId: 'platform'
  managementGroupDisplayName: 'Connectivity'
  managementGroupExcludedPolicyAssignments: ['Enable-DDoS-VNET']
})
