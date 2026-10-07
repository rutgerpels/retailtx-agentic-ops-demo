targetScope = 'subscription'

@minLength(2)
@maxLength(12)
param environmentName string = 'demo01'
param location string = 'swedencentral'
@minLength(36)
@maxLength(36)
param ownerToken string
param expiresAt string
@description('Discovered Microsoft.HybridCompute/machines ID, never the backing Compute VM ID. Lifecycle must verify it equals main ARC_MACHINE_RESOURCE_ID and matches ownership tags before invoking.')
param arcMachineResourceId string
@description('Discovered Arc system-assigned identity principal/object ID, not its client ID. Lifecycle must verify against the live Arc resource.')
@minLength(36)
@maxLength(36)
param arcPrincipalId string
param serviceBusNamespaceName string
param storageAccountName string
param appInsightsName string
param workspaceName string
param dcrId string
param dceId string
param grantWorkspaceReader bool = true
@description('Setup only: Arc MI reads cloud-generated mTLS files from provisioning/dc. Capture the role output before setting false; incremental deployment does not revoke omitted assignments, so lifecycle must explicitly delete it after installation.')
param enableProvisioningReader bool = true

var tags = {
  demo: 'retailtx'
  environmentId: environmentName
  profile: 'azure-lite'
  ownerToken: ownerToken
  managedBy: 'retailtx'
  expiresAt: expiresAt
}
var cloudRg = 'rg-retailtx-cloud-${environmentName}-${location}'
var opsRg = 'rg-retailtx-ops-${environmentName}-${location}'
module receiver 'azure-queue-access.bicep' = {
  name: 'arc-receiver-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: { serviceBusNamespaceName: serviceBusNamespaceName, principalId: arcPrincipalId, access: 'Receiver' }
}
module artifacts 'azure-artifact-access.bicep' = {
  name: 'arc-artifacts-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: { storageAccountName: storageAccountName, principalId: arcPrincipalId }
}
module provisioningReader 'azure-artifact-access.bicep' = if (enableProvisioningReader) {
  name: 'arc-provisioning-reader-${environmentName}'
  scope: resourceGroup(cloudRg)
  params: {
    storageAccountName: storageAccountName
    principalId: arcPrincipalId
    containerName: 'provisioning'
    access: 'Reader'
  }
}
module monitorAccess 'azure-monitor-access.bicep' = {
  name: 'arc-monitor-access-${environmentName}'
  scope: resourceGroup(opsRg)
  params: { appInsightsName: appInsightsName, workspaceName: workspaceName, principalId: arcPrincipalId, grantReader: grantWorkspaceReader }
}
module arcMonitor 'azure-arc-monitor.bicep' = {
  name: 'arc-ama-${environmentName}'
  scope: resourceGroup(split(arcMachineResourceId, '/')[2], split(arcMachineResourceId, '/')[4])
  params: { machineName: last(split(arcMachineResourceId, '/')), location: location, tags: tags, dcrId: dcrId, dceId: dceId }
  dependsOn: [receiver, artifacts, provisioningReader, monitorAccess]
}
output ARC_AMA_EXTENSION_ID string = arcMonitor.outputs.extensionId
output ARC_ROLE_ASSIGNMENT_IDS array = [
  receiver.outputs.roleAssignmentId
  artifacts.outputs.roleAssignmentId
  monitorAccess.outputs.publisherRoleAssignmentId
]
output ARC_WORKSPACE_READER_ROLE_ASSIGNMENT_ID string = monitorAccess.outputs.readerRoleAssignmentId
// Deliberately separate from permanent runtime grants so cleanup cannot revoke
// receiver, releases Reader, or telemetry permissions by mistake.
output ARC_PROVISIONING_READER_ROLE_ASSIGNMENT_ID string = enableProvisioningReader ? provisioningReader!.outputs.roleAssignmentId : ''
