param name string
param location string
param tags object

// RDP only, from the VirtualNetwork tag, which covers the Azure platform address (168.63.129.16) that Bastion
// Developer connects from. Everything else inbound stays denied by the default rules.
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowRdpFromVirtualNetwork'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

output nsgId string = nsg.id
