targetScope = 'resourceGroup'

param environmentName string
param tags object
param workspaceId string
param dceId string
param privateLinkScopeId string
param enableAlert bool = false

var suffix = 'retailtx-guest-${environmentName}'
var zoneNames = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.blob.${environment().suffixes.storage}'
]
resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' existing = { name: 'vm-${suffix}' }
resource hostNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = { name: 'vnet-${suffix}' }
resource agentNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: 'vnet-retailtx-guest-agent-${environmentName}'
}
module zones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [for zoneName in zoneNames: {
  name: 'monitor-dns-${uniqueString(zoneName)}'
  params: {
    name: zoneName
    tags: tags
    enableTelemetry: false
    virtualNetworkLinks: [
      { name: 'guest', virtualNetworkResourceId: hostNetwork.id, registrationEnabled: false }
      { name: 'agent', virtualNetworkResourceId: agentNetwork.id, registrationEnabled: false }
    ]
  }
}]
resource guestPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: hostNetwork
  name: 'monitor-agent'
  properties: {
    remoteVirtualNetwork: { id: agentNetwork.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}
resource agentPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: agentNetwork
  name: 'monitor-guest'
  properties: {
    remoteVirtualNetwork: { id: hostNetwork.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}
module endpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'guest-monitor-endpoint'
  params: {
    name: 'pe-${suffix}-monitor'
    customNetworkInterfaceName: 'nic-${suffix}-monitor'
    location: resourceGroup().location
    subnetResourceId: '${hostNetwork.id}/subnets/host'
    privateLinkServiceConnections: [{
      name: 'monitor'
      properties: { privateLinkServiceId: privateLinkScopeId, groupIds: ['azuremonitor'] }
    }]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [for (zoneName, i) in zoneNames: {
        name: 'monitor-${i}', privateDnsZoneResourceId: zones[i].outputs.resourceId
      }]
    }
    tags: tags
    enableTelemetry: false
  }
}
module dcr 'br/public:avm/res/insights/data-collection-rule:0.11.0' = {
  name: 'guest-service-collection'
  params: {
    name: 'dcr-${suffix}'
    location: resourceGroup().location
    tags: tags
    enableTelemetry: false
    dataCollectionRuleProperties: {
      kind: 'Linux'
      dataCollectionEndpointResourceId: dceId
      dataSources: {
        syslog: [{
          name: 'service-observations'
          streams: ['Microsoft-Syslog']
          facilityNames: ['local0']
          logLevels: ['Info']
        }]
      }
      destinations: { logAnalytics: [{ name: 'workspace', workspaceResourceId: workspaceId }] }
      dataFlows: [{
        streams: ['Microsoft-Syslog'], destinations: ['workspace']
        transformKql: 'source | where ProcessName == "RetailTxGuest"'
      }]
    }
  }
}
resource association 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  scope: vm
  name: 'retailtx-guest'
  properties: { dataCollectionRuleId: dcr.outputs.resourceId }
}
resource configuration 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  scope: vm
  name: 'configurationAccessEndpoint'
  properties: { dataCollectionEndpointId: dceId }
}
resource ama 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: resourceGroup().location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  dependsOn: [association, configuration, endpoint]
}
var query = replace(replace('''
Syslog
| where _ResourceId =~ '__VM__' and ProcessName == 'RetailTxGuest'
| extend receipt = parse_json(SyslogMessage)
| where tostring(receipt.ownerToken) == '__OWNER__'
| extend observedAt = todatetime(receipt.observedAtUtc)
| summarize arg_max(observedAt, *) by _ResourceId
| where TimeGenerated >= ago(3m) and observedAt >= ago(3m) and observedAt <= now() + 30s
| where receipt.active == false and receipt.healthy == false
| where tostring(receipt.marker.phase) == 'fault-active' and receipt.marker.canary == false
| where todatetime(receipt.marker.deadlineUtc) > now()
| project TimeGenerated, _ResourceId
''', '__VM__', vm.id), '__OWNER__', tags.ownerToken)
module alert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = {
  name: 'guest-service-alert'
  params: {
    name: 'alert-${suffix}'
    location: resourceGroup().location
    tags: tags
    enableTelemetry: false
    alertDisplayName: 'RetailTx guest ${environmentName}: posting fixture service stopped'
    alertDescription: 'Fresh real fixture service failure, not a VM-down or retail-transaction alert.'
    enabled: enableAlert
    severity: 2
    scopes: [workspaceId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    skipQueryValidation: !enableAlert
    managedIdentities: { systemAssigned: true }
    criterias: {
      allOf: [{
        query: query
        resourceIdColumn: '_ResourceId'
        timeAggregation: 'Count'
        operator: 'GreaterThan'
        threshold: 0
        failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
      }]
    }
  }
}
output alertId string = alert.outputs.resourceId
output alertPrincipalId string = alert.outputs.systemAssignedMIPrincipalId!
