param vnetName string
param subnetName string
param addressPrefix string
param nsgId string
param routeTableName string

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource routeTable 'Microsoft.Network/routeTables@2024-05-01' existing = {
  name: routeTableName
}

// Private subnet: no default outbound access. Internet goes through the hub firewall (default route) and only
// to the FQDNs allowed by the jumpbox firewall rule group. Peered spokes are reached directly over peering.
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: subnetName
  properties: {
    addressPrefix: addressPrefix
    networkSecurityGroup: { id: nsgId }
    routeTable: { id: routeTable.id }
    defaultOutboundAccess: false
  }
}

output subnetId string = subnet.id
output vnetId string = vnet.id
