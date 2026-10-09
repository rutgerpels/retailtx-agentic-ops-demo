targetScope = 'resourceGroup'

param environmentName string
param location string
param tags object
param agentPrincipalId string
param startRoleId string
param adminSshPublicKey string

var suffix = 'retailtx-action-${environmentName}'
module nsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'action-nsg'
  params: {
    name: 'nsg-${suffix}'
    location: location
    tags: tags
    enableTelemetry: false
    securityRules: [for direction in ['Inbound', 'Outbound']: {
      name: 'DenyAll${direction}'
      properties: {
        priority: 4096
        direction: direction
        access: 'Deny'
        protocol: '*'
        sourcePortRange: '*'
        destinationPortRange: '*'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: '*'
      }
    }]
  }
}
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'action-vnet'
  params: {
    name: 'vnet-${suffix}'
    location: location
    addressPrefixes: ['10.88.0.0/24']
    subnets: [{
      name: 'host'
      addressPrefix: '10.88.0.0/24'
      networkSecurityGroupResourceId: nsg.outputs.resourceId
      defaultOutboundAccess: false
    }]
    tags: tags
    enableTelemetry: false
  }
}
module host 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: 'action-host'
  params: {
    name: 'vm-${suffix}'
    computerName: 'action-${environmentName}'
    location: location
    vmSize: 'Standard_B2s'
    availabilityZone: -1
    osType: 'Linux'
    imageReference: {
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
      version: '24.04.202609040'
    }
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    adminUsername: 'retailtxadmin'
    disablePasswordAuthentication: true
    publicKeys: [{ keyData: adminSshPublicKey, path: '/home/retailtxadmin/.ssh/authorized_keys' }]
    customData: '#cloud-config\nruncmd:\n  - [systemctl, disable, --now, ssh.socket, ssh.service]\n'
    provisionVMAgent: true
    allowExtensionOperations: false
    patchMode: 'ImageDefault'
    patchAssessmentMode: 'ImageDefault'
    extensionAadJoinConfig: { enabled: false }
    extensionAntiMalwareConfig: { enabled: false }
    extensionMonitoringAgentConfig: { enabled: false, dataCollectionRuleAssociations: [] }
    extensionDependencyAgentConfig: { enabled: false }
    extensionNetworkWatcherAgentConfig: { enabled: false }
    extensionAzureDiskEncryptionConfig: { enabled: false }
    extensionDSCConfig: { enabled: false }
    extensionGuestConfigurationExtension: { enabled: false }
    bootDiagnostics: true
    bootDiagnosticStorageAccountName: ''
    networkAccessPolicy: 'DenyAll'
    publicNetworkAccess: 'Disabled'
    osDisk: {
      name: 'osdisk-${suffix}'
      diskSizeGB: 32
      caching: 'ReadWrite'
      createOption: 'FromImage'
      deleteOption: 'Delete'
      managedDisk: { storageAccountType: 'StandardSSD_LRS' }
    }
    managedIdentities: { systemAssigned: true }
    nicConfigurations: [{
      name: 'nic-${suffix}'
      deleteOption: 'Delete'
      enableAcceleratedNetworking: false
      enableIPForwarding: false
      tags: tags
      enableTelemetry: false
      ipConfigurations: [{
        name: 'primary'
        subnetResourceId: vnet.outputs.subnetResourceIds[0]
        privateIPAllocationMethod: 'Dynamic'
      }]
    }]
    tags: tags
    enableTelemetry: false
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' existing = { name: 'vm-${suffix}' }
resource startAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, agentPrincipalId, startRoleId)
  scope: vm
  properties: {
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: startRoleId
  }
  dependsOn: [host]
}
resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, agentPrincipalId, 'reader')
  properties: {
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}

output vmId string = vm.id
output startAssignmentId string = startAssignment.id
output readerAssignmentId string = readerAssignment.id
