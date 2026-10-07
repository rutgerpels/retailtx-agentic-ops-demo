targetScope = 'subscription'

@description('Generic environment identifier: lowercase letters, digits and hyphens. Lifecycle validates naming and ownership before provisioning.')
@minLength(2)
@maxLength(20)
param environmentName string

@description('Azure region approved for this Stage 0 environment.')
param location string = 'swedencentral'

@description('Ownership GUID generated and retained by lifecycle. This is an ownership tag, not a credential.')
@minLength(36)
@maxLength(36)
param ownerToken string

@description('Ephemeral SSH public key supplied by lifecycle. No private key is accepted; bootstrap disables SSH and the host has no public IP.')
@minLength(1)
param adminSshPublicKey string

@description('Entra object ID of the human or service principal permitted to administer this SRE Agent.')
@minLength(36)
@maxLength(36)
param deployerObjectId string

@description('Size of the single Azure-hosted Arc evaluation VM.')
param vmSize string = 'Standard_B2s'

@description('Pinned Canonical:ubuntu-24_04-lts:server Gen2 image version verified in Sweden Central. Override only with a verified supported image version.')
param vmImageVersion string = '24.04.202609040'

var resourceGroupName = 'rg-retailtx-${environmentName}-${location}'
var ownershipTags = {
  demo: 'retailtx'
  environmentId: environmentName
  ownerToken: ownerToken
  managedBy: 'retailtx-stage0'
}

// Exactly one owned group. Lifecycle, not this template, checks existing ownership.
module ownedResourceGroup 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'retailtx-rg-${environmentName}'
  params: {
    name: resourceGroupName
    location: location
    tags: ownershipTags
    enableTelemetry: false
  }
}

module stage0 'stage0.bicep' = {
  name: 'retailtx-stage0-${environmentName}'
  scope: resourceGroup(resourceGroupName)
  params: {
    environmentName: environmentName
    location: location
    ownerToken: ownerToken
    adminSshPublicKey: adminSshPublicKey
    deployerObjectId: deployerObjectId
    vmSize: vmSize
    vmImageVersion: vmImageVersion
  }
  dependsOn: [
    ownedResourceGroup
  ]
}

// arc-monitor.bicep is intentionally NOT invoked here: lifecycle first waits for
// Arc registration, removes the temporary onboarding role, then deploys it.
output RESOURCE_GROUP_NAME string = resourceGroupName
output VM_NAME string = stage0.outputs.VM_NAME
output ARC_MACHINE_NAME string = stage0.outputs.ARC_MACHINE_NAME
output ARC_PRIVATE_LINK_SCOPE_ID string = stage0.outputs.ARC_PRIVATE_LINK_SCOPE_ID
output WORKSPACE_ID string = stage0.outputs.WORKSPACE_ID
output WORKSPACE_CUSTOMER_ID string = stage0.outputs.WORKSPACE_CUSTOMER_ID
output DCE_ID string = stage0.outputs.DCE_ID
output DCR_ID string = stage0.outputs.DCR_ID
output SRE_AGENT_ID string = stage0.outputs.SRE_AGENT_ID
output SRE_ENDPOINT string = stage0.outputs.SRE_ENDPOINT
output BOOTSTRAP_IDENTITY_ID string = stage0.outputs.BOOTSTRAP_IDENTITY_ID
output BOOTSTRAP_ROLE_ASSIGNMENT_ID string = stage0.outputs.BOOTSTRAP_ROLE_ASSIGNMENT_ID
