targetScope = 'subscription'

var config = loadJsonContent('../deployment.json')
var network = config.networking

resource spokeGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: network.resourceGroupName
  location: config.location
  tags: config.tags
}

module spoke '../bicep/infra/modules/networking/vnet.bicep' = {
  name: 'govhub-spoke-vnet'
  scope: spokeGroup
  params: {
    name: network.vnetName
    location: config.location
    tags: config.tags
    apimSubnetName: network.apimSubnetName
    apimNsgName: 'nsg-apim-${network.vnetName}'
    privateEndpointSubnetName: network.privateEndpointSubnetName
    privateEndpointNsgName: 'nsg-pe-${network.vnetName}'
    functionAppSubnetName: network.functionAppSubnetName
    functionAppNsgName: 'nsg-logic-${network.vnetName}'
    apimRouteTableName: 'rt-apim-${network.vnetName}'
    vnetAddressPrefix: config.vnetAddressPrefix
    apimSubnetAddressPrefix: config.apimSubnetPrefix
    privateEndpointSubnetAddressPrefix: config.privateEndpointSubnetPrefix
    functionAppSubnetAddressPrefix: config.functionAppSubnetPrefix
    isAPIMV2SKU: config.apimSku == 'StandardV2' || config.apimSku == 'PremiumV2'
    enableAgentSubnet: false
    privateDnsZoneNames: []
  }
}

module spokeToHub './peering.bicep' = {
  name: 'govhub-spoke-to-hub'
  scope: spokeGroup
  params: {
    vnetName: network.vnetName
    peeringName: 'to-${network.hub.vnetName}'
    remoteVnetId: resourceId(network.hub.subscriptionId, network.hub.resourceGroupName, 'Microsoft.Network/virtualNetworks', network.hub.vnetName)
  }
  dependsOn: [spoke]
}

module hubToSpoke './peering.bicep' = {
  name: 'govhub-hub-to-spoke'
  scope: resourceGroup(network.hub.subscriptionId, network.hub.resourceGroupName)
  params: {
    vnetName: network.hub.vnetName
    peeringName: 'to-${network.vnetName}'
    remoteVnetId: spoke.outputs.virtualNetworkId
  }
}

output vnetId string = spoke.outputs.virtualNetworkId
