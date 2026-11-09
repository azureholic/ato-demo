var config = loadJsonContent('./workload-egress.json')
resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' existing = {
  name: config.firewallPolicyName
}
resource rules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: 'ai-agent-and-private-runner'
  properties: {
    priority: 300
    ruleCollections: [
      {
        name: 'azure-platform-dependencies'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        rules: [
          {
            name: 'azure-service-dependencies'
            ruleType: 'NetworkRule'
            ipProtocols: ['TCP']
            sourceAddresses: config.sourceAddresses
            destinationAddresses: config.serviceTags
            destinationPorts: ['443', '12000']
          }
        ]
      }
      {
        name: 'trusted-build-and-deployment-feeds'
        priority: 200
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        rules: [
          {
            name: 'package-and-control-plane-access'
            ruleType: 'ApplicationRule'
            sourceAddresses: config.sourceAddresses
            targetFqdns: config.fqdns
            protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
          }
        ]
      }
    ]
  }
}
