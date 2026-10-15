#Requires -Version 7.2
<#
.SYNOPSIS
Manage the isolated native Azure VM guest-service transport and manual faults.
.DESCRIPTION
Operator-only Action Run Command, not an SRE fixed-action RBAC boundary. Legacy
and SRE fixtures grant group-scoped Reader to the retained action identity; public
monitor-only diagnostics grant it nothing. Never grants retained guest write
privilege. Does not change SRE configuration, stop a VM, or process transactions.
Writes durable intent before commands. A timeout is an unknown outcome, not a
failed guest action; use Status for exact readback, or Down for safe disposal.
.PARAMETER Operation
Up, Status, Fault, Repair, Reset, or Down.
Inspect validates live ownership, source and grants without a guest command.
Monitor, Telemetry, Connect, Arm and Incident manage optional authenticated monitoring.
SkillCheck verifies exact-owned native recovery skill and Review routing.
Probe tests native command return; Command resumes an outstanding diagnostic without resubmission.
.PARAMETER SubscriptionId
Explicit authorized subscription, bound to the retained foundation tenant.
.PARAMETER EnvironmentName
Separate neutral disposable environment, default demo16.
.PARAMETER FoundationEnvironment
Retained ownership manifest used only to validate subscription and tenant.
.PARAMETER RunId
Exact UUID required for Repair, and for Reset when a fault exists.
.PARAMETER FaultDurationSeconds
Legacy fixtures only. New manual-lifetime fixtures reject an explicit duration.
.PARAMETER Canary
Inject a test fault. New fixtures require explicit Repair/Reset; no auto-recovery.
.PARAMETER WithSreExecution
On Up only, create a separate Review-mode SRE Agent and UAMI in the fixture
resource group, with VM-scoped Run Command permission and isolated VNet.
Includes documented group monitoring readers and subscription Monitoring Contributor.
.PARAMETER Standalone
Up only: create an independent public monitored SRE fixture without a retained
foundation manifest or retained-agent grants. Later operations use recorded mode.
.PARAMETER WithMonitoring
On Up only, prepare AMA monitoring. Without WithSreExecution, only public
monitor-only diagnostics are supported; no SRE or retained identity grants.
.PARAMETER WithRecoverySkill
On Connect only, opt in to reusable native SRE skill-led proposals instead of
operator Propose messages. Down removes the exact-owned skill and routing.
.PARAMETER MonitorTransport
Up with WithMonitoring only. Public (default) creates no DCE, AMPLS, private
endpoint or DNS links. Private retains the original private monitoring profile.
.PARAMETER MonitorReadMode
Fresh public SRE fixtures may explicitly select Operator to read Log Analytics
directly with the operator CLI identity, without a VM diagnostic command.
VmIdentity remains the default; source identity never changes automatically.
.PARAMETER WithIsolatedMonitoring
Fresh Up only, use a fixture-owned workspace, DCE and AMPLS for a diagnostic
experiment. Requires WithMonitoring and WithSreExecution; never changes shared
monitoring. Down permanently deletes the disposable workspace and its logs.
.EXAMPLE
.\scripts\Invoke-GuestService.ps1 Up -SubscriptionId <guid>
.EXAMPLE
.\scripts\Invoke-GuestService.ps1 Fault -SubscriptionId <guid> -Canary
.OUTPUTS
One JSON-safe status object with state, groupExists, powerState, and evidence.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Up', 'Status', 'Inspect', 'Fault', 'Repair', 'Reset', 'Down', 'Monitor', 'Telemetry', 'Connect', 'Arm', 'Incident', 'SkillCheck', 'Probe', 'Command')][string]$Operation,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo16',
    [string]$FoundationEnvironment = 'stage0',
    [ValidateRange(120, 600)][int]$FaultDurationSeconds = 300,
    [guid]$RunId,
    [switch]$Canary,
    [switch]$WithSreExecution,
    [switch]$Standalone,
    [switch]$WithMonitoring,
    [switch]$WithRecoverySkill,
    [ValidateSet('Public', 'Private')][string]$MonitorTransport = 'Public',
    [ValidateSet('VmIdentity', 'Operator')][string]$MonitorReadMode = 'VmIdentity',
    [switch]$WithIsolatedMonitoring
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Stage0.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
Assert-Stage0Name $FoundationEnvironment
if ($EnvironmentName -ceq $FoundationEnvironment) { throw 'Fixture must not reuse the foundation environment.' }
if ($Canary -and $Operation -cne 'Fault') { throw 'Canary applies only to Fault.' }
if ($WithSreExecution -and $Operation -cne 'Up') { throw 'WithSreExecution applies only to Up.' }
if ($Standalone -and ($Operation -cne 'Up' -or -not $WithSreExecution -or
    -not $WithMonitoring -or $MonitorTransport -ine 'Public' -or $MonitorReadMode -ine 'Operator' -or
    $WithIsolatedMonitoring)) {
    throw 'Standalone requires Up with SRE execution, public monitoring and Operator reads.'
}
if ($WithRecoverySkill -and $Operation -cne 'Connect') { throw 'WithRecoverySkill applies only to Connect.' }
if ($WithMonitoring -and $Operation -cne 'Up') {
    throw 'WithMonitoring applies only to Up.'
}
if ($PSBoundParameters.ContainsKey('MonitorTransport') -and ($Operation -cne 'Up' -or -not $WithMonitoring)) {
    throw 'MonitorTransport applies only to Up with WithMonitoring.'
}
if ($WithIsolatedMonitoring -and ($Operation -cne 'Up' -or -not $WithMonitoring -or -not $WithSreExecution)) {
    throw 'WithIsolatedMonitoring requires fresh Up with WithMonitoring and WithSreExecution.'
}
if ($WithIsolatedMonitoring) {
    if ($PSBoundParameters.ContainsKey('MonitorTransport') -and $MonitorTransport -ine 'Private') {
        throw 'WithIsolatedMonitoring is a private diagnostic; cannot select Public.'
    }
    $MonitorTransport = 'Private'
}
$MonitorTransport = if ($MonitorTransport -ieq 'Public') { 'Public' } else { 'Private' }
if ($WithMonitoring -and -not $WithSreExecution -and $MonitorTransport -cne 'Public') {
    throw 'Monitor-only diagnostics require Public transport; private incident profiles still require isolated SRE.'
}
if ($PSBoundParameters.ContainsKey('MonitorReadMode') -and ($Operation -cne 'Up' -or -not $WithMonitoring)) {
    throw 'MonitorReadMode applies only to Up with WithMonitoring.'
}
$MonitorReadMode = if ($MonitorReadMode -ieq 'Operator') { 'Operator' } else { 'VmIdentity' }
if ($MonitorReadMode -ceq 'Operator' -and (-not $WithSreExecution -or $MonitorTransport -cne 'Public')) {
    throw 'Operator Monitor reads require a fresh public monitored SRE fixture.'
}
if ($PSBoundParameters.ContainsKey('RunId') -and $Operation -cnotin @('Repair', 'Reset')) {
    throw 'RunId applies only to exact-run Repair and Reset.'
}
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root ".azure\$EnvironmentName"
$statePath = Join-Path $directory 'guest-service-state.json'
$subscription = $SubscriptionId.ToString()
$location = 'swedencentral'
$groupName = "rg-retailtx-guest-$EnvironmentName-$location"
$groupId = "/subscriptions/$subscription/resourceGroups/$groupName"
$vmName = "vm-retailtx-guest-$EnvironmentName"
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/$vmName"
$script:state = $null
$guestFiles = @('controller.py', 'bootstrap.py', 'worker.py', 'retailtx-demo-posting-worker.service',
    'retailtx-guest-watchdog.service', 'retailtx-guest-watchdog.timer',
    'retailtx-guest-observer.service', 'retailtx-guest-observer.timer')
. (Join-Path $PSScriptRoot 'disk\DiskSre.ps1')
. (Join-Path $PSScriptRoot 'guest\GuestMonitor.ps1')
. (Join-Path $PSScriptRoot 'guest\GuestRecoverySkill.ps1')
. (Join-Path $PSScriptRoot 'guest\GuestNativeRead.ps1')

function Invoke-Azure {
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 180)
    Invoke-RetailAzure -SubscriptionId $subscription -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Get-SourceHash {
    $hashes = @{}
    foreach ($name in $guestFiles) {
        $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot "guest\$name") -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}

