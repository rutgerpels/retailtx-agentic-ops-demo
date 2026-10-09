targetScope = 'subscription'

param environmentName string
param location string = 'swedencentral'
param ownerToken string
param expiresAt string
param roleDefinitionName string
param agentPrincipalId string
param adminSshPublicKey string

var tags = {
  demo: 'retailtx'
  environmentId: environmentName
  profile: 'native-action'
  managedBy: 'retailtx'
  ownerToken: ownerToken
  expiresAt: expiresAt
}

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-retailtx-action-${environmentName}-${location}'
  location: location
  tags: tags
}

resource startRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: roleDefinitionName
  properties: {
    roleName: 'retailtx-start-${environmentName}-${roleDefinitionName}'
    description: 'RetailTx native action proof; ownerToken=${ownerToken}'
    type: 'CustomRole'
    assignableScopes: [group.id]
    permissions: [
      {
        actions: ['Microsoft.Compute/virtualMachines/start/action']
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
  dependsOn: [group]
}

module target './native-action-target.bicep' = {
  name: 'native-action-target-${environmentName}'
  scope: group
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    agentPrincipalId: agentPrincipalId
    startRoleId: startRole.id
    adminSshPublicKey: adminSshPublicKey
  }
}

output vmId string = target.outputs.vmId
output roleDefinitionId string = startRole.id
output startAssignmentId string = target.outputs.startAssignmentId
output readerAssignmentId string = target.outputs.readerAssignmentId
