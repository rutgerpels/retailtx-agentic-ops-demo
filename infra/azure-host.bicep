targetScope = 'resourceGroup'
param environmentName string
param location string
param tags object
@allowed(['cloud', 'dc'])
param domain string
param adminSshPublicKey string
param subnetId string
param bootstrapIdentityIds array = []
param vmSize string = 'Standard_B2s'
param vmImageVersion string = '24.04.202609040'
@secure()
@maxLength(48000)
@description('Plaintext bootstrap script containing public configuration only, never credentials. AVM base64-encodes exactly once. Preserve unchanged on identity-only redeployment.')
param bootstrapScript string

var suffix = 'retailtx-${domain}-${environmentName}'
module host 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: 'host'
  params: {
    name: 'vm-${suffix}'
    computerName: domain == 'cloud' ? 'cap-${environmentName}' : 'erp-${environmentName}'
    location: location
    vmSize: vmSize
    availabilityZone: -1
    osType: 'Linux'
    imageReference: {
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
      version: vmImageVersion
    }
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    adminUsername: 'retailtxadmin'
    disablePasswordAuthentication: true
    publicKeys: [{ keyData: adminSshPublicKey, path: '/home/retailtxadmin/.ssh/authorized_keys' }]
    customData: replace(bootstrapScript, '\r\n', '\n')
    provisionVMAgent: true
    allowExtensionOperations: domain == 'cloud'
    patchMode: 'ImageDefault'
    patchAssessmentMode: 'ImageDefault'
    // DC bootstrap disables walinuxagent, SSH and IMDS inside the guest. Never
    // install a Compute extension there; Arc AMA is installed only by bindings.
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
    managedIdentities: {
      // Guest Configuration Modify policies 3cf2ab00-13f1-4d0c-8971-2ac904541a7e
      // and 497dff13-db2a-4c0f-8603-28fa3b331ab6 add a native system identity even
      // on DC. Declare that desired state explicitly; AVM 0.22.3 emits an invalid
      // identity.type=null for systemAssigned=false with no remaining UAMIs.
      // DC's native identity receives NO application grants; IMDS stays blocked
      // in its guest and applications authenticate exclusively as the Arc machine.
      // Empty bootstrapIdentityIds converges to SystemAssigned, never None, while
      // retaining full AVM host/NIC/disk convergence and removing bootstrap UAMIs.
      // https://github.com/Azure/azure-policy/blob/master/built-in-policies/policyDefinitions/Guest%20Configuration/AddSystemIdentityWhenNone_Prerequisite.json
      // https://github.com/Azure/azure-policy/blob/master/built-in-policies/policyDefinitions/Guest%20Configuration/AddSystemIdentityWhenUser_Prerequisite.json
      systemAssigned: true
      userAssignedResourceIds: bootstrapIdentityIds
    }
    nicConfigurations: [
      {
        name: 'nic-${suffix}'
        deleteOption: 'Delete'
        enableAcceleratedNetworking: false
        enableIPForwarding: false
        tags: tags
        enableTelemetry: false
        ipConfigurations: [
          {
            name: 'primary'
            subnetResourceId: subnetId
            privateIPAllocationMethod: 'Static'
            privateIPAddress: domain == 'cloud' ? '10.86.0.4' : '10.87.0.4'
          }
        ]
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}
output name string = host.outputs.name
output resourceId string = host.outputs.resourceId
// Only cloud's system identity is an application principal. Never expose DC's
// policy-required native principal through this runtime-identity output.
output principalId string = domain == 'cloud' ? (host.outputs.?systemAssignedMIPrincipalId ?? '') : ''