function Get-ArtifactHash {
    $hashes = @{}
    foreach ($relative in @('scripts\Invoke-GuestService.ps1', 'infra\guest-service.bicep',
        'infra\guest-service-target.bicep', 'infra\guest-service-agent.bicep',
        'infra\guest-service-agent-target.bicep', 'scripts\Invoke-GuestServiceApproval.ps1',
        'scripts\Azure.Common.psm1', 'scripts\Stage0.Common.psm1',
        'scripts\guest\GuestMonitor.ps1', 'scripts\guest\GuestNativeRead.ps1', 'scripts\guest\query.py',
        'scripts\guest\GuestRecoverySkill.ps1', 'docs\agent-context\skills\guest-service-recovery\SKILL.md',
        'infra\guest-service-monitor.bicep', 'infra\guest-monitor-foundation.bicep', 'scripts\disk\DiskSre.ps1')) {
        $hashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}

function Assert-ExactHash {
    param([hashtable]$Expected, [hashtable]$Actual)
    if ($Expected.Count -ne $Actual.Count) { throw 'Source manifest file set mismatch.' }
    foreach ($name in $Actual.Keys) {
        if (-not $Expected.ContainsKey($name) -or $Expected[$name] -cne $Actual[$name]) {
            throw 'Source changed since deployment; do not replace a live controller. Use Down and redeploy.'
        }
    }
}

function Assert-GuestManifest {
    if ($script:state.ContainsKey('standalone') -and $script:state.standalone -isnot [bool]) {
        throw 'Invalid standalone deployment mode.'
    }
    if ($script:state['standalone'] -and (-not $script:state.withSreExecution -or
        -not $script:state.withMonitoring -or $script:state.monitorTransport -cne 'Public' -or
        $script:state.monitorReadMode -cne 'Operator' -or $script:state.withIsolatedMonitoring -or
        $script:state.retainedAgentId -or $script:state.retainedAgentIdentityId -or
        $script:state.retainedAgentPrincipalId -or $script:state.readerAssignmentId)) {
        throw 'Standalone fixture must own its SRE/monitoring and have no retained identity binding.'
    }
    if (-not $script:state.ContainsKey('withSreExecution') -and $script:state.schemaVersion -eq 1) {
        $script:state.withSreExecution = $false
    }
    if (-not $script:state.ContainsKey('withMonitoring')) { $script:state.withMonitoring = $false }
    if (-not $script:state.ContainsKey('withIsolatedMonitoring')) { $script:state.withIsolatedMonitoring = $false }
    if (-not $script:state.ContainsKey('monitorTransport')) { $script:state.monitorTransport = 'Private' }
    $null = Get-GuestMonitorTransport
    $null = Get-GuestMonitorReadMode
    if (-not $script:state.withMonitoring -and $script:state.monitorTransport -cne 'Private') {
        throw 'Monitor transport cannot be selected without monitoring.'
    }
    if ($script:state.withIsolatedMonitoring -and $script:state.monitorTransport -cne 'Private') {
        throw 'Isolated AMPLS monitoring requires Private transport.'
    }
    if ($script:state.withIsolatedMonitoring -isnot [bool] -or
        ($script:state.withIsolatedMonitoring -and -not $script:state.withMonitoring)) {
        throw 'Invalid isolated monitoring mode.'
    }
    if ($script:state.withMonitoring -isnot [bool] -or
        ($script:state.withMonitoring -and -not $script:state.withSreExecution -and $script:state.monitorTransport -cne 'Public')) {
        throw 'Invalid monitoring mode; monitor-only fixtures require public transport.'
    }
    if ($script:state.schemaVersion -notin @(1, 2) -or $script:state.profile -cne 'guest-service' -or
        $script:state.subscriptionId -ine $subscription -or $script:state.tenantId -ine $account.tenantId -or
        $script:state.environmentName -cne $EnvironmentName -or $script:state.location -cne $location -or
        $script:state.groupId -ine $groupId -or $script:state.vmId -ine $vmId) {
        throw 'Guest-service manifest does not match the explicit environment.'
    }
    $null = [guid]::Parse($script:state.ownerToken)
    if ($script:state.withMonitoring) { Assert-GuestMonitorBinding }
    if ($script:state.schemaVersion -ge 2 -and $script:state.withSreExecution -isnot [bool]) {
        throw 'Fixture execution mode is missing or invalid.'
    }
    if (-not $script:state.withSreExecution -and @('agentPermissionModel', 'actionLogReaderAssignmentId',
        'actionMonitoringReaderAssignmentId', 'actionMonitoringContributorAssignmentId' |
        Where-Object { $script:state[$_] }).Count -ne 0) {
        throw 'Recorded SRE baseline cannot be detached from its execution fixture.'
    }
    if ($script:state.ContainsKey('readerAssignmentId') -and $script:state.readerAssignmentId -and
        $script:state.readerAssignmentId -notlike "$groupId/providers/Microsoft.Authorization/roleAssignments/*") {
        throw 'Retained fixture Reader assignment is outside the owned resource group.'
    }
    if ($script:state.withSreExecution) {
        if ($script:state.agentId -cne "$groupId/providers/Microsoft.App/agents/sre-retailtx-guest-agent-$EnvironmentName" -or
            $script:state.agentIdentityId -cne "$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-retailtx-guest-agent-$EnvironmentName" -or
            (-not $script:state['standalone'] -and (
            $script:state.retainedAgentId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.App/agents/*" -or
            $script:state.retainedAgentIdentityId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.ManagedIdentity/userAssignedIdentities/*" -or
            $script:state.retainedAgentId -ieq $script:state.agentId -or
            $script:state.retainedAgentIdentityId -ieq $script:state.agentIdentityId))) {
            throw 'Isolated guest SRE Agent or retained foundation binding is invalid.'
        }
        if ($script:state.retainedAgentPrincipalId) { $null = [guid]::Parse($script:state.retainedAgentPrincipalId) }
        if ($script:state.adminObjectId) { $null = [guid]::Parse($script:state.adminObjectId) }
        $null = [guid]::Parse($script:state.actionRoleDefinitionName)
        if ($script:state.actionRoleDefinitionId -ine
            "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$($script:state.actionRoleDefinitionName)") {
            throw 'Fixture Run Command role definition ID is outside its manifest.'
        }
        foreach ($field in @('agentPrincipalId', 'actionClientId', 'systemPrincipalId')) {
            if ($script:state[$field]) { $null = [guid]::Parse($script:state[$field]) }
        }
        $null = @(Get-GuestBaselineGrantExpectation -AllowLegacy)
        if ($script:state.phase -notin @('provisioning', 'deleting', 'deleted') -and
            (-not $script:state.agentPrincipalId -or -not $script:state.actionClientId -or
                -not $script:state.systemPrincipalId -or -not $script:state.agentEndpoint -or
                $script:state.agentEndpoint -notmatch '^https://' -or -not $script:state.adminObjectId -or
                -not $script:state.actionRoleAssignmentId -or -not $script:state.actionReaderAssignmentId -or
                -not $script:state.systemReaderAssignmentId -or -not $script:state.networkAssignmentId -or
                -not $script:state.adminAssignmentId -or -not $script:state.sreSubnetId -or
                $script:state.sreSubnetId -ine "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName/subnets/sre" -or
                $script:state.guestVmId -ine $vmId -or
                $script:state.sreAdministratorRoleDefinitionId -ine
                    "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/e79298df-d852-4c6d-84f9-5d13249d1e55")) {
            throw 'Disposable SRE Agent identity and endpoint outputs are incomplete.'
        }
        foreach ($field in @('actionRoleAssignmentId', 'actionReaderAssignmentId', 'systemReaderAssignmentId',
            'networkAssignmentId', 'adminAssignmentId')) {
            $expectedScope = switch ($field) {
                'actionRoleAssignmentId' { $vmId }
                'networkAssignmentId' { "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName/subnets/sre" }
                'adminAssignmentId' { $script:state.agentId }
                default { $groupId }
            }
            if ($script:state[$field] -and $script:state[$field] -notlike "$expectedScope/providers/Microsoft.Authorization/roleAssignments/*") {
                throw "Fixture role assignment ID '$field' is outside its owned scope."
            }
        }
    } elseif ($script:state.agentId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.App/agents/*" -or
        $script:state.agentIdentityId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.ManagedIdentity/userAssignedIdentities/*") {
        throw 'Retained action identity binding is invalid.'
    } else {
        $null = [guid]::Parse($script:state.agentPrincipalId)
    }
}

function Get-RetainedGuestIdentity {
    param([hashtable]$Foundation)
    $agentId = $Foundation.outputs.SRE_AGENT_ID
    if ($agentId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.App/agents/*") {
        throw 'Invalid retained SRE Agent ID.'
    }
    $agent = Invoke-Azure @('resource', 'show', '--ids', $agentId, '--api-version', '2026-01-01')
    if ($agent.properties.actionConfiguration.mode -cne 'Review') { throw 'SRE must remain in Review mode.' }
    $identityId = $agent.properties.actionConfiguration.identity
    if ($identityId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.ManagedIdentity/userAssignedIdentities/*") {
        throw 'Retained SRE action identity is outside the explicit subscription.'
    }
    $identity = Invoke-Azure @('identity', 'show', '--ids', $identityId)
    $principal = [guid]::Parse($identity.principalId).ToString()
    if ($identity.id -ine $identityId -or $identity.tenantId -ine $account.tenantId) {
        throw 'Retained action identity tenant/ID mismatch.'
    }
    $storedAgentId = $null
    $storedIdentityId = $null
    $storedPrincipalId = $null
    if ($script:state) {
        $storedAgentId = if ($script:state.ContainsKey('retainedAgentId') -and $script:state.retainedAgentId) { $script:state.retainedAgentId } else { $script:state.agentId }
        $storedIdentityId = if ($script:state.ContainsKey('retainedAgentIdentityId') -and $script:state.retainedAgentIdentityId) { $script:state.retainedAgentIdentityId } else { $script:state.agentIdentityId }
        $storedPrincipalId = if ($script:state.ContainsKey('retainedAgentPrincipalId') -and $script:state.retainedAgentPrincipalId) { $script:state.retainedAgentPrincipalId } else { $script:state.agentPrincipalId }
    }
    if ($script:state -and $script:state.phase -cne 'deleted' -and
        ($storedAgentId -ine $agentId -or $storedIdentityId -ine $identityId -or $storedPrincipalId -ine $principal)) {
        throw 'Guest manifest is bound to a different retained SRE action identity.'
    }
    return @{ agentId = $agentId; agentIdentityId = $identityId; agentPrincipalId = $principal }
}

function Assert-GuestReader {
    $assignments = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $groupId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
    $expectedRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
    if ($script:state.withMonitoring -and -not $script:state.withSreExecution) {
        if ($script:state.readerAssignmentId -or @($assignments | Where-Object { $_.scope -ieq $groupId }).Count) {
            throw 'Monitor-only fixture must have no SRE/retained identity group grants.'
        }
        return
    }
    $expectedPrincipals = @()
    if ($script:state.ContainsKey('retainedAgentPrincipalId')) { $expectedPrincipals += @($script:state.retainedAgentPrincipalId) }
    if ($expectedPrincipals.Count -eq 0) { $expectedPrincipals = @($script:state.agentPrincipalId) }
    if ($script:state.withSreExecution) { $expectedPrincipals += @($script:state.agentPrincipalId, $script:state.systemPrincipalId) }
    $expectedPrincipals = @($expectedPrincipals | Where-Object { $_ } | Select-Object -Unique)
    $baseline = @(if ($script:state.withSreExecution) { Get-GuestBaselineGrantExpectation })
    foreach ($principalId in $expectedPrincipals) {
        $matches = @($assignments | Where-Object {
            $_.scope -ieq $groupId -and $_.principalId -ieq $principalId -and $_.roleDefinitionId -ieq $expectedRole
        })
        if ($matches.Count -ne 1) { throw 'Exact guest group Reader grant is missing or ambiguous.' }
    }
    foreach ($assignment in $assignments) {
        if ($assignment.principalId -ieq $script:state.agentPrincipalId -and
            @($baseline | Where-Object {
                $_.scope -ieq $assignment.scope -and $_.id -ieq $assignment.id -and
                $_.roleDefinitionId -ieq $assignment.roleDefinitionId -and -not $assignment['condition']
            }).Count -eq 1) { continue }
        if ($assignment.principalId -iin $expectedPrincipals -and
            ($assignment.scope -ine $groupId -or $assignment.roleDefinitionId -ine $expectedRole)) {
            throw 'Unexpected guest-scope action identity privilege; refusing guest proof.'
        }
    }
}

function Get-OwnedGuestActionRole {
    param([switch]$AllowAbsent)
    if (-not $script:state.withSreExecution -or -not $script:state.actionRoleDefinitionName) { return $null }
    $roles = @(Invoke-Azure @('role', 'definition', 'list', '--name', $script:state.actionRoleDefinitionName))
    if ($roles.Count -eq 0 -and $AllowAbsent) { return $null }
    if ($roles.Count -ne 1) { throw 'Fixture Run Command role definition is missing or ambiguous.' }
    $role = $roles[0]
    if ($role.id -ine $script:state.actionRoleDefinitionId -or $role.roleType -cne 'CustomRole' -or
        $role.roleName -cne "RetailTx guest repair $EnvironmentName" -or
        $role.description -cne "RetailTx guest repair for environment $EnvironmentName; ownerToken=$($script:state.ownerToken)" -or
        @($role.assignableScopes).Count -ne 1 -or $role.assignableScopes[0] -ine $groupId -or
        @($role.permissions).Count -ne 1 -or @($role.permissions[0].actions).Count -ne 1 -or
        $role.permissions[0].actions[0] -cne 'Microsoft.Compute/virtualMachines/runCommand/action' -or
        @($role.permissions[0].notActions).Count -ne 0 -or
        @($role.permissions[0].dataActions).Count -ne 0 -or
        @($role.permissions[0].notDataActions).Count -ne 0) {
        throw 'Fixture Run Command role ownership or exact permission boundary mismatch.'
    }
    return $role
}

function Get-GuestBaselineGrantExpectation {
    param([switch]$AllowLegacy)
    $bindings = @(
        @{ field = 'actionLogReaderAssignmentId'; scope = $groupId; role = '73c42c96-874c-492b-b04d-ab87d138a893' }
        @{ field = 'actionMonitoringReaderAssignmentId'; scope = $groupId; role = '43d0d8ad-25c7-4714-9337-8ba259a9fe05' }
        @{ field = 'actionMonitoringContributorAssignmentId'; scope = "/subscriptions/$subscription"; role = '749f88d5-cbae-40b8-bcfc-e573ddc772fa' }
    )
    if (-not $script:state['agentPermissionModel']) {
        if (@($bindings | Where-Object { $script:state[$_.field] }).Count -ne 0) {
            throw 'Baseline assignments have no declared permission model.'
        }
        if ($AllowLegacy) { return }
        throw 'Legacy isolated SRE fixture has no declared documented baseline; use Down and redeploy. Do not adopt external grants.'
    }
    if ($script:state.agentPermissionModel -cne 'DocumentedBaseline') {
        throw 'Unknown SRE Agent permission model.'
    }
    foreach ($binding in $bindings) {
        $id = $script:state[$binding.field]
        $prefix = "$($binding.scope)/providers/Microsoft.Authorization/roleAssignments/"
        if (-not $id -or $id -notmatch "^$([regex]::Escape($prefix))[0-9a-fA-F-]{36}$") {
            throw "Declared SRE baseline assignment '$($binding.field)' is missing or outside its exact scope."
        }
        $null = [guid]::Parse(($id -split '/')[-1])
        @{ id = $id; scope = $binding.scope
            roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$($binding.role)" }
    }
}

function Assert-GuestExecutionAgent {
    if (-not $script:state.withSreExecution) { return }
    $agent = Invoke-Azure @('resource', 'show', '--ids', $script:state.agentId, '--api-version', '2026-01-01')
    $identity = Invoke-Azure @('identity', 'show', '--ids', $script:state.agentIdentityId)
    $role = Get-OwnedGuestActionRole
    $subnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName/subnets/sre"
    $action = $agent.properties.actionConfiguration
    $knowledge = $agent.properties.knowledgeGraphConfiguration
    $egress = $agent.properties.sandboxConfiguration.egress
    if ($agent.id -ine $script:state.agentId -or $agent.location -ine $location -or
        $agent.tags.ownerToken -cne $script:state.ownerToken -or $agent.tags.profile -cne 'guest-service' -or
        $agent.tags.demo -cne 'retailtx' -or $agent.tags.environmentId -cne $EnvironmentName -or
        $agent.tags.managedBy -cne 'retailtx' -or
        $agent.properties.agentEndpoint -ine $script:state.agentEndpoint -or
        $action.mode -cne 'Review' -or $action.accessLevel -cne 'Low' -or
        $action.identity -ine $script:state.agentIdentityId -or
        $knowledge.identity -ine $script:state.agentIdentityId -or
        @($knowledge.managedResources).Count -ne 1 -or $knowledge.managedResources[0] -ine $groupId -or
        $agent.properties.vnetConfiguration.subnetResourceId -ine $subnetId -or
        $egress.mode -cne 'AzureVNet' -or $egress.vnetConfiguration.usePrivateDnsResolution -ne $true -or
        $identity.id -ine $script:state.agentIdentityId -or $identity.location -ine $location -or
        $identity.tags.ownerToken -cne $script:state.ownerToken -or
        $identity.tags.profile -cne 'guest-service' -or $identity.tags.environmentId -cne $EnvironmentName -or
        $identity.tags.managedBy -cne 'retailtx' -or $identity.tenantId -ine $account.tenantId -or
        [guid]::Parse($identity.principalId).ToString() -ine $script:state.agentPrincipalId -or
        [guid]::Parse($identity.clientId).ToString() -ine $script:state.actionClientId -or
        [guid]::Parse($agent.identity.principalId).ToString() -ine $script:state.systemPrincipalId) {
        throw 'Disposable SRE Agent identity, Review mode, managed scope, or isolated VNet configuration drifted.'
    }
    if (-not $role) { throw 'Fixture Run Command role definition is missing.' }
    Assert-GuestExecutionNetwork -SubnetId $subnetId

    $actionAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--include-inherited', '--assignee-object-id',
        $script:state.agentPrincipalId, '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
    $readerRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
    $networkRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
    $expectedAction = @(
        @{ scope = $groupId; roleDefinitionId = $readerRole; id = $script:state.actionReaderAssignmentId }
        @{ scope = $vmId; roleDefinitionId = $script:state.actionRoleDefinitionId; id = $script:state.actionRoleAssignmentId }
        @{ scope = $subnetId; roleDefinitionId = $networkRole; id = $script:state.networkAssignmentId }
    )
    $expectedAction += @(Get-GuestBaselineGrantExpectation)
    $expectedAction += @(Get-GuestMonitorGrantExpectation action $script:state.agentPrincipalId)
    if ($actionAssignments.Count -ne $expectedAction.Count) { throw 'Unknown or missing grant on the disposable action identity.' }
    foreach ($expectedGrant in $expectedAction) {
        $matches = @($actionAssignments | Where-Object {
            $_.scope -ieq $expectedGrant.scope -and $_.roleDefinitionId -ieq $expectedGrant.roleDefinitionId -and
            $_.principalId -ieq $script:state.agentPrincipalId -and
            $_.id -ieq $expectedGrant.id -and -not $_['condition']
        })
        if ($matches.Count -ne 1) { throw 'Disposable action identity grant scope/role does not match the exact allow-list.' }
    }

    $systemAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--include-inherited', '--assignee-object-id',
        $script:state.systemPrincipalId, '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
    $expectedSystem = @(@{ scope = $groupId; roleDefinitionId = $readerRole; id = $script:state.systemReaderAssignmentId })
    $expectedSystem += @(Get-GuestMonitorGrantExpectation system $script:state.systemPrincipalId)
    if ($systemAssignments.Count -ne $expectedSystem.Count) {
        throw 'Disposable SRE Agent system principal has an unknown or missing grant.'
    }
    foreach ($expectedGrant in $expectedSystem) {
        $matches = @($systemAssignments | Where-Object {
            $_.scope -ieq $expectedGrant.scope -and $_.roleDefinitionId -ieq $expectedGrant.roleDefinitionId -and
            $_.id -ieq $expectedGrant.id -and $_.principalId -ieq $script:state.systemPrincipalId
        })
        if ($matches.Count -ne 1) { throw 'Disposable SRE system grant does not match the exact allow-list.' }
    }

    $adminAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $script:state.agentId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
    $adminRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/e79298df-d852-4c6d-84f9-5d13249d1e55"
    if ($adminAssignments.Count -ne 1 -or $adminAssignments[0].scope -ine $script:state.agentId -or
        $adminAssignments[0].principalId -ine $script:state.adminObjectId -or
        $adminAssignments[0].roleDefinitionId -ine $adminRole -or
        $adminAssignments[0].id -ine $script:state.adminAssignmentId) {
        throw 'Disposable SRE Agent must have only the exact human administrator grant.'
    }
}

function Get-GuestSubnetDelegationServiceName {
    param([Parameter(Mandatory)]$Delegation)
    if ($Delegation -is [System.Collections.IDictionary]) {
        if ($Delegation.Contains('serviceName')) { return [string]$Delegation.serviceName }
        if ($Delegation.Contains('properties') -and $Delegation.properties -is [System.Collections.IDictionary] -and
            $Delegation.properties.Contains('serviceName')) {
            return [string]$Delegation.properties.serviceName
        }
    } else {
        if ($Delegation.PSObject.Properties['serviceName']) { return [string]$Delegation.serviceName }
        if ($Delegation.PSObject.Properties['properties'] -and
            $Delegation.properties.PSObject.Properties['serviceName']) {
            return [string]$Delegation.properties.serviceName
        }
    }
    return $null
}

function Assert-GuestGeneratedNsg {
    param([hashtable]$Subnet)
    $nsgId = "$groupId/providers/Microsoft.Network/networkSecurityGroups/vnet-retailtx-guest-agent-$EnvironmentName-sre-nsg-$location"
    $subnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName/subnets/sre"
    $nsg = Invoke-Azure @('network', 'nsg', 'show', '--ids', $nsgId)
    if ($nsg.id -ine $nsgId -or $nsg.location -ine $location -or
        $nsg.tags.ownerToken -cne $script:state.ownerToken -or
        $nsg.tags.demo -cne 'retailtx' -or $nsg.tags.profile -cne 'guest-service' -or
        $nsg.tags.environmentId -cne $EnvironmentName -or $nsg.tags.managedBy -cne 'retailtx' -or
        @($nsg.securityRules).Count -ne 0 -or
        @($nsg['networkInterfaces'] | Where-Object { $null -ne $_ }).Count -ne 0 -or
        @($nsg.subnets).Count -ne 1 -or $nsg.subnets[0].id -ine $subnetId -or
        $Subnet.id -ine $subnetId -or $Subnet.networkSecurityGroup.id -ine $nsgId) {
        throw 'Generated SRE NSG is not the empty owned group attached only to its exact subnet.'
    }
}

function Assert-GuestExecutionNetwork {
    param([Parameter(Mandatory)][string]$SubnetId)
    $vnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName"
    $natId = "$groupId/providers/Microsoft.Network/natGateways/nat-retailtx-guest-agent-$EnvironmentName"
    $pipId = "$groupId/providers/Microsoft.Network/publicIPAddresses/pip-retailtx-guest-agent-$EnvironmentName-egress"
    $vnet = Invoke-Azure @('network', 'vnet', 'show', '--ids', $vnetId)
    $subnet = Invoke-Azure @('network', 'vnet', 'subnet', 'show', '--ids', $SubnetId)
    $nat = Invoke-Azure @('network', 'nat', 'gateway', 'show', '--ids', $natId)
    $pip = Invoke-Azure @('network', 'public-ip', 'show', '--ids', $pipId)
    if ($subnet['networkSecurityGroup']) { Assert-GuestGeneratedNsg $subnet }
    if ($vnet.id -ine $vnetId -or $vnet.location -ine $location -or
        $vnet.tags.ownerToken -cne $script:state.ownerToken -or $vnet.tags.profile -cne 'guest-service' -or
        $vnet.tags.environmentId -cne $EnvironmentName -or $vnet.tags.managedBy -cne 'retailtx' -or
        @($vnet.addressSpace.addressPrefixes).Count -ne 1 -or
        $vnet.addressSpace.addressPrefixes[0] -cne '10.90.0.0/24' -or
        (@($vnet.virtualNetworkPeerings).Count -ne 0 -and -not
            ($script:state.ContainsKey('withMonitoring') -and $script:state.withMonitoring -and (Get-GuestMonitorTransport) -ceq 'Private')) -or
        $subnet.id -ine $SubnetId -or $subnet.addressPrefix -cne '10.90.0.0/27' -or
        $subnet.defaultOutboundAccess -ne $false -or
        @($subnet.delegations).Count -ne 1 -or
        (Get-GuestSubnetDelegationServiceName -Delegation $subnet.delegations[0]) -cne 'Microsoft.App/environments' -or
        $subnet.natGateway.id -ine $natId -or
        $subnet['routeTable'] -or
        $nat.id -ine $natId -or $nat.location -ine $location -or
        $nat.tags.ownerToken -cne $script:state.ownerToken -or $nat.tags.profile -cne 'guest-service' -or
        $nat.tags.environmentId -cne $EnvironmentName -or $nat.tags.managedBy -cne 'retailtx' -or
        $nat.sku.name -cne 'Standard' -or
        $nat.idleTimeoutInMinutes -ne 4 -or @($nat.publicIpAddresses).Count -ne 1 -or
        $nat.publicIpAddresses[0].id -ine $pipId -or @($nat.subnets).Count -ne 1 -or
        $nat.subnets[0].id -ine $SubnetId -or
        $pip.id -ine $pipId -or $pip.location -ine $location -or
        $pip.tags.ownerToken -cne $script:state.ownerToken -or $pip.tags.profile -cne 'guest-service' -or
        $pip.tags.environmentId -cne $EnvironmentName -or $pip.tags.managedBy -cne 'retailtx' -or
        $pip.sku.name -cne 'Standard' -or $pip.sku.tier -cne 'Regional' -or
        $pip.publicIPAllocationMethod -cne 'Static' -or $pip.publicIPAddressVersion -cne 'IPv4' -or
        $pip.natGateway.id -ine $natId -or $pip['ipConfiguration'] -or $pip['publicIPPrefix'] -or
        $pip['dnsSettings']) {
        throw 'Disposable SRE Agent network is not an isolated delegated /27 with its exact owned NAT egress.'
    }
    if ($script:state.ContainsKey('withMonitoring') -and $script:state.withMonitoring -and (Get-GuestMonitorTransport) -ceq 'Private' -and
        @($vnet.virtualNetworkPeerings).Count) {
        Assert-GuestMonitorPeering $vnet.virtualNetworkPeerings[0] -AgentSide
        if (@($vnet.virtualNetworkPeerings).Count -ne 1) { throw 'Unexpected isolated agent peering.' }
    }
}

function Assert-GuestExecutionAssignmentsForTeardown {
    if (-not $script:state.withSreExecution) { return }
    $readerRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
    $networkRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
    $sreSubnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName/subnets/sre"
    $identity = $null
    $knownAssignments = @()
    $baseline = @(Get-GuestBaselineGrantExpectation -AllowLegacy)
    $resources = if (Get-OwnedGroup) { @(Invoke-Azure @('resource', 'list', '--resource-group', $groupName)) } else { @() }
    $identityResources = @($resources | Where-Object { $_.id -ieq $script:state.agentIdentityId })
    if ($identityResources.Count -gt 1) { throw 'Duplicate disposable SRE action identity resources.' }
    if ($identityResources.Count -eq 1) {
        $identity = Invoke-Azure @('identity', 'show', '--ids', $script:state.agentIdentityId)
        if ($identity.id -ine $script:state.agentIdentityId -or $identity.tenantId -ine $account.tenantId -or
            $identity.tags.ownerToken -cne $script:state.ownerToken -or
            [guid]::Parse($identity.principalId).ToString() -ine $script:state.agentPrincipalId -and
            $script:state.agentPrincipalId) {
            throw 'Teardown action identity ownership does not match its manifest.'
        }
        $principal = [guid]::Parse($identity.principalId).ToString()
        $script:state.agentPrincipalId = $principal
    }
    if ($script:state.agentPrincipalId) {
        $identityAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--include-inherited', '--assignee-object-id',
            $script:state.agentPrincipalId, '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
        $allowed = @(
            @{ scope = $groupId; roleDefinitionId = $readerRole; id = $script:state.actionReaderAssignmentId }
            @{ scope = $vmId; roleDefinitionId = $script:state.actionRoleDefinitionId; id = $script:state.actionRoleAssignmentId }
            @{ scope = $sreSubnetId; roleDefinitionId = $networkRole; id = $script:state.networkAssignmentId }
        )
        $allowed += $baseline
        foreach ($assignment in $identityAssignments) {
            $matches = @($allowed | Where-Object {
                $assignment.scope -ieq $_.scope -and $assignment.roleDefinitionId -ieq $_.roleDefinitionId -and
                (-not $_.id -or $assignment.id -ieq $_.id) -and
                $assignment.principalId -ieq $script:state.agentPrincipalId -and -not $assignment['condition']
            })
            if ($matches.Count -ne 1) { throw 'Unknown or foreign grant on the disposable action identity; refusing teardown.' }
            $knownAssignments += $assignment
        }
    }
    foreach ($scope in @($baseline | ForEach-Object scope | Select-Object -Unique)) {
        $scopeAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $scope,
            '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
        foreach ($expectedGrant in @($baseline | Where-Object { $_.scope -ieq $scope })) {
            foreach ($assignment in @($scopeAssignments | Where-Object { $_.id -ieq $expectedGrant.id })) {
                if (-not $script:state.agentPrincipalId -or $assignment.principalId -ine $script:state.agentPrincipalId -or
                    $assignment.scope -ine $expectedGrant.scope -or $assignment.roleDefinitionId -ine $expectedGrant.roleDefinitionId -or
                    $assignment['condition']) {
                    throw 'Recorded baseline grant no longer matches the exact fixture binding.'
                }
                $knownAssignments += $assignment
            }
        }
    }

    $agentResources = @($resources | Where-Object { $_.id -ieq $script:state.agentId })
    if ($agentResources.Count -gt 1) { throw 'Duplicate disposable SRE Agent resources.' }
    if ($agentResources.Count -eq 1) {
        $agent = Invoke-Azure @('resource', 'show', '--ids', $script:state.agentId, '--api-version', '2026-01-01')
        if ($agent.id -ine $script:state.agentId -or $agent.tags.ownerToken -cne $script:state.ownerToken) {
            throw 'Teardown SRE Agent resource does not match this fixture owner.'
        }
        $systemPrincipal = [guid]::Parse($agent.identity.principalId).ToString()
        if ($script:state.systemPrincipalId -and $systemPrincipal -ine $script:state.systemPrincipalId) {
            throw 'Teardown SRE Agent system principal changed.'
        }
        $script:state.systemPrincipalId = $systemPrincipal
        $systemAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--include-inherited', '--assignee-object-id',
            $systemPrincipal, '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
        foreach ($assignment in $systemAssignments) {
            if ($assignment.scope -ine $groupId -or $assignment.roleDefinitionId -ine $readerRole -or
                ($script:state.systemReaderAssignmentId -and $assignment.id -ine $script:state.systemReaderAssignmentId)) {
                throw 'Unknown or foreign grant on the disposable SRE Agent system identity.'
            }
            $knownAssignments += $assignment
        }
        $adminAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $script:state.agentId,
            '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
        $adminRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/e79298df-d852-4c6d-84f9-5d13249d1e55"
        foreach ($assignment in $adminAssignments) {
            if (-not $script:state.adminObjectId -or $assignment.scope -ine $script:state.agentId -or
                $assignment.principalId -ine $script:state.adminObjectId -or $assignment.roleDefinitionId -ine $adminRole -or
                ($script:state.adminAssignmentId -and $assignment.id -ine $script:state.adminAssignmentId)) {
                throw 'Unknown or foreign SRE Agent administrator grant; refusing teardown.'
            }
            $knownAssignments += $assignment
        }
    }

    $groupAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $groupId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
    $allowedGroupPrincipals = @($script:state.retainedAgentPrincipalId, $script:state.agentPrincipalId, $script:state.systemPrincipalId) |
        Where-Object { $_ }
    foreach ($assignment in $groupAssignments) {
        if ($assignment.principalId -ieq $script:state.agentPrincipalId -and
            @($baseline | Where-Object {
                $_.scope -ieq $assignment.scope -and $_.id -ieq $assignment.id -and
                $_.roleDefinitionId -ieq $assignment.roleDefinitionId -and -not $assignment['condition']
            }).Count -eq 1) {
            $knownAssignments += $assignment
            continue
        }
        if ($assignment.principalId -iin $allowedGroupPrincipals -and
            ($assignment.scope -ine $groupId -or $assignment.roleDefinitionId -ine $readerRole)) {
            throw 'Unknown or foreign fixture identity grant at resource-group scope.'
        }
        if ($assignment.principalId -iin $allowedGroupPrincipals) {
            if ($assignment.principalId -ieq $script:state.retainedAgentPrincipalId -and
                $script:state.ContainsKey('readerAssignmentId') -and $script:state.readerAssignmentId -and
                $assignment.id -ine $script:state.readerAssignmentId) {
                throw 'Retained foundation Reader assignment ID changed; refusing teardown.'
            }
            $knownAssignments += $assignment
        }
    }
    if (@($knownAssignments | Where-Object { -not $_.id }).Count -ne 0) {
        throw 'Fixture role-assignment inventory contains an ID-less grant.'
    }
    $knownAssignments = @($knownAssignments | Sort-Object -Property id -Unique)
    $script:state.teardownRoleAssignments = @($knownAssignments | ForEach-Object {
        @{ id = $_.id; scope = $_.scope; principalId = $_.principalId; roleDefinitionId = $_.roleDefinitionId }
    })
    Save-RetailState $script:state $statePath
}

function Remove-GuestExecutionRoleAssignments {
    if (-not $script:state.withSreExecution) { return }
    $assignments = @($script:state.teardownRoleAssignments)
    $readerRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
    $networkRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
    $adminRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/e79298df-d852-4c6d-84f9-5d13249d1e55"
    $subnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName/subnets/sre"
    $baseline = @(Get-GuestBaselineGrantExpectation -AllowLegacy)
    $liveAssignments = @()
    foreach ($assignment in $assignments) {
        $exactPair = ($assignment.scope -ieq $groupId -and $assignment.roleDefinitionId -ieq $readerRole -and
            $assignment.principalId -iin @($script:state.retainedAgentPrincipalId, $script:state.agentPrincipalId, $script:state.systemPrincipalId)) -or
            ($assignment.scope -ieq $vmId -and $assignment.roleDefinitionId -ieq $script:state.actionRoleDefinitionId -and
                $assignment.principalId -ieq $script:state.agentPrincipalId) -or
            ($assignment.scope -ieq $subnetId -and $assignment.roleDefinitionId -ieq $networkRole -and
                $assignment.principalId -ieq $script:state.agentPrincipalId) -or
            ($assignment.scope -ieq $script:state.agentId -and $assignment.roleDefinitionId -ieq $adminRole -and
                $assignment.principalId -ieq $script:state.adminObjectId)
        $exactBaseline = @($baseline | Where-Object {
            $_.id -ieq $assignment.id -and $_.scope -ieq $assignment.scope -and
            $_.roleDefinitionId -ieq $assignment.roleDefinitionId -and
            $assignment.principalId -ieq $script:state.agentPrincipalId
        }).Count -eq 1
        if (-not $assignment.id -or (-not $exactPair -and -not $exactBaseline)) {
            throw 'Teardown role-assignment inventory escaped the fixture allow-list.'
        }
        $live = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $assignment.scope,
            '--fill-principal-name', 'false', '--fill-role-definition-name', 'false') |
            Where-Object { $_.id -ieq $assignment.id })
        if ($live.Count -gt 1 -or ($live.Count -eq 1 -and
            ($live[0].scope -ine $assignment.scope -or $live[0].principalId -ine $assignment.principalId -or
                $live[0].roleDefinitionId -ine $assignment.roleDefinitionId -or $live[0]['condition']))) {
            throw 'Role assignment changed after teardown inventory; refusing deletion.'
        }
        if ($live.Count -eq 0) { continue }
        $liveAssignments += $assignment
    }
    foreach ($assignment in $liveAssignments) {
        $null = Invoke-Azure @('role', 'assignment', 'delete', '--ids', $assignment.id)
    }
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
    $tracked = @($assignments) + $baseline
    do {
        $pending = @()
        foreach ($scope in @($tracked | ForEach-Object scope | Select-Object -Unique)) {
            $live = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $scope,
                '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
            $pending += @($live | Where-Object { $_.id -iin @($tracked | ForEach-Object id) })
        }
        if (@($pending | Where-Object { $_.id -inotin @($assignments | ForEach-Object id) }).Count -gt 0) {
            Save-GuestTeardownUnknown -Reason 'Recorded baseline assignment appeared after inventory; read/reconcile before further teardown.'
            throw 'Late recorded baseline grant detected; no absence claim. Reconcile the deployment and exact binding before retrying Down.'
        }
        if ($pending.Count -eq 0) { break }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Fixture role-assignment deletion is still pending.' }
        Start-Sleep -Seconds 5
    } while ($true)
    $script:state.teardownRoleAssignments = @()
    Save-RetailState $script:state $statePath
}

function Remove-GuestExecutionRole {
    if (-not $script:state.withSreExecution -or -not $script:state.actionRoleDefinitionName) { return }
    $role = Get-OwnedGuestActionRole -AllowAbsent
    $assignments = @(Invoke-Azure @('role', 'assignment', 'list', '--role',
        $script:state.actionRoleDefinitionId, '--all', '--fill-principal-name', 'false',
        '--fill-role-definition-name', 'false'))
    if ($assignments.Count -gt 0) {
        $principal = if ($script:state.agentPrincipalId) {
            [guid]::Parse($script:state.agentPrincipalId).ToString()
        } else { $null }
        $identity = $null
        try { $identity = Invoke-Azure @('identity', 'show', '--ids', $script:state.agentIdentityId) }
        catch {
            if (-not $principal) { throw }
            Write-Verbose 'Using the persisted action principal to clean an exact VM role assignment after identity deletion.'
        }
        if ($identity) {
            if ($identity.id -ine $script:state.agentIdentityId -or
                $identity.tags.ownerToken -cne $script:state.ownerToken -or
                $identity.tenantId -ine $account.tenantId) {
                throw 'Fixture action identity ownership mismatch; refusing custom role cleanup.'
            }
            $observedPrincipal = [guid]::Parse($identity.principalId).ToString()
            if ($principal -and $principal -ine $observedPrincipal) {
                throw 'Fixture action identity principal changed; refusing custom role cleanup.'
            }
            $principal = $observedPrincipal
        }
        if (-not $principal) { throw 'Cannot prove the principal for the fixture VM role assignment.' }
        foreach ($assignment in $assignments) {
            if ($assignment.scope -ine $vmId -or $assignment.principalId -ine $principal -or
                $assignment.roleDefinitionId -ine $script:state.actionRoleDefinitionId -or
                ($script:state.actionRoleAssignmentId -and $assignment.id -ine $script:state.actionRoleAssignmentId)) {
                throw 'Unknown assignment of the owned custom role; refusing role or VM cleanup.'
            }
        }
        foreach ($assignment in $assignments) {
            $null = Invoke-Azure @('role', 'assignment', 'delete', '--ids', $assignment.id)
        }
        $deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
        do {
            $remaining = @(Invoke-Azure @('role', 'assignment', 'list', '--role',
                $script:state.actionRoleDefinitionId, '--all', '--fill-principal-name', 'false',
                '--fill-role-definition-name', 'false'))
            if ($remaining.Count -eq 0) { break }
            if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Fixture VM Run Command role assignment deletion is still pending.' }
            Start-Sleep -Seconds 5
        } while ($true)
    }
    if ($role) {
        $null = Invoke-Azure @('role', 'definition', 'delete', '--name', $script:state.actionRoleDefinitionName)
        $deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
        do {
            $remainingRoles = @(Invoke-Azure @('role', 'definition', 'list', '--name', $script:state.actionRoleDefinitionName))
            if ($remainingRoles.Count -eq 0) { break }
            if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Fixture custom role definition deletion is still pending.' }
            Start-Sleep -Seconds 5
        } while ($true)
    }
}

function Get-OwnedGroup {
    if (-not (Invoke-Azure @('group', 'exists', '--name', $groupName))) { return $null }
    $group = Invoke-Azure @('group', 'show', '--name', $groupName)
    if (-not $script:state -or $group.id -ine $groupId -or $group.location -ine $location -or
        $group.tags.demo -cne 'retailtx' -or $group.tags.environmentId -cne $EnvironmentName -or
        $group.tags.profile -cne 'guest-service' -or $group.tags.managedBy -cne 'retailtx' -or
        $group.tags.ownerToken -cne $script:state.ownerToken) {
        throw 'Guest group ownership mismatch; refusing adoption or mutation.'
    }
    return $group
}

function Assert-GuestTeardownInventory {
    if (-not (Get-OwnedGroup)) { return }
    $suffix = "retailtx-guest-$EnvironmentName"
    $expected = @{
        "$groupId/providers/Microsoft.Network/publicIPAddresses/pip-$suffix-egress" = 'Microsoft.Network/publicIPAddresses'
        "$groupId/providers/Microsoft.Network/natGateways/nat-$suffix" = 'Microsoft.Network/natGateways'
        "$groupId/providers/Microsoft.Network/networkSecurityGroups/nsg-$suffix" = 'Microsoft.Network/networkSecurityGroups'
        "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-$suffix" = 'Microsoft.Network/virtualNetworks'
        "$groupId/providers/Microsoft.Network/networkInterfaces/nic-$suffix" = 'Microsoft.Network/networkInterfaces'
        "$vmId" = 'Microsoft.Compute/virtualMachines'
        "$groupId/providers/Microsoft.Compute/disks/osdisk-$suffix" = 'Microsoft.Compute/disks'
    }
    if ($script:state.withSreExecution) {
        $expected["$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-retailtx-guest-agent-$EnvironmentName"] = 'Microsoft.ManagedIdentity/userAssignedIdentities'
        $expected["$groupId/providers/Microsoft.App/agents/sre-retailtx-guest-agent-$EnvironmentName"] = 'Microsoft.App/agents'
        $expected["$groupId/providers/Microsoft.Network/publicIPAddresses/pip-retailtx-guest-agent-$EnvironmentName-egress"] = 'Microsoft.Network/publicIPAddresses'
        $expected["$groupId/providers/Microsoft.Network/natGateways/nat-retailtx-guest-agent-$EnvironmentName"] = 'Microsoft.Network/natGateways'
        $expected["$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName"] = 'Microsoft.Network/virtualNetworks'
        $generatedNsgId = "$groupId/providers/Microsoft.Network/networkSecurityGroups/vnet-retailtx-guest-agent-$EnvironmentName-sre-nsg-$location"
        $expected[$generatedNsgId] = 'Microsoft.Network/networkSecurityGroups'
    }
    if ($script:state.withMonitoring) { Add-GuestMonitorInventory $expected }
    $platformExtensions = @{
        "$vmId/extensions/AzurePolicyforLinux" = @{ name = 'AzurePolicyforLinux'; publisher = 'Microsoft.GuestConfiguration'; type = 'ConfigurationforLinux' }
        "$vmId/extensions/MDE.Linux" = @{ name = 'MDE.Linux'; publisher = 'Microsoft.Azure.AzureDefenderForServers'; type = 'MDE.Linux' }
    }
    $resources = @(Invoke-Azure @('resource', 'list', '--resource-group', $groupName))
    $seen = @{}
    foreach ($resource in $resources) {
        if ($seen.ContainsKey($resource.id)) { throw 'Duplicate teardown inventory ID.' }
        $seen[$resource.id] = $true
        if ($script:state.withMonitoring -and (Get-GuestMonitorTransport) -ceq 'Private' -and
            $resource.id -ieq "$groupId/providers/Microsoft.Network/networkInterfaces/nic-$suffix-monitor") {
            Assert-GuestMonitorNic $resource
            continue
        }
        if ($platformExtensions.ContainsKey($resource.id)) {
            if ($resource.type -ine 'Microsoft.Compute/virtualMachines/extensions') {
                throw 'Unexpected policy child resource type.'
            }
            continue
        }
        if (-not $expected.ContainsKey($resource.id) -or $resource.type -ine $expected[$resource.id] -or
            ($resource.location -ine $location -and -not ($resource.type -iin @('Microsoft.Network/privateDnsZones', 'Microsoft.Network/privateDnsZones/virtualNetworkLinks', 'Microsoft.Insights/privateLinkScopes') -and $resource.location -ceq 'global')) -or $resource.tags.demo -cne 'retailtx' -or
            $resource.tags.environmentId -cne $EnvironmentName -or $resource.tags.profile -cne 'guest-service' -or
            $resource.tags.managedBy -cne 'retailtx' -or $resource.tags.ownerToken -cne $script:state.ownerToken) {
            throw 'Foreign or unexpected resource in owned group; refusing group deletion.'
        }
        if ($resource.type -ieq 'Microsoft.Network/privateDnsZones/virtualNetworkLinks') {
            Assert-GuestMonitorDnsLink $resource
        }
        if ($script:state.withSreExecution -and $resource.id -ieq $generatedNsgId) {
            $subnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName/subnets/sre"
            $subnet = Invoke-Azure @('network', 'vnet', 'subnet', 'show', '--ids', $subnetId)
            Assert-GuestGeneratedNsg $subnet
        }
    }
    if ($seen.ContainsKey($vmId)) {
        $extensionResponse = Invoke-Azure @('rest', '--method', 'get', '--url', "$vmId/extensions?api-version=2024-11-01")
        $extensions = @($extensionResponse.value)
        if ($extensions.Count -gt $(if ($script:state.withMonitoring) { 3 } else { 2 })) { throw 'Unexpected VM child extensions; refusing group deletion.' }
        foreach ($platformId in $platformExtensions.Keys) {
            if ($seen.ContainsKey($platformId) -and @($extensions | Where-Object id -IEQ $platformId).Count -ne 1) {
                throw 'Platform extension inventory did not resolve to exact child.'
            }
        }
        $extensionIds = @{}
        foreach ($extension in $extensions) {
            if ($extensionIds.ContainsKey($extension.id)) { throw 'Duplicate VM child extension.' }
            $extensionIds[$extension.id] = $true
            if ($script:state.withMonitoring -and $extension.id -ieq "$vmId/extensions/AzureMonitorLinuxAgent") {
                Assert-GuestMonitorExtension $extension
                continue
            }
            $platform = $platformExtensions[$extension.id]
            if (-not $platform -or $extension.name -cne $platform.name -or
                $extension.type -ine 'Microsoft.Compute/virtualMachines/extensions' -or
                $extension.location -ine $location -or $extension.properties.publisher -cne $platform.publisher -or
                $extension.properties.type -cne $platform.type -or
                ($extension['tags'] -and $extension.tags.Count -ne 0)) {
                throw 'Only exact untagged platform policy or Defender extensions are permitted.'
            }
        }
    } elseif (@($platformExtensions.Keys | Where-Object { $seen.ContainsKey($_) }).Count) {
        throw 'Platform extension has no exact owned parent VM.'
    }
}

function Get-OwnedVm {
    $null = Get-OwnedGroup
    $vms = @(Invoke-Azure @('vm', 'list', '--resource-group', $groupName) | Where-Object id -IEQ $vmId)
    if ($vms.Count -ne 1) { throw 'Exact owned guest VM not found.' }
    $vm = $vms[0]
    if ($vm.id -ine $vmId -or $vm.tags.ownerToken -cne $script:state.ownerToken -or
        $vm.tags.profile -cne 'guest-service' -or $vm.location -ine $location -or
        -not $vm.osProfile.allowExtensionOperations -or -not $vm.osProfile.linuxConfiguration.provisionVMAgent -or
        -not $vm.osProfile.linuxConfiguration.disablePasswordAuthentication) {
        throw 'Guest VM ownership or native VM-agent configuration mismatch.'
    }
    $image = $vm.storageProfile.imageReference
    if ($image.publisher -cne 'Canonical' -or $image.offer -cne 'ubuntu-24_04-lts' -or
        $image.sku -cne 'server' -or $image.version -cne '24.04.202609040') {
        throw 'Guest image does not match the source-attested deployment.'
    }
    $interfaces = @($vm.networkProfile.networkInterfaces)
    $nicId = "$groupId/providers/Microsoft.Network/networkInterfaces/nic-retailtx-guest-$EnvironmentName"
    if ($interfaces.Count -ne 1 -or $interfaces[0].id -ine $nicId) { throw 'Unexpected VM network attachment.' }
    $nic = Invoke-Azure @('network', 'nic', 'show', '--ids', $nicId)
    if ($nic.tags.ownerToken -cne $script:state.ownerToken -or @($nic.ipConfigurations).Count -ne 1 -or
        $nic.ipConfigurations[0]['publicIPAddress'] -or $nic.enableIPForwarding -or
        $nic.ipConfigurations[0].subnet.id -ine
            "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-$EnvironmentName/subnets/host") {
        throw 'Guest VM must have one owned private NIC without a public IP or forwarding.'
    }
    return $vm
}

function Assert-GuestNetwork {
    $subnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-$EnvironmentName/subnets/host"
    $subnet = Invoke-Azure @('network', 'vnet', 'subnet', 'show', '--ids', $subnetId)
    $nsgId = "$groupId/providers/Microsoft.Network/networkSecurityGroups/nsg-retailtx-guest-$EnvironmentName"
    $natId = "$groupId/providers/Microsoft.Network/natGateways/nat-retailtx-guest-$EnvironmentName"
    if ($subnet.id -ine $subnetId -or $subnet.defaultOutboundAccess -ne $false -or
        $subnet.networkSecurityGroup.id -ine $nsgId -or $subnet.natGateway.id -ine $natId -or
        $subnet['routeTable']) {
        throw 'Explicit isolated outbound network attachment changed.'
    }
    $nat = Invoke-Azure @('network', 'nat', 'gateway', 'show', '--ids', $natId)
    $pipId = "$groupId/providers/Microsoft.Network/publicIPAddresses/pip-retailtx-guest-$EnvironmentName-egress"
    if ($nat.id -ine $natId -or $nat.location -ine $location -or
        $nat.tags.ownerToken -cne $script:state.ownerToken -or $nat.tags.profile -cne 'guest-service' -or
        $nat.sku.name -cne 'Standard' -or $nat.idleTimeoutInMinutes -ne 4 -or
        @($nat.publicIpAddresses).Count -ne 1 -or $nat.publicIpAddresses[0].id -ine $pipId -or
        $nat['publicIpPrefixes'] -or @($nat.subnets).Count -ne 1 -or $nat.subnets[0].id -ine $subnetId) {
        throw 'Exact owned NAT configuration or attachment changed.'
    }
    $pip = Invoke-Azure @('network', 'public-ip', 'show', '--ids', $pipId)
    if ($pip.id -ine $pipId -or $pip.location -ine $location -or
        $pip.tags.ownerToken -cne $script:state.ownerToken -or $pip.tags.profile -cne 'guest-service' -or
        $pip.sku.name -cne 'Standard' -or $pip.sku.tier -cne 'Regional' -or
        $pip.publicIPAllocationMethod -cne 'Static' -or $pip.publicIPAddressVersion -cne 'IPv4' -or
        $pip.natGateway.id -ine $natId -or $pip['ipConfiguration'] -or $pip['publicIPPrefix'] -or
        $pip['dnsSettings']) {
        throw 'Exact owned outbound-only public IP configuration changed.'
    }
    $nsg = Invoke-Azure @('network', 'nsg', 'show', '--ids', $nsgId)
    $monitoring = $script:state.ContainsKey('withMonitoring') -and $script:state.withMonitoring
    if ($nsg.tags.ownerToken -cne $script:state.ownerToken -or @($nsg.securityRules).Count -ne $(if ($monitoring) { 6 } else { 5 })) {
        throw 'Guest network security ownership/rule count mismatch.'
    }
    $expected = @{
        AzureHttps = @{ direction = 'Outbound'; access = 'Allow'; priority = 100; protocol = 'Tcp'
            destinationPortRange = '443'; destinationAddressPrefix = 'AzureCloud' }
        AzureVmAgent = @{ direction = 'Outbound'; access = 'Allow'; priority = 110; protocol = 'Tcp'
            destinationAddressPrefix = '168.63.129.16' }
        AzureDns = @{ direction = 'Outbound'; access = 'Allow'; priority = 120; protocol = '*'
            destinationPortRange = '53'; destinationAddressPrefix = '168.63.129.16' }
        DenyInbound = @{ direction = 'Inbound'; access = 'Deny'; priority = 4096; protocol = '*'
            destinationPortRange = '*'; destinationAddressPrefix = '*' }
        DenyOutbound = @{ direction = 'Outbound'; access = 'Deny'; priority = 4096; protocol = '*'
            destinationPortRange = '*'; destinationAddressPrefix = '*' }
    }
    if ($monitoring) {
        if ((Get-GuestMonitorTransport) -ceq 'Private') {
            $expected.PrivateMonitor = @{ direction = 'Outbound'; access = 'Allow'; priority = 130; protocol = 'Tcp'
                destinationPortRange = '443'; destinationAddressPrefix = '10.89.0.0/24' }
        } else {
            $expected.PublicMonitor = @{ direction = 'Outbound'; access = 'Allow'; priority = 130; protocol = 'Tcp'
                destinationPortRange = '443'; destinationAddressPrefix = 'AzureMonitor' }
        }
    }
    foreach ($rule in $nsg.securityRules) {
        if (-not $expected.ContainsKey($rule.name)) { throw 'Unexpected guest network rule.' }
        foreach ($key in $expected[$rule.name].Keys) {
            if ($rule[$key] -cne $expected[$rule.name][$key]) { throw 'Guest network policy drift.' }
        }
        if ($rule.sourceAddressPrefix -cne '*' -or $rule.sourcePortRange -cne '*' -or
            $rule['sourceAddressPrefixes'] -or $rule['sourcePortRanges'] -or
            $rule['destinationAddressPrefixes']) { throw 'Unexpected guest network range.' }
        if ($rule.name -ceq 'AzureVmAgent') {
            if (@($rule.destinationPortRanges).Count -ne 2 -or
                $rule.destinationPortRanges[0] -cne '80' -or $rule.destinationPortRanges[1] -cne '32526') {
                throw 'VM agent outbound ports changed.'
            }
        } elseif ($rule['destinationPortRanges']) { throw 'Guest network port range changed.' }
    }
}

function Get-PowerState {
    $view = Invoke-Azure @('vm', 'get-instance-view', '--ids', $vmId)
    $states = @($view.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' })
    if ($states.Count -ne 1) { throw 'Unambiguous VM power evidence missing.' }
    return $states[0].code
}

function Add-GuestJournal {
    param([hashtable]$Record)
    $script:state.journal = @($script:state.journal) + @($Record)
    Save-RetailState $script:state $statePath
}

function Get-GuestBaseDeploymentParameters {
    param([string]$AdminSshPublicKey)
    $parameters = @{
        environmentName = @{ value = $EnvironmentName }
        location = @{ value = $location }
        ownerToken = @{ value = $script:state.ownerToken }
        expiresAt = @{ value = $script:state.expiresAt }
        adminSshPublicKey = @{ value = $AdminSshPublicKey }
        agentPrincipalId = @{ value = if ($script:state['standalone']) { '' } else { $script:state.retainedAgentPrincipalId } }
    }
    if ($script:state.ContainsKey('withMonitoring')) { $parameters.withMonitoring = @{ value = $script:state.withMonitoring } }
    $parameters.assignRetainedReader = @{ value = -not $script:state['standalone'] -and
        -not ($script:state['withMonitoring'] -and -not $script:state['withSreExecution']) }
    $parameters.monitorTransport = @{ value = (Get-GuestMonitorTransport) }
    return $parameters
}

function Save-GuestTeardownUnknown {
    param([string]$Reason)
    $residuals = @()
    try {
        if (Invoke-Azure @('group', 'exists', '--name', $groupName)) {
            $resources = @(Invoke-Azure @('resource', 'list', '--resource-group', $groupName))
            $residuals = @($resources | ForEach-Object {
                @{ id = $_.id; type = $_.type; provisioningState = $_.properties.provisioningState }
            })
        }
    } catch {
        $residuals = @(@{ id = $groupId; type = 'Microsoft.Resources/resourceGroups'; status = 'unknown' })
        $script:state.teardownReconcileError = $_.Exception.Message
    }
    if ($residuals.Count -eq 0) {
        $residuals = @(@{ id = $groupId; type = 'Microsoft.Resources/resourceGroups'; status = 'outcome-unknown' })
    }
    $script:state.teardownStatus = 'unknown'
    $script:state.teardownFailureReason = $Reason
    $script:state.teardownResiduals = $residuals
    $script:state.retentionReportAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Save-RetailState $script:state $statePath
}

function Wait-GuestDeployment {
    param([int]$TimeoutSeconds = 180, [int]$PollSeconds = 5)
    foreach ($binding in @(
        @{ action = 'deploy'; name = "retailtx-guest-$EnvironmentName" }
        @{ action = 'deploy-isolated-sre-agent'; name = "retailtx-guest-agent-$EnvironmentName" }
    )) {
        $intents = @($script:state.journal | Where-Object { $_.action -ceq $binding.action })
        if ($intents.Count -eq 0) { continue }
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            $names = @(Invoke-Azure @('deployment', 'sub', 'list', '--query', "[?name=='$($binding.name)'].name"))
            if ($names.Count -eq 0 -and $intents[-1].outcome -ceq 'deployment-succeeded') { break }
            if ($names.Count -gt 1) { throw 'Ambiguous owned deployment history; refusing teardown.' }
            if ($names.Count -eq 1) {
                $deployment = Invoke-Azure @('deployment', 'sub', 'show', '--name', $binding.name)
                $parameters = $deployment.properties.parameters
                if ($deployment.id -ine "/subscriptions/$subscription/providers/Microsoft.Resources/deployments/$($binding.name)" -or
                    $parameters.ownerToken.value -cne $script:state.ownerToken -or
                    $parameters.environmentName.value -cne $EnvironmentName -or
                    $parameters.location.value -cne $location) {
                    throw 'Deployment ownership does not match the teardown intent.'
                }
                if ($deployment.properties.provisioningState -cin @('Succeeded', 'Failed', 'Canceled')) { break }
            }
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                Save-GuestTeardownUnknown -Reason 'Owned deployment is nonterminal or its admission remains unknown; no deletion attempted.'
                throw 'Deployment outcome is unresolved; reconcile it read-only before Down. No role/resource absence claim.'
            }
            Start-Sleep -Seconds $PollSeconds
        } while ($true)
    }
}

function Assert-GuestBaselineAbsent {
    $baseline = @(Get-GuestBaselineGrantExpectation -AllowLegacy)
    $remaining = @()
    foreach ($scope in @($baseline | ForEach-Object scope | Select-Object -Unique)) {
        $remaining += @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $scope,
            '--fill-principal-name', 'false', '--fill-role-definition-name', 'false') |
            Where-Object { $_.id -iin @($baseline | ForEach-Object id) })
    }
    if ($script:state.withSreExecution -and $script:state.agentPrincipalId) {
        $remaining += @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--include-inherited',
            '--assignee-object-id', $script:state.agentPrincipalId,
            '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
    }
    if ($remaining.Count -ne 0) {
        Save-GuestTeardownUnknown -Reason 'Recorded baseline or unexpected action-identity roles remain after resource deletion.'
        $script:state.teardownResiduals = @($remaining | Sort-Object -Property id -Unique | ForEach-Object {
            @{ id = $_.id; type = 'Microsoft.Authorization/roleAssignments' }
        })
        Save-RetailState $script:state $statePath
        throw 'Role-assignment residuals remain after resource teardown; no deleted/absence-verified claim.'
    }
}

function Assert-GuestGroupAbsent {
    if (Get-OwnedGroup) {
        Save-GuestTeardownUnknown -Reason 'Owned resource group still exists after teardown.'
        $script:state.teardownResiduals = @(@{ id = $groupId; type = 'Microsoft.Resources/resourceGroups' })
        Save-RetailState $script:state $statePath
        throw 'Owned resource group remains; no deleted/absence-verified claim.'
    }
}

function Invoke-GuestGroupDeletion {
    param([int]$TimeoutMinutes = 10, [int]$PollSeconds = 10)
    try {
        $null = Invoke-Azure @('group', 'delete', '--name', $groupName, '--yes', '--no-wait')
    } catch {
        $submitError = $_.Exception.Message
        try {
            if (-not (Invoke-Azure @('group', 'exists', '--name', $groupName))) { return }
        } catch {
            Save-GuestTeardownUnknown -Reason "Delete submission and read-only reconciliation failed: $submitError"
            throw 'Guest fixture deletion outcome is unknown. Review retentionReportAtUtc and teardownResiduals in the manifest.'
        }
        Save-GuestTeardownUnknown -Reason "Delete submission failed and the resource group still exists: $submitError"
        throw 'Guest fixture deletion was not confirmed. Review retentionReportAtUtc and teardownResiduals in the manifest.'
    }

    $deadline = [DateTimeOffset]::UtcNow.AddMinutes($TimeoutMinutes)
    do {
        try {
            if (-not (Invoke-Azure @('group', 'exists', '--name', $groupName))) { return }
        } catch {
            Save-GuestTeardownUnknown -Reason "Read-only deletion polling failed: $($_.Exception.Message)"
            throw 'Guest fixture deletion outcome is unknown. Review retentionReportAtUtc and teardownResiduals in the manifest.'
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            Save-GuestTeardownUnknown -Reason 'Resource-group deletion did not complete before the bounded timeout.'
            throw 'Guest fixture deletion remains asynchronous or blocked. Review teardownResiduals in the manifest; do not claim SRE Agent removal.'
        }
        Start-Sleep -Seconds $PollSeconds
    } while ($true)
}

function ConvertFrom-GuestJson {
    param([string]$Json)
    $options = @{ AsHashtable = $true }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
    return ($Json | ConvertFrom-Json @options)
}

function ConvertFrom-GuestResult {
    param([hashtable]$Result)
    if (-not $Result.ContainsKey('value') -or @($Result.value).Count -eq 0) {
        throw 'No Action Run Command result.'
    }
    $lines = @()
    foreach ($item in $Result.value) {
        if ($item.code -notmatch '/succeeded$') { throw 'Run Command did not report success.' }
        $lines += @($item.message -split "`r?`n" | Where-Object { $_.StartsWith('RETAILTX_GUEST=') })
    }
    if ($lines.Count -ne 1 -or [Text.Encoding]::UTF8.GetByteCount($lines[0]) -gt 3500) {
        throw 'Guest evidence missing, ambiguous, or truncated.'
    }
    $evidence = ConvertFrom-GuestJson $lines[0].Substring('RETAILTX_GUEST='.Length)
    if ($evidence.schemaVersion -ne 1 -or $evidence.ownerToken -cne $script:state.ownerToken -or
        $evidence.service -cne 'retailtx-demo-posting-worker' -or
        $evidence.active -isnot [bool] -or $evidence.healthy -isnot [bool] -or
        $evidence.watchdogActive -isnot [bool] -or $evidence.watchdogEnabled -isnot [bool]) {
        throw 'Guest evidence ownership or shape mismatch.'
    }
    $observed = [DateTimeOffset]::Parse($evidence.observedAtUtc)
    if ([Math]::Abs(([DateTimeOffset]::UtcNow - $observed).TotalSeconds) -gt 180) {
        throw 'Guest evidence is stale; no recovery claim permitted.'
    }
    Assert-ExactHash $script:state.sourceHashes $evidence.sourceHashes
    Assert-GuestRecoveryPolicy $evidence
    if ($evidence.marker) { Assert-GuestMarker $evidence.marker }
    return $evidence
}

function Assert-GuestMarker {
    param([hashtable]$Marker)
    $null = [guid]::Parse($Marker.runId)
    $null = [guid]::Parse($Marker.actor)
    $started = [DateTimeOffset]$Marker.startedAtUtc
    $admission = [DateTimeOffset]$Marker.startBeforeUtc
    if ($Marker.ContainsKey('faultLifetime')) {
        if ($Marker.faultLifetime -cne 'Manual' -or $Marker.durationSeconds -ne 0 -or $Marker.deadlineUtc -or
            $Marker.canary -isnot [bool] -or
            $Marker.phase -cnotin @('prepared', 'fault-active', 'recovering', 'recovered', 'cancelled') -or
            ($Marker.phase -cne 'cancelled' -and $started -gt $admission)) {
            throw 'Invalid manual lifetime or fault admission marker.'
        }
        return
    }
    $deadline = [DateTimeOffset]$Marker.deadlineUtc
    if ($Marker.phase -cnotin @('prepared', 'fault-active', 'recovering', 'recovered', 'cancelled') -or
        $Marker.canary -isnot [bool] -or
        ($Marker.canary -and $Marker.durationSeconds -ne 60) -or
        (-not $Marker.canary -and ($Marker.durationSeconds -lt 120 -or $Marker.durationSeconds -gt 600)) -or
        [Math]::Abs(($deadline - $started).TotalSeconds - $Marker.durationSeconds) -gt 0.01 -or
        ($Marker.phase -cne 'cancelled' -and $started -gt $admission)) {
        throw 'Unbounded or invalid guest marker.'
    }
}

function Assert-GuestCommandEvidence {
    param([hashtable]$Request, [hashtable]$Evidence)
    if ($Request.action -ceq 'status') { return }
    Assert-GuestRecoveryPolicy $Evidence
    if ($Request.action -ceq 'fault') {
        $marker = $Evidence.marker
        if (-not $marker -or $marker.runId -cne $Request.runId -or $marker.actor -cne $Request.actor -or
            [DateTimeOffset]$marker.startBeforeUtc -ne [DateTimeOffset]$Request.startBeforeUtc -or
            $marker.durationSeconds -ne $Request.durationSeconds -or
            $marker.canary -ne $Request.canary -or $marker.phase -cnotin @('fault-active', 'recovered')) {
            throw 'Fault requires exact run, actor, deadline and stopped-service readback.'
        }
        if ($marker.phase -ceq 'fault-active') {
            if ($Evidence.active -or $Evidence.healthy) { throw 'Fault did not stop the exact worker.' }
            return
        }
    } elseif ($Request.action -in @('repair', 'reset')) {
        if ($Evidence.marker) {
            if ($Evidence.marker.runId -cne $Request.runId -or $Evidence.marker.phase -cne 'recovered' -or
                $Evidence.marker['recoveredBy'] -cne $Request.actor -or
                $Evidence.marker['recoveryReason'] -cne $Request.action) {
                throw 'Repair/reset did not recover the exact expected run.'
            }
        } elseif ($Request.action -cne 'reset' -or $Request.runId -cne [guid]::Empty.ToString()) {
            throw 'Repair/reset run evidence missing.'
        }
    }
    if (-not $Evidence.active -or -not $Evidence.healthy) { throw 'Write readback did not verify healthy service.' }
}

function Invoke-GuestCommand {
    param([hashtable]$Request, [switch]$Configure)
    Assert-GuestNativeReadSettled
    $null = Get-OwnedVm
    if ((Get-PowerState) -cne 'PowerState/running') { throw 'Guest command requires running VM; VM lifecycle is not a repair action.' }
    $id = [guid]::NewGuid().ToString()
    $commandPath = Join-Path $directory "guest-command-$id.sh"
    $resultPath = Join-Path $directory "guest-result-$id.json"
    $encoded = ConvertTo-RetailGuestPayload $Request
    $command = "/usr/bin/python3 /opt/retailtx-guest/controller.py '$encoded'"
    if ($Configure) {
        $sources = @{}
        foreach ($name in $guestFiles) {
            $sources[$name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot "guest\$name")))
        }
        $payload = ConvertTo-RetailGuestPayload @{
            config = @{ schemaVersion = $(if ($script:state['faultLifetime'] -ceq 'Manual') { 2 } else { 1 })
                ownerToken = $script:state.ownerToken; sourceHashes = $script:state.sourceHashes }
            sources = $sources
        }
        $installer = $sources['bootstrap.py']
        $command = "/usr/bin/python3 -c `"import base64;exec(base64.b64decode('$installer'))`" '$payload'"
    }
    "#!/bin/bash`nset -euo pipefail`n$command`n" | Set-Content -LiteralPath $commandPath -Encoding utf8NoBOM
    $record = @{
        commandId = $id; action = $Request.action; request = $Request
        commandSha256 = (Get-FileHash $commandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        intentAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); outcome = 'intent'
        commandFile = $commandPath; resultFile = $resultPath
    }
    if ($Request.action -cne 'status') {
        if ($script:state.pendingCommand) { throw 'Unresolved write intent; use Status or Down, never replay it.' }
        $script:state.pendingCommand = $record
    }
    Add-GuestJournal $record
    try {
        $raw = Invoke-Azure @('vm', 'run-command', 'invoke', '--ids', $vmId,
            '--command-id', 'RunShellScript', '--scripts', "@$commandPath") -TimeoutSeconds 180
        $raw | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
        $record.outcome = 'result-received'
        $record.resultSha256 = (Get-FileHash $resultPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Save-RetailState $script:state $statePath
        $evidence = ConvertFrom-GuestResult $raw
        Assert-GuestCommandEvidence $Request $evidence
        $record.outcome = 'verified'
        $record.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $script:state.lastEvidence = $evidence
        $script:state.observedAtUtc = $evidence.observedAtUtc
        if ($Request.action -cne 'status') { $script:state.pendingCommand = $null }
        Save-RetailState $script:state $statePath
        return $evidence
    } catch {
        $record.outcome = 'unknown'
        $record.errorAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Save-RetailState $script:state $statePath
        throw 'Guest command outcome is unverified. Do not replay writes: use Status for exact readback, explicit Reset or Down. Manual faults do not automatically recover.'
    }
}

function Get-GuestStatus {
    if ((Get-GuestMonitorReadMode) -ceq 'Operator' -and $script:state['monitorConfigured']) {
        return (Get-GuestTelemetry).receipt
    } else {
        $request = @{ action = 'status'; ownerToken = $script:state.ownerToken; sourceHashes = $script:state.sourceHashes }
        $evidence = Invoke-GuestCommand $request
    }
    Update-GuestStatus $evidence
    return $evidence
}

function Update-GuestStatus {
    param([hashtable]$Evidence)
    $script:state.lastEvidence = $Evidence
    $script:state.observedAtUtc = $Evidence.observedAtUtc
    $pending = $script:state.pendingCommand
    if ($pending) {
        $failed = $Evidence['failedCommand']
        $terminalFailure = $script:state['faultLifetime'] -ceq 'Manual' -and
            $Evidence['faultLifetime'] -ceq 'Manual' -and $failed -and
            $pending.action -cin @('repair', 'reset') -and $failed.outcome -ceq 'failed' -and
            $failed.action -ceq $pending.action -and $failed.runId -ceq $pending.request.runId -and
            $failed.actor -ceq $pending.request.actor -and $Evidence.marker -and
            $Evidence.marker.runId -ceq $pending.request.runId -and
            [DateTimeOffset]$failed.completedAtUtc -ge [DateTimeOffset]$pending.intentAtUtc -and
            [DateTimeOffset]$failed.completedAtUtc -le [DateTimeOffset]$Evidence.observedAtUtc
        $confirmed = switch ($pending.action) {
            'configure' { $evidence.active -and $evidence.healthy }
            'fault' {
                $evidence.marker -and $evidence.marker.runId -ceq $pending.request.runId -and
                $evidence.marker.actor -ceq $pending.request.actor -and
                [DateTimeOffset]$evidence.marker.startBeforeUtc -eq [DateTimeOffset]$pending.request.startBeforeUtc -and
                $evidence.marker.durationSeconds -eq $pending.request.durationSeconds -and
                $evidence.marker.canary -eq $pending.request.canary
            }
            { $_ -in @('repair', 'reset') } {
                $evidence.healthy -and $evidence.active -and
                $evidence.marker -and $evidence.marker.runId -ceq $pending.request.runId -and
                $evidence.marker.phase -ceq 'recovered' -and
                $evidence.marker['recoveredBy'] -ceq $pending.request.actor -and
                $evidence.marker['recoveryReason'] -ceq $pending.request.action
            }
            default { $false }
        }
        if ($confirmed -or $terminalFailure) {
            $pending.outcome = if ($terminalFailure) { 'guest-failed' } else { 'readback-confirmed' }
            $pending.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            foreach ($entry in $script:state.journal) {
                if ($entry.ContainsKey('commandId') -and $entry.commandId -ceq $pending.commandId) {
                    $entry.outcome = $pending.outcome
                    $entry.completedAtUtc = $pending.completedAtUtc
                }
            }
            if ($terminalFailure) {
                $script:state.failedRecovery = @{
                    commandId = $pending.commandId; action = $pending.action; runId = $pending.request.runId
                    actor = $pending.request.actor; guestCompletedAtUtc = $failed.completedAtUtc
                }
            } elseif ($confirmed -and $pending.action -ceq 'reset') {
                $script:state.Remove('failedRecovery')
            }
            $script:state.pendingCommand = $null
        }
    }
    if ($evidence.marker -and $script:state.currentFault -and
        $script:state.currentFault.runId -ceq $evidence.marker.runId) {
        $script:state.currentFault.deadlineUtc = $evidence.marker.deadlineUtc
    }
    $script:state.phase = if ($script:state.pendingCommand) { 'outcome-unknown' }
        elseif ($evidence.marker -and $evidence.marker.phase -cnotin @('recovered', 'cancelled')) { $evidence.marker.phase }
        elseif ($evidence.active -and $evidence.healthy) { 'ready' }
        else { 'unhealthy' }
    Save-RetailState $script:state $statePath
}

function Get-GuestOutput {
    param([bool]$GroupExists, [string]$PowerState, [AllowNull()][hashtable]$Evidence)
    $publicState = $script:state.Clone()
    $publicState.Remove('journal')
    if ($publicState['nativeRead']) { $publicState.nativeRead = Get-GuestNativeReadSummary }
    $publicState.journalCount = @($script:state.journal).Count
    return [pscustomobject]@{ state = $publicState; groupExists = $GroupExists; powerState = $PowerState; evidence = $Evidence }
}

if ($WhatIfPreference) {
    $null = $PSCmdlet.ShouldProcess($vmId, "$Operation operator Action Run Command fixture (no preflight or local writes)")
    return
}

$account = Invoke-Azure @('account', 'show')
$null = New-Item -ItemType Directory -Path $directory -Force
$lease = [IO.File]::Open((Join-Path $directory 'guest-service.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    if (Test-Path -LiteralPath $statePath) {
        $script:state = ConvertFrom-GuestJson (Get-Content -LiteralPath $statePath -Raw)
        Assert-GuestManifest
    }
    $group = Get-OwnedGroup
    if ($Operation -ne 'Up' -and -not $script:state) { throw 'No guest-service ownership manifest.' }
    if ($Operation -eq 'Down') {
        if (-not $PSCmdlet.ShouldProcess($groupId, 'Delete exact owned guest fixture and verify absence')) { return }
        Wait-GuestDeployment
        $group = Get-OwnedGroup
        Assert-GuestTeardownInventory
        if ($group -and $script:state['recoverySkill']) {
            Remove-GuestRecoverySkill (Get-GuestMonitorConnection)
        }
        if ($script:state.withMonitoring) { Remove-GuestMonitorAccess }
        if ($script:state.withMonitoring -and (Test-GuestOwnedMonitor)) { Remove-GuestMonitorFoundation }
        Assert-GuestExecutionAssignmentsForTeardown
        Remove-GuestExecutionRoleAssignments
        Remove-GuestExecutionRole
        $script:state.phase = 'deleting'
        Add-GuestJournal @{ action = 'delete'; intentAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); outcome = 'intent' }
        if ($group) { Invoke-GuestGroupDeletion }
        if ($script:state.withMonitoring) { Assert-GuestMonitorEndpointAbsent }
        if ($script:state.withMonitoring -and (Test-GuestOwnedMonitor)) { Assert-GuestMonitorWorkspaceAbsent }
        $residuals = @(Invoke-Azure @('resource', 'list', '--tag', "ownerToken=$($script:state.ownerToken)"))
        if ($residuals.Count -ne 0) {
            $script:state.teardownResiduals = @($residuals | ForEach-Object { @{ id = $_.id; type = $_.type } })
            $script:state.retentionReportAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Save-RetailState $script:state $statePath
            throw 'Owned resources remain outside the deleted group. See teardownResiduals; no absence claim.'
        }
        $remainingRoles = @(if ($script:state.withSreExecution) {
            @(Invoke-Azure @('role', 'definition', 'list', '--name', $script:state.actionRoleDefinitionName))
        })
        if ($remainingRoles.Count -ne 0) {
            $script:state.teardownResiduals = @($remainingRoles | ForEach-Object { @{ id = $_.id; type = 'Microsoft.Authorization/roleDefinitions' } })
            $script:state.retentionReportAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Save-RetailState $script:state $statePath
            throw 'Fixture-scoped custom role definition remains after group teardown. See teardownResiduals.'
        }
        Assert-GuestGroupAbsent
        Assert-GuestBaselineAbsent
        $script:state.phase = 'deleted'
        $script:state.teardownStatus = 'absence-verified'
        $script:state.Remove('teardownFailureReason')
        $script:state.Remove('teardownReconcileError')
        $script:state.absenceVerifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $script:state.teardownResiduals = @()
        $script:state.journal[-1].outcome = 'absence-verified'
        Save-RetailState $script:state $statePath
        Get-GuestOutput -GroupExists $false -PowerState 'absent' -Evidence $null
        return
    }
    $independent = if ($script:state -and $script:state.phase -cne 'deleted') {
        $script:state['standalone'] -eq $true
    } else { $Standalone.IsPresent }
    if ($Operation -ceq 'Up' -and $script:state -and $script:state.phase -cne 'deleted' -and
        $independent -ne $Standalone.IsPresent) { throw 'Standalone mode is immutable; use the recorded deployment mode.' }
    $foundation = $null
    if ($independent) {
        $binding = @{ agentId = $null; agentIdentityId = $null; agentPrincipalId = $null }
    } else {
        $foundationPath = Join-Path $root ".azure\$FoundationEnvironment\retailtx-state.json"
        $foundation = Get-Content -LiteralPath $foundationPath -Raw | ConvertFrom-Json -AsHashtable
        if ($foundation.schemaVersion -ne 1 -or $foundation.subscriptionId -ine $subscription -or
            $foundation.tenantId -ine $account.tenantId -or $foundation.environmentName -cne $FoundationEnvironment) {
            throw 'Retained foundation and CLI identity do not match explicit subscription/tenant.'
        }
        $binding = Get-RetainedGuestIdentity $foundation
    }
    $sourceHashes = Get-SourceHash
    $artifactHashes = Get-ArtifactHash
    if ($script:state -and $script:state.phase -cne 'deleted') {
        Assert-ExactHash $script:state.sourceHashes $sourceHashes
        Assert-ExactHash $script:state.artifactHashes $artifactHashes
    }
    if ($Operation -cne 'Inspect' -and
        ($Operation -cne 'Telemetry' -or (Get-GuestMonitorReadMode) -cne 'Operator') -and
        -not $PSCmdlet.ShouldProcess($vmId, "$Operation operator Action Run Command fixture")) { return }
    if ($group) { $null = Get-OwnedVm; Assert-GuestNetwork }
    if ($Operation -eq 'Up') {
        if ($script:state -and $script:state.phase -cne 'deleted') {
            if ([bool]$script:state.withSreExecution -ne $WithSreExecution.IsPresent) {
                throw 'Fixture execution mode is immutable. Use Down before changing WithSreExecution.'
            }
            if ([bool]$script:state.withMonitoring -ne $WithMonitoring.IsPresent) { throw 'Monitoring mode is immutable; use Down first.' }
            if ($WithMonitoring -and $script:state.monitorTransport -cne $MonitorTransport) {
                throw 'Monitor transport is immutable; use Down before changing it.'
            }
            if ((Get-GuestMonitorReadMode) -cne $MonitorReadMode) {
                throw 'Monitor read mode is immutable; use Down before changing it.'
            }
            if ([bool]$script:state.withIsolatedMonitoring -ne $WithIsolatedMonitoring.IsPresent) {
                throw 'Monitoring isolation is immutable; use Down before changing it.'
            }
            if (-not $group -or $script:state.phase -in @('provisioning', 'deleting')) {
                throw 'Incomplete deployment intent cannot be replayed blindly; use Down then Up.'
            }
            if ($script:state.pendingCommand -and $script:state.pendingCommand.action -cne 'configure') {
                throw 'Outstanding guest fault/repair intent; use Status or Down.'
            }
            Assert-GuestReader
            Assert-GuestExecutionAgent
            $evidence = Get-GuestStatus
        } else {
            if ($group) { throw 'Deleted manifest has live resources; refusing recreation.' }
            $operatorObjectId = $null
            $actionRoleName = $null
            if ($WithSreExecution) {
                $operatorIdentity = Invoke-Azure @('rest', '--method', 'get', '--url',
                    'https://graph.microsoft.com/v1.0/me?$select=id')
                $operatorObjectId = [guid]::Parse($operatorIdentity.id).ToString()
                $actionRoleName = [guid]::NewGuid().ToString()
            }
            $script:state = @{
                schemaVersion = 2; profile = 'guest-service'; environmentName = $EnvironmentName
                subscriptionId = $subscription; tenantId = $account.tenantId; location = $location
                groupId = $groupId; vmId = $vmId; ownerToken = [guid]::NewGuid().ToString()
                phase = 'provisioning'; sourceHashes = $sourceHashes; artifactHashes = $artifactHashes
                faultLifetime = 'Manual'
                expiresAt = [DateTimeOffset]::UtcNow.AddHours(4).ToString('o')
                journal = @(); pendingCommand = $null; currentFault = $null; lastEvidence = $null
                withSreExecution = $WithSreExecution.IsPresent
                standalone = $Standalone.IsPresent
                withMonitoring = $WithMonitoring.IsPresent
                withIsolatedMonitoring = $WithIsolatedMonitoring.IsPresent
                monitorTransport = if ($WithMonitoring) { $MonitorTransport } else { 'Private' }
                monitorReadMode = $MonitorReadMode
                retainedAgentId = $binding.agentId; retainedAgentIdentityId = $binding.agentIdentityId
                retainedAgentPrincipalId = $binding.agentPrincipalId
                readerAssignmentId = $null
                agentId = if ($WithSreExecution) { "$groupId/providers/Microsoft.App/agents/sre-retailtx-guest-agent-$EnvironmentName" } else { $binding.agentId }
                agentIdentityId = if ($WithSreExecution) { "$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-retailtx-guest-agent-$EnvironmentName" } else { $binding.agentIdentityId }
                agentPrincipalId = if ($WithSreExecution) { $null } else { $binding.agentPrincipalId }
                actionClientId = $null; systemPrincipalId = $null; agentEndpoint = $null
                actionRoleDefinitionName = $actionRoleName
                actionRoleDefinitionId = if ($actionRoleName) { "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$actionRoleName" } else { $null }
                actionRoleAssignmentId = $null; actionReaderAssignmentId = $null
                systemReaderAssignmentId = $null; networkAssignmentId = $null
                adminObjectId = $operatorObjectId; adminAssignmentId = $null
            }
            if ($WithSreExecution) {
                $script:state.agentPermissionModel = 'DocumentedBaseline'
                $script:state.actionLogReaderAssignmentId = "$groupId/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())"
                $script:state.actionMonitoringReaderAssignmentId = "$groupId/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())"
                $script:state.actionMonitoringContributorAssignmentId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())"
            }
            if ($WithMonitoring) {
                $script:state.workspaceId = if ($WithIsolatedMonitoring -or $MonitorTransport -ceq 'Public') {
                    "$groupId/providers/Microsoft.OperationalInsights/workspaces/law-retailtx-guest-$EnvironmentName"
                } else { $foundation.outputs.WORKSPACE_ID }
                $script:state.workspaceCustomerId = if ($WithIsolatedMonitoring -or $MonitorTransport -ceq 'Public') { $null } else { $foundation.outputs.WORKSPACE_CUSTOMER_ID }
                $script:state.dceId = if ($MonitorTransport -ceq 'Public') { $null } elseif ($WithIsolatedMonitoring) {
                    "$groupId/providers/Microsoft.Insights/dataCollectionEndpoints/dce-retailtx-guest-$EnvironmentName"
                } else { $foundation.outputs.DCE_ID }
                $script:state.privateLinkScopeId = if ($MonitorTransport -ceq 'Public') { $null } elseif ($WithIsolatedMonitoring) {
                    "$groupId/providers/Microsoft.Insights/privateLinkScopes/ampls-retailtx-guest-$EnvironmentName"
                } else { "$(($foundation.outputs.WORKSPACE_ID -split '/providers/')[0])/providers/Microsoft.Insights/privateLinkScopes/ampls-retailtx-$FoundationEnvironment" }
                $script:state.monitorAccess = @{}
            }
            Save-RetailState $script:state $statePath
            $keyPath = Join-Path $directory 'guest-ephemeral-key'
            if ((Test-Path $keyPath) -or (Test-Path "$keyPath.pub")) { throw 'Uncleaned ephemeral key; refusing overwrite.' }
            try {
                & ssh-keygen -q -t ed25519 -N '' -C 'retailtx-guest-service' -f $keyPath
                if ($LASTEXITCODE -ne 0) { throw 'Ephemeral key generation failed.' }
                $publicKey = (Get-Content "$keyPath.pub" -Raw).Trim()
            } finally {
                foreach ($path in @($keyPath, "$keyPath.pub")) {
                    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
                }
            }
            $parameters = Get-GuestBaseDeploymentParameters -AdminSshPublicKey $publicKey
            $parameterPath = Join-Path $directory 'guest-service.parameters.json'
            @{ parameters = $parameters } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameterPath -Encoding utf8NoBOM
            Add-GuestJournal @{ action = 'deploy'; intentAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); outcome = 'intent' }
            $deployment = Invoke-Azure @('deployment', 'sub', 'create', '--name', "retailtx-guest-$EnvironmentName",
                '--location', $location, '--template-file', (Join-Path $root 'infra\guest-service.bicep'),
                '--parameters', "@$parameterPath") -TimeoutSeconds 1200
            if ($deployment.properties.provisioningState -cne 'Succeeded') { throw 'Deployment completion not verified; use Down.' }
            $script:state.journal[-1].outcome = 'deployment-succeeded'
            $outputs = ConvertFrom-RetailDeploymentOutputs $deployment.properties.outputs
            $script:state.readerAssignmentId = $outputs.READERASSIGNMENTID
            Save-RetailState $script:state $statePath
            Assert-GuestNetwork
            if ($WithSreExecution) {
                $agentParameters = @{
                    resourceGroupName = @{ value = $groupName }
                    environmentName = @{ value = $EnvironmentName }
                    location = @{ value = $location }
                    tags = @{ value = @{
                        demo = 'retailtx'; environmentId = $EnvironmentName; profile = 'guest-service'
                        managedBy = 'retailtx'; ownerToken = $script:state.ownerToken
                        expiresAt = $script:state.expiresAt
                    } }
                    ownerToken = @{ value = $script:state.ownerToken }
                    vmName = @{ value = $vmName }
                    actionRoleDefinitionName = @{ value = $script:state.actionRoleDefinitionName }
                    adminObjectId = @{ value = $script:state.adminObjectId }
                    actionLogReaderAssignmentName = @{ value = ($script:state.actionLogReaderAssignmentId -split '/')[-1] }
                    actionMonitoringReaderAssignmentName = @{ value = ($script:state.actionMonitoringReaderAssignmentId -split '/')[-1] }
                    actionMonitoringContributorAssignmentName = @{ value = ($script:state.actionMonitoringContributorAssignmentId -split '/')[-1] }
                }
                $agentParameterPath = Join-Path $directory 'guest-service-agent.parameters.json'
                @{ parameters = $agentParameters } | ConvertTo-Json -Depth 10 |
                    Set-Content -LiteralPath $agentParameterPath -Encoding utf8NoBOM
                Add-GuestJournal @{ action = 'deploy-isolated-sre-agent'; intentAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); outcome = 'intent' }
                $agentDeployment = Invoke-Azure @('deployment', 'sub', 'create', '--name', "retailtx-guest-agent-$EnvironmentName",
                    '--location', $location, '--template-file', (Join-Path $root 'infra\guest-service-agent.bicep'),
                    '--parameters', "@$agentParameterPath") -TimeoutSeconds 1200
                if ($agentDeployment.properties.provisioningState -cne 'Succeeded') {
                    throw 'Isolated SRE Agent deployment is incomplete; use Down, never replay partial provisioning.'
                }
                $agentOutputs = ConvertFrom-RetailDeploymentOutputs $agentDeployment.properties.outputs
                $script:state.agentId = $agentOutputs.AGENTID
                $script:state.agentEndpoint = $agentOutputs.AGENTENDPOINT
                $script:state.agentIdentityId = $agentOutputs.ACTIONIDENTITYID
                $script:state.agentPrincipalId = [guid]::Parse($agentOutputs.ACTIONPRINCIPALID).ToString()
                $script:state.actionClientId = [guid]::Parse($agentOutputs.ACTIONCLIENTID).ToString()
                $script:state.systemPrincipalId = [guid]::Parse($agentOutputs.SYSTEMPRINCIPALID).ToString()
                $script:state.actionRoleDefinitionId = $agentOutputs.ACTIONROLEDEFINITIONID
                $script:state.actionRoleAssignmentId = $agentOutputs.ACTIONROLEASSIGNMENTID
                $script:state.actionReaderAssignmentId = $agentOutputs.ACTIONREADERASSIGNMENTID
                $script:state.systemReaderAssignmentId = $agentOutputs.SYSTEMREADERASSIGNMENTID
                $script:state.networkAssignmentId = $agentOutputs.NETWORKASSIGNMENTID
                $script:state.adminAssignmentId = $agentOutputs.ADMINASSIGNMENTID
                $script:state.sreAdministratorRoleDefinitionId = $agentOutputs.SREADMINISTRATORROLEDEFINITIONID
                $script:state.sreSubnetId = $agentOutputs.SRESUBNETID
                $script:state.guestVmId = $agentOutputs.GUESTVMID
                $null = @(Get-GuestBaselineGrantExpectation)
                foreach ($field in @('actionLogReaderAssignmentId', 'actionMonitoringReaderAssignmentId',
                    'actionMonitoringContributorAssignmentId')) {
                    if ($agentOutputs[$field.ToUpperInvariant()] -ine $script:state[$field]) {
                        throw 'Deployed SRE baseline assignment ID does not match the persisted intent; use Down.'
                    }
                }
                $script:state.journal[-1].outcome = 'deployment-succeeded'
                Save-RetailState $script:state $statePath
            }
            $script:state.phase = 'configuring'
            Save-RetailState $script:state $statePath
            Assert-GuestReader
            Assert-GuestExecutionAgent
            $request = @{ action = 'configure'; ownerToken = $script:state.ownerToken; sourceHashes = $sourceHashes }
            $evidence = Invoke-GuestCommand $request -Configure
            $script:state.phase = 'ready'
            Save-RetailState $script:state $statePath
        }
    } else {
        if (-not $group) {
            if ($Operation -ne 'Status') { throw 'Owned fixture absent; use Up.' }
            Get-GuestOutput -GroupExists $false -PowerState 'absent' -Evidence $null
            return
        }
        Assert-GuestReader
        Assert-GuestExecutionAgent
        $inspection = @{ phase = 'LivePermissionsVerified'; ownerToken = $script:state.ownerToken
            vmId = $vmId; agentPrincipalId = $script:state.agentPrincipalId
            permissionModel = $script:state['agentPermissionModel']
            verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
        if ($Operation -eq 'Inspect') {
            $output = Get-GuestOutput -GroupExists $true -PowerState (Get-PowerState) -Evidence $null
            $output | Add-Member -NotePropertyName inspection -NotePropertyValue $inspection -PassThru
            return
        }
        if ($script:state.withMonitoring -and -not $script:state.withSreExecution -and $Operation -in @('Fault', 'Repair')) {
            throw 'Monitor-only diagnostics do not inject faults or repair services; use a fresh isolated SRE incident fixture.'
        }
        if ($Operation -eq 'Command') {
            $null = Wait-GuestNativeRead
            Get-GuestNativeReadSummary
            return
        }
        if ($Operation -eq 'Probe') {
            if ($script:state.pendingCommand -or $script:state.currentFault) {
                throw 'Probe requires no outstanding guest write or fault.'
            }
            $probePath = Join-Path $directory 'guest-native-probe.sh'
            $probe = [ordered]@{ ownerToken = $script:state.ownerToken; vmId = $vmId } | ConvertTo-Json -Compress
            "#!/bin/bash`nset -euo pipefail`nprintf '%s\n' 'RETAILTX_NATIVE_PROBE=$probe'" |
                Set-Content $probePath -Encoding utf8NoBOM
            $result = Invoke-GuestNativeRead -Kind Probe -ScriptPath $probePath
            Assert-GuestNativeReadOutput $result
            $text = ($result.value | ForEach-Object message) -join "`n"
            $match = [regex]::Matches($text, '(?m)^RETAILTX_NATIVE_PROBE=(\{[^\r\n]*\})\r?$')
            if ($match.Count -ne 1) { throw 'Native probe result missing or ambiguous.' }
            $receipt = $match[0].Groups[1].Value | ConvertFrom-Json -AsHashtable
            if ($receipt.ownerToken -cne $script:state.ownerToken -or $receipt.vmId -ine $vmId) {
                throw 'Native probe result belongs to another fixture.'
            }
            $script:state.nativeRead.probeVerifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Save-GuestNativeReadRecord
            @{ phase = 'NativeProbeVerified'; command = (Get-GuestNativeReadSummary) }
            return
        }
        if ($Operation -in @('Monitor', 'Telemetry', 'Connect', 'Arm', 'Incident', 'SkillCheck')) {
            $result = Invoke-GuestMonitorOperation $Operation
            if ($Operation -eq 'Telemetry') { $result.inspection = $inspection }
            $result
            return
        }
        $evidence = Get-GuestStatus
        if ($Operation -ne 'Status') {
            if ($script:state.pendingCommand) { throw 'Unresolved command; writes remain blocked. Use Status or Down.' }
            if ($script:state['failedRecovery'] -and $Operation -cne 'Reset') {
                throw 'A guest-confirmed failed recovery requires explicit exact-run Reset or Down, not repair replay.'
            }
            if ($Operation -ceq 'Reset') { Assert-GuestRecoveryResetSafe $evidence }
            if ($Operation -ceq 'Repair' -and $script:state['recoverySkill']) {
                throw 'Skill-led incident repair is human-approved in SRE, not operator replay. Use settled exact-run Reset or Down.'
            }
            $operatorIdentity = Invoke-Azure @('rest', '--method', 'get', '--url',
                'https://graph.microsoft.com/v1.0/me?$select=id')
            $actor = [guid]::Parse($operatorIdentity.id).ToString()
            $request = @{ action = $Operation.ToLowerInvariant(); ownerToken = $script:state.ownerToken
                sourceHashes = $sourceHashes; actor = $actor }
            if ($Operation -eq 'Fault') {
                if ($script:state.withMonitoring -and -not $Canary) { Assert-GuestMonitorFaultReady }
                if ($script:state.phase -cne 'ready') { throw 'Fault requires healthy, guarded ready state.' }
                $manual = $script:state['faultLifetime'] -ceq 'Manual'
                if ($manual -and $PSBoundParameters.ContainsKey('FaultDurationSeconds')) {
                    throw 'Manual faults have no duration; omit FaultDurationSeconds and explicitly repair/reset/tear down.'
                }
                if (-not $manual -and -not $Canary -and -not $evidence.watchdogProof) { throw '60-second independent watchdog canary must pass first.' }
                $duration = if ($manual) { 0 } elseif ($Canary) { 60 } else { $FaultDurationSeconds }
                $request.runId = [guid]::NewGuid().ToString()
                $request.durationSeconds = $duration
                $request.canary = $Canary.IsPresent
                $request.startBeforeUtc = [DateTimeOffset]::UtcNow.AddSeconds(90).ToString('o')
                $script:state.currentFault = $request.Clone()
                Save-RetailState $script:state $statePath
            } else {
                $expectedRun = if ($evidence.marker) { $evidence.marker.runId } else { [guid]::Empty.ToString() }
                if (($evidence.marker -and (-not $PSBoundParameters.ContainsKey('RunId') -or $RunId.ToString() -cne $expectedRun)) -or
                    ($Operation -eq 'Repair' -and -not $evidence.marker)) { throw 'Repair/reset requires the exact current fault RunId.' }
                $request.runId = $expectedRun
                if ($Operation -eq 'Repair' -and $evidence.marker['faultLifetime'] -ceq 'Manual') {
                    $request.expectedFaultLifetime = 'Manual'
                    $request.expectedActor = $evidence.marker.actor
                }
            }
            $evidence = Invoke-GuestCommand $request
            if ($Operation -ceq 'Reset') { $script:state.Remove('failedRecovery') }
            if ($Operation -eq 'Fault') { $script:state.currentFault.deadlineUtc = $evidence.marker.deadlineUtc }
            $script:state.phase = if ($evidence.marker -and $evidence.marker.phase -cnotin @('recovered', 'cancelled')) { 'fault-active' } else { 'ready' }
            Save-RetailState $script:state $statePath
            if ($Operation -eq 'Reset' -and $script:state.withMonitoring -and $script:state.withSreExecution) { Complete-GuestMonitorReset }
        }
    }
    Get-GuestOutput -GroupExists $true -PowerState 'PowerState/running' -Evidence $evidence
} finally {
    $lease.Dispose()
}
