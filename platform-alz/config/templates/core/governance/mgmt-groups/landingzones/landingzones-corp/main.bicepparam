using './main.bicep'
import { settings, groupDefaults } from '../../../smb-settings.bicep'

param parLocations = [settings.location]
param landingZonesCorpConfig = union(groupDefaults, {
  managementGroupName: 'corp'
  managementGroupParentId: 'landingzones'
  managementGroupDisplayName: 'Corp'
  managementGroupExcludedPolicyAssignments: ['Deploy-Private-DNS-Zones']
})
