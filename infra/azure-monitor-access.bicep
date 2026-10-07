targetScope = 'resourceGroup'
param appInsightsName string
param workspaceName string
param principalId string
param grantPublisher bool = true
param grantReader bool = false
@allowed(['ServicePrincipal', 'User', 'Group'])
param principalType string = 'ServicePrincipal'
resource insights 'Microsoft.Insights/components@2020-02-02' existing = { name: appInsightsName }
resource workspace 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = { name: workspaceName }
var publisherRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
var readerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantPublisher) {
  name: guid(insights.id, principalId, publisherRoleId)
  scope: insights
  properties: { principalId: principalId, principalType: principalType, roleDefinitionId: publisherRoleId }
}
resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantReader) {
  name: guid(workspace.id, principalId, readerRoleId)
  scope: workspace
  properties: { principalId: principalId, principalType: principalType, roleDefinitionId: readerRoleId }
}
output publisherRoleAssignmentId string = grantPublisher ? publisher!.id : ''
output readerRoleAssignmentId string = grantReader ? reader!.id : ''
