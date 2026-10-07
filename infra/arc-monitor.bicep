targetScope = 'resourceGroup'

@description('Name of the already registered Arc-enabled Linux machine. Stage 0 uses erp-core-01; do not target the backing Azure VM.')
param machineName string

@description('ARM resource ID of the Stage 0 Linux data collection rule.')
param dcrId string

@description('ARM resource ID of the private Stage 0 Linux data collection endpoint.')
param dceId string

@description('Name of the Stage 0 Log Analytics workspace in this resource group, used for an Arc-identity private query smoke test.')
param workspaceName string

// Registration and its system-assigned identity must exist before this template
// runs. Never recreate the Arc machine or configure Microsoft.Compute extensions.
resource arcMachine 'Microsoft.HybridCompute/machines@2024-07-10' existing = {
  name: machineName
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: workspaceName
}

// Match the built-in Linux Arc AMA DINE (845857af-0333-4c5d-bbbc-6076697da122):
// same extension name, publisher, type, auto-upgrades and no explicit settings,
// protected settings, handler version or UAMI authentication override.
// https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-manage
resource azureMonitorAgent 'Microsoft.HybridCompute/machines/extensions@2024-07-10' = {
  parent: arcMachine
  name: 'AzureMonitorLinuxAgent'
  // The Stage 0 machine and its owned resource group use the same region.
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  // Private configuration discovery requires the machine's DCE association.
  // Stage both associations before this template enables AMA, instead of
  // launching all three resources in parallel. This does not force an existing
  // extension to restart or eliminate backend/policy-driven propagation delays.
  // https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-private-link
  dependsOn: [
    configurationEndpointAssociation
    dataCollectionRuleAssociation
  ]
}

resource dataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'retailtx-host'
  scope: arcMachine
  properties: {
    dataCollectionRuleId: dcrId
  }
}

// The DCR's DCE reference alone does not configure AMA's private configuration
// channel. This separate association directs configuration downloads to the DCE.
resource configurationEndpointAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'configurationAccessEndpoint'
  scope: arcMachine
  properties: {
    dataCollectionEndpointId: dceId
  }
}

var logAnalyticsReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')

// Query smoke-test permission, not an AMA configuration/ingestion prerequisite.
// Keep it parallel; successful deployment completion includes this assignment.
resource arcWorkspaceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, arcMachine.id, logAnalyticsReaderRoleId)
  scope: workspace
  properties: {
    roleDefinitionId: logAnalyticsReaderRoleId
    principalId: arcMachine.identity.principalId!
    principalType: 'ServicePrincipal'
  }
}
