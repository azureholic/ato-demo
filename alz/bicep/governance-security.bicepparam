using './upstream/templates/core/governance/mgmt-groups/platform/platform-security/main.bicep'
import { settings, groupDefaults } from './governance-settings.bicep'

param parLocations = [settings.location]
param platformSecurityConfig = union(groupDefaults, {
  managementGroupName: 'security'
  managementGroupParentId: 'platform'
  managementGroupDisplayName: 'Security'
})
