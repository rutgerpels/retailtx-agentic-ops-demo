targetScope = 'resourceGroup'
param environmentName string
param location string
param tags object
param privateEndpointSubnetId string
param monitorZoneIds array
param arcZoneIds array
@description('Post-ingestion activation only. False omits alert rules and reader grants; existing rules are not disabled/deleted by incremental omission.')
param enableAlerts bool = false
@minValue(0)
param backlogThresholdCount int = 0
@minValue(5)
@maxValue(60)
param staleAfterMinutes int = 10

var suffix = 'retailtx-${environmentName}'
module workspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'workspace'
  params: {
    name: 'law-${suffix}'
    location: location
    skuName: 'PerGB2018'
    dataRetention: 30
    tables: [for tableName in ['Syslog', 'Perf']: { name: tableName, plan: 'Analytics' }]
    features: { disableLocalAuth: true }
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    forceCmkForQuery: false
    tags: tags
    enableTelemetry: false
  }
}
module insights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'application-insights'
  params: {
    name: 'appi-${suffix}'
    location: location
    applicationType: 'web'
    workspaceResourceId: workspace.outputs.resourceId
    disableLocalAuth: true
    disableIpMasking: false
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    retentionInDays: 30
    tags: tags
    enableTelemetry: false
  }
}
module dce 'br/public:avm/res/insights/data-collection-endpoint:0.5.1' = {
  name: 'data-collection-endpoint'
  params: {
    name: 'dce-${suffix}'
    location: location
    kind: 'Linux'
    publicNetworkAccess: 'Disabled'
    tags: tags
    enableTelemetry: false
  }
}
module ampls 'br/public:avm/res/insights/private-link-scope:0.7.3' = {
  name: 'monitor-private-link-scope'
  params: {
    name: 'ampls-${suffix}'
    accessModeSettings: { ingestionAccessMode: 'PrivateOnly', queryAccessMode: 'PrivateOnly' }
    scopedResources: [
      { name: 'workspace', linkedResourceId: workspace.outputs.resourceId }
      { name: 'application-insights', linkedResourceId: insights.outputs.resourceId }
      { name: 'data-collection-endpoint', linkedResourceId: dce.outputs.resourceId }
    ]
    tags: tags
    enableTelemetry: false
  }
}
// No published AVM for Arc private-link scopes or workbooks.
resource arcScope 'Microsoft.HybridCompute/privateLinkScopes@2022-12-27' = {
  name: 'pls-${suffix}-arc'
  location: location
  tags: tags
  properties: { publicNetworkAccess: 'Disabled' }
}
module monitorEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'monitor-private-endpoint'
  params: {
    name: 'pe-${suffix}-monitor'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      { name: 'monitor', properties: { privateLinkServiceId: ampls.outputs.resourceId, groupIds: ['azuremonitor'] } }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [for (zoneId, i) in monitorZoneIds: { name: 'monitor-${i}', privateDnsZoneResourceId: zoneId }]
    }
    tags: tags
    enableTelemetry: false
  }
}
module arcEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'arc-private-endpoint'
  params: {
    name: 'pe-${suffix}-arc'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      { name: 'arc', properties: { privateLinkServiceId: arcScope.id, groupIds: ['hybridcompute'] } }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [for (zoneId, i) in arcZoneIds: { name: 'arc-${i}', privateDnsZoneResourceId: zoneId }]
    }
    tags: tags
    enableTelemetry: false
  }
}
module dcr 'br/public:avm/res/insights/data-collection-rule:0.11.0' = {
  name: 'data-collection-rule'
  params: {
    name: 'dcr-${suffix}-host'
    location: location
    dataCollectionRuleProperties: {
      kind: 'Linux'
      dataCollectionEndpointResourceId: dce.outputs.resourceId
      dataSources: {
        syslog: [
          {
            name: 'retailtx-syslog'
            streams: ['Microsoft-Syslog']
            facilityNames: ['local0']
            logLevels: ['Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency']
          }
        ]
        performanceCounters: [
          {
            name: 'retailtx-performance'
            streams: ['Microsoft-Perf']
            samplingFrequencyInSeconds: 60
            counterSpecifiers: ['Processor(*)\\% Processor Time', 'Memory(*)\\% Used Memory']
          }
        ]
      }
      destinations: { logAnalytics: [{ name: 'workspace', workspaceResourceId: workspace.outputs.resourceId }] }
      dataFlows: [{ streams: ['Microsoft-Syslog', 'Microsoft-Perf'], destinations: ['workspace'] }]
    }
    tags: tags
    enableTelemetry: false
  }
}

