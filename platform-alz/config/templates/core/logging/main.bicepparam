using './main.bicep'
import { settings, locationShort } from '../governance/smb-settings.bicep'

var location = settings.location

param parLocations = [location]
param parTags = settings.tags
param parGlobalResourceLock = { kind: 'None' }
param parMgmtLoggingResourceGroup = 'rg-management-${locationShort}'
param parAutomationAccountName = 'aa-management-${locationShort}'
param parDeployAutomationAccount = false
param parAutomationAccountLocation = location
param parLogAnalyticsWorkspaceName = 'law-management-${locationShort}'
param parLogAnalyticsWorkspaceLocation = location
param parLogAnalyticsWorkspaceLogRetentionInDays = 30
param parLogAnalyticsWorkspaceSolutions = ['ChangeTracking']
param parUserAssignedIdentityName = 'uami-management-ama-${locationShort}'
param parDataCollectionRuleVMInsightsName = 'dcr-vm-insights'
param parDataCollectionRuleChangeTrackingName = 'dcr-change-tracking'
param parDataCollectionRuleMDFCSQLName = 'dcr-defender-sql'
