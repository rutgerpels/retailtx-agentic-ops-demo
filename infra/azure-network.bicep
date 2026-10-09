targetScope = 'resourceGroup'

param environmentName string
param location string
param tags object
@allowed(['cloud', 'dc'])
param domain string
@description('Enable only if the bootstrap cannot switch Ubuntu package sources to HTTPS. NSGs cannot restrict HTTP by hostname.')
param allowPackageHttpEgress bool = false

var suffix = 'retailtx-${domain}-${environmentName}'
var hostCidr = domain == 'cloud' ? '10.86.0.0/24' : '10.87.0.0/24'
var peerIp = domain == 'cloud' ? '10.87.0.4' : '10.86.0.4'

// A separate NAT per VNet: NAT is not transitive across VNet peering.
module publicIp 'br/public:avm/res/network/public-ip-address:0.13.0' = {
  name: 'egress-ip'
  params: {
    name: 'pip-${suffix}-egress'
    location: location
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'
    tags: tags
    enableTelemetry: false
  }
}
module nat 'br/public:avm/res/network/nat-gateway:2.1.1' = {
  name: 'egress-nat'
  params: {
    availabilityZone: -1
    name: 'nat-${suffix}'
    location: location
    publicIpResourceIds: [publicIp.outputs.resourceId]
    tags: tags
    enableTelemetry: false
  }
}
module nsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'host-nsg'
  params: {
    name: 'nsg-${suffix}-host'
    location: location
    tags: tags
    enableTelemetry: false
    securityRules: concat([
      {
        name: 'PeerApplicationHttpsInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '8443'
          sourceAddressPrefix: peerIp
          destinationAddressPrefix: hostCidr
        }
      }
      {
        name: 'DenyAllInbound'
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
        name: 'PeerApplicationHttpsOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '8443'
          sourceAddressPrefix: hostCidr
          destinationAddressPrefix: peerIp
        }
      }
      {
        name: 'PrivateServices'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: domain == 'cloud' ? ['443', '5432', '5671'] : ['443', '5671']
          sourceAddressPrefix: hostCidr
          destinationAddressPrefix: '10.86.1.0/24'
        }
      }
      // AzurePlatformDNS/IMDS tags support Deny only, never Allow. These
      // platform services bypass ordinary NSG rules, including final egress deny,
      // unless explicitly denied by their platform tag. Keep DNS and initial
      // IMDS available; DC bootstrap still blocks IMDS persistently in the guest.
      // https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview#azure-platform-considerations
      {
        name: 'HttpsEgress'
        properties: {
          priority: 140
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: hostCidr
          destinationAddressPrefix: 'Internet'
        }
      }
      {
        name: 'DenyOtherEgress'
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
    ], allowPackageHttpEgress ? [
      {
        name: 'BootstrapPackagesHttp'
        properties: {
          priority: 150
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: hostCidr
          destinationAddressPrefix: 'Internet'
        }
      }
    ] : [])
  }
}
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet'
  params: {
    name: 'vnet-${suffix}'
    location: location
    addressPrefixes: [domain == 'cloud' ? '10.86.0.0/16' : '10.87.0.0/16']
    subnets: concat([
      {
        name: 'host'
        addressPrefix: hostCidr
        natGatewayResourceId: nat.outputs.resourceId
        networkSecurityGroupResourceId: nsg.outputs.resourceId
        defaultOutboundAccess: false
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ], domain == 'cloud' ? [
      {
        name: 'private-endpoints'
        addressPrefix: '10.86.1.0/24'
        defaultOutboundAccess: false
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ] : [])
    tags: tags
    enableTelemetry: false
  }
}
output vnetId string = vnet.outputs.resourceId
output vnetName string = vnet.outputs.name
output hostSubnetId string = vnet.outputs.subnetResourceIds[0]
output privateEndpointSubnetId string = domain == 'cloud' ? vnet.outputs.subnetResourceIds[1] : ''
