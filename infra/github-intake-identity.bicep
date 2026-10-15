targetScope = 'subscription'

metadata description = 'Standalone GitHub caller identity and exact-agent investigator-read-v1 grant. See docs/github-intake-identity.md for the ownership handoff.'

@description('Explicit neutral environment from the trusted intake configuration (not the GitHub environment).')
@minLength(3)
@maxLength(21)
param environment string

@description('Explicit trusted Azure location for the caller identity.')
param location string

@description('Canonical UUID ownership token from config.binding.ownerToken.')
@minLength(36)
@maxLength(36)
param ownerToken string

@description('Exact existing Microsoft.App/agents ID. Deploy in this agent subscription; its existing resource group is derived from this ID.')
param agentId string

@description('Verified repository full name, owner/repository; never issue-actor data.')
param repository string

@description('Verified immutable repository ID from authenticated repository evidence.')
@minValue(1)
param repositoryId int

@description('Verified immutable repository OWNER ID from authenticated repository evidence.')
@minValue(1)
param repositoryOwnerId int

@description('Verified exact classic or immutable subject. GitHub environment is always sre-github-intake.')
param verifiedOidcSubject string

@description('Explicit UTC retention expiry, validated by federation.specifications(). This is a tag, not automatic deletion.')
param expiresAt string

// Bicep guid() has a fixed namespace and is NOT Python uuid.uuid5(ownerToken, name).
// Require the existing pure Python specifications() UUIDs rather than changing ownership IDs.
@description('UUIDv5(ownerToken, "github-intake-role:" + agentId), from federation.specifications().')
@minLength(36)
@maxLength(36)
param roleDefinitionName string

@description('UUIDv5(ownerToken, "github-intake-assignment:" + identityId), from federation.specifications().')
@minLength(36)
@maxLength(36)
param roleAssignmentName string

resource agentGroup 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: split(agentId, '/')[4]
}

var identityName = 'retailtx-github-intake-${environment}'
// At subscription scope, always use the explicit subscription + RG overload.
var identityId = resourceId(subscription().subscriptionId, agentGroup.name, 'Microsoft.ManagedIdentity/userAssignedIdentities', identityName)
var federationId = '${identityId}/federatedIdentityCredentials/github-intake'
var agentName = last(split(agentId, '/'))
// Exact, case-sensitive resource binding matches the Python config contract.
// An invalid ID/subject produces an out-of-range lookup, never a wider scope/alternate subject.
var allowedAgentIds = [resourceId(subscription().subscriptionId, agentGroup.name, 'Microsoft.App/agents', agentName)]
var boundAgentId = allowedAgentIds[indexOf(allowedAgentIds, agentId)]
var classicSubject = 'repo:${repository}:environment:sre-github-intake'
var immutableSubject = 'repo:${split(repository, '/')[0]}@${repositoryOwnerId}/${split(repository, '/')[1]}@${repositoryId}:environment:sre-github-intake'
var allowedSubjects = [classicSubject, immutableSubject]
var boundSubject = allowedSubjects[indexOf(allowedSubjects, verifiedOidcSubject)]
var identityTags = {
  demo: 'retailtx'
  environmentId: environment
  profile: 'github-intake'
  managedBy: 'retailtx'
  ownerToken: ownerToken
  expiresAt: expiresAt
}
var federationProperties = {
  issuer: 'https://token.actions.githubusercontent.com'
  subject: boundSubject
  audiences: ['api://AzureADTokenExchange']
}
var roleProperties = {
  roleName: 'RetailTx GitHub intake ${environment} ${ownerToken}'
  description: 'Proposal-only GitHub intake; ownerToken=${ownerToken}'
  type: 'CustomRole'
  assignableScopes: [agentGroup.id]
  permissions: [{
    actions: ['Microsoft.App/agents/read']
    notActions: []
    dataActions: [
      'Microsoft.App/agents/threads/read'
      'Microsoft.App/agents/threads/write'
      'Microsoft.App/agents/extendedagents/read'
    ]
    notDataActions: []
  }]
}

