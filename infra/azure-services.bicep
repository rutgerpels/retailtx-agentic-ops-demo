targetScope = 'resourceGroup'
param environmentName string
param location string
param tags object
param privateEndpointSubnetId string
param postgresZoneId string
param serviceBusZoneId string
param blobZoneId string
param databaseBootstrapPrincipalId string = ''
param databaseBootstrapName string

var suffix = 'retailtx-${environmentName}-${uniqueString(subscription().subscriptionId, environmentName)}'
// Based on the AVM public-with-pe example: no delegated subnet is supplied.
// Disabled public access retains private endpoints, not public firewall access.
// https://learn.microsoft.com/azure/postgresql/network/how-to-networking-servers-deployed-public-access-disable-public-access
module postgres 'br/public:avm/res/db-for-postgre-sql/flexible-server:0.16.1' = {
  name: 'postgres'
  params: {
    name: 'psql-${suffix}'
    location: location
    skuName: 'Standard_B1ms'
    tier: 'Burstable'
    availabilityZone: -1
    highAvailability: 'Disabled'
    geoRedundantBackup: 'Disabled'
    backupRetentionDays: 7
    storageSizeGB: 32
    version: '17'
    publicNetworkAccess: 'Disabled'
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled'
      tenantId: tenant().tenantId
    }
    administrators: empty(databaseBootstrapPrincipalId) ? [] : [
      {
        objectId: databaseBootstrapPrincipalId
        principalName: databaseBootstrapName
        principalType: 'ServicePrincipal'
        tenantId: tenant().tenantId
      }
    ]
    databases: [{ name: 'retailtx', charset: 'UTF8', collation: 'en_US.utf8' }]
    configurations: [
      { name: 'require_secure_transport', value: 'on', source: 'user-override' }
      { name: 'ssl_min_protocol_version', value: 'TLSv1.2', source: 'user-override' }
    ]
    tags: tags
    enableTelemetry: false
  }
}
module broker 'br/public:avm/res/service-bus/namespace:0.17.1' = {
  name: 'service-bus'
  params: {
    name: 'sb-${suffix}'
    location: location
    skuObject: { name: 'Premium', capacity: 1 }
    premiumMessagingPartitions: 1
    zoneRedundant: true
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: '1.2'
    // Keep AVM's default authorization-rule resource: its protected outputs
    // evaluate listKeys against that rule. Local auth is disabled; never consume
    // or forward those protected outputs. No client can authenticate with SAS.
    queues: [
      {
        name: 'IDOC_POSTING'
        lockDuration: 'PT30S'
        maxDeliveryCount: 5
        requiresDuplicateDetection: false
        requiresSession: false
        deadLetteringOnMessageExpiration: true
        authorizationRules: []
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}
module artifacts 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'artifacts'
  params: {
    name: 'strtx${uniqueString(subscription().subscriptionId, environmentName)}'
    location: location
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    blobServices: {
      containers: [
        { name: 'releases', publicAccess: 'None' }
        { name: 'provisioning', publicAccess: 'None' }
      ]
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: 7
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 7
    }
    tags: tags
    enableTelemetry: false
  }
}
var endpoints = [
  { name: 'postgres', resourceId: postgres.outputs.resourceId, groupId: 'postgresqlServer', zoneId: postgresZoneId }
  { name: 'servicebus', resourceId: broker.outputs.resourceId, groupId: 'namespace', zoneId: serviceBusZoneId }
  { name: 'blob', resourceId: artifacts.outputs.resourceId, groupId: 'blob', zoneId: blobZoneId }
]
module endpointsPrivate 'br/public:avm/res/network/private-endpoint:0.12.1' = [for i in range(0, 3): {
  name: 'pe-${i}'
  params: {
    name: 'pe-retailtx-${environmentName}-${endpoints[i].name}'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      { name: endpoints[i].name, properties: { privateLinkServiceId: endpoints[i].resourceId, groupIds: [endpoints[i].groupId] } }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [{ name: 'service', privateDnsZoneResourceId: endpoints[i].zoneId }]
    }
    tags: tags
    enableTelemetry: false
  }
}]
output postgresName string = postgres.outputs.name
output postgresId string = postgres.outputs.resourceId
output postgresFqdn string = postgres.outputs.fqdn!
output databaseBootstrapAdministratorId string = empty(databaseBootstrapPrincipalId) ? '' : '${postgres.outputs.resourceId}/administrators/${databaseBootstrapPrincipalId}'
output serviceBusName string = broker.outputs.name
output serviceBusNamespace string = '${broker.outputs.name}.servicebus.windows.net'
output queueId string = '${broker.outputs.resourceId}/queues/IDOC_POSTING'
output storageAccountName string = artifacts.outputs.name
output blobEndpoint string = artifacts.outputs.primaryBlobEndpoint
output releaseContainerId string = '${artifacts.outputs.resourceId}/blobServices/default/containers/releases'
output provisioningContainerId string = '${artifacts.outputs.resourceId}/blobServices/default/containers/provisioning'
