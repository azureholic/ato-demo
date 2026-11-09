var config = loadJsonContent('./jumpbox.json')

resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' existing = {
  name: config.hub.firewallPolicyName
}

// Dedicated, minimal egress for the jumpbox subnet: sign-in, Azure and Foundry portals, Windows Update, the
// package/CLI downloads, and what Windows Server Azure Edition needs to stay activated: Azure KMS (TCP 1688) and
// the certificate download/revocation endpoints (HTTP 80) for its IMDS attestation chain. Without them the VM
// shows a "has been deactivated" pop-up. Add domains here as the desktop needs them.
resource rules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: 'platform-jumpbox'
  properties: {
    priority: 320
    ruleCollections: [
      {
        name: 'jumpbox-windows-activation'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        rules: [
          {
            name: 'azure-kms'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP']
            sourceAddresses: [config.subnet.addressPrefix]
            destinationAddresses: config.kmsAddresses
            destinationPorts: ['1688']
          }
        ]
      }
      {
        name: 'jumpbox-scoped-https'
        priority: 200
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
