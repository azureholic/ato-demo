@description('Existing central platform private DNS zone names.')
param zoneNames string[]

@description('VNets to link to the existing central zones.')
param virtualNetworkIds string[]

param tags object = {
  source: 'Platform private DNS'
}

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' existing = [for zoneName in zoneNames: {
  name: zoneName
}]

var links = flatten(map(zoneNames, zone => map(virtualNetworkIds, vnetId => {
  zoneName: zone
  vnetId: vnetId
})))

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for link in links: {
  parent: zones[indexOf(zoneNames, link.zoneName)]
  name: 'vnet-${uniqueString(link.vnetId)}'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: {
      id: link.vnetId
    }
    registrationEnabled: false
  }
}]
