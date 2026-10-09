targetScope = 'resourceGroup'

param environmentName string
param tags object
param workspaceId string
param dceId string
param ownerToken string
param eventSource string
param enableAlert bool = false
@description('False only after the lifecycle verifies an existing Microsoft monitoring extension.')
param deployMonitoringAgent bool = true

resource machine 'Microsoft.HybridCompute/machines@2024-07-10' existing = {
  name: 'disk-${environmentName}'
}

module dcr 'br/public:avm/res/insights/data-collection-rule:0.11.0' = {
  name: 'price-service-data-collection'
  params: {
    name: 'dcr-retailtx-price-service-${environmentName}'
    location: resourceGroup().location
    tags: tags
    enableTelemetry: false
    dataCollectionRuleProperties: {
      kind: 'Windows'
      dataCollectionEndpointResourceId: dceId
      dataSources: {
        windowsEventLogs: [{
          name: 'price-service-observations'
          streams: ['Microsoft-Event']
          xPathQueries: [
            'Application!*[System[Provider[@Name="${eventSource}"] and (EventID=2200)]]'
          ]
        }]
      }
      destinations: {
        logAnalytics: [{ name: 'workspace', workspaceResourceId: workspaceId }]
      }
      dataFlows: [{ streams: ['Microsoft-Event'], destinations: ['workspace'] }]
    }
  }
}

resource ruleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'retailtx-price-service'
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

var query = replace(replace(replace('''
Event
| where TimeGenerated >= ago(3m) and _ResourceId =~ '__RESOURCE__'
| where Source == '__SOURCE__' and EventID == 2200
| extend data = parse_json(RenderedDescription)
| summarize arg_max(TimeGenerated, data) by _ResourceId
| where tostring(data.ownerToken) == '__OWNER__'
| where tostring(data.environmentName) == '__ENVIRONMENT__'
| where tostring(data.kind) == 'price-probe'
| where tostring(data.phase) == 'fault-active'
| where tostring(data.endpoint) == 'http://127.0.0.1:18081/price/basket-a/'
| where toint(data.serviceStatus) == 503
| where toint(data.baselineHttpStatus) == 200
| where tostring(data.poolState) == 'Stopped'
| where tostring(data.contractValid) == 'false'
| where isnotempty(tostring(data.runId))
| project TimeGenerated, _ResourceId
''', '__RESOURCE__', machine.id), '__SOURCE__', eventSource), '__OWNER__', ownerToken)
var scopedQuery = replace(query, '__ENVIRONMENT__', environmentName)

module alert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = {
  name: 'price-service-alert'
  params: {
    name: 'alert-retailtx-price-service-${environmentName}'
    location: resourceGroup().location
    tags: tags
    enableTelemetry: false
    alertDisplayName: 'RetailTx price fixture ${environmentName}: owned IIS price pool unavailable'
    alertDescription: 'Fresh same-run guest HTTP failure for the owned loopback price dependency; not a checkout or customer-impact alert.'
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
        query: scopedQuery
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
