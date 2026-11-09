@description('Existing Foundry (AI Services) account.')
param accountName string

@description('Existing Foundry project.')
param projectName string

param connectionName string

@description('Web IQ MCP endpoint.')
param serverUrl string = 'https://api.microsoft.ai/v3/mcp'

@description('Header that carries the Web IQ API key.')
param apiKeyHeader string = 'x-apikey'

@secure()
param apiKey string

resource account 'Microsoft.CognitiveServices/accounts@2026-03-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-03-01' existing = {
  parent: account
  name: projectName
}

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-03-01' = {
  parent: project
  name: connectionName
  properties: {
    category: 'RemoteTool'
    target: serverUrl
    authType: 'CustomKeys'
    isSharedToAll: true
    credentials: {
      keys: {
        '${apiKeyHeader}': apiKey
      }
    }
    metadata: {
      type: 'web_iq_mcp'
    }
  }
}

output connectionId string = connection.id
