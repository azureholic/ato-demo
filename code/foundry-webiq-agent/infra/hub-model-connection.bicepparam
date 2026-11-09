using 'hub-model-connection.bicep'

var config = loadJsonContent('../config/deployment.json')

param accountName = readEnvironmentVariable('FOUNDRY_ACCOUNT_NAME')
param projectName = readEnvironmentVariable('FOUNDRY_PROJECT_NAME')
param connectionName = '${config.accessContract.connectionNamePrefix}-LLM'
param targetUrl = '${readEnvironmentVariable('HUB_GATEWAY_URL')}/${config.accessContract.foundryBasePath}'
param apiKey = readEnvironmentVariable('HUB_API_KEY')
param modelName = config.model.name
param modelVersion = config.model.version
