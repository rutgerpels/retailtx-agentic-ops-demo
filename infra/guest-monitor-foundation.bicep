targetScope = 'resourceGroup'

param environmentName string
param tags object

var suffix = 'retailtx-guest-${environmentName}'
module workspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'guest-workspace'
  params: {
    name: 'law-${suffix}'
    location: resourceGroup().location
    skuName: 'PerGB2018'
    dataRetention: 30
    tables: [{ name: 'Syslog', plan: 'Analytics' }]
    features: { disableLocalAuth: true }
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    forceCmkForQuery: false
    tags: tags
    enableTelemetry: false
  }
}
module dce 'br/public:avm/res/insights/data-collection-endpoint:0.5.1' = {
  name: 'guest-collection-endpoint'
  params: {
    name: 'dce-${suffix}'
    location: resourceGroup().location
    kind: 'Linux'
    publicNetworkAccess: 'Disabled'
    tags: tags
    enableTelemetry: false
  }
}
module scope 'br/public:avm/res/insights/private-link-scope:0.7.3' = {
  name: 'guest-private-link-scope'
  params: {
    name: 'ampls-${suffix}'
    accessModeSettings: { ingestionAccessMode: 'PrivateOnly', queryAccessMode: 'PrivateOnly' }
    scopedResources: [
      { name: 'workspace', linkedResourceId: workspace.outputs.resourceId }
      { name: 'data-collection-endpoint', linkedResourceId: dce.outputs.resourceId }
    ]
    tags: tags
    enableTelemetry: false
  }
}
output workspaceId string = workspace.outputs.resourceId
output workspaceCustomerId string = workspace.outputs.logAnalyticsWorkspaceId
output dceId string = dce.outputs.resourceId
output privateLinkScopeId string = scope.outputs.resourceId
