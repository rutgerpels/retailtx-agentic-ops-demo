targetScope = 'subscription'

param resourceGroupName string
param environmentName string
param location string
param tags object
param ownerToken string
param vmName string
param actionRoleDefinitionName string
param adminObjectId string

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: resourceGroupName
}

resource actionRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: actionRoleDefinitionName
  properties: {
    roleName: 'RetailTx guest repair ${environmentName}'
    description: 'RetailTx guest repair for environment ${environmentName}; ownerToken=${ownerToken}'
    type: 'CustomRole'
    assignableScopes: [group.id]
    permissions: [{
      actions: ['Microsoft.Compute/virtualMachines/runCommand/action']
      notActions: []
      dataActions: []
      notDataActions: []
    }]
  }
}

module fixtureAgent './guest-service-agent-target.bicep' = {
  name: 'guest-agent-${environmentName}'
  scope: group
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    vmName: vmName
    actionRoleDefinitionName: actionRoleDefinitionName
    adminObjectId: adminObjectId
  }
  dependsOn: [actionRole]
}

output actionRoleDefinitionId string = actionRole.id
output actionRoleAssignmentId string = fixtureAgent.outputs.actionRoleAssignmentId
output actionIdentityId string = fixtureAgent.outputs.actionIdentityId
output actionPrincipalId string = fixtureAgent.outputs.actionPrincipalId
output actionClientId string = fixtureAgent.outputs.actionClientId
output agentId string = fixtureAgent.outputs.agentId
output agentEndpoint string = fixtureAgent.outputs.agentEndpoint
output systemPrincipalId string = fixtureAgent.outputs.systemPrincipalId
output actionReaderAssignmentId string = fixtureAgent.outputs.actionReaderAssignmentId
output systemReaderAssignmentId string = fixtureAgent.outputs.systemReaderAssignmentId
output networkAssignmentId string = fixtureAgent.outputs.networkAssignmentId
output adminAssignmentId string = fixtureAgent.outputs.adminAssignmentId
output sreAdministratorRoleDefinitionId string = fixtureAgent.outputs.sreAdministratorRoleDefinitionId
output sreSubnetId string = fixtureAgent.outputs.sreSubnetId
output guestVmId string = fixtureAgent.outputs.guestVmId
