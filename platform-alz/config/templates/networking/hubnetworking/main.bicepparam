using './main.bicep'
import { settings, locationShort } from '../../core/governance/smb-settings.bicep'

var location = settings.location

param parLocations = [location]
param parTags = settings.tags
param parHubNetworkingResourceGroupNamePrefix = 'rg-hub'
param parHubNetworkingResourceGroupNameOverrides = ['rg-hub-${locationShort}']
param parDnsResourceGroupNamePrefix = 'rg-hub-dns'
param parDnsResourceGroupNameOverrides = ['rg-hub-dns-${locationShort}']
param parDnsPrivateResolverResourceGroupNamePrefix = 'rg-hub-resolver'
param parDnsPrivateResolverResourceGroupNameOverrides = ['rg-hub-resolver-${locationShort}']
param hubNetworks = [
  {
    name: 'vnet-hub-${locationShort}'
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
      azureFirewallName: 'afw-hub-${locationShort}'
      azureSkuTier: 'Basic'
      zones: []
      publicIPAddressObject: { name: 'pip-afw-hub-${locationShort}' }
      managementIPAddressObject: { name: 'pip-afw-management-${locationShort}' }
    }
    bastionHostSettings: {
      deployBastion: false
      bastionHostSettingsName: 'bas-hub-${locationShort}'
      bastionNsgName: 'nsg-bas-hub-${locationShort}'
    }
    vpnGatewaySettings: {
      deployVpnGateway: false
      name: 'vgw-hub-${locationShort}'
      skuName: 'VpnGw1AZ'
    }
    expressRouteGatewaySettings: {
      deployExpressRouteGateway: false
      name: 'ergw-hub-${locationShort}'
    }
    privateDnsSettings: {
      deployPrivateDnsZones: false
      deployDnsPrivateResolver: false
      privateDnsResolverName: 'dnspr-hub-${locationShort}'
    }
    ddosProtectionPlanSettings: {
      deployDdosProtectionPlan: false
      name: 'ddos-hub-${locationShort}'
    }
  }
]
