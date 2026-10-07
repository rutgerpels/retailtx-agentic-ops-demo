targetScope = 'subscription'

@description('Lowercase letters/digits/hyphens; lifecycle validates syntax, subscription, and ownership before every deployment.')
@minLength(2)
@maxLength(12)
param environmentName string = 'demo01'
param location string = 'swedencentral'
@description('Lifecycle-owned GUID, not a credential. Must match all three existing groups before an update.')
@minLength(36)
@maxLength(36)
param ownerToken string
@description('ISO-8601 timestamp for reporting only. No expiry automation or deletion is installed.')
param expiresAt string
@description('Ephemeral SSH PUBLIC key only. No inbound SSH is permitted; bootstrap disables SSH.')
param adminSshPublicKey string
@secure()
@maxLength(48000)
@description('Plaintext cloud bootstrap containing public IDs/config only; AVM base64-encodes once. Supply empty only for deployHosts=false.')
param cloudBootstrapScript string
@secure()
@maxLength(48000)
@description('Plaintext DC bootstrap; must disable guest agent/SSH and persistently block IMDS after Arc onboarding. No credentials in customData.')
param dcBootstrapScript string
@description('Foundation-only pass can obtain public service/UAMI outputs before parent renders immutable customData.')
param deployHosts bool = true
@description('False detaches temporary UAMIs and stops reasserting bootstrap grants/admin. Incremental deployment does NOT delete them: capture cleanup IDs, detach, then explicitly delete using lifecycle.')
param enableBootstrapIdentities bool = true
@description('Temporary cloud system-MI Contributor on ONLY releases/provisioning containers for deployment bridge. Disable and explicitly delete returned assignments after setup; Reader on releases remains.')
param enableArtifactBridge bool = enableBootstrapIdentities
param allowPackageHttpEgress bool = false
@description('Create/enable alert rules only after verified AppTraces ingestion. False omits rules and their reader grants entirely; it does not disable/delete rules left by an earlier deployment.')
param enableAlerts bool = false
@minValue(0)
param backlogThresholdCount int = 0
@minValue(5)
@maxValue(60)
param staleAfterMinutes int = 10
param enableCloudVerificationReader bool = true
@description('Optional [{principalId, principalType: User|Group|ServicePrincipal}] for workspace query verification. Private network access is still required.')
param verificationReaders array = []
param vmSize string = 'Standard_B2s'
@description('Pinned Canonical Ubuntu 24.04 Gen2 version, matching the verified proof image.')
param vmImageVersion string = '24.04.202609040'

var tags = {
  demo: 'retailtx'
  environmentId: environmentName
  profile: 'azure-lite'
  ownerToken: ownerToken
  managedBy: 'retailtx'
  expiresAt: expiresAt
}
var domains = ['cloud', 'dc', 'ops']
var cloudRg = 'rg-retailtx-cloud-${environmentName}-${location}'
var dcRg = 'rg-retailtx-dc-${environmentName}-${location}'
var opsRg = 'rg-retailtx-ops-${environmentName}-${location}'
var databaseIdentityName = 'id-retailtx-database-bootstrap-${environmentName}'
var dcIdentityName = 'id-retailtx-dc-bootstrap-${environmentName}'

