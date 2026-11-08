param config object

var network = config.networking

resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-${network.vnetName}'
  location: config.location
  tags: config.tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'hub-egress'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: network.egressNextHopIp
        }
      }
    ]
  }
}

resource nsgs 'Microsoft.Network/networkSecurityGroups@2024-05-01' = [for subnet in network.subnets: {
  name: 'nsg-${network.vnetName}-${subnet.name}'
  location: config.location
  tags: config.tags
  properties: { securityRules: [] }
}]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: network.vnetName
  location: config.location
  tags: config.tags
  properties: {
    addressSpace: { addressPrefixes: [network.addressPrefix] }
    dhcpOptions: { dnsServers: [] }
    subnets: [for (subnet, index) in network.subnets: {
      name: subnet.name
      properties: {
        addressPrefix: subnet.addressPrefix
        routeTable: { id: routeTable.id }
        networkSecurityGroup: { id: nsgs[index].id }
        privateEndpointNetworkPolicies: 'Disabled'
        delegations: empty(subnet.delegation) ? [] : [
          {
            name: 'delegation'
            properties: { serviceName: subnet.delegation }
          }
        ]
        serviceEndpoints: map(subnet.serviceEndpoints, service => { service: service })
      }
    }]
  }
}

output vnetId string = vnet.id
