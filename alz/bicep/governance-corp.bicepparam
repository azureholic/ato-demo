using './upstream/templates/core/governance/mgmt-groups/landingzones/landingzones-corp/main.bicep'
import { settings, groupDefaults } from './governance-settings.bicep'

param parLocations = [settings.location]
param landingZonesCorpConfig = union(groupDefaults, {
  managementGroupName: 'corp'
  managementGroupParentId: 'landingzones'
  managementGroupDisplayName: 'Corp'
  managementGroupExcludedPolicyAssignments: ['Deploy-Private-DNS-Zones']
})
