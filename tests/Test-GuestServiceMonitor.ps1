#Requires -Version 7.2
# Local ownership, freshness, alert correlation and policy gates; no Azure calls.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\guest\GuestMonitor.ps1')
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'scripts\Invoke-GuestServiceApproval.ps1'), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
$node = $ast.Find({ param($candidate)
    $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $candidate.Name -ceq 'Assert-ApprovalIncidentThread'
}, $true)
. ([scriptblock]::Create($node.Extent.Text))
$script:checks = 0
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe monitoring input accepted.' }
    $script:checks++
}
$subscription = [guid]::NewGuid().ToString()
$EnvironmentName = 'demo01'
$FoundationEnvironment = 'foundation'
$location = 'swedencentral'
$groupId = "/subscriptions/$subscription/resourceGroups/rg-retailtx-guest-$EnvironmentName-$location"
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-retailtx-guest-$EnvironmentName"
$foundationId = "/subscriptions/$subscription/resourceGroups/rg-retailtx-$FoundationEnvironment-$location"
$script:state = @{
    withMonitoring = $true; withSreExecution = $true; ownerToken = [guid]::NewGuid().ToString()
    vmId = $vmId
    workspaceId = "$foundationId/providers/Microsoft.OperationalInsights/workspaces/law-retailtx-$FoundationEnvironment"
    dceId = "$foundationId/providers/Microsoft.Insights/dataCollectionEndpoints/dce-retailtx-$FoundationEnvironment"
    privateLinkScopeId = "$foundationId/providers/Microsoft.Insights/privateLinkScopes/ampls-retailtx-$FoundationEnvironment"
    workspaceCustomerId = [guid]::NewGuid().ToString()
    currentFault = @{ runId = [guid]::NewGuid().ToString(); canary = $false
        startBeforeUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    agentId = "$groupId/providers/Microsoft.App/agents/sre-retailtx-guest-agent-$EnvironmentName"
    alertId = "$groupId/providers/Microsoft.Insights/scheduledQueryRules/alert-retailtx-guest-$EnvironmentName"
    monitorAccess = @{}
}
Assert-GuestMonitorBinding
foreach ($field in @('workspaceId', 'dceId', 'privateLinkScopeId')) {
    $original = $script:state[$field]
    $script:state[$field] = '/subscriptions/foreign/resource'
    Assert-Rejected { Assert-GuestMonitorBinding }
    $script:state[$field] = $original
}
$evidence = @{ vmId = $vmId; workspaceCustomerId = $script:state.workspaceCustomerId
    receipt = @{ schemaVersion = 1; ownerToken = $script:state.ownerToken
        service = 'retailtx-demo-posting-worker'; observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        active = $true; healthy = $true; watchdogEnabled = $true; watchdogActive = $true
        bootId = [guid]::NewGuid().ToString()
        marker = @{ runId = $script:state.currentFault.runId; phase = 'recovered' } } }
Assert-GuestTelemetry $evidence -RequireHealthy
foreach ($change in @(
    @{ observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o') },
    @{ observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o') },
    @{ ownerToken = [guid]::NewGuid().ToString() }, @{ service = 'foreign' },
    @{ active = 'true' }, @{ watchdogActive = $false }
)) {
    $receipt = $evidence.receipt.Clone()
    foreach ($key in $change.Keys) { $evidence.receipt[$key] = $change[$key] }
    Assert-Rejected { Assert-GuestTelemetry $evidence -RequireHealthy }
    $evidence.receipt = $receipt
}
$evidence.receipt.marker.phase = 'fault-active'
Assert-Rejected { Assert-GuestTelemetry $evidence -RequireHealthy }
$evidence.receipt.marker.phase = 'recovered'
$evidence.receipt.marker.runId = [guid]::NewGuid().ToString()
Assert-Rejected { Assert-GuestTelemetry $evidence }
$expected = @{}
Add-GuestMonitorInventory $expected
if ($expected.Count -ne 9 -or -not $expected.ContainsKey("$vmId/extensions/AzureMonitorLinuxAgent")) {
    throw 'Monitoring teardown inventory is incomplete.'
}
$peering = @{ name = 'monitor-guest'; remoteVirtualNetwork = @{
    id = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-$EnvironmentName" }
    allowVirtualNetworkAccess = $true; allowForwardedTraffic = $false
    allowGatewayTransit = $false; useRemoteGateways = $false }
Assert-GuestMonitorPeering $peering -AgentSide
$peering.allowForwardedTraffic = $true
Assert-Rejected { Assert-GuestMonitorPeering $peering -AgentSide }
$threadId = [guid]::NewGuid()
$alertGuid = [guid]::NewGuid().ToString()
$incident = @{ ownerToken = $script:state.ownerToken; agentId = $script:state.agentId
    runId = $script:state.currentFault.runId; threadId = $threadId.ToString(); monitorCondition = 'Fired'
    sreIncident = @{ id = $alertGuid; threadId = $threadId.ToString(); targetResourceId = $vmId
        alertRuleResourceId = $script:state.alertId
        alertId = "$vmId/providers/Microsoft.AlertsManagement/alerts/$alertGuid" } }
$null = Assert-ApprovalIncidentThread $threadId $script:state $incident
$incident.runId = [guid]::NewGuid().ToString()
Assert-Rejected { Assert-ApprovalIncidentThread $threadId $script:state $incident }
$incident.runId = $script:state.currentFault.runId
$incident.sreIncident.threadId = [guid]::NewGuid().ToString()
Assert-Rejected { Assert-ApprovalIncidentThread $threadId $script:state $incident }
$incident.sreIncident.threadId = $threadId.ToString()
$incident.sreIncident.targetResourceId = '/foreign'
Assert-Rejected { Assert-ApprovalIncidentThread $threadId $script:state $incident }
# All grant validation must precede any deletion, including forged late entries.
$script:deletes = @()
function Invoke-Azure {
    param([string[]]$Arguments)
    if ($Arguments[0..2] -join ' ' -ceq 'role assignment delete') { $script:deletes += $Arguments; return }
    if ($Arguments[0..2] -join ' ' -ceq 'role assignment list') { return $script:assignments }
    throw 'Unexpected Azure call in local test.'
}
$grantId = [guid]::NewGuid().ToString()
$principal = [guid]::NewGuid().ToString()
$grant = @{ name = $grantId; id = "$($script:state.workspaceId)/providers/Microsoft.Authorization/roleAssignments/$grantId"
    principalId = $principal }
$script:state.monitorAccess.vm = $grant
$script:assignments = @(@{ id = $grant.id; scope = $script:state.workspaceId; principalId = $principal
    roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/73c42c96-874c-492b-b04d-ab87d138a893" })
Assert-GuestMonitorGrant $script:assignments[0] $grant
$script:state.monitorAccess.forged = @{ name = [guid]::NewGuid().ToString(); principalId = $principal; id = '/foreign' }
Assert-Rejected { Remove-GuestMonitorAccess }
if ($script:deletes.Count) { throw 'Cleanup mutated a grant before validating the entire manifest.' }
$script:state.monitorAccess.Remove('forged')
$script:assignments[0].principalId = [guid]::NewGuid().ToString()
Assert-Rejected { Remove-GuestMonitorAccess }
$script:assignments = @()
Remove-GuestMonitorAccess
$script:state.monitorAccess = @{}
Remove-GuestMonitorAccess
$policy = @{ permissions = @{ allow = @()
    ask = @('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)')
    deny = @('RunInTerminal', 'RunShellCommand', 'ExecutePythonCode') } }
Assert-GuestMonitorPolicy $policy
$policy.permissions.allow = @('RunAzCliWriteCommands')
Assert-Rejected { Assert-GuestMonitorPolicy $policy }
$policy.permissions.allow = @()
$policy.permissions.deny = @()
Assert-Rejected { Assert-GuestMonitorPolicy $policy }
foreach ($operation in @('Monitor', 'Telemetry', 'Connect', 'Arm', 'Incident')) {
    & (Join-Path $root 'scripts\Invoke-GuestService.ps1') $operation -SubscriptionId $subscription -EnvironmentName 'dry01' -WhatIf
}
"Guest monitoring contracts passed ($script:checks rejection checks)."
