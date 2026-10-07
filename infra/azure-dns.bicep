targetScope = 'resourceGroup'
param environmentName string
param tags object
param cloudVnetId string
param dcVnetId string

var zoneNames = [
  'privatelink.postgres.database.azure.com'
  'privatelink.servicebus.windows.net'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.his.arc.azure.com'
  'privatelink.guestconfiguration.azure.com'
]
var links = [for (vnetId, i) in [cloudVnetId, dcVnetId]: {
  name: i == 0 ? 'cloud' : 'dc'
  virtualNetworkResourceId: vnetId
  registrationEnabled: false
  tags: tags
}]
// One owned blob zone is deliberately shared by artifacts and Azure Monitor.
module zones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [for zone in zoneNames: {
  name: 'dns-${uniqueString(zone)}'
  params: {
    name: zone
    virtualNetworkLinks: links
    tags: tags
    enableTelemetry: false
  }
}]
module internalZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'internal-dns'
  params: {
    name: '${environmentName}.retailtx.internal'
    virtualNetworkLinks: links
    a: [
      { name: 'cap', ttl: 60, aRecords: [{ ipv4Address: '10.86.0.4' }] }
      { name: 'erp', ttl: 60, aRecords: [{ ipv4Address: '10.87.0.4' }] }
    ]
    tags: tags
    enableTelemetry: false
  }
}
output postgresZoneId string = zones[0].outputs.resourceId
output serviceBusZoneId string = zones[1].outputs.resourceId
output blobZoneId string = zones[2].outputs.resourceId
output monitorZoneIds array = [for i in range(2, 5): zones[i].outputs.resourceId]
output arcZoneIds array = [for i in range(7, 2): zones[i].outputs.resourceId]
