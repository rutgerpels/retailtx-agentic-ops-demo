targetScope = 'resourceGroup'

param environmentName string
param tags object
param subnetId string
param agentPrincipalId string
@secure()
param adminPassword string

var suffix = 'retailtx-disk-${environmentName}'
module host 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: 'disk-host'
  params: {
    name: 'vm-${suffix}'
    computerName: 'disk-${environmentName}'
    location: resourceGroup().location
    vmSize: 'Standard_D2s_v5'
    availabilityZone: -1
    osType: 'Windows'
    imageReference: {
      publisher: 'MicrosoftWindowsServer'
      offer: 'WindowsServer'
      sku: '2022-datacenter-azure-edition'
      version: '20348.5622.260906'
    }
    adminUsername: 'retailtxadmin'
    adminPassword: adminPassword
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    provisionVMAgent: true
    allowExtensionOperations: true
    enableAutomaticUpdates: false
    patchMode: 'Manual'
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
      diskSizeGB: 128
      caching: 'ReadWrite'
      createOption: 'FromImage'
      deleteOption: 'Delete'
      managedDisk: { storageAccountType: 'StandardSSD_LRS' }
    }
    dataDisks: [{
      name: 'data-${suffix}'
      diskSizeGB: 4
      caching: 'None'
      createOption: 'Empty'
      deleteOption: 'Delete'
      managedDisk: { storageAccountType: 'StandardSSD_LRS' }
    }]
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
        subnetResourceId: subnetId
        privateIPAllocationMethod: 'Dynamic'
      }]
    }]
    tags: tags
    enableTelemetry: false
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-11-01' existing = { name: 'vm-${suffix}' }
resource bootstrap 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, 'arc-onboarding')
  properties: {
    principalId: host.outputs.systemAssignedMIPrincipalId!
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7')
  }
}
// Intentionally Reader-only: acknowledgment/changestate on alerts needs
// Microsoft.AlertsManagement/alerts/changestate/action, which only the
// broad built-in Monitoring Contributor grants. Decision is to keep the
// incident unacknowledged by design rather than widen the role. See
// "Remaining acceptance gates" in docs/disk-scenario.md.
resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, agentPrincipalId, 'reader')
  properties: {
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  }
}
output vmId string = vm.id
output bootstrapPrincipalId string = host.outputs.systemAssignedMIPrincipalId!
output bootstrapRoleId string = bootstrap.id
output readerRoleId string = reader.id
