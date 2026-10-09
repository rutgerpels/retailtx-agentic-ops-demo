targetScope = 'resourceGroup'
param storageAccountName string
param principalId string
@allowed(['Reader', 'Contributor'])
param access string = 'Reader'
@allowed(['releases', 'provisioning'])
param containerName string = 'releases'
param principalType string = 'ServicePrincipal'
resource account 'Microsoft.Storage/storageAccounts@2025-01-01' existing = { name: storageAccountName }
resource blob 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' existing = { parent: account, name: 'default' }
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' existing = { parent: blob, name: containerName }
var roleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', access == 'Reader' ? '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' : 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, principalId, roleId)
  scope: container
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: roleId
  }
}
output roleAssignmentId string = assignment.id
