targetScope = 'resourceGroup'

param environmentName string
param location string
param tags object
param vmName string
param actionRoleDefinitionName string
param adminObjectId string

var readerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
var networkContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
var sreAdministratorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e79298df-d852-4c6d-84f9-5d13249d1e55')
var identityName = 'id-retailtx-guest-agent-${environmentName}'
var actionIdentityId = resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', identityName)
var agentName = 'sre-retailtx-guest-agent-${environmentName}'
var vnetName = 'vnet-retailtx-guest-agent-${environmentName}'
var subnetName = 'sre'
var natName = 'nat-retailtx-guest-agent-${environmentName}'
var publicIpName = 'pip-retailtx-guest-agent-${environmentName}-egress'

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' existing = {
  name: vmName
}

resource actionRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: actionRoleDefinitionName
}

module actionIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'guest-agent-identity'
  params: {
    name: identityName
    location: location
    tags: tags
    enableTelemetry: false
  }
}

resource outboundAddress 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nat 'Microsoft.Network/natGateways@2024-05-01' = {
  name: natName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [{ id: outboundAddress.id }]
  }
}

module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'guest-agent-network'
  params: {
    name: vnetName
    location: location
    addressPrefixes: ['10.90.0.0/24']
    subnets: [{
      name: subnetName
      addressPrefix: '10.90.0.0/27'
      delegation: 'Microsoft.App/environments'
      natGatewayResourceId: nat.id
      defaultOutboundAccess: false
    }]
    tags: tags
    enableTelemetry: false
  }
}

resource agentVnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: vnetName
}

resource sreSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-05-01' existing = {
  parent: agentVnet
  name: subnetName
}

resource actionIdentityNetworkAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreSubnet.id, actionIdentityId, networkContributorRoleId)
  scope: sreSubnet
  properties: {
    roleDefinitionId: networkContributorRoleId
    principalId: actionIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [vnet]
}

resource actionIdentityReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, actionIdentityId, readerRoleId)
  properties: {
    roleDefinitionId: readerRoleId
    principalId: actionIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

resource agent 'Microsoft.App/agents@2026-01-01' = {
  name: agentName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${actionIdentityId}': {}
    }
  }
  properties: {
    actionConfiguration: {
      identity: actionIdentityId
      accessLevel: 'Low'
      mode: 'Review'
    }
    knowledgeGraphConfiguration: {
      identity: actionIdentityId
      managedResources: [resourceGroup().id]
    }
    upgradeChannel: 'Stable'
    #disable-next-line BCP089
    vnetConfiguration: {
      subnetResourceId: sreSubnet.id
    }
    #disable-next-line BCP037
    sandboxConfiguration: {
      egress: {
        mode: 'AzureVNet'
        allowedHosts: []
        allowedRegistries: []
        allowedCodeRepositories: []
        allowHttpMcpServerNetworkAccess: false
        vnetConfiguration: {
          usePrivateDnsResolution: true
        }
      }
    }
  }
  dependsOn: [
    actionIdentityNetworkAccess
    actionIdentityReader
  ]
}

resource actionIdentityRunCommand 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, actionIdentityId, actionRole.id)
  scope: vm
  properties: {
    roleDefinitionId: actionRole.id
    principalId: actionIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [agent]
}

resource agentSystemReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, agent.name, readerRoleId)
  properties: {
    roleDefinitionId: readerRoleId
    principalId: agent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource admin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(agent.id, adminObjectId, sreAdministratorRoleId)
  scope: agent
  properties: {
    roleDefinitionId: sreAdministratorRoleId
    principalId: adminObjectId
    principalType: 'User'
  }
}

output agentId string = agent.id
output agentEndpoint string = agent.properties.agentEndpoint
output actionIdentityId string = actionIdentity.outputs.resourceId
output actionPrincipalId string = actionIdentity.outputs.principalId
output actionClientId string = actionIdentity.outputs.clientId
output systemPrincipalId string = agent.identity.principalId
output actionRoleAssignmentId string = actionIdentityRunCommand.id
output actionReaderAssignmentId string = actionIdentityReader.id
output systemReaderAssignmentId string = agentSystemReader.id
output networkAssignmentId string = actionIdentityNetworkAccess.id
output adminAssignmentId string = admin.id
output sreAdministratorRoleDefinitionId string = sreAdministratorRoleId
output sreSubnetId string = sreSubnet.id
output guestVmId string = vm.id
