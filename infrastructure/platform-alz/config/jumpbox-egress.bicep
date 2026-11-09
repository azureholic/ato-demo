var config = loadJsonContent('./jumpbox.json')

resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' existing = {
  name: config.hub.firewallPolicyName
}

// Dedicated, minimal egress for the jumpbox subnet: sign-in, Azure and Foundry portals, Windows Update and the
// package/CLI downloads. Add domains here as the desktop needs them.
resource rules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: 'platform-jumpbox'
  properties: {
    priority: 320
    ruleCollections: [
      {
        name: 'jumpbox-scoped-https'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        rules: [
          {
            name: 'login-portals-and-downloads'
            ruleType: 'ApplicationRule'
            sourceAddresses: [config.subnet.addressPrefix]
            targetFqdns: config.egressFqdns
            protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
          }
          {
            name: 'windows-update'
            ruleType: 'ApplicationRule'
            sourceAddresses: [config.subnet.addressPrefix]
            fqdnTags: ['WindowsUpdate']
            protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
          }
        ]
      }
    ]
  }
}
