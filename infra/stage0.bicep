targetScope = 'resourceGroup'

@description('Generic environment identifier validated by lifecycle before deployment.')
@minLength(2)
@maxLength(20)
param environmentName string

@description('Location of the owned Stage 0 resources.')
param location string = resourceGroup().location

@description('Lifecycle-generated ownership GUID, not a credential. Propagated to owned resources and Arc bootstrap.')
@minLength(36)
@maxLength(36)
param ownerToken string

@description('Ephemeral public SSH key only; bootstrap disables SSH. The VM has no public IP and denies all inbound connections.')
@minLength(1)
param adminSshPublicKey string

@description('Entra object ID to receive SRE Agent Administrator on this agent only.')
@minLength(36)
@maxLength(36)
param deployerObjectId string

@description('Single Arc evaluation host size.')
param vmSize string = 'Standard_B2s'

@description('Pinned Canonical:ubuntu-24_04-lts:server Gen2 image version.')
param vmImageVersion string = '24.04.202609040'

var tags = {
  demo: 'retailtx'
  environmentId: environmentName
  ownerToken: ownerToken
  managedBy: 'retailtx-stage0'
}
var suffix = 'retailtx-${environmentName}'
var vnetName = 'vnet-${suffix}'
var vmName = 'vm-${suffix}'
var arcMachineName = 'erp-core-01'
var bootstrapIdentityName = 'id-${suffix}-bootstrap'
var sreIdentityName = 'id-${suffix}-sre'
var sreIdentityResourceId = resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', sreIdentityName)
var adminUsername = 'retailtxadmin'
var arcDnsZoneNames = [
  'privatelink.his.arc.azure.com'
  'privatelink.guestconfiguration.azure.com'
]
var monitorDnsZoneNames = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.blob.${environment().suffixes.storage}'
]
var privateDnsZoneNames = concat(arcDnsZoneNames, monitorDnsZoneNames)
var readerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
var logAnalyticsReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
var networkContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
// Verified built-in Azure Connected Machine Onboarding. Removed by lifecycle once connected.
var onboardingRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7')
var sreAdminRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e79298df-d852-4c6d-84f9-5d13249d1e55')

// AVM examples and exact parameter types reviewed at these pinned versions:
// https://github.com/Azure/bicep-registry-modules/tree/avm/res/network/virtual-network/0.10.2/avm/res/network/virtual-network
// https://github.com/Azure/bicep-registry-modules/tree/avm/res/operational-insights/workspace/0.16.1/avm/res/operational-insights/workspace
module outboundPublicIp 'br/public:avm/res/network/public-ip-address:0.13.0' = {
  name: 'outbound-public-ip'
  params: {
    name: 'pip-${suffix}-egress'
    location: location
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'
    availabilityZones: []
    tags: tags
    enableTelemetry: false
  }
}

// This is the only public IP: attached exclusively to NAT, never the VM NIC.
module natGateway 'br/public:avm/res/network/nat-gateway:2.1.1' = {
  name: 'outbound-nat'
  params: {
    name: 'nat-${suffix}'
    location: location
    natGatewaySku: 'Standard'
    availabilityZone: -1
    publicIpResourceIds: [outboundPublicIp.outputs.resourceId]
    tags: tags
    enableTelemetry: false
  }
}

module hostNsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'host-nsg'
  params: {
    name: 'nsg-${suffix}-host'
    location: location
    tags: tags
    enableTelemetry: false
    securityRules: [
      {
        name: 'DenyAllInbound'
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
      {
        name: 'AllowPrivateEndpointHttps'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '10.84.1.0/24'
          destinationPortRange: '443'
        }
      }
      // AzurePlatformDNS/IMDS are deny-only service tags, not allow-list tags.
      // These platform services bypass ordinary NSG rules (including the final
      // outbound deny) unless explicitly denied via their platform service tag.
      // Keep DNS and initial IMDS token acquisition available; bootstrap blocks
      // IMDS persistently inside the guest after acquiring its temporary token.
      // https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview#azure-platform-considerations
      {
        name: 'AllowOutboundHttps'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowPackageHttp'
        properties: {
          priority: 140
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
      {
        name: 'DenyOtherOutbound'
        properties: {
          priority: 4096
          direction: 'Outbound'
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
}

module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'network'
  params: {
    name: vnetName
    location: location
    addressPrefixes: ['10.84.0.0/16']
    tags: tags
    enableTelemetry: false
    subnets: [
      {
        name: 'host'
        addressPrefix: '10.84.0.0/24'
        natGatewayResourceId: natGateway.outputs.resourceId
        networkSecurityGroupResourceId: hostNsg.outputs.resourceId
        defaultOutboundAccess: false
        privateEndpointNetworkPolicies: 'Disabled'
      }
      {
        name: 'private-endpoints'
        addressPrefix: '10.84.1.0/24'
        defaultOutboundAccess: false
        privateEndpointNetworkPolicies: 'Disabled'
      }
      {
        name: 'sre'
        addressPrefix: '10.84.2.0/27'
        // AVM 0.10.2 takes one delegation STRING, not an ARM delegations array.
        delegation: 'Microsoft.App/environments'
        natGatewayResourceId: natGateway.outputs.resourceId
        defaultOutboundAccess: false
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
  }
}

resource existingVnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: vnetName
}
resource sreSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-05-01' existing = {
  parent: existingVnet
  name: 'sre'
}

// Owned local zones only; do not discover or mutate shared DNS or policy.
// Arc: https://learn.microsoft.com/azure/azure-arc/servers/private-link-security
// Monitor: https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-configure
module privateDnsZones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [for zoneName in privateDnsZoneNames: {
  name: 'dns-${uniqueString(zoneName)}'
  params: {
    name: zoneName
    tags: tags
    enableTelemetry: false
    virtualNetworkLinks: [
      {
        name: 'retailtx-vnet'
        virtualNetworkResourceId: vnet.outputs.resourceId
        registrationEnabled: false
        tags: tags
      }
    ]
  }
}]

module workspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'workspace'
  params: {
    name: 'law-${suffix}'
    location: location
    skuName: 'PerGB2018'
    dataRetention: 30
    // Same-name workspace recreation can recover a soft-deleted workspace before
    // its built-in tables are ready for DCR validation. Materialize the two DCR
    // destinations inside this AVM deployment so its completion includes their
    // table operations, rather than only the workspace resource's completion.
    // These are Microsoft tables: omit schema/columns and preserve Analytics.
    // Omitted table retention uses AVM's -1 defaults: inherit the existing 30-day
    // workspace retention, with no separate long-term retention or data purge.
    // https://learn.microsoft.com/azure/azure-monitor/logs/data-retention-configure
    tables: [for tableName in ['Syslog', 'Perf']: {
      name: tableName
      plan: 'Analytics'
    }]
    features: {
      disableLocalAuth: true
    }
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
    forceCmkForQuery: false
    tags: tags
    enableTelemetry: false
  }
}

module dce 'br/public:avm/res/insights/data-collection-endpoint:0.5.1' = {
  name: 'data-collection-endpoint'
  params: {
    name: 'dce-${suffix}'
    location: location
    kind: 'Linux'
    publicNetworkAccess: 'Disabled'
    tags: tags
    enableTelemetry: false
  }
}

module ampls 'br/public:avm/res/insights/private-link-scope:0.7.3' = {
  name: 'monitor-private-link-scope'
  params: {
    name: 'ampls-${suffix}'
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'PrivateOnly'
    }
    scopedResources: [
      {
        name: 'workspace'
        linkedResourceId: workspace.outputs.resourceId
      }
      {
        name: 'data-collection-endpoint'
        linkedResourceId: dce.outputs.resourceId
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

// Arc server private-link scopes have no published AVM resource module.
resource arcPrivateLinkScope 'Microsoft.HybridCompute/privateLinkScopes@2022-12-27' = {
  name: 'pls-${suffix}-arc'
  location: location
  tags: tags
  properties: {
    publicNetworkAccess: 'Disabled'
  }
}

module arcPrivateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'arc-private-endpoint'
  params: {
    name: 'pe-${suffix}-arc'
    location: location
    subnetResourceId: vnet.outputs.subnetResourceIds[1]
    privateLinkServiceConnections: [
      {
        name: 'arc'
        properties: {
          privateLinkServiceId: arcPrivateLinkScope.id
          groupIds: ['hybridcompute']
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [for (zoneName, index) in arcDnsZoneNames: {
        name: replace(zoneName, '.', '-')
        privateDnsZoneResourceId: privateDnsZones[index].outputs.resourceId
      }]
    }
    tags: tags
    enableTelemetry: false
  }
}

module monitorPrivateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'monitor-private-endpoint'
  params: {
    name: 'pe-${suffix}-monitor'
    location: location
    subnetResourceId: vnet.outputs.subnetResourceIds[1]
    privateLinkServiceConnections: [
      {
        name: 'monitor'
        properties: {
          privateLinkServiceId: ampls.outputs.resourceId
          groupIds: ['azuremonitor']
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [for (zoneName, index) in monitorDnsZoneNames: {
        name: replace(zoneName, '.', '-')
        privateDnsZoneResourceId: privateDnsZones[index + length(arcDnsZoneNames)].outputs.resourceId
      }]
    }
    tags: tags
    enableTelemetry: false
  }
}

// Minimal Linux collection, adapted from the pinned AVM Linux example.
// No workspace keys, custom log endpoint tokens or data-plane credentials.
module dcr 'br/public:avm/res/insights/data-collection-rule:0.11.0' = {
  name: 'data-collection-rule'
  params: {
    name: 'dcr-${suffix}-host'
    location: location
    tags: tags
    enableTelemetry: false
    dataCollectionRuleProperties: {
      kind: 'Linux'
      dataCollectionEndpointResourceId: dce.outputs.resourceId
      dataSources: {
        syslog: [
          {
            name: 'retailtx-syslog'
            streams: ['Microsoft-Syslog']
            facilityNames: ['local0']
            logLevels: ['Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency']
          }
        ]
        performanceCounters: [
          {
            name: 'host-performance'
            streams: ['Microsoft-Perf']
            samplingFrequencyInSeconds: 60
            counterSpecifiers: [
              'Processor(*)\\% Processor Time'
              'Memory(*)\\% Used Memory'
            ]
          }
        ]
      }
      destinations: {
        logAnalytics: [
          {
            name: 'stage0-workspace'
            // Referencing the module output makes the DCR wait for the ENTIRE
            // workspace deployment, including both explicit table operations.
            workspaceResourceId: workspace.outputs.resourceId
          }
        ]
      }
      dataFlows: [
        {
          streams: ['Microsoft-Syslog', 'Microsoft-Perf']
          destinations: ['stage0-workspace']
        }
      ]
    }
  }
}

module bootstrapIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'bootstrap-identity'
  params: {
    name: bootstrapIdentityName
    location: location
    tags: tags
    enableTelemetry: false
  }
}

resource bootstrapOnboarding 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // Stable ID: repeated up reapplies this role; lifecycle removes this exact ID.
  name: guid(resourceGroup().id, resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', bootstrapIdentityName), onboardingRoleId)
  properties: {
    roleDefinitionId: onboardingRoleId
    principalId: bootstrapIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// Only public IDs/tags are substituted. The token is acquired at runtime by the
// parent-owned script and is never a Bicep parameter, deployment output or file.
// Normalize CRLF so a Windows checkout still produces a valid Linux shebang.
var bootstrapTemplate = replace(loadTextContent('../scripts/bootstrap-arc.sh'), '\r\n', '\n')
var bootstrapSubscription = replace(bootstrapTemplate, '__SUBSCRIPTION_ID__', subscription().subscriptionId)
var bootstrapTenant = replace(bootstrapSubscription, '__TENANT_ID__', tenant().tenantId)
var bootstrapResourceGroup = replace(bootstrapTenant, '__RESOURCE_GROUP__', resourceGroup().name)
var bootstrapLocation = replace(bootstrapResourceGroup, '__LOCATION__', location)
var bootstrapMachine = replace(bootstrapLocation, '__ARC_MACHINE_NAME__', arcMachineName)
var bootstrapScope = replace(bootstrapMachine, '__ARC_SCOPE_ID__', arcPrivateLinkScope.id)
var bootstrapClient = replace(bootstrapScope, '__BOOTSTRAP_CLIENT_ID__', bootstrapIdentity.outputs.clientId)
var bootstrapOwner = replace(bootstrapClient, '__OWNER_TOKEN__', ownerToken)
var bootstrapScript = replace(bootstrapOwner, '__ENVIRONMENT_NAME__', environmentName)

// The pinned VM module's tags use the newer 2025-11-01 resourceInput type.
// Bicep 0.42.1 lacks that type; all VM settings use the reviewed AVM interface.
#disable-next-line BCP081
module host 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: 'arc-evaluation-host'
  params: {
    name: vmName
    computerName: arcMachineName
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
    adminUsername: adminUsername
    disablePasswordAuthentication: true
    publicKeys: [
      {
        keyData: adminSshPublicKey
        path: '/home/${adminUsername}/.ssh/authorized_keys'
      }
    ]
    // AVM performs base64(customData) exactly once in the VM osProfile.
    customData: bootstrapScript
    provisionVMAgent: true
    allowExtensionOperations: false
    patchMode: 'ImageDefault'
    patchAssessmentMode: 'ImageDefault'
    // No VM extensions. Bootstrap itself disables walinuxagent/SSH and blocks
    // Azure IMDS persistently after acquiring the temporary onboarding token.
    extensionAadJoinConfig: { enabled: false }
    extensionAntiMalwareConfig: { enabled: false }
    extensionMonitoringAgentConfig: { enabled: false, dataCollectionRuleAssociations: [] }
    extensionDependencyAgentConfig: { enabled: false }
    extensionNetworkWatcherAgentConfig: { enabled: false }
    extensionAzureDiskEncryptionConfig: { enabled: false }
    extensionDSCConfig: { enabled: false }
    extensionGuestConfigurationExtension: { enabled: false }
    // Platform-managed boot logs/screenshots remain available without SSH or
    // the guest agent. Empty account name makes AVM emit storageUri: null:
    // no customer storage resource, account key, SAS or diagnostic URL output.
    // customData above embeds only the script and public IDs, never its runtime
    // access token; do not add credential substitutions or expose customData.
    // https://learn.microsoft.com/azure/virtual-machines/boot-diagnostics
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
      managedDisk: {
        storageAccountType: 'StandardSSD_LRS'
      }
    }
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [bootstrapIdentity.outputs.resourceId]
    }
    nicConfigurations: [
      {
        name: 'nic-${suffix}-host'
        deleteOption: 'Delete'
        enableAcceleratedNetworking: false
        enableIPForwarding: false
        tags: tags
        enableTelemetry: false
        ipConfigurations: [
          {
            name: 'primary'
            subnetResourceId: vnet.outputs.subnetResourceIds[0]
          }
        ]
      }
    ]
    tags: union(tags, {
      system: 'ERP'
      site: 'simulated-datacenter'
      arcEvaluation: 'true'
    })
    enableTelemetry: false
  }
  dependsOn: [
    bootstrapOnboarding
    arcPrivateEndpoint
    monitorPrivateEndpoint
  ]
}

module sreIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'sre-identity'
  params: {
    name: sreIdentityName
    location: location
    tags: tags
    enableTelemetry: false
  }
}

resource sreSubnetJoin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreSubnet.id, resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', sreIdentityName), networkContributorRoleId)
  scope: sreSubnet
  properties: {
    roleDefinitionId: networkContributorRoleId
    principalId: sreIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [vnet]
}

resource sreIdentityReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in [readerRoleId, logAnalyticsReaderRoleId]: {
  name: guid(resourceGroup().id, resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', sreIdentityName), roleId)
  properties: {
    roleDefinitionId: roleId
    principalId: sreIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}]

// No AVM yet for Microsoft.App/agents. Stable RP core schema:
// https://github.com/Azure/azure-rest-api-specs/blob/main/specification/app/resource-manager/Microsoft.App/SreAgent/stable/2026-01-01/sreagent.json
// VNet/sandbox shape is documented in Microsoft's pinned official template:
// https://github.com/microsoft/sre-agent/blob/25a42306d298c4d28f11dd11ef9bb93cb0393be8/sreagent-templates/bicep/agent-core.bicep
// The stable published swagger/types omit those network fields; the narrow
// BCP089/BCP037 suppressions below do NOT prove RP acceptance. Lifecycle must
// verify effective VNet/private DNS/egress configuration after provisioning.
// logConfiguration is not required by that swagger: omit it rather than add
// Application Insights/local-auth dependencies. No model override or triggers.
resource sreAgent 'Microsoft.App/agents@2026-01-01' = {
  name: 'sre-retailtx-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${sreIdentityResourceId}': {}
    }
  }
  properties: {
    actionConfiguration: {
      identity: sreIdentity.outputs.resourceId
      accessLevel: 'Low'
      mode: 'Review'
    }
    knowledgeGraphConfiguration: {
      identity: sreIdentity.outputs.resourceId
      managedResources: [resourceGroup().id]
    }
    upgradeChannel: 'Stable'
    // Official pinned template field absent from stable generated types.
    #disable-next-line BCP089
    vnetConfiguration: {
      subnetResourceId: sreSubnet.id
    }
    // Official pinned template field absent from stable generated types.
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
    sreSubnetJoin
    sreIdentityReaders
    monitorPrivateEndpoint
    arcPrivateEndpoint
  ]
}

// Both SRE identities are read-only on the owned RG. Network Contributor above
// is limited to the dedicated delegated subnet; no Contributor/RunCommand role.
resource sreSystemIdentityReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in [readerRoleId, logAnalyticsReaderRoleId]: {
  name: guid(resourceGroup().id, sreAgent.id, roleId)
  properties: {
    roleDefinitionId: roleId
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource sreDeployerAdministrator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, deployerObjectId, sreAdminRoleId)
  scope: sreAgent
  properties: {
    roleDefinitionId: sreAdminRoleId
    principalId: deployerObjectId
    // Deliberately omit principalType: lifecycle may run as a human or an SP.
  }
}

// SRE inbound Private Link is unsupported. Connectors run outside VNet and are
// intentionally absent; this template makes no private-connector claim.
output RESOURCE_GROUP_NAME string = resourceGroup().name
output VM_NAME string = host.outputs.name
output ARC_MACHINE_NAME string = arcMachineName
output ARC_PRIVATE_LINK_SCOPE_ID string = arcPrivateLinkScope.id
output WORKSPACE_ID string = workspace.outputs.resourceId
output WORKSPACE_CUSTOMER_ID string = workspace.outputs.logAnalyticsWorkspaceId
output DCE_ID string = dce.outputs.resourceId
output DCR_ID string = dcr.outputs.resourceId
output SRE_AGENT_ID string = sreAgent.id
// Actual read-only RP property from the stable schema, not a constructed URL.
output SRE_ENDPOINT string = sreAgent.properties.agentEndpoint
output BOOTSTRAP_IDENTITY_ID string = bootstrapIdentity.outputs.resourceId
output BOOTSTRAP_ROLE_ASSIGNMENT_ID string = bootstrapOnboarding.id
