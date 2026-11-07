using './main.bicep'

var config = loadJsonContent('./deployment.json')

param environmentName = config.environmentName
param location = config.location
param apicLocation = config.location
param resourceGroupName = config.resourceGroupName
param tags = union(config.tags, { 'azd-env-name': config.environmentName })

param apimSku = config.apimSku
param apimSkuUnits = config.apimSkuUnits
param useExistingVnet = false
param vnetAddressPrefix = config.vnetAddressPrefix
param apimSubnetPrefix = config.apimSubnetPrefix
param privateEndpointSubnetPrefix = config.privateEndpointSubnetPrefix
param functionAppSubnetPrefix = config.functionAppSubnetPrefix
param foundryNetworkInjectionEnabled = false
param useExistingLogAnalytics = false

param apimV2UsePrivateEndpoint = true
param apimV2PublicNetworkAccess = true
param logicAppUsePrivateEndpoint = false
param logicAppPublicNetworkAccess = true
param cosmosDbPublicAccess = 'Disabled'
param eventHubNetworkAccess = 'Enabled'
param aiFoundryExternalNetworkAccess = 'Disabled'
param keyVaultExternalNetworkAccess = 'Disabled'

param enableAIModelInference = true
param enableUnifiedAiApi = true
param enableOpenAIRealtime = false
param enableDocumentIntelligence = false
param enableAzureAISearch = false
param enableAPICenter = false
param enableManagedRedis = false
param enableAIGatewayPiiRedaction = true
param createAppInsightsDashboards = false
param entraAuth = false
param eventHubCapacityUnits = 1
param cosmosDbRUs = 400
param logicAppsSkuCapacityUnits = 1

param aiFoundryInstances = config.aiFoundryInstances

// Explicit indices are required for upstream APIM supportedModels grouping.
param aiFoundryModelsConfig = [
  union(config.model, { aiserviceIndex: 0 })
  union(config.model, { aiserviceIndex: 1 })
]

param azureMonitorLogSettings = {
  frontend: {
    request: { headers: [], body: { bytes: 0 } }
    response: { headers: [], body: { bytes: 0 } }
  }
  backend: {
    request: { headers: [], body: { bytes: 0 } }
    response: { headers: [], body: { bytes: 0 } }
  }
  largeLanguageModel: {
    logs: 'disabled'
    requests: { messages: 'all', maxSizeInBytes: 1 }
    responses: { messages: 'all', maxSizeInBytes: 1 }
  }
}

param appInsightsLogSettings = {
  headers: []
  body: { bytes: 0 }
}