// Runtime sends structured Properties, never parses the human-readable Message.
// Latest snapshots only: an old backlog must not keep an alert firing after recovery.
var freshEvidenceQuery = replace(replace('''
let fresh = toscalar(AppTraces
| where tostring(Properties.environment_id) == '__ENVIRONMENT__'
| where tostring(Properties.event) == 'reconciliation.freshness'
| summarize arg_max(TimeGenerated, Properties)
| project IsFresh = TimeGenerated >= ago(__STALE_MINUTES__m) and tostring(Properties.status) == 'fresh');
''', '__ENVIRONMENT__', environmentName), '__STALE_MINUTES__', string(staleAfterMinutes))
// The one-minute path is one table/pipeline: no scalar subqueries, print,
// take/limit, union, search, or cross-table functions. Runtime emits observed
// ONLY for fresh evidence. Include unhealthy markers before arg_max so a newer
// stale/unknown attempt suppresses old business impact; filter count AFTER latest.
// https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule#configure-alert-rule-conditions
var backlogQuery = replace(replace(replace('''
AppTraces
| where tostring(Properties.environment_id) == '__ENVIRONMENT__'
| where tostring(Properties.event) == 'reconciliation.observed'
    or (tostring(Properties.event) == 'reconciliation.freshness' and tostring(Properties.status) != 'fresh')
| summarize arg_max(TimeGenerated, Properties)
| where tostring(Properties.event) == 'reconciliation.observed'
| where TimeGenerated >= ago(__STALE_MINUTES__m) and todatetime(Properties.observed_at) >= ago(__STALE_MINUTES__m)
| extend UnpostedCount=tolong(Properties.unposted_count), UnpostedCents=tolong(Properties.unposted_cents)
| where UnpostedCount > __BACKLOG_COUNT__
| project TimeGenerated, UnpostedCount, UnpostedCents
''', '__ENVIRONMENT__', environmentName), '__STALE_MINUTES__', string(staleAfterMinutes)), '__BACKLOG_COUNT__', string(backlogThresholdCount))
var staleQuery = replace(replace(replace('''
__FRESHNESS_QUERY__
let observedAt = toscalar(AppTraces
| where tostring(Properties.environment_id) == '__ENVIRONMENT__'
| where tostring(Properties.event) == 'reconciliation.observed'
| summarize arg_max(TimeGenerated, Properties)
| project todatetime(Properties.observed_at));
print Unhealthy = iff(coalesce(fresh, false) and isnotnull(observedAt) and observedAt >= ago(__STALE_MINUTES__m), 0, 1)
| where Unhealthy == 1
''', '__ENVIRONMENT__', environmentName), '__STALE_MINUTES__', string(staleAfterMinutes)), '__FRESHNESS_QUERY__', freshEvidenceQuery)
var alerts = [
  { name: 'backlog', query: backlogQuery, frequency: 'PT1M', description: 'Fresh latest reconciliation exceeds the unposted-count threshold.' }
  { name: 'stale-reconciliation', query: staleQuery, frequency: 'PT5M', description: 'Latest reconciliation is stale, unknown, missing, or has stopped reporting.' }
]
module alertRules 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = [for alert in alerts: if (enableAlerts) {
  name: 'alert-${alert.name}'
  params: {
    name: 'alert-${suffix}-${alert.name}'
    location: location
    alertDisplayName: 'RetailTx ${environmentName}: ${alert.name}'
    alertDescription: alert.description
    enabled: true
    severity: 2
    scopes: [workspace.outputs.resourceId]
    // Only the single-table backlog query uses the one-minute optimizer. The
    // no-data staleness query keeps scalar subqueries at five-minute cadence.
    evaluationFrequency: alert.frequency
    windowSize: 'PT5M'
    queryTimeRange: 'PT1H'
    autoMitigate: true
    // One-minute rules require ingested data. Omit the entire deployment until
    // lifecycle verifies AppTraces, then let ARM validate the activation query.
    skipQueryValidation: false
    managedIdentities: { systemAssigned: true }
    criterias: {
      allOf: [
        {
          query: alert.query
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    // No action group is required for a real fired Azure Monitor alert instance.
    // No email, webhook, SRE response plan, or automatic remediation is installed.
    tags: tags
    enableTelemetry: false
  }
}]
module alertReaders 'azure-monitor-access.bicep' = [for (alert, i) in alerts: if (enableAlerts) {
  name: 'alert-reader-${alert.name}'
  params: {
    appInsightsName: insights.outputs.name
    workspaceName: workspace.outputs.name
    principalId: alertRules[i]!.outputs.systemAssignedMIPrincipalId!
    grantPublisher: false
    grantReader: true
  }
}]
var countryQuery = replace(replace(replace('''
__FRESHNESS_QUERY__
let observation = toscalar(AppTraces
| where tostring(Properties.environment_id) == '__ENVIRONMENT__'
| where tostring(Properties.event) == 'reconciliation.observed'
| summarize arg_max(TimeGenerated, Properties)
| project tostring(Properties.observed_at));
AppTraces
| where tostring(Properties.environment_id) == '__ENVIRONMENT__'
| where tostring(Properties.event) == 'reconciliation.country'
| where isnotempty(observation) and tostring(Properties.observed_at) == observation
| extend Country=tostring(Properties.country)
| summarize arg_max(TimeGenerated, Properties) by Country
| where coalesce(fresh, false) and TimeGenerated >= ago(__STALE_MINUTES__m)
| project Country, UnpostedCount=tolong(Properties.unposted_count), UnpostedEUR=todouble(Properties.unposted_cents)/100.0, ObservedAt=TimeGenerated
| order by Country asc
''', '__ENVIRONMENT__', environmentName), '__STALE_MINUTES__', string(staleAfterMinutes)), '__FRESHNESS_QUERY__', freshEvidenceQuery)
resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'retailtx-country-workbook', environmentName)
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: 'RetailTx ${environmentName}: unposted EUR by country'
    category: 'workbook'
    sourceId: workspace.outputs.resourceId
    serializedData: string({
      version: 'Notebook/1.0'
      isLocked: false
      fallbackResourceIds: [workspace.outputs.resourceId]
      items: [
        {
          type: 1
          name: 'introduction'
          content: { json: '# RetailTx ${environmentName}\nLatest fresh reconciliation by country. Missing/stale evidence is not zero business impact. Query from a host with private access; this workbook grants no network access.' }
        }
        {
          type: 3
          name: 'freshness'
          content: {
            version: 'KqlItem/1.0'
            title: 'Evidence freshness (1 = unhealthy)'
            query: '${freshEvidenceQuery}\nprint Unhealthy=iff(coalesce(fresh, false),0,1)'
            resourceType: 'microsoft.operationalinsights/workspaces'
            queryType: 0
            visualization: 'table'
            size: 0
            timeContext: { durationMs: 3600000 }
          }
        }
        {
          type: 3
          name: 'country-impact'
          content: {
            version: 'KqlItem/1.0'
            title: 'Unposted EUR by country — latest fresh evidence'
            query: countryQuery
            resourceType: 'microsoft.operationalinsights/workspaces'
            queryType: 0
            visualization: 'table'
            size: 0
            timeContext: { durationMs: 3600000 }
          }
        }
      ]
    })
  }
}
output workspaceName string = workspace.outputs.name
output workspaceId string = workspace.outputs.resourceId
output workspaceCustomerId string = workspace.outputs.logAnalyticsWorkspaceId
output appInsightsName string = insights.outputs.name
output appInsightsId string = insights.outputs.resourceId
// ConnectionString is a public routing identifier, not a credential; local auth is disabled.
output appInsightsConnectionString string = insights.outputs.connectionString
output dceId string = dce.outputs.resourceId
output dcrId string = dcr.outputs.resourceId
output arcPrivateLinkScopeId string = arcScope.id
output workbookId string = workbook.id
// Predicted IDs remain stable while creation is omitted; these are not evidence
// that rules exist, are enabled, or have fired. No conditional output reference.
output alertIds array = [for alert in alerts: resourceId('Microsoft.Insights/scheduledQueryRules', 'alert-${suffix}-${alert.name}')]
