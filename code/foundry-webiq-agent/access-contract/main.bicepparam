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

// Creates the project connection '<connectionNamePrefix>-LLM' used as '<connection>/<model>' by the agent.
param useTargetFoundry = true
param foundry = {
  subscriptionId: config.subscriptionId
  resourceGroupName: config.foundry.resourceGroupName
  accountName: readEnvironmentVariable('FOUNDRY_ACCOUNT_NAME')
  projectName: readEnvironmentVariable('FOUNDRY_PROJECT_NAME')
}

// ApiKey keeps the contract independent of the Hub's JWT named values. ProjectManagedIdentity
// additionally requires jwtRequired/jwtAudience in the product policy and the project MI client ID.
param foundryConfig = {
  connectionNamePrefix: config.accessContract.connectionNamePrefix
  authType: 'ApiKey'
  deploymentInPath: 'true'
  isSharedToAll: true
  inferenceAPIVersion: config.model.apiVersion
  staticModels: [
    {
      name: config.model.name
      properties: {
        model: {
          name: config.model.name
          version: config.model.version
          format: 'OpenAI'
        }
      }
    }
  ]
}
