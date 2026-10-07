targetScope = 'resourceGroup'
param machineName string
param location string
param tags object
param dcrId string
param dceId string
resource machine 'Microsoft.HybridCompute/machines@2024-07-10' existing = { name: machineName }
resource ruleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'retailtx-host'
  scope: machine
  properties: { dataCollectionRuleId: dcrId }
}
resource endpointAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'configurationAccessEndpoint'
  scope: machine
  properties: { dataCollectionEndpointId: dceId }
}
// Match Arc AMA DINE settings; this is HybridCompute, NOT a Compute VM extension.
// https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-private-link
resource ama 'Microsoft.HybridCompute/machines/extensions@2024-07-10' = {
  parent: machine
  name: 'AzureMonitorLinuxAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  dependsOn: [ruleAssociation, endpointAssociation]
}
output extensionId string = ama.id
