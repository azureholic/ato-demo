@description('Central platform private DNS zone names required by connected workloads.')
param zoneNames string[]

@description('All VNets discovered in the configured platform and workload subscriptions.')
param virtualNetworkIds string[]

param tags object = {
  source: 'Platform private DNS'
}

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zoneName in zoneNames: {
  name: zoneName
  location: 'global'
  tags: tags
}]

var links = flatten(map(zoneNames, zone => map(virtualNetworkIds, vnetId => {
  zoneName: zone
  vnetId: vnetId
})))

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for link in links: {
  name: '${link.zoneName}/vnet-${uniqueString(link.vnetId)}'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: {
      id: link.vnetId
    }
    registrationEnabled: false
  }
  dependsOn: [zones]
}]
