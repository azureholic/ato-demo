targetScope = 'subscription'
param config object

module forward '../../ai-governance-hub/networking/peering.bicep' = [for target in config.targetNetworks: {
  name: '${config.networking.vnetName}-to-${target.vnetName}'
  scope: resourceGroup(config.subscriptionId, config.networking.resourceGroupName)
  params: {
    vnetName: config.networking.vnetName
    peeringName: 'to-${target.vnetName}'
    remoteVnetId: resourceId(target.subscriptionId, target.resourceGroupName, 'Microsoft.Network/virtualNetworks', target.vnetName)
  }
}]
module reverse '../../ai-governance-hub/networking/peering.bicep' = [for target in config.targetNetworks: {
  name: '${target.vnetName}-to-${config.networking.vnetName}'
  scope: resourceGroup(target.subscriptionId, target.resourceGroupName)
  params: {
    vnetName: target.vnetName
    peeringName: 'to-${config.networking.vnetName}'
    remoteVnetId: resourceId(config.subscriptionId, config.networking.resourceGroupName, 'Microsoft.Network/virtualNetworks', config.networking.vnetName)
  }
}]
