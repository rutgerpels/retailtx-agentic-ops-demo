#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\guest\GuestMonitor.ps1')
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'scripts\Invoke-GuestService.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors -join "`n") }
foreach ($name in @('Assert-GuestManifest', 'Get-GuestBaseDeploymentParameters')) {
    $node = $ast.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Get-GuestBaselineGrantExpectation { @() }
$subscription = [guid]::NewGuid().ToString()
$account = @{ tenantId = [guid]::NewGuid().ToString() }
$EnvironmentName = 'demo01'
$location = 'swedencentral'
$groupId = "/subscriptions/$subscription/resourceGroups/rg-retailtx-guest-$EnvironmentName-$location"
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-retailtx-guest-$EnvironmentName"
$script:state = @{
    schemaVersion = 2; profile = 'guest-service'; subscriptionId = $subscription; tenantId = $account.tenantId
    environmentName = $EnvironmentName; location = $location; groupId = $groupId; vmId = $vmId
    ownerToken = [guid]::NewGuid().ToString(); standalone = $true; phase = 'provisioning'
    expiresAt = [DateTimeOffset]::UtcNow.AddHours(4).ToString('o')
    withSreExecution = $true; withMonitoring = $true; withIsolatedMonitoring = $false
    monitorTransport = 'Public'; monitorReadMode = 'Operator'
    retainedAgentId = $null; retainedAgentIdentityId = $null; retainedAgentPrincipalId = $null
    readerAssignmentId = $null; adminObjectId = $null; actionRoleDefinitionName = [guid]::NewGuid().ToString()
    agentId = "$groupId/providers/Microsoft.App/agents/sre-retailtx-guest-agent-$EnvironmentName"
    agentIdentityId = "$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-retailtx-guest-agent-$EnvironmentName"
    agentPrincipalId = $null; actionClientId = $null; systemPrincipalId = $null
    workspaceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/law-retailtx-guest-$EnvironmentName"
    workspaceCustomerId = $null; dceId = $null; privateLinkScopeId = $null
    actionRoleAssignmentId = $null; actionReaderAssignmentId = $null; systemReaderAssignmentId = $null
    networkAssignmentId = $null; adminAssignmentId = $null
}
$script:state.actionRoleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$($script:state.actionRoleDefinitionName)"
Assert-GuestManifest
$parameters = Get-GuestBaseDeploymentParameters -AdminSshPublicKey 'ssh-ed25519 test-key'
if ($parameters.assignRetainedReader.value -or $parameters.agentPrincipalId.value -cne '') {
    throw 'Standalone base deployment must not grant a retained identity access.'
}
$checks = 2
foreach ($change in @(
    @{ standalone = 'true' }, @{ withSreExecution = $false }, @{ monitorReadMode = 'VmIdentity' },
    @{ monitorTransport = 'Private' }, @{ retainedAgentId = 'foreign' },
    @{ retainedAgentIdentityId = 'foreign' }, @{ retainedAgentPrincipalId = [guid]::NewGuid().ToString() },
    @{ readerAssignmentId = "$groupId/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())" }
)) {
    $saved = $script:state.Clone()
    foreach ($key in $change.Keys) { $script:state[$key] = $change[$key] }
    $rejected = $false
    try { Assert-GuestManifest } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe standalone manifest accepted.' }
    $script:state = $saved
    $checks++
}
Write-Output "Standalone contracts passed ($checks checks; no Azure calls)."
