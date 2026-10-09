targetScope = 'resourceGroup'

param environmentName string
param location string
param tags object
param adminSshPublicKey string
param agentPrincipalId string

var suffix = 'retailtx-guest-${environmentName}'
resource outboundAddress 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${suffix}-egress'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}
resource nat 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'nat-${suffix}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [{ id: outboundAddress.id }]
  }
}
module nsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'guest-nsg'
  params: {
    name: 'nsg-${suffix}'
    location: location
    tags: tags
    enableTelemetry: false
    securityRules: [
      {
        name: 'AzureHttps'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureCloud'
        }
      }
      {
        name: 'AzureVmAgent'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: ['80', '32526']
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '168.63.129.16'
        }
      }
      {
        name: 'AzureDns'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '53'
          sourceAddressPrefix: '*'
          // AzurePlatformDNS is a deny-only opt-out tag; use the fixed Azure resolver IP.
          destinationAddressPrefix: '168.63.129.16'
        }
      }
      {
        name: 'DenyInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyOutbound'
        properties: {
          priority: 4096
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'guest-vnet'
  params: {
    name: 'vnet-${suffix}'
    location: location
    addressPrefixes: ['10.89.0.0/24']
    subnets: [{
      name: 'host'
      addressPrefix: '10.89.0.0/24'
      networkSecurityGroupResourceId: nsg.outputs.resourceId
      natGatewayResourceId: nat.id
      defaultOutboundAccess: false
    }]
    tags: tags
    enableTelemetry: false
  }
}
module host 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: 'guest-host'
  params: {
    name: 'vm-${suffix}'
    computerName: 'guest-${environmentName}'
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
    allowExtensionOperations: true
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

output vmId string = host.outputs.resourceId
resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, agentPrincipalId, 'reader')
  properties: {
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}

output readerAssignmentId string = readerAssignment.id
