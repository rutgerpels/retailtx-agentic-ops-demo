targetScope = 'resourceGroup'

@description('Generic environment ID; do not include delivery stages or milestone numbers.')
@minLength(3)
@maxLength(12)
param environmentName string

@description('Lifecycle-generated ownership GUID.')
@minLength(36)
@maxLength(36)
param ownerToken string

@description('Expiry recorded on owned Azure resources.')
param expiresAt string

@description('Exact private Service Bus queue deployed by servicebus-scenario.bicep.')
param queueResourceId string

@description('Queue resource name in namespace/queue form.')
param queueResourceName string

@description('Existing retained Stage 0 VNet resource ID containing the queue private endpoint.')
param foundationVirtualNetworkId string

@description('Existing retained Stage 0 VNet resource group.')
param foundationResourceGroupName string

@description('Existing retained Stage 0 VNet name.')
param foundationVirtualNetworkName string

@description('Microsoft Entra tenant that issued the fixed SRE managed-identity token.')
@minLength(36)
@maxLength(36)
param tenantId string

@description('Executor-specific custom API audience registered in Microsoft Entra ID; never the ARM audience.')
param executorAudience string

@description('Client application ID of the SRE Agent system identity used by its stdio connector.')
@minLength(36)
@maxLength(36)
param sreClientAppId string

@description('Object ID of the exact SRE connector system identity allowed to invoke the executor.')
@minLength(36)
@maxLength(36)
param srePrincipalObjectId string

@description('Attested source and installer script for the private probe/publisher VM.')
@secure()
@maxLength(48000)
param runnerBootstrapScript string

@description('Ephemeral provisioning-only OpenSSH public key stored in the owned local manifest.')
@minLength(100)
@maxLength(2048)
param runnerSshPublicKey string

param location string = resourceGroup().location

var tags = {
  demo: 'retailtx'
  environmentId: environmentName
  profile: 'servicebus'
  ownerToken: ownerToken
  managedBy: 'retailtx'
  expiresAt: expiresAt
  system: 'CAP'
  site: 'cloud'
}
var executorAppName = 'func-sb-exec-${environmentName}-${uniqueString(resourceGroup().id)}'
var watchdogAppName = 'func-sb-watch-${environmentName}-${uniqueString(resourceGroup().id)}'
var storageName = 'stsb${uniqueString(resourceGroup().id, environmentName)}'
var executorVnetName = 'vnet-sb-exec-${environmentName}'
var runnerNatPublicIpName = 'pip-sb-runner-${environmentName}'
var runnerNatGatewayName = 'nat-sb-runner-${environmentName}'
var runnerNetworkSecurityGroupName = 'nsg-sb-runner-${environmentName}'
var serviceBusZoneName = 'privatelink.servicebus.windows.net'
var webPrivateZoneName = 'privatelink.azurewebsites.net'
var storageZones = [
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.queue.${environment().suffixes.storage}'
  'privatelink.table.${environment().suffixes.storage}'
]
var storageServices = [
  {
    name: 'blob'
    groupId: 'blob'
    zoneIndex: 0
  }
  {
    name: 'queue'
    groupId: 'queue'
    zoneIndex: 1
  }
  {
    name: 'table'
    groupId: 'table'
    zoneIndex: 2
  }
]
var storageRoleIds = [
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor
]
var queueContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b24988ac-6180-42a0-ab88-20f7382dd24c'
)
var websiteContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'de139f84-1756-47ae-9be6-808fbbe84772'
)
var senderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
)
var receiverRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
)

resource executorVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: executorVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.85.0.0/24']
    }
    subnets: [
      {
        name: 'function-integration'
        properties: {
          addressPrefix: '10.85.0.0/26'
          defaultOutboundAccess: false
          natGateway: {
            id: runnerNatGateway.id
          }
          delegations: [
            {
              name: 'Microsoft.Web.serverFarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: '10.85.0.64/26'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'runner'
        properties: {
          addressPrefix: '10.85.0.128/26'
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: runnerNetworkSecurityGroup.id
          }
          natGateway: {
            id: runnerNatGateway.id
          }
        }
      }
    ]
  }
}

