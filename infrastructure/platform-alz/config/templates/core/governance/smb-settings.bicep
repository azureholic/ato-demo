@export()
var settings = loadJsonContent('../../smb.json')
var subscriptionId = settings.subscriptionId
var location = settings.location
@export()
var locationShort = substring(location, 0, 3)
var managementResourceGroupId = '/subscriptions/${subscriptionId}/resourceGroups/rg-management-${locationShort}'
@export()
var workspaceId = '${managementResourceGroupId}/providers/Microsoft.OperationalInsights/workspaces/law-management-${locationShort}'
var amaIdentityId = '${managementResourceGroupId}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami-management-ama-${locationShort}'
var changeTrackingDcrId = '${managementResourceGroupId}/providers/Microsoft.Insights/dataCollectionRules/dcr-change-tracking'
var vmInsightsDcrId = '${managementResourceGroupId}/providers/Microsoft.Insights/dataCollectionRules/dcr-vm-insights'
var defenderSqlDcrId = '${managementResourceGroupId}/providers/Microsoft.Insights/dataCollectionRules/dcr-defender-sql'

@export()
var groupDefaults = {
  createOrUpdateManagementGroup: true
  managementGroupIntermediateRootName: settings.intermediateRootManagementGroupId
  waitForConsistencyCounterBeforeCustomPolicyDefinitions: 10
  waitForConsistencyCounterBeforeCustomPolicySetDefinitions: 10
  waitForConsistencyCounterBeforeCustomRoleDefinitions: 10
  waitForConsistencyCounterBeforePolicyAssignments: 40
  waitForConsistencyCounterBeforeRoleAssignments: 40
  waitForConsistencyCounterBeforeSubPlacement: 10
}

var defenderServices = [
  'enableAscForServers'
  'enableAscForServersVulnerabilityAssessments'
  'enableAscForSql'
  'enableAscForAppServices'
  'enableAscForStorage'
  'enableAscForContainers'
  'enableAscForKeyVault'
  'enableAscForSqlOnVm'
  'enableAscForArm'
  'enableAscForOssDb'
  'enableAscForCosmosDbs'
  'enableAscForCspm'
]

@export()
var rootOverrides = {
  'Deploy-MDFC-Config-H224': {
    parameters: union(toObject(defenderServices, service => service, service => { value: 'DeployIfNotExists' }), {
      logAnalytics: { value: workspaceId }
      emailSecurityContact: { value: settings.securityContactEmail }
      ascExportResourceGroupName: { value: 'rg-asc-export-${locationShort}' }
      ascExportResourceGroupLocation: { value: location }
    })
  }
  'Deploy-AzActivity-Log': {
    parameters: { logAnalytics: { value: workspaceId } }
  }
  'Deploy-Diag-LogsCat': {
    parameters: { logAnalytics: { value: workspaceId } }
  }
  'Deploy-SvcHealth-BuiltIn': {
    parameters: {
      resourceGroupName: { value: 'rg-service-health-alerts-${locationShort}' }
      resourceGroupLocation: { value: location }
      actionGroupResources: {
        value: {
          actionGroupEmail: [settings.securityContactEmail]
          eventHubResourceId: []
          functionResourceId: ''
          functionTriggerUrl: ''
          logicappCallbackUrl: ''
          logicappResourceId: ''
          webhookServiceUri: []
        }
      }
    }
  }
}

@export()
var monitoringOverrides = {
  'Deploy-VM-ChangeTrack': {
    parameters: {
      dcrResourceId: { value: changeTrackingDcrId }
      userAssignedIdentityResourceId: { value: amaIdentityId }
    }
  }
  'Deploy-VMSS-ChangeTrack': {
    parameters: {
      dcrResourceId: { value: changeTrackingDcrId }
      userAssignedIdentityResourceId: { value: amaIdentityId }
    }
  }
  'Deploy-VM-Monitoring': {
    parameters: {
      dcrResourceId: { value: vmInsightsDcrId }
      userAssignedIdentityResourceId: { value: amaIdentityId }
    }
  }
  'Deploy-VMSS-Monitoring': {
    parameters: {
      dcrResourceId: { value: vmInsightsDcrId }
      userAssignedIdentityResourceId: { value: amaIdentityId }
    }
  }
  'Deploy-vmArc-ChangeTrack': {
    parameters: { dcrResourceId: { value: changeTrackingDcrId } }
  }
  'Deploy-vmHybr-Monitoring': {
    parameters: { dcrResourceId: { value: vmInsightsDcrId } }
  }
  'Deploy-MDFC-DefSQL-AMA': {
    parameters: {
      userWorkspaceResourceId: { value: workspaceId }
      dcrResourceId: { value: defenderSqlDcrId }
      userAssignedIdentityResourceId: { value: amaIdentityId }
      workspaceRegion: { value: location }
    }
  }
  'DenyAction-DeleteUAMIAMA': {
    parameters: { resourceName: { value: 'uami-management-ama-${locationShort}' } }
  }
}
