targetScope = 'resourceGroup'
param serviceBusNamespaceName string
param principalId string
@allowed(['Sender', 'Receiver'])
param access string
resource broker 'Microsoft.ServiceBus/namespaces@2024-01-01' existing = { name: serviceBusNamespaceName }
resource queue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' existing = { parent: broker, name: 'IDOC_POSTING' }
var roleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', access == 'Sender' ? '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39' : '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0')
resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(queue.id, principalId, roleId)
  scope: queue
  properties: { principalId: principalId, principalType: 'ServicePrincipal', roleDefinitionId: roleId }
}
output roleAssignmentId string = assignment.id
