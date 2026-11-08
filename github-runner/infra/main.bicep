param config object
param dns object
param deployJob bool = false
param runnerImage string = ''
param githubAppId string
param githubInstallationId string
param githubAppKeyExpiresOn int
@secure()
param githubAppPrivateKey string

var suffix = uniqueString(subscription().subscriptionId, resourceGroup().id)
var registryName = '${config.registryNamePrefix}${suffix}'
var vaultName = '${config.keyVaultNamePrefix}-${suffix}'
var vnetId = resourceId('Microsoft.Network/virtualNetworks', config.networking.vnetName)
var peSubnetId = '${vnetId}/subnets/snet-private-endpoints'
var dnsId = '/subscriptions/${dns.subscriptionId}/resourceGroups/${dns.resourceGroupName}/providers/Microsoft.Network/privateDnsZones'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-github-runner'
  location: config.location
  tags: config.tags
}
resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: registryName
  location: config.location
  tags: config.tags
  sku: { name: 'Premium' }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Disabled'
    dataEndpointEnabled: true
    networkRuleBypassOptions: 'AzureServices'
    policies: {
      retentionPolicy: { status: 'enabled', days: 30 }
      // A separate image-verification/release pipeline is required before enabling quarantine.
      quarantinePolicy: { status: 'disabled' }
    }
  }
}
resource pool 'Microsoft.ContainerRegistry/registries/agentPools@2019-06-01-preview' = {
  parent: registry
  name: config.buildPoolName
  location: config.location
  tags: config.tags
  properties: {
    count: 1
    tier: 'S2'
    os: 'Linux'
    virtualNetworkSubnetResourceId: '${vnetId}/subnets/snet-acr-build'
  }
}
resource pull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, identity.id, 'AcrPull')
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}
resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: vaultName
  location: config.location
  tags: config.tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
  }
}
resource privateKey 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: vault
  name: 'github-app-private-key'
  properties: {
    value: githubAppPrivateKey
    contentType: 'application/x-pem-file'
    attributes: { exp: githubAppKeyExpiresOn }
  }
}
resource secretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, identity.id, 'KeyVaultSecretsUser')
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

var privateServices = [
  { name: 'registry', id: registry.id, group: 'registry', zones: [dns.zones.containerRegistry] }
  { name: 'vault', id: vault.id, group: 'vault', zones: [dns.zones.keyVault] }
]
@batchSize(1)
resource privateEndpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [for service in privateServices: {
  name: 'pe-github-${service.name}'
  location: config.location
  tags: config.tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: service.name
        properties: { privateLinkServiceId: service.id, groupIds: [service.group] }
      }
    ]
  }
}]
resource zoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [for (service, index) in privateServices: {
  parent: privateEndpoints[index]
  name: 'platform'
  properties: {
    privateDnsZoneConfigs: [for zone in service.zones: {
      name: replace(zone, '.', '-')
      properties: { privateDnsZoneId: '${dnsId}/${zone}' }
    }]
  }
}]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-github-runner'
  location: config.location
  tags: config.tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}
resource monitorScope 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
  name: 'ampls-github-runner'
  location: 'global'
  tags: config.tags
  properties: { accessModeSettings: { ingestionAccessMode: 'PrivateOnly', queryAccessMode: 'PrivateOnly' } }
}
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-github-runner'
  location: config.location
  tags: config.tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}
resource monitorInsights 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: monitorScope
  name: 'runner-insights'
  properties: { linkedResourceId: appInsights.id }
}
resource monitorWorkspace 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: monitorScope
  name: 'runner-workspace'
  properties: { linkedResourceId: workspace.id }
}
resource monitorEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-github-monitor'
  location: config.location
  tags: config.tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      { name: 'monitor', properties: { privateLinkServiceId: monitorScope.id, groupIds: ['azuremonitor'] } }
    ]
  }
  dependsOn: [monitorWorkspace, monitorInsights, privateEndpoints]
}
resource monitorZones 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: monitorEndpoint
  name: 'platform'
  properties: {
    privateDnsZoneConfigs: [for zone in [dns.zones.azureMonitor, dns.zones.omsOpsInsights, dns.zones.odsOpsInsights, dns.zones.azureAutomation]: {
      name: replace(zone, '.', '-')
      properties: { privateDnsZoneId: '${dnsId}/${zone}' }
    }]
  }
}
resource environment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: config.environmentName
  location: config.location
  tags: config.tags
  properties: {
    publicNetworkAccess: 'Disabled'
    vnetConfiguration: { infrastructureSubnetId: '${vnetId}/subnets/snet-containerapps', internal: true }
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    appLogsConfiguration: { destination: 'azure-monitor' }
  }
}
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: environment
  name: 'runner-logs'
  properties: {
    workspaceId: workspace.id
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}
resource job 'Microsoft.App/jobs@2025-01-01' = if (deployJob) {
  name: config.jobName
  location: config.location
  tags: config.tags
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${identity.id}': {} } }
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Event'
      replicaTimeout: config.replicaTimeout
      replicaRetryLimit: 0
      registries: [{ server: registry.properties.loginServer, identity: identity.id }]
      secrets: [{ name: 'github-app-key', keyVaultUrl: '${vault.properties.vaultUri}secrets/${privateKey.name}', identity: identity.id }]
      eventTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
        scale: {
          minExecutions: 0
          maxExecutions: config.maxExecutions
          pollingInterval: 30
          rules: [
            {
              name: 'github'
              type: 'github-runner'
              metadata: {
                githubApiURL: 'https://api.github.com'
                owner: config.repositoryOwner
                runnerScope: 'repo'
                repos: config.repositoryName
                labels: config.runnerLabel
                noDefaultLabels: 'true'
                targetWorkflowQueueLength: '1'
                applicationID: githubAppId
                installationID: githubInstallationId
              }
              auth: [{ triggerParameter: 'appKey', secretRef: 'github-app-key' }]
            }
          ]
        }
      }
    }
    template: {
      containers: [
        {
          name: 'runner'
          image: runnerImage
          resources: { cpu: 2, memory: '4Gi' }
          env: [
            { name: 'GITHUB_APP_ID', value: githubAppId }
            { name: 'GITHUB_INSTALLATION_ID', value: githubInstallationId }
            { name: 'GITHUB_APP_PRIVATE_KEY', secretRef: 'github-app-key' }
            { name: 'GH_URL', value: 'https://github.com/${config.repositoryOwner}/${config.repositoryName}' }
            { name: 'RUNNER_LABELS', value: config.runnerLabel }
            { name: 'GITHUB_REPOSITORY', value: '${config.repositoryOwner}/${config.repositoryName}' }
          ]
        }
      ]
    }
  }
  dependsOn: [pull, secretsUser, privateEndpoints, zoneGroups]
}

output registryName string = registry.name
output registryId string = registry.id
output registryEndpoint string = registry.properties.loginServer
output keyVaultName string = vault.name
output workspaceId string = workspace.id
output appInsightsId string = appInsights.id