resource runnerNatPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: runnerNatPublicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
  }
  tags: tags
}

resource runnerNatGateway 'Microsoft.Network/natGateways@2023-09-01' = {
  name: runnerNatGatewayName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: runnerNatPublicIp.id
      }
    ]
  }
  tags: tags
}

resource runnerNetworkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: runnerNetworkSecurityGroupName
  location: location
  properties: {
    securityRules: [
      {
        name: 'deny-runner-inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
  tags: tags
}

resource integrationSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: executorVnet
  name: 'function-integration'
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: executorVnet
  name: 'private-endpoints'
}

resource runnerSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: executorVnet
  name: 'runner'
}

module privateRunner 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: 'servicebus-private-runner'
  params: {
    name: 'vm-sb-runner-${environmentName}'
    computerName: 'sb-runner-${environmentName}'
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
    publicKeys: [
      {
        path: '/home/retailtxadmin/.ssh/authorized_keys'
        keyData: runnerSshPublicKey
      }
    ]
    customData: replace(runnerBootstrapScript, '\r\n', '\n')
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
      name: 'osdisk-sb-runner-${environmentName}'
      diskSizeGB: 64
      caching: 'ReadWrite'
      createOption: 'FromImage'
      deleteOption: 'Delete'
      managedDisk: { storageAccountType: 'StandardSSD_LRS' }
    }
    managedIdentities: {
      systemAssigned: true
      userAssignedResourceIds: []
    }
    nicConfigurations: [
      {
        name: 'nic-sb-runner-${environmentName}'
        deleteOption: 'Delete'
        enableAcceleratedNetworking: false
        enableIPForwarding: false
        tags: tags
        enableTelemetry: false
        ipConfigurations: [
          {
            name: 'primary'
            subnetResourceId: runnerSubnet.id
            privateIPAllocationMethod: 'Dynamic'
          }
        ]
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

resource executorVnetPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: executorVnet
  name: 'peer-stage0'
  properties: {
    remoteVirtualNetwork: {
      id: foundationVirtualNetworkId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

module foundationVnetPeering './servicebus-executor-foundation-peer.bicep' = {
  name: 'servicebus-executor-foundation-peer'
  scope: resourceGroup(subscription().subscriptionId, foundationResourceGroupName)
  params: {
    foundationVirtualNetworkName: foundationVirtualNetworkName
    executorVirtualNetworkId: executorVnet.id
    peeringName: 'peer-retailtx-sb-${environmentName}'
  }
}

resource serviceBusPrivateZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: serviceBusZoneName
}

resource serviceBusZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: serviceBusPrivateZone
  name: 'executor-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: executorVnet.id
    }
  }
}

resource webPrivateZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: webPrivateZoneName
  location: 'global'
  tags: tags
}

resource storagePrivateZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [
  for zoneName in storageZones: {
    name: zoneName
    location: 'global'
    tags: tags
  }
]

resource webPrivateZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: webPrivateZone
  name: 'executor-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: executorVnet.id
    }
  }
}

resource blobZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: storagePrivateZones[0]
  name: 'executor-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: executorVnet.id
    }
  }
}

resource queueZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: storagePrivateZones[1]
  name: 'executor-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: executorVnet.id
    }
  }
}

resource tableZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: storagePrivateZones[2]
  name: 'executor-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: executorVnet.id
    }
  }
}

resource hostStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  tags: tags
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

resource hostStorageBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: hostStorage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: hostStorageBlobService
  name: 'function-packages'
  properties: {
    publicAccess: 'None'
  }
}

resource coordinationContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: hostStorageBlobService
  name: 'scenario-coordination'
  properties: {
    publicAccess: 'None'
  }
}

resource storagePrivateEndpoints 'Microsoft.Network/privateEndpoints@2023-09-01' = [
  for service in storageServices: {
    name: 'pe-sb-${environmentName}-${service.name}'
    location: location
    tags: tags
    properties: {
      subnet: {
        id: privateEndpointSubnet.id
      }
      privateLinkServiceConnections: [
        {
          name: service.name
          properties: {
            privateLinkServiceId: hostStorage.id
            groupIds: [service.groupId]
          }
        }
      ]
    }
  }
]