module groups 'br/public:avm/res/resources/resource-group:0.4.4' = [for domain in domains: {
  name: 'rg-${domain}-${environmentName}'
  params: {
    name: 'rg-retailtx-${domain}-${environmentName}-${location}'
    location: location
    tags: tags
    enableTelemetry: false
  }
}]
module cloudNetwork 'azure-network.bicep' = {
  name: 'network-cloud-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: { environmentName: environmentName, location: location, tags: tags, domain: 'cloud', allowPackageHttpEgress: allowPackageHttpEgress }
  dependsOn: [groups]
}
module dcNetwork 'azure-network.bicep' = {
  name: 'network-dc-${environmentName}'
  scope: resourceGroup(dcRg)
  params: { environmentName: environmentName, location: location, tags: tags, domain: 'dc', allowPackageHttpEgress: allowPackageHttpEgress }
  dependsOn: [groups]
}
module cloudPeering 'azure-peering.bicep' = {
  name: 'peering-cloud-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: { vnetName: cloudNetwork.outputs.vnetName, remoteVnetId: dcNetwork.outputs.vnetId }
}
module dcPeering 'azure-peering.bicep' = {
  name: 'peering-dc-${environmentName}'
  scope: resourceGroup(dcRg)
  params: { vnetName: dcNetwork.outputs.vnetName, remoteVnetId: cloudNetwork.outputs.vnetId }
}
module dns 'azure-dns.bicep' = {
  name: 'dns-${environmentName}'
  scope: resourceGroup(opsRg)
  params: { environmentName: environmentName, tags: tags, cloudVnetId: cloudNetwork.outputs.vnetId, dcVnetId: dcNetwork.outputs.vnetId }
}
module databaseIdentity 'azure-bootstrap-identity.bicep' = if (enableBootstrapIdentities) {
  name: 'database-bootstrap-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: { name: databaseIdentityName, location: location, tags: tags }
  dependsOn: [groups]
}
module dcIdentity 'azure-bootstrap-identity.bicep' = if (enableBootstrapIdentities) {
  name: 'dc-bootstrap-${environmentName}'
  scope: resourceGroup(dcRg)
  params: { name: dcIdentityName, location: location, tags: tags, grantArcOnboarding: true }
  dependsOn: [groups]
}
module services 'azure-services.bicep' = {
  name: 'services-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    privateEndpointSubnetId: cloudNetwork.outputs.privateEndpointSubnetId
    postgresZoneId: dns.outputs.postgresZoneId
    serviceBusZoneId: dns.outputs.serviceBusZoneId
    blobZoneId: dns.outputs.blobZoneId
    databaseBootstrapPrincipalId: enableBootstrapIdentities ? databaseIdentity!.outputs.principalId : ''
    databaseBootstrapName: databaseIdentityName
  }
}
module monitor 'azure-monitor.bicep' = {
  name: 'monitor-${environmentName}'
  scope: resourceGroup(opsRg)
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    privateEndpointSubnetId: cloudNetwork.outputs.privateEndpointSubnetId
    monitorZoneIds: dns.outputs.monitorZoneIds
    arcZoneIds: dns.outputs.arcZoneIds
    enableAlerts: enableAlerts
    backlogThresholdCount: backlogThresholdCount
    staleAfterMinutes: staleAfterMinutes
  }
}
module dcBootstrapArtifacts 'azure-artifact-access.bicep' = if (enableBootstrapIdentities) {
  name: 'dc-bootstrap-artifacts-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: { storageAccountName: services.outputs.storageAccountName, principalId: dcIdentity!.outputs.principalId }
}
module dcBootstrapScopeReader 'azure-arc-scope-access.bicep' = if (enableBootstrapIdentities) {
  name: 'dc-bootstrap-scope-reader-${environmentName}'
  scope: resourceGroup(opsRg)
  params: { scopeName: last(split(monitor.outputs.arcPrivateLinkScopeId, '/')), principalId: dcIdentity!.outputs.principalId }
}
module cloudHost 'azure-host.bicep' = if (deployHosts) {
  name: 'host-cloud-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    domain: 'cloud'
    adminSshPublicKey: adminSshPublicKey
    subnetId: cloudNetwork.outputs.hostSubnetId
    bootstrapIdentityIds: enableBootstrapIdentities ? [databaseIdentity!.outputs.resourceId] : []
    bootstrapScript: cloudBootstrapScript
    vmSize: vmSize
    vmImageVersion: vmImageVersion
  }
  dependsOn: [services, monitor, cloudPeering, dcPeering]
}
module dcHost 'azure-host.bicep' = if (deployHosts) {
  name: 'host-dc-${environmentName}'
  scope: resourceGroup(dcRg)
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    domain: 'dc'
    adminSshPublicKey: adminSshPublicKey
    subnetId: dcNetwork.outputs.hostSubnetId
    bootstrapIdentityIds: enableBootstrapIdentities ? [dcIdentity!.outputs.resourceId] : []
    bootstrapScript: dcBootstrapScript
    vmSize: vmSize
    vmImageVersion: vmImageVersion
  }
  dependsOn: [services, monitor, cloudPeering, dcPeering, dcBootstrapArtifacts, dcBootstrapScopeReader]
}
module cloudAma 'azure-host-monitor.bicep' = if (deployHosts) {
  name: 'cloud-ama-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: { vmName: cloudHost!.outputs.name, location: location, tags: tags, dcrId: monitor.outputs.dcrId, dceId: monitor.outputs.dceId }
}
module cloudSender 'azure-queue-access.bicep' = if (deployHosts) {
  name: 'cloud-sender-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: { serviceBusNamespaceName: services.outputs.serviceBusName, principalId: cloudHost!.outputs.principalId, access: 'Sender' }
}
module cloudArtifacts 'azure-artifact-access.bicep' = if (deployHosts) {
  name: 'cloud-artifacts-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: { storageAccountName: services.outputs.storageAccountName, principalId: cloudHost!.outputs.principalId }
}
module artifactBridge 'azure-artifact-access.bicep' = [for container in ['releases', 'provisioning']: if (deployHosts && enableArtifactBridge) {
  name: 'bridge-${container}-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: {
    storageAccountName: services.outputs.storageAccountName
    principalId: cloudHost!.outputs.principalId
    containerName: container
    access: 'Contributor'
  }
}]
module cloudMonitorAccess 'azure-monitor-access.bicep' = if (deployHosts) {
  name: 'cloud-monitor-access-${environmentName}'
  scope: resourceGroup(opsRg)
  params: {
    appInsightsName: monitor.outputs.appInsightsName
    workspaceName: monitor.outputs.workspaceName
    principalId: cloudHost!.outputs.principalId
    grantReader: enableCloudVerificationReader
  }
}
module verificationAccess 'azure-monitor-access.bicep' = [for reader in verificationReaders: {
  name: 'verify-reader-${uniqueString(reader.principalId)}'
  scope: resourceGroup(opsRg)
  params: {
    appInsightsName: monitor.outputs.appInsightsName
    workspaceName: monitor.outputs.workspaceName
    principalId: reader.principalId
    principalType: reader.principalType
    grantPublisher: false
    grantReader: true
  }
}]

