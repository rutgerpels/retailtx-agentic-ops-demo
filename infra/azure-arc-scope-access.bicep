targetScope = 'resourceGroup'
param scopeName string
param principalId string
resource arcScope 'Microsoft.HybridCompute/privateLinkScopes@2022-12-27' existing = { name: scopeName }
var roleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(arcScope.id, principalId, roleId)
  scope: arcScope
  properties: { principalId: principalId, principalType: 'ServicePrincipal', roleDefinitionId: roleId }
}
output roleAssignmentId string = assignment.id
