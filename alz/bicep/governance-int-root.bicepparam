using './upstream/templates/core/governance/mgmt-groups/int-root/main.bicep'
import { settings, groupDefaults, rootOverrides } from './governance-settings.bicep'

param parLocations = [settings.location]
param intRootConfig = union(groupDefaults, {
  createOrUpdateManagementGroup: false
  managementGroupName: settings.intermediateRootManagementGroupId
  managementGroupParentId: settings.tenantId
  managementGroupDisplayName: 'Azure Landing Zones'
})
param parPolicyAssignmentParameterOverrides = rootOverrides
