@description('Existing Foundry (AI Services) account.')
param accountName string

@description('Existing Foundry project.')
param projectName string

@description('Connection name; agents reference the model as <connectionName>/<modelName>.')
param connectionName string

@description('OpenAI-compatible gateway base URL, e.g. https://<apim>/unified-ai/v1. Foundry appends the route.')
param targetUrl string

@secure()
@description('APIM subscription key of the access contract.')
param apiKey string

param modelName string
param modelVersion string
param modelFormat string = 'OpenAI'
param isSharedToAll bool = true

var staticModels = [
  {
    name: modelName
    properties: {
      model: {
        name: modelName
        version: modelVersion
        format: modelFormat
      }
    }
  }
]

resource account 'Microsoft.CognitiveServices/accounts@2026-03-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-03-01' existing = {
  parent: account
  name: projectName
}

// Same shape the upstream access-contract module writes for ApiKey connections, with an explicit base URL.
// deploymentInPath 'false' puts the model name in the request body (OpenAI v1 style); no api-version is sent.
// upstreamSurface 'responses' is the property behind the portal's "Use the Responses API for upstream requests":
// Foundry then appends /responses to the target instead of /chat/completions. gpt-6-astra rejects function tools
// on Chat Completions, so agent calls must reach the Hub's Responses route (<target>/responses).
resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-03-01' = {
  parent: project
  name: connectionName
  properties: {
    category: 'ApiManagement'
    target: targetUrl
    authType: 'ApiKey'
    isSharedToAll: isSharedToAll
    credentials: {
      key: apiKey
    }
    metadata: {
      deploymentInPath: 'false'
      upstreamSurface: 'responses'
      customHeaders: '{}'
      models: string(staticModels)
    }
  }
}

output connectionId string = connection.id
