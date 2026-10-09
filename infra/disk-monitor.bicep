targetScope = 'resourceGroup'
param environmentName string
param tags object
param workspaceId string
param dceId string
param enableAlert bool = false
@description('False only after the lifecycle verifies an existing Microsoft monitoring extension.')
param deployMonitoringAgent bool = true

resource machine 'Microsoft.HybridCompute/machines@2024-07-10' existing = {
  name: 'disk-${environmentName}'
}
module dcr 'br/public:avm/res/insights/data-collection-rule:0.11.0' = {
  name: 'disk-data-collection'
  params: {
    name: 'dcr-retailtx-disk-${environmentName}'
    location: resourceGroup().location
    tags: tags
    enableTelemetry: false
    dataCollectionRuleProperties: {
      kind: 'Windows'
      dataCollectionEndpointResourceId: dceId
      dataSources: {
        performanceCounters: [{
          name: 'test-volume'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 30
          counterSpecifiers: ['\\LogicalDisk(R:)\\% Free Space']
        }]
        windowsEventLogs: [{
          name: 'disk-observations'
          streams: ['Microsoft-Event']
          xPathQueries: ['Application!*[System[Provider[@Name="RetailTxDisk"] and (EventID=2100)]]']
        }]
      }
      destinations: { logAnalytics: [{ name: 'workspace', workspaceResourceId: workspaceId }] }
      dataFlows: [{ streams: ['Microsoft-Perf', 'Microsoft-Event'], destinations: ['workspace'] }]
    }
  }
}
resource ruleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'retailtx-disk'
  scope: machine
  properties: { dataCollectionRuleId: dcr.outputs.resourceId }
}
resource endpointAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'configurationAccessEndpoint'
  scope: machine
  properties: { dataCollectionEndpointId: dceId }
}
resource ama 'Microsoft.HybridCompute/machines/extensions@2024-07-10' = if (deployMonitoringAgent) {
  parent: machine
  name: 'AzureMonitorWindowsAgent'
  location: resourceGroup().location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  dependsOn: [ruleAssociation, endpointAssociation]
}
var query = replace('''
Perf
| where _ResourceId =~ '__RESOURCE__'
| where ObjectName == 'LogicalDisk' and InstanceName == 'R:' and CounterName == '% Free Space'
| summarize arg_max(TimeGenerated, CounterValue) by _ResourceId
| where TimeGenerated >= ago(3m) and CounterValue < 10
| project TimeGenerated, _ResourceId, CounterValue
''', '__RESOURCE__', machine.id)
module alert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = {
  name: 'disk-alert'
  params: {
    name: 'alert-retailtx-disk-${environmentName}'
    location: resourceGroup().location
    tags: tags
    enableTelemetry: false
    alertDisplayName: 'RetailTx disk ${environmentName}: data volume below 10 percent free'
    alertDescription: 'Latest fresh R: capacity on the exact Arc host; not an OS-disk or retail-outage alert.'
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
        timeAggregation: 'Count'
        operator: 'GreaterThan'
        threshold: 0
        resourceIdColumn: '_ResourceId'
        failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
      }]
    }
  }
}
output alertId string = alert.outputs.resourceId
output alertPrincipalId string = alert.outputs.systemAssignedMIPrincipalId!
output dcrId string = dcr.outputs.resourceId
