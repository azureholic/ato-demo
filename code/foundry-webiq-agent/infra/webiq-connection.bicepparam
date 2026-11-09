using 'webiq-connection.bicep'

var config = loadJsonContent('../config/deployment.json')

param accountName = readEnvironmentVariable('FOUNDRY_ACCOUNT_NAME')
param projectName = readEnvironmentVariable('FOUNDRY_PROJECT_NAME')
param connectionName = config.webIq.connectionName
param serverUrl = config.webIq.serverUrl
param apiKeyHeader = config.webIq.apiKeyHeader
param apiKey = readEnvironmentVariable('WEBIQ_API_KEY')