output RESOURCE_GROUP_NAMES array = [cloudRg, dcRg, opsRg]
output CLOUD_RESOURCE_GROUP_NAME string = cloudRg
output DC_RESOURCE_GROUP_NAME string = dcRg
output OPS_RESOURCE_GROUP_NAME string = opsRg
output OWNERSHIP_TAGS object = tags
output CLOUD_VM_NAME string = 'vm-retailtx-cloud-${environmentName}'
output DC_VM_NAME string = 'vm-retailtx-dc-${environmentName}'
output CLOUD_VM_ID string = deployHosts ? cloudHost!.outputs.resourceId : ''
output DC_VM_ID string = deployHosts ? dcHost!.outputs.resourceId : ''
output CLOUD_PRINCIPAL_ID string = deployHosts ? cloudHost!.outputs.principalId : ''
output CLOUD_PRIVATE_IP string = '10.86.0.4'
output DC_PRIVATE_IP string = '10.87.0.4'
output ARC_MACHINE_NAME string = 'erp-${environmentName}'
// At subscription scope, specify subscription AND RG: the RG-only overload
// otherwise interprets dcRg as a subscription identifier during output evaluation.
output ARC_MACHINE_RESOURCE_ID string = resourceId(subscription().subscriptionId, dcRg, 'Microsoft.HybridCompute/machines', 'erp-${environmentName}')
output ARC_PRIVATE_LINK_SCOPE_ID string = monitor.outputs.arcPrivateLinkScopeId
output POSTGRES_SERVER_NAME string = services.outputs.postgresName
output POSTGRES_SERVER_ID string = services.outputs.postgresId
output POSTGRES_FQDN string = services.outputs.postgresFqdn
output SERVICE_BUS_NAMESPACE_NAME string = services.outputs.serviceBusName
output SERVICE_BUS_QUEUE_ID string = services.outputs.queueId
output STORAGE_ACCOUNT_NAME string = services.outputs.storageAccountName
output ARTIFACTS_BLOB_ENDPOINT string = services.outputs.blobEndpoint
output RELEASE_CONTAINER_ID string = services.outputs.releaseContainerId
output PROVISIONING_CONTAINER_ID string = services.outputs.provisioningContainerId
output WORKSPACE_NAME string = monitor.outputs.workspaceName
output WORKSPACE_ID string = monitor.outputs.workspaceId
output WORKSPACE_CUSTOMER_ID string = monitor.outputs.workspaceCustomerId
output APP_INSIGHTS_ID string = monitor.outputs.appInsightsId
output DCE_ID string = monitor.outputs.dceId
output DCR_ID string = monitor.outputs.dcrId
output WORKBOOK_ID string = monitor.outputs.workbookId
output ALERT_IDS array = monitor.outputs.alertIds
output DATABASE_BOOTSTRAP_NAME string = databaseIdentityName
output DATABASE_BOOTSTRAP_IDENTITY_ID string = enableBootstrapIdentities ? databaseIdentity!.outputs.resourceId : ''
output DATABASE_BOOTSTRAP_CLIENT_ID string = enableBootstrapIdentities ? databaseIdentity!.outputs.clientId : ''
output DATABASE_BOOTSTRAP_PRINCIPAL_ID string = enableBootstrapIdentities ? databaseIdentity!.outputs.principalId : ''
output DATABASE_BOOTSTRAP_ADMINISTRATOR_ID string = services.outputs.databaseBootstrapAdministratorId
output DC_BOOTSTRAP_IDENTITY_ID string = enableBootstrapIdentities ? dcIdentity!.outputs.resourceId : ''
output DC_BOOTSTRAP_CLIENT_ID string = enableBootstrapIdentities ? dcIdentity!.outputs.clientId : ''
output DC_BOOTSTRAP_PRINCIPAL_ID string = enableBootstrapIdentities ? dcIdentity!.outputs.principalId : ''
output BOOTSTRAP_ROLE_ASSIGNMENT_IDS array = enableBootstrapIdentities ? [
  dcIdentity!.outputs.onboardingRoleAssignmentId
  dcBootstrapArtifacts!.outputs.roleAssignmentId
  dcBootstrapScopeReader!.outputs.roleAssignmentId
] : []
output ARTIFACT_BRIDGE_ROLE_ASSIGNMENT_IDS array = deployHosts && enableArtifactBridge ? [
  artifactBridge[0]!.outputs.roleAssignmentId
  artifactBridge[1]!.outputs.roleAssignmentId
] : []
output RUNTIME_CONFIG object = {
  RETAILTX_MODE: 'azure'
  RETAILTX_ENVIRONMENT_ID: environmentName
  BROKER_NAMESPACE: services.outputs.serviceBusNamespace
  CAP_DB_HOST: services.outputs.postgresFqdn
  CAP_DB_USER: 'retailtx-cap'
  CAP_DB_NAME: 'retailtx'
  CAP_DB_SSLROOTCERT: '/etc/ssl/certs/ca-certificates.crt'
  ERP_DB_HOST: '/var/run/postgresql'
  ERP_DB_USER: 'retailtx'
  ERP_DB_NAME: 'retailtx'
  CAP_URL: 'https://cap.${environmentName}.retailtx.internal:8443'
  ERP_URL: 'https://erp.${environmentName}.retailtx.internal:8443'
  TLS_CA_FILE: '/etc/retailtx/tls/ca.crt'
  TLS_CERT_FILE: '/etc/retailtx/tls/host.crt'
  TLS_KEY_FILE: '/etc/retailtx/tls/host.key'
  APPLICATIONINSIGHTS_CONNECTION_STRING: monitor.outputs.appInsightsConnectionString
}
// Pass this object as binding parameters, adding the DISCOVERED Arc ID and MI
// principal ID only after onboarding; never derive a principal ID from a client ID.
output BINDINGS_CONFIG object = {
  environmentName: environmentName
  location: location
  ownerToken: ownerToken
  expiresAt: expiresAt
  serviceBusNamespaceName: services.outputs.serviceBusName
  storageAccountName: services.outputs.storageAccountName
  appInsightsName: monitor.outputs.appInsightsName
  workspaceName: monitor.outputs.workspaceName
  dcrId: monitor.outputs.dcrId
  dceId: monitor.outputs.dceId
}
