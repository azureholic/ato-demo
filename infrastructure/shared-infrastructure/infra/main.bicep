targetScope = 'subscription'
param config object

var network = config.networking
resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: network.resourceGroupName
  location: config.location
  tags: config.tags
}
module spoke './modules/vnet.bicep' = {
  name: '${network.vnetName}-network'
  scope: group
  params: { config: config }
}
module forward '../../ai-governance-hub/networking/peering.bicep' = {
  name: '${network.vnetName}-to-hub'
  scope: group
  params: {
    vnetName: network.vnetName
    peeringName: 'peer-${network.vnetName}-to-hub'
    remoteVnetId: resourceId(network.hub.subscriptionId, network.hub.resourceGroupName, 'Microsoft.Network/virtualNetworks', network.hub.vnetName)
  }
  dependsOn: [spoke]
}
module reverse '../../ai-governance-hub/networking/peering.bicep' = {
  name: 'hub-to-${network.vnetName}'
  scope: resourceGroup(network.hub.subscriptionId, network.hub.resourceGroupName)
  params: {
    vnetName: network.hub.vnetName
    peeringName: 'peer-hub-to-${network.vnetName}'
    remoteVnetId: spoke.outputs.vnetId
  }
}
output vnetId string = spoke.outputs.vnetId
