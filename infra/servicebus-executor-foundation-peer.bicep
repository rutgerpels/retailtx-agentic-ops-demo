targetScope = 'resourceGroup'

param foundationVirtualNetworkName string
param executorVirtualNetworkId string
param peeringName string

resource foundationVnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: foundationVirtualNetworkName
}

resource executorPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: foundationVnet
  name: peeringName
  properties: {
    remoteVirtualNetwork: {
      id: executorVirtualNetworkId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

output peeringId string = executorPeering.id
