// Overlay for the pinned Citadel access-contract template. Invoke-WebIqAgent.ps1 copies this
// file, ai-product-policy.xml and config/deployment.json into the upstream checkout at
// bicep/infra/citadel-access-contracts/contracts/platform/web-research/demo/, so the `using`
// path resolves there and not inside this repository.
using '../../../../main.bicep'

var config = loadJsonContent('deployment.json')

param apim = {
  subscriptionId: config.subscriptionId
  resourceGroupName: config.governanceHub.resourceGroupName
  name: readEnvironmentVariable('HUB_APIM_NAME')
}

// Required by the template even though Key Vault publishing is disabled.
param useTargetAzureKeyVault = false
param keyVault = {
  subscriptionId: config.subscriptionId
  resourceGroupName: config.governanceHub.resourceGroupName
  name: 'unused'
}

param useCase = {
  businessUnit: config.accessContract.businessUnit
  useCaseName: config.accessContract.useCaseName
  environment: config.accessContract.environment
}

param apiNameMapping = {
  LLM: [config.accessContract.apiName]
}

param services = [
  {
    code: 'LLM'
    endpointSecretName: 'WEBRESEARCH-LLM-ENDPOINT'
    apiKeySecretName: 'WEBRESEARCH-LLM-KEY'
    foundryApiName: config.accessContract.apiName
    policyXml: loadTextContent('ai-product-policy.xml')
  }
]

param productTerms = 'Read-only public-web research agent. Prompts may contain public queries only; no confidential enterprise content.'

// The Foundry project connection is created by Invoke-WebIqAgent.ps1 (infra/hub-model-connection.bicep), not by
// this template: the upstream module targets '<gateway>/<api path>', but the OpenAI-compatible routes of
// unified-ai-api live under '<gateway>/unified-ai/v1'. The ApiKey auth type keeps the contract independent of
// the Hub's JWT named values; ProjectManagedIdentity would also need jwtRequired/jwtAudience in the product policy.
param useTargetFoundry = false
