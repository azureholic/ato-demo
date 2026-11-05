using './upstream/templates/networking/hubnetworking/main.bicep'

var settings = loadJsonContent('../config/demo.json')
var location = settings.location

param parLocations = [location]
param parTags = settings.tags
param parHubNetworkingResourceGroupNamePrefix = 'rg-hub'
param parDnsResourceGroupNamePrefix = 'rg-hub-dns'
param parDnsPrivateResolverResourceGroupNamePrefix = 'rg-hub-resolver'
param hubNetworks = [
  {
    name: 'vnet-hub-${location}'
    location: location
    addressPrefixes: [settings.hubAddressPrefix]
    deployPeering: false
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        addressPrefix: '10.100.0.0/26'
      }
      {
        name: 'AzureFirewallManagementSubnet'
        addressPrefix: '10.100.0.64/26'
      }
    ]
    azureFirewallSettings: {
      deployAzureFirewall: true
      azureFirewallName: 'afw-hub-${location}'
      azureSkuTier: 'Basic'
      zones: []
      publicIPAddressObject: { name: 'pip-afw-hub-${location}' }
      managementIPAddressObject: { name: 'pip-afw-management-${location}' }
    }
    bastionHostSettings: { deployBastion: false }
    vpnGatewaySettings: {
      deployVpnGateway: false
      skuName: 'VpnGw1AZ'
    }
    expressRouteGatewaySettings: { deployExpressRouteGateway: false }
    privateDnsSettings: {
      deployPrivateDnsZones: false
      deployDnsPrivateResolver: false
    }
    ddosProtectionPlanSettings: { deployDdosProtectionPlan: false }
  }
]
