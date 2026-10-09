targetScope = 'resourceGroup'
param name string
param location string
param tags object
param grantArcOnboarding bool = false

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'identity'
  params: {
    name: name
    location: location
    tags: tags
    enableTelemetry: false
  }
}
var onboardingRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7')
resource onboarding 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantArcOnboarding) {
  name: guid(resourceGroup().id, resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', name), onboardingRoleId)
  properties: {
    principalId: identity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: onboardingRoleId
  }
}
output resourceId string = identity.outputs.resourceId
output principalId string = identity.outputs.principalId
output clientId string = identity.outputs.clientId
output onboardingRoleAssignmentId string = grantArcOnboarding ? onboarding!.id : ''