resource storagePrivateEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = [
  for (service, index) in storageServices: {
    parent: storagePrivateEndpoints[index]
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: service.name
          properties: {
            privateDnsZoneId: storagePrivateZones[service.zoneIndex].id
          }
        }
      ]
    }
  }
]

resource functionsPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'plan-sb-${environmentName}'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
  tags: tags
}

var packageContainerUrl = 'https://${hostStorage.name}.blob.${environment().suffixes.storage}/${deploymentContainer.name}'
var identityBasedStorageSettings = [
  {
    name: 'AzureWebJobsStorage__accountName'
    value: hostStorage.name
  }
  {
    name: 'AzureWebJobsStorage__credential'
    value: 'managedidentity'
  }
  {
    name: 'SCENARIO_ENVIRONMENT_NAME'
    value: environmentName
  }
  {
    name: 'COORDINATION_STORAGE_ACCOUNT'
    value: hostStorage.name
  }
  {
    name: 'COORDINATION_CONTAINER'
    value: coordinationContainer.name
  }
  {
    name: 'COORDINATION_BLOB_NAME'
    value: 'scenario-state.json'
  }
  {
    name: 'EXECUTOR_QUEUE_RESOURCE_ID'
    value: queueResourceId
  }
  {
    name: 'SCENARIO_OWNER_TOKEN'
    value: ownerToken
  }
  {
    name: 'SRE_TENANT_ID'
    value: tenantId
  }
  {
    name: 'EXECUTOR_AUDIENCE'
    value: executorAudience
  }
  {
    name: 'SRE_CLIENT_APP_ID'
    value: sreClientAppId
  }
  {
    name: 'SRE_PRINCIPAL_OBJECT_ID'
    value: srePrincipalObjectId
  }
  {
    name: 'SRE_REQUIRED_ROLE'
    value: 'ServiceBus.QueueRestore'
  }
]

resource executorApp 'Microsoft.Web/sites@2024-04-01' = {
  name: executorAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
  properties: {
    serverFarmId: functionsPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: integrationSubnet.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: packageContainerUrl
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 1
        instanceMemoryMB: 2048
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: true
      appSettings: identityBasedStorageSettings
    }
  }
}

resource watchdogApp 'Microsoft.Web/sites@2024-04-01' = {
  name: watchdogAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  tags: tags
  properties: {
    serverFarmId: functionsPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: integrationSubnet.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: packageContainerUrl
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 1
        instanceMemoryMB: 2048
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: true
      appSettings: concat(identityBasedStorageSettings, [
        {
          name: 'WATCHDOG_SCHEDULE'
          value: '0 */1 * * * *'
        }
      ])
    }
  }
}

resource executorAppPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-sb-${environmentName}-executor'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'executor'
        properties: {
          privateLinkServiceId: executorApp.id
          groupIds: ['sites']
        }
      }
    ]
  }
}

resource executorAppPrivateEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: executorAppPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'web'
        properties: {
          privateDnsZoneId: webPrivateZone.id
        }
      }
    ]
  }
}

resource executorAuthentication 'Microsoft.Web/sites/config@2022-09-01' = {
  parent: executorApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [executorAudience]
          defaultAuthorizationPolicy: {
            allowedApplications: [sreClientAppId]
          }
        }
      }
    }
    httpSettings: {
      requireHttps: true
      routes: {
        apiPrefix: '/.auth'
      }
    }
  }
}

resource watchdogAuthentication 'Microsoft.Web/sites/config@2022-09-01' = {
  parent: watchdogApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [executorAudience]
          defaultAuthorizationPolicy: {
            allowedApplications: [sreClientAppId]
          }
        }
      }
    }
    httpSettings: {
      requireHttps: true
      routes: {
        apiPrefix: '/.auth'
      }
    }
  }
}

