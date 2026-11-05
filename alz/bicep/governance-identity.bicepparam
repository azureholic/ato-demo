using './upstream/templates/core/governance/mgmt-groups/platform/platform-identity/main.bicep'
import { settings, groupDefaults } from './governance-settings.bicep'

param parLocations = [settings.location]
param platformIdentityConfig = union(groupDefaults, {
  managementGroupName: 'identity'
  managementGroupParentId: 'platform'
  managementGroupDisplayName: 'Identity'
})