// Pinned AVM, consistent with the repository's existing identity modules.
// No lock, identity-scoped grants, extra tags, isolation scope or telemetry.
module callerIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  scope: agentGroup
  name: 'github-intake-identity-${environment}'
  params: {
    name: identityName
    location: location
    tags: identityTags
    enableTelemetry: false
    federatedIdentityCredentials: [{
      name: 'github-intake'
      issuer: federationProperties.issuer
      subject: federationProperties.subject
      audiences: federationProperties.audiences
    }]
  }
}

resource callerIdentityReadback 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  scope: agentGroup
  name: identityName
}

// Subscription-level role ID is required for Python ownership compatibility;
// assignability remains limited to the existing agent resource group.
resource investigatorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  scope: subscription()
  name: roleDefinitionName
  properties: roleProperties
}

// A subscription entry point cannot directly deploy an agent-scoped extension
// in a resource group (BCP139). Inline only this tiny nested ARM template to keep
// the requested module standalone; all values are explicit inner-scope parameters.
#disable-next-line no-deployments-resources
resource invocationGrant 'Microsoft.Resources/deployments@2022-09-01' = {
  name: 'github-intake-assignment-${environment}'
  resourceGroup: agentGroup.name
  properties: {
    mode: 'Incremental'
    expressionEvaluationOptions: { scope: 'inner' }
    parameters: {
      agentId: { value: boundAgentId }
      roleAssignmentName: { value: roleAssignmentName }
      roleDefinitionId: { value: investigatorRole.id }
      principalId: { value: callerIdentity.outputs.principalId }
    }
    // json() materializes the inner template at the outer scope; this prevents
    // Bicep from escaping its ARM expressions into literal "[[parameters(...)]".
    template: json('''
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "agentId": { "type": "string" },
    "roleAssignmentName": { "type": "string" },
    "roleDefinitionId": { "type": "string" },
    "principalId": { "type": "string" }
  },
  "resources": [{
    "type": "Microsoft.Authorization/roleAssignments",
    "apiVersion": "2022-04-01",
    "name": "[parameters('roleAssignmentName')]",
    "scope": "[parameters('agentId')]",
    "properties": {
      "roleDefinitionId": "[parameters('roleDefinitionId')]",
      "principalType": "ServicePrincipal",
      "principalId": "[parameters('principalId')]"
    }
  }]
}
''')
  }
}

var assignmentId = '${boundAgentId}/providers/Microsoft.Authorization/roleAssignments/${roleAssignmentName}'

output identityResourceId string = callerIdentity.outputs.resourceId
output federatedIdentityCredentialId string = federationId
output roleDefinitionId string = investigatorRole.id
output roleAssignmentId string = assignmentId
output clientId string = callerIdentity.outputs.clientId
output principalId string = callerIdentity.outputs.principalId
output tenantId string = callerIdentityReadback.properties.tenantId
output roleProfile string = 'investigator-read-v1'
output ownerBinding object = {
  environment: environment
  ownerToken: ownerToken
  agentId: boundAgentId
  repository: repository
  repositoryId: repositoryId
  oidc: {
    repositoryOwnerId: repositoryOwnerId
    subject: boundSubject
  }
}

// Expected Python manifest assets, not evidence of ARM readback or OIDC readiness.
// Keep the Python GET API versions even though AVM uses a newer identity PUT version.
output federationAssets array = [
  {
    kind: 'identity'
    id: identityId
    apiVersion: '2023-01-31'
    body: { location: location, tags: identityTags }
  }
  {
    kind: 'federation'
    id: federationId
    apiVersion: '2023-01-31'
    body: { properties: federationProperties }
  }
  {
    kind: 'role'
    id: investigatorRole.id
    apiVersion: '2022-04-01'
    body: { properties: roleProperties }
  }
  {
    kind: 'assignment'
    id: assignmentId
    apiVersion: '2022-04-01'
    body: {
      properties: {
        roleDefinitionId: investigatorRole.id
        principalType: 'ServicePrincipal'
        principalId: callerIdentity.outputs.principalId
      }
    }
  }
]