resource queue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' existing = {
  name: queueResourceName
}

resource executorStorageRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in storageRoleIds: {
    name: guid(hostStorage.id, executorApp.id, roleId)
    scope: hostStorage
    properties: {
      principalId: executorApp.identity.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    }
  }
]

resource watchdogStorageRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in storageRoleIds: {
    name: guid(hostStorage.id, watchdogApp.id, roleId)
    scope: hostStorage
    properties: {
      principalId: watchdogApp.identity.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    }
  }
]

resource executorDeploymentStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hostStorage.id, executorApp.id, 'deployment-blob-contributor')
  scope: hostStorage
  properties: {
    principalId: executorApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
  }
}

resource watchdogDeploymentStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hostStorage.id, watchdogApp.id, 'deployment-blob-contributor')
  scope: hostStorage
  properties: {
    principalId: watchdogApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
  }
}

resource executorQueueRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(queue.id, executorApp.id, queueContributorRoleId)
  scope: queue
  properties: {
    principalId: executorApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: queueContributorRoleId
  }
}

resource watchdogQueueRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(queue.id, watchdogApp.id, queueContributorRoleId)
  scope: queue
  properties: {
    principalId: watchdogApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: queueContributorRoleId
  }
}

resource runnerQueueRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in [senderRoleId, receiverRoleId]: {
    name: guid(queue.id, privateRunner.name, roleId)
    scope: queue
    properties: {
      principalId: privateRunner.outputs.systemAssignedMIPrincipalId!
      principalType: 'ServicePrincipal'
      roleDefinitionId: roleId
    }
  }
]

resource runnerCoordinationBlobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(coordinationContainer.id, privateRunner.name, 'coordination-blob-contributor')
  scope: coordinationContainer
  properties: {
    principalId: privateRunner.outputs.systemAssignedMIPrincipalId!
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
  }
}

resource runnerExecutorPublishRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(executorApp.id, privateRunner.name, websiteContributorRoleId)
  scope: executorApp
  properties: {
    principalId: privateRunner.outputs.systemAssignedMIPrincipalId!
    principalType: 'ServicePrincipal'
    roleDefinitionId: websiteContributorRoleId
  }
}

resource runnerWatchdogPublishRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(watchdogApp.id, privateRunner.name, websiteContributorRoleId)
  scope: watchdogApp
  properties: {
    principalId: privateRunner.outputs.systemAssignedMIPrincipalId!
    principalType: 'ServicePrincipal'
    roleDefinitionId: websiteContributorRoleId
  }
}

output executorAppName string = executorApp.name
output executorAppId string = executorApp.id
output executorPrivateEndpointId string = executorAppPrivateEndpoint.id
output executorIdentityPrincipalId string = executorApp.identity.principalId
output watchdogAppName string = watchdogApp.name
output watchdogAppId string = watchdogApp.id
output watchdogIdentityPrincipalId string = watchdogApp.identity.principalId
output runnerVmName string = privateRunner.outputs.name
output runnerVmId string = privateRunner.outputs.resourceId
output runnerIdentityPrincipalId string = privateRunner.outputs.systemAssignedMIPrincipalId!
output runnerQueueRoleAssignmentIds array = [
  runnerQueueRoleAssignments[0].id
  runnerQueueRoleAssignments[1].id
]
output runnerExecutorPublishRoleAssignmentId string = runnerExecutorPublishRole.id
output runnerWatchdogPublishRoleAssignmentId string = runnerWatchdogPublishRole.id
output hostStorageName string = hostStorage.name
output coordinationContainerId string = coordinationContainer.id
output coordinationContainerName string = coordinationContainer.name
output coordinationBlobName string = 'scenario-state.json'
output executorVnetId string = executorVnet.id
output executorVnetPeeringId string = executorVnetPeering.id
output foundationVnetPeeringId string = foundationVnetPeering.outputs.peeringId
output executorQueueRoleAssignmentId string = executorQueueRoleAssignment.id
output watchdogQueueRoleAssignmentId string = watchdogQueueRoleAssignment.id
