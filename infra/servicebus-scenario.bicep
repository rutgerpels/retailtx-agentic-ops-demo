targetScope = 'resourceGroup'

@description('Generic environment ID; do not include delivery stages or milestone numbers.')
@minLength(3)
@maxLength(12)
param environmentName string

@description('Lifecycle-generated ownership GUID, not a credential.')
@minLength(36)
@maxLength(36)
param ownerToken string

@description('Expiry recorded on owned Azure resources for operator cleanup.')
param expiresAt string

@description('Existing private endpoint subnet in the retained Stage 0 VNet.')
param privateEndpointSubnetId string

@description('Existing retained Stage 0 VNet, linked to the owned Service Bus private DNS zone.')
param virtualNetworkId string

param location string = resourceGroup().location

var tags = {
  demo: 'retailtx'
  environmentId: environmentName
  profile: 'servicebus'
  ownerToken: ownerToken
  managedBy: 'retailtx'
  expiresAt: expiresAt
}
var namespaceName = 'sbtx${uniqueString(subscription().subscriptionId, environmentName)}'
var queueName = 'recovery-${environmentName}'
module broker 'br/public:avm/res/service-bus/namespace:0.17.1' = {
  name: 'service-bus'
  params: {
    name: namespaceName
    location: location
    skuObject: {
      name: 'Premium'
      capacity: 1
    }
    premiumMessagingPartitions: 1
    zoneRedundant: true
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: '1.2'
    queues: []
    tags: tags
    enableTelemetry: false
  }
}

resource scenarioQueue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  name: '${namespaceName}/${queueName}'
  dependsOn: [broker]
  properties: {
    status: 'Active'
    lockDuration: 'PT30S'
    maxDeliveryCount: 5
    maxSizeInMegabytes: 1024
    requiresDuplicateDetection: false
    requiresSession: false
    deadLetteringOnMessageExpiration: true
  }
}

module serviceBusZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'service-bus-private-dns'
  params: {
    name: 'privatelink.servicebus.windows.net'
    virtualNetworkLinks: [
      {
        name: 'retained-stage0'
        virtualNetworkResourceId: virtualNetworkId
        registrationEnabled: false
        tags: tags
      }
    ]
    tags: tags
    enableTelemetry: false
  }
}

module privateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'service-bus-private-endpoint'
  params: {
    name: 'pe-retailtx-${environmentName}-servicebus'
    location: location
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: 'servicebus'
        properties: {
          privateLinkServiceId: broker.outputs.resourceId
          groupIds: ['namespace']
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'servicebus'
          privateDnsZoneResourceId: serviceBusZone.outputs.resourceId
        }
      ]
    }
    tags: tags
    enableTelemetry: false
  }
}

resource sendFailureAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-servicebus-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Service Bus UserErrors on the dedicated RetailTx recovery queue.'
    severity: 2
    enabled: true
    autoMitigate: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [broker.outputs.resourceId]
    targetResourceType: 'Microsoft.ServiceBus/namespaces'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'QueueSendErrors'
          metricName: 'UserErrors'
          metricNamespace: 'Microsoft.ServiceBus/namespaces'
          timeAggregation: 'Total'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: [
            {
              name: 'EntityName'
              operator: 'Include'
              values: [queueName]
            }
          ]
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: []
  }
}

output namespaceName string = broker.outputs.name
output namespaceId string = broker.outputs.resourceId
output queueName string = queueName
output queueId string = scenarioQueue.id
output privateEndpointId string = privateEndpoint.outputs.resourceId
output privateDnsZoneId string = serviceBusZone.outputs.resourceId
output sendFailureAlertId string = sendFailureAlert.id
