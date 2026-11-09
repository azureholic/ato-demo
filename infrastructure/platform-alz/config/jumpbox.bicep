// Jumpbox in the platform hub: a subnet in the existing hub VNet, Bastion Developer, and an Ubuntu VM.
// The subnet is a child resource of the ALZ hub VNet. The accelerator's VNet module writes subnets as
// child resources too, so re-running ALZ does not remove it.
targetScope = 'subscription'

var config = loadJsonContent('./jumpbox.json')

@secure()
@description('Local administrator password of the Windows VM; supplied from JUMPBOX_ADMIN_PASSWORD.')
param adminPassword string

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: config.resourceGroupName
  location: config.location
  tags: config.tags
}

module security './jumpbox-nsg.bicep' = {
  name: 'jumpbox-nsg'
  scope: group
  params: {
    name: config.nsgName
    location: config.location
    tags: config.tags
  }
}

module subnet './jumpbox-subnet.bicep' = {
  name: 'jumpbox-subnet'
  scope: resourceGroup(config.hub.resourceGroupName)
  params: {
    vnetName: config.hub.vnetName
    subnetName: config.subnet.name
    addressPrefix: config.subnet.addressPrefix
    nsgId: security.outputs.nsgId
    routeTableName: config.hub.routeTableName
  }
}

module host './jumpbox-vm.bicep' = {
  name: 'jumpbox-vm'
  scope: group
  params: {
    location: config.location
    tags: config.tags
    vmName: config.vm.name
    vmSize: config.vm.size
    adminUsername: config.vm.adminUsername
    adminPassword: adminPassword
    osDiskSku: config.vm.osDiskSku
    osDiskSizeGB: config.vm.osDiskSizeGB
    image: config.vm.image
    subnetId: subnet.outputs.subnetId
    vnetId: subnet.outputs.vnetId
    bastionName: config.bastionName
  }
}

output vmId string = host.outputs.vmId
output privateIpAddress string = host.outputs.privateIpAddress
output bastionId string = host.outputs.bastionId
