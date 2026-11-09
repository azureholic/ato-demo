param name string
param location string
param tags object

// Bastion Developer reaches the VM from the Azure platform address 168.63.129.16, which the VirtualNetwork
// tag covers. Everything else inbound stays denied by the default rules.
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSshFromVirtualNetwork'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

output nsgId string = nsg.id
