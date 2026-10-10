targetScope = 'subscription'

param environmentName string
param location string = 'swedencentral'
param ownerToken string
param expiresAt string
param adminSshPublicKey string
param agentPrincipalId string
param withMonitoring bool = false

var tags = {
  demo: 'retailtx'
  environmentId: environmentName
  profile: 'guest-service'
  managedBy: 'retailtx'
  ownerToken: ownerToken
  expiresAt: expiresAt
}

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-retailtx-guest-${environmentName}-${location}'
  location: location
  tags: tags
}

module fixture 'guest-service-target.bicep' = {
  name: 'guest-service-target'
  scope: group
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    adminSshPublicKey: adminSshPublicKey
    agentPrincipalId: agentPrincipalId
    withMonitoring: withMonitoring
  }
}

output groupId string = group.id
output vmId string = fixture.outputs.vmId
output readerAssignmentId string = fixture.outputs.readerAssignmentId
