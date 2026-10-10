#Requires -Version 7.2
<#
.SYNOPSIS
Manage the isolated native Azure VM guest-service transport and watchdog proof.
.DESCRIPTION
Operator-only Action Run Command, not an SRE fixed-action RBAC boundary. Grants
only group-scoped Reader to the retained action identity; never guest write
privilege. Does not change SRE configuration, stop a VM, or process transactions.
Writes durable intent before commands. A timeout is an unknown outcome, not a
failed guest action; use Status for exact readback, or Down for safe disposal.
.PARAMETER Operation
Up, Status, Fault, Repair, Reset, or Down.
Monitor, Telemetry, Connect, Arm and Incident manage optional private monitoring.
.PARAMETER SubscriptionId
Explicit authorized subscription, bound to the retained foundation tenant.
.PARAMETER EnvironmentName
Separate neutral disposable environment, default demo16.
.PARAMETER FoundationEnvironment
Retained ownership manifest used only to validate subscription and tenant.
.PARAMETER RunId
Exact UUID required for Repair, and for Reset when a fault exists.
.PARAMETER FaultDurationSeconds
120-600 seconds for normal faults. Canary always uses 60 seconds.
.PARAMETER Canary
First fault is a 60-second independent deadline recovery canary. Wait and run
Status to verify watchdog recovery before attempting a longer fault.
.PARAMETER WithSreExecution
On Up only, create a separate Review-mode SRE Agent and UAMI in the fixture
resource group, with VM-scoped Run Command permission and isolated VNet.
.PARAMETER WithMonitoring
On Up only, prepare private AMA monitoring. Requires WithSreExecution.
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
    [ValidateSet('Up', 'Status', 'Fault', 'Repair', 'Reset', 'Down', 'Monitor', 'Telemetry', 'Connect', 'Arm', 'Incident')][string]$Operation,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo16',
    [string]$FoundationEnvironment = 'stage0',
    [ValidateRange(120, 600)][int]$FaultDurationSeconds = 300,
    [guid]$RunId,
    [switch]$Canary,
    [switch]$WithSreExecution,
    [switch]$WithMonitoring
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
if ($WithMonitoring -and ($Operation -cne 'Up' -or -not $WithSreExecution)) {
    throw 'WithMonitoring requires Up with WithSreExecution.'
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
        'scripts\guest\GuestMonitor.ps1', 'scripts\guest\query.py',
        'infra\guest-service-monitor.bicep', 'scripts\disk\DiskSre.ps1')) {
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
    if (-not $script:state.ContainsKey('withSreExecution') -and $script:state.schemaVersion -eq 1) {
        $script:state.withSreExecution = $false
    }
    if (-not $script:state.ContainsKey('withMonitoring')) { $script:state.withMonitoring = $false }
    if ($script:state.withMonitoring -isnot [bool] -or
        ($script:state.withMonitoring -and -not $script:state.withSreExecution)) {
        throw 'Invalid monitoring mode or missing isolated execution identity.'
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
    if ($script:state.ContainsKey('readerAssignmentId') -and $script:state.readerAssignmentId -and
        $script:state.readerAssignmentId -notlike "$groupId/providers/Microsoft.Authorization/roleAssignments/*") {
        throw 'Retained fixture Reader assignment is outside the owned resource group.'
    }
    if ($script:state.withSreExecution) {
        if ($script:state.agentId -cne "$groupId/providers/Microsoft.App/agents/sre-retailtx-guest-agent-$EnvironmentName" -or
            $script:state.agentIdentityId -cne "$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-retailtx-guest-agent-$EnvironmentName" -or
            $script:state.retainedAgentId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.App/agents/*" -or
            $script:state.retainedAgentIdentityId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.ManagedIdentity/userAssignedIdentities/*" -or
            $script:state.retainedAgentId -ieq $script:state.agentId -or
            $script:state.retainedAgentIdentityId -ieq $script:state.agentIdentityId) {
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
    $expectedPrincipals = @()
    if ($script:state.ContainsKey('retainedAgentPrincipalId')) { $expectedPrincipals += @($script:state.retainedAgentPrincipalId) }
    if ($expectedPrincipals.Count -eq 0) { $expectedPrincipals = @($script:state.agentPrincipalId) }
    if ($script:state.withSreExecution) { $expectedPrincipals += @($script:state.agentPrincipalId, $script:state.systemPrincipalId) }
    $expectedPrincipals = @($expectedPrincipals | Where-Object { $_ } | Select-Object -Unique)
    foreach ($principalId in $expectedPrincipals) {
        $matches = @($assignments | Where-Object {
            $_.scope -ieq $groupId -and $_.principalId -ieq $principalId -and $_.roleDefinitionId -ieq $expectedRole
        })
        if ($matches.Count -ne 1) { throw 'Exact guest group Reader grant is missing or ambiguous.' }
    }
    foreach ($assignment in $assignments) {
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

    $actionAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--assignee-object-id',
        $script:state.agentPrincipalId, '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
    $readerRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
    $networkRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
    $expectedAction = @(
        @{ scope = $groupId; roleDefinitionId = $readerRole; id = $script:state.actionReaderAssignmentId }
        @{ scope = $vmId; roleDefinitionId = $script:state.actionRoleDefinitionId; id = $script:state.actionRoleAssignmentId }
        @{ scope = $subnetId; roleDefinitionId = $networkRole; id = $script:state.networkAssignmentId }
    )
    $expectedAction += @(Get-GuestMonitorGrantExpectation action $script:state.agentPrincipalId)
    if ($actionAssignments.Count -ne $expectedAction.Count) { throw 'Unknown or missing grant on the disposable action identity.' }
    foreach ($expectedGrant in $expectedAction) {
        $matches = @($actionAssignments | Where-Object {
            $_.scope -ieq $expectedGrant.scope -and $_.roleDefinitionId -ieq $expectedGrant.roleDefinitionId -and
            $_.principalId -ieq $script:state.agentPrincipalId -and
            (-not $expectedGrant.id -or $_.id -ieq $expectedGrant.id)
        })
        if ($matches.Count -ne 1) { throw 'Disposable action identity grant scope/role does not match the exact allow-list.' }
    }

    $systemAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--assignee-object-id',
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

function Assert-GuestExecutionNetwork {
    param([Parameter(Mandatory)][string]$SubnetId)
    $vnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName"
    $natId = "$groupId/providers/Microsoft.Network/natGateways/nat-retailtx-guest-agent-$EnvironmentName"
    $pipId = "$groupId/providers/Microsoft.Network/publicIPAddresses/pip-retailtx-guest-agent-$EnvironmentName-egress"
    $vnet = Invoke-Azure @('network', 'vnet', 'show', '--ids', $vnetId)
    $subnet = Invoke-Azure @('network', 'vnet', 'subnet', 'show', '--ids', $SubnetId)
    $nat = Invoke-Azure @('network', 'nat', 'gateway', 'show', '--ids', $natId)
    $pip = Invoke-Azure @('network', 'public-ip', 'show', '--ids', $pipId)
    if ($vnet.id -ine $vnetId -or $vnet.location -ine $location -or
        $vnet.tags.ownerToken -cne $script:state.ownerToken -or $vnet.tags.profile -cne 'guest-service' -or
        $vnet.tags.environmentId -cne $EnvironmentName -or $vnet.tags.managedBy -cne 'retailtx' -or
        @($vnet.addressSpace.addressPrefixes).Count -ne 1 -or
        $vnet.addressSpace.addressPrefixes[0] -cne '10.90.0.0/24' -or
        (@($vnet.virtualNetworkPeerings).Count -ne 0 -and -not
            ($script:state.ContainsKey('withMonitoring') -and $script:state.withMonitoring)) -or
        $subnet.id -ine $SubnetId -or $subnet.addressPrefix -cne '10.90.0.0/27' -or
        $subnet.defaultOutboundAccess -ne $false -or
        @($subnet.delegations).Count -ne 1 -or
        (Get-GuestSubnetDelegationServiceName -Delegation $subnet.delegations[0]) -cne 'Microsoft.App/environments' -or
        $subnet.natGateway.id -ine $natId -or $subnet['networkSecurityGroup'] -or
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
    if ($script:state.ContainsKey('withMonitoring') -and $script:state.withMonitoring -and
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
        $identityAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--assignee-object-id',
            $principal, '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
        $allowed = @(
            @{ scope = $groupId; roleDefinitionId = $readerRole; id = $script:state.actionReaderAssignmentId }
            @{ scope = $vmId; roleDefinitionId = $script:state.actionRoleDefinitionId; id = $script:state.actionRoleAssignmentId }
            @{ scope = $sreSubnetId; roleDefinitionId = $networkRole; id = $script:state.networkAssignmentId }
        )
        foreach ($assignment in $identityAssignments) {
            $matches = @($allowed | Where-Object {
                $assignment.scope -ieq $_.scope -and $assignment.roleDefinitionId -ieq $_.roleDefinitionId -and
                (-not $_.id -or $assignment.id -ieq $_.id)
            })
            if ($matches.Count -ne 1) { throw 'Unknown or foreign grant on the disposable action identity; refusing teardown.' }
            $knownAssignments += $assignment
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
        $systemAssignments = @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--assignee-object-id',
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
    foreach ($assignment in $assignments) {
        $exactPair = ($assignment.scope -ieq $groupId -and $assignment.roleDefinitionId -ieq $readerRole -and
            $assignment.principalId -iin @($script:state.retainedAgentPrincipalId, $script:state.agentPrincipalId, $script:state.systemPrincipalId)) -or
            ($assignment.scope -ieq $vmId -and $assignment.roleDefinitionId -ieq $script:state.actionRoleDefinitionId -and
                $assignment.principalId -ieq $script:state.agentPrincipalId) -or
            ($assignment.scope -ieq $subnetId -and $assignment.roleDefinitionId -ieq $networkRole -and
                $assignment.principalId -ieq $script:state.agentPrincipalId) -or
            ($assignment.scope -ieq $script:state.agentId -and $assignment.roleDefinitionId -ieq $adminRole -and
                $assignment.principalId -ieq $script:state.adminObjectId)
        if (-not $assignment.id -or -not $exactPair) {
            throw 'Teardown role-assignment inventory escaped the fixture allow-list.'
        }
        $null = Invoke-Azure @('role', 'assignment', 'delete', '--ids', $assignment.id)
    }
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
    do {
        $pending = @()
        foreach ($scope in @($assignments | ForEach-Object scope | Select-Object -Unique)) {
            $live = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $scope,
                '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
            $pending += @($live | Where-Object { $_.id -iin @($assignments | ForEach-Object id) })
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
    }
    if ($script:state.withMonitoring) { Add-GuestMonitorInventory $expected }
    $policyId = "$vmId/extensions/AzurePolicyforLinux"
    $resources = @(Invoke-Azure @('resource', 'list', '--resource-group', $groupName))
    $seen = @{}
    foreach ($resource in $resources) {
        if ($seen.ContainsKey($resource.id)) { throw 'Duplicate teardown inventory ID.' }
        $seen[$resource.id] = $true
        if ($script:state.withMonitoring -and
            $resource.id -ieq "$groupId/providers/Microsoft.Network/networkInterfaces/nic-$suffix-monitor") {
            Assert-GuestMonitorNic $resource
            continue
        }
        if ($resource.id -ieq $policyId) {
            if ($resource.type -ine 'Microsoft.Compute/virtualMachines/extensions') {
                throw 'Unexpected policy child resource type.'
            }
            continue
        }
        if (-not $expected.ContainsKey($resource.id) -or $resource.type -ine $expected[$resource.id] -or
            ($resource.location -ine $location -and -not ($resource.type -ieq 'Microsoft.Network/privateDnsZones' -and $resource.location -ceq 'global')) -or $resource.tags.demo -cne 'retailtx' -or
            $resource.tags.environmentId -cne $EnvironmentName -or $resource.tags.profile -cne 'guest-service' -or
            $resource.tags.managedBy -cne 'retailtx' -or $resource.tags.ownerToken -cne $script:state.ownerToken) {
            throw 'Foreign or unexpected resource in owned group; refusing group deletion.'
        }
    }
    if ($seen.ContainsKey($vmId)) {
        $extensionResponse = Invoke-Azure @('rest', '--method', 'get', '--url', "$vmId/extensions?api-version=2024-11-01")
        $extensions = @($extensionResponse.value)
        if ($extensions.Count -gt $(if ($script:state.withMonitoring) { 2 } else { 1 })) { throw 'Unexpected VM child extensions; refusing group deletion.' }
        if ($seen.ContainsKey($policyId) -and @($extensions | Where-Object id -IEQ $policyId).Count -ne 1) {
            throw 'Policy extension inventory did not resolve to exact child.'
        }
        foreach ($extension in $extensions) {
            if ($script:state.withMonitoring -and $extension.id -ieq "$vmId/extensions/AzureMonitorLinuxAgent") {
                Assert-GuestMonitorExtension $extension
                continue
            }
            if ($extension.id -ine $policyId -or $extension.name -cne 'AzurePolicyforLinux' -or
                $extension.type -ine 'Microsoft.Compute/virtualMachines/extensions' -or
                $extension.location -ine $location -or $extension.properties.publisher -cne 'Microsoft.GuestConfiguration' -or
                $extension.properties.type -cne 'ConfigurationforLinux' -or
                ($extension['tags'] -and $extension.tags.Count -ne 0)) {
                throw 'Only the exact untagged platform AzurePolicyforLinux extension is permitted.'
            }
        }
    } elseif ($seen.ContainsKey($policyId)) {
        throw 'Policy extension has no exact owned parent VM.'
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
        $expected.PrivateMonitor = @{ direction = 'Outbound'; access = 'Allow'; priority = 130; protocol = 'Tcp'
            destinationPortRange = '443'; destinationAddressPrefix = '10.89.0.0/24' }
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
        agentPrincipalId = @{ value = $script:state.retainedAgentPrincipalId }
    }
    if ($script:state.ContainsKey('withMonitoring')) { $parameters.withMonitoring = @{ value = $script:state.withMonitoring } }
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
    if ($evidence.marker) {
        $marker = $evidence.marker
        $null = [guid]::Parse($marker.runId)
        $null = [guid]::Parse($marker.actor)
        $deadline = [DateTimeOffset]::Parse($marker.deadlineUtc)
        $started = [DateTimeOffset]::Parse($marker.startedAtUtc)
        $admission = [DateTimeOffset]::Parse($marker.startBeforeUtc)
        if ($marker.phase -cnotin @('prepared', 'fault-active', 'recovering', 'recovered', 'cancelled') -or
            $marker.canary -isnot [bool] -or
            ($marker.canary -and $marker.durationSeconds -ne 60) -or
            (-not $marker.canary -and ($marker.durationSeconds -lt 120 -or $marker.durationSeconds -gt 600)) -or
            [Math]::Abs(($deadline - $started).TotalSeconds - $marker.durationSeconds) -gt 0.01 -or
            ($marker.phase -cne 'cancelled' -and $started -gt $admission)) {
            throw 'Unbounded or invalid guest marker.'
        }
    }
    return $evidence
}

function Assert-GuestCommandEvidence {
    param([hashtable]$Request, [hashtable]$Evidence)
    if ($Request.action -ceq 'status') { return }
    if (-not $Evidence.watchdogActive -or -not $Evidence.watchdogEnabled) {
        throw 'Successful write requires the independent recovery watchdog.'
    }
    if ($Request.action -ceq 'fault') {
        $marker = $Evidence.marker
        if (-not $marker -or $marker.runId -cne $Request.runId -or $marker.actor -cne $Request.actor -or
            $marker.startBeforeUtc -cne $Request.startBeforeUtc -or $marker.durationSeconds -ne $Request.durationSeconds -or
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
            config = @{ schemaVersion = 1; ownerToken = $script:state.ownerToken; sourceHashes = $script:state.sourceHashes }
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
        throw 'Guest command outcome is unverified. Do not replay writes: use Status for exact readback, or Down. Independent guest watchdog remains the recovery path.'
    }
}

function Get-GuestStatus {
    $request = @{ action = 'status'; ownerToken = $script:state.ownerToken; sourceHashes = $script:state.sourceHashes }
    $evidence = Invoke-GuestCommand $request
    $pending = $script:state.pendingCommand
    if ($pending) {
        $confirmed = switch ($pending.action) {
            'configure' { $evidence.active -and $evidence.healthy -and $evidence.watchdogActive -and $evidence.watchdogEnabled }
            'fault' {
                $evidence.marker -and $evidence.marker.runId -ceq $pending.request.runId -and
                $evidence.marker.actor -ceq $pending.request.actor -and
                $evidence.marker.startBeforeUtc -ceq $pending.request.startBeforeUtc -and
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
        if ($confirmed) {
            $pending.outcome = 'readback-confirmed'
            $pending.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            foreach ($entry in $script:state.journal) {
                if ($entry.ContainsKey('commandId') -and $entry.commandId -ceq $pending.commandId) {
                    $entry.outcome = $pending.outcome
                    $entry.completedAtUtc = $pending.completedAtUtc
                }
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
        elseif ($evidence.active -and $evidence.healthy -and $evidence.watchdogActive -and $evidence.watchdogEnabled) { 'ready' }
        else { 'unhealthy' }
    Save-RetailState $script:state $statePath
    return $evidence
}

function Get-GuestOutput {
    param([bool]$GroupExists, [string]$PowerState, [AllowNull()][hashtable]$Evidence)
    $publicState = $script:state.Clone()
    $publicState.Remove('journal')
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
        Assert-GuestTeardownInventory
        if ($script:state.withMonitoring) { Remove-GuestMonitorAccess }
        Assert-GuestExecutionAssignmentsForTeardown
        Remove-GuestExecutionRoleAssignments
        Remove-GuestExecutionRole
        $script:state.phase = 'deleting'
        Add-GuestJournal @{ action = 'delete'; intentAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); outcome = 'intent' }
        if ($group) { Invoke-GuestGroupDeletion }
        if ($script:state.withMonitoring) { Assert-GuestMonitorEndpointAbsent }
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
        $script:state.phase = 'deleted'
        $script:state.absenceVerifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $script:state.teardownResiduals = @()
        $script:state.journal[-1].outcome = 'absence-verified'
        Save-RetailState $script:state $statePath
        Get-GuestOutput -GroupExists $false -PowerState 'absent' -Evidence $null
        return
    }
    $foundationPath = Join-Path $root ".azure\$FoundationEnvironment\retailtx-state.json"
    $foundation = Get-Content -LiteralPath $foundationPath -Raw | ConvertFrom-Json -AsHashtable
    if ($foundation.schemaVersion -ne 1 -or $foundation.subscriptionId -ine $subscription -or
        $foundation.tenantId -ine $account.tenantId -or $foundation.environmentName -cne $FoundationEnvironment) {
        throw 'Retained foundation and CLI identity do not match explicit subscription/tenant.'
    }
    $binding = Get-RetainedGuestIdentity $foundation
    $sourceHashes = Get-SourceHash
    $artifactHashes = Get-ArtifactHash
    if ($script:state -and $script:state.phase -cne 'deleted') {
        Assert-ExactHash $script:state.sourceHashes $sourceHashes
        Assert-ExactHash $script:state.artifactHashes $artifactHashes
    }
    if (-not $PSCmdlet.ShouldProcess($vmId, "$Operation operator Action Run Command fixture")) { return }
    if ($group) { $null = Get-OwnedVm; Assert-GuestNetwork }
    if ($Operation -eq 'Up') {
        if ($script:state -and $script:state.phase -cne 'deleted') {
            if ([bool]$script:state.withSreExecution -ne $WithSreExecution.IsPresent) {
                throw 'Fixture execution mode is immutable. Use Down before changing WithSreExecution.'
            }
            if ([bool]$script:state.withMonitoring -ne $WithMonitoring.IsPresent) { throw 'Monitoring mode is immutable; use Down first.' }
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
                expiresAt = [DateTimeOffset]::UtcNow.AddHours(4).ToString('o')
                journal = @(); pendingCommand = $null; currentFault = $null; lastEvidence = $null
                withSreExecution = $WithSreExecution.IsPresent
                withMonitoring = $WithMonitoring.IsPresent
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
            if ($WithMonitoring) {
                $script:state.workspaceId = $foundation.outputs.WORKSPACE_ID
                $script:state.workspaceCustomerId = $foundation.outputs.WORKSPACE_CUSTOMER_ID
                $script:state.dceId = $foundation.outputs.DCE_ID
                $script:state.privateLinkScopeId = "$(($foundation.outputs.WORKSPACE_ID -split '/providers/')[0])/providers/Microsoft.Insights/privateLinkScopes/ampls-retailtx-$FoundationEnvironment"
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
        if ($Operation -in @('Monitor', 'Telemetry', 'Connect', 'Arm', 'Incident')) {
            Invoke-GuestMonitorOperation $Operation
            return
        }
        $evidence = Get-GuestStatus
        if ($Operation -ne 'Status') {
            if ($script:state.pendingCommand) { throw 'Unresolved command; writes remain blocked. Use Status or Down.' }
            $operatorIdentity = Invoke-Azure @('rest', '--method', 'get', '--url',
                'https://graph.microsoft.com/v1.0/me?$select=id')
            $actor = [guid]::Parse($operatorIdentity.id).ToString()
            $request = @{ action = $Operation.ToLowerInvariant(); ownerToken = $script:state.ownerToken
                sourceHashes = $sourceHashes; actor = $actor }
            if ($Operation -eq 'Fault') {
                if ($script:state.withMonitoring -and -not $Canary) { Assert-GuestMonitorFaultReady }
                if ($script:state.phase -cne 'ready') { throw 'Fault requires healthy, guarded ready state.' }
                if (-not $Canary -and -not $evidence.watchdogProof) { throw '60-second independent watchdog canary must pass first.' }
                $duration = if ($Canary) { 60 } else { $FaultDurationSeconds }
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
            }
            $evidence = Invoke-GuestCommand $request
            if ($Operation -eq 'Fault') { $script:state.currentFault.deadlineUtc = $evidence.marker.deadlineUtc }
            $script:state.phase = if ($evidence.marker -and $evidence.marker.phase -cnotin @('recovered', 'cancelled')) { 'fault-active' } else { 'ready' }
            Save-RetailState $script:state $statePath
            if ($Operation -eq 'Reset' -and $script:state.withMonitoring) { Complete-GuestMonitorReset }
        }
    }
    Get-GuestOutput -GroupExists $true -PowerState 'PowerState/running' -Evidence $evidence
} finally {
    $lease.Dispose()
}
