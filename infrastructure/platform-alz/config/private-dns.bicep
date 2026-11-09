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

module zoneLinks './private-dns-links.bicep' = {
  name: 'platform-private-dns-links'
  params: {
    zoneNames: zoneNames
    virtualNetworkIds: virtualNetworkIds
    tags: tags
  }
  dependsOn: [zones]
}
