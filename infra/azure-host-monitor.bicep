targetScope = 'resourceGroup'
param vmName string
param location string
param tags object
param dcrId string
param dceId string
resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' existing = { name: vmName }
resource ruleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'retailtx-host'
  scope: vm
  properties: { dataCollectionRuleId: dcrId }
}
resource endpointAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'configurationAccessEndpoint'
  scope: vm
  properties: { dataCollectionEndpointId: dceId }
}
// AVM VM deployment deliberately disables its AMA wrapper so both private
// associations exist BEFORE the agent extension starts configuration discovery.
resource ama 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  dependsOn: [ruleAssociation, endpointAssociation]
}
