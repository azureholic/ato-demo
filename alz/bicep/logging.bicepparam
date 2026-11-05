using './upstream/templates/core/logging/main.bicep'

var settings = loadJsonContent('../config/demo.json')
var location = settings.location

param parLocations = [location]
param parTags = settings.tags
param parGlobalResourceLock = { kind: 'None' }
param parMgmtLoggingResourceGroup = 'rg-management-${location}'
param parAutomationAccountName = 'aa-management-${location}'
param parDeployAutomationAccount = false
param parAutomationAccountLocation = location
param parLogAnalyticsWorkspaceName = 'law-management-${location}'
param parLogAnalyticsWorkspaceLocation = location
param parLogAnalyticsWorkspaceLogRetentionInDays = 30
param parLogAnalyticsWorkspaceSolutions = ['ChangeTracking']
param parUserAssignedIdentityName = 'uami-management-ama-${location}'
param parDataCollectionRuleVMInsightsName = 'dcr-vm-insights'
param parDataCollectionRuleChangeTrackingName = 'dcr-change-tracking'
param parDataCollectionRuleMDFCSQLName = 'dcr-defender-sql'
