#Requires -Version 7.2
<#
.SYNOPSIS
Provision and inspect a private Service Bus probe fixture; fail closed on recovery.
.DESCRIPTION
Up creates an isolated Premium Service Bus namespace, dedicated queue, private
endpoint/DNS zone and queue-scoped probe data roles. Doctor verifies the saved
fixture and reports the native SRE action-enforcement gate. Arm, Fault, Recover,
and Reset are blocked until a verified pre-invocation gate can constrain the
exact queue/status/fault-run action. Down deletes only the exact owned scenario
resource group. The shared Stage 0 SRE configuration is never changed.
.PARAMETER Operation
Lifecycle operation to run.
.PARAMETER SubscriptionId
Explicit Azure subscription for every CLI request.
.PARAMETER EnvironmentName
Generic ID for the isolated scenario and local ownership manifest.
.PARAMETER FoundationEnvironment
Existing Stage 0 environment whose private VNet/endpoint subnet are linked.
.PARAMETER ProbePrincipalId
System-assigned managed identity principal of the private Python sender/receiver host.
.EXAMPLE
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Up -SubscriptionId <guid> -EnvironmentName demo01 -ProbePrincipalId <guid>
.EXAMPLE
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Doctor -SubscriptionId <guid> -EnvironmentName demo01
.EXAMPLE
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Down -SubscriptionId <guid> -EnvironmentName demo01
.OUTPUTS
Structured fixture lifecycle and readiness results.
.NOTES
No operation configures or mutates the SRE Agent. Arm and fault/recovery
operations deliberately fail closed until the product safety gate is verified.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Up', 'Doctor', 'Arm', 'Fault', 'Incident', 'Recover', 'Reset', 'Down')]
    [string]$Operation,
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9]{2,11}$')]
    [string]$EnvironmentName,
    [ValidatePattern('^[a-z][a-z0-9]{2,11}$')]
    [string]$FoundationEnvironment = 'stage0',
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ProbePrincipalId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
Assert-RetailEnvironmentName $FoundationEnvironment

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $repositoryRoot ".azure\$EnvironmentName"
$statePath = Join-Path $directory 'servicebus-scenario-state.json'
$lockPath = Join-Path $directory 'servicebus-scenario.lock'
$groupName = "rg-retailtx-servicebus-$EnvironmentName-swedencentral"
$foundationGroupName = "rg-retailtx-$FoundationEnvironment-swedencentral"
$subscription = $SubscriptionId.ToString()
$scenarioState = $null
$sharedDnsLock = $null

function Invoke-Azure {
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 0)
    Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Save-State {
    $scenarioState | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath "$statePath.tmp" -Encoding utf8NoBOM
    Move-Item -LiteralPath "$statePath.tmp" -Destination $statePath -Force
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'No Service Bus ownership manifest exists. Refusing to adopt a resource group.'
    }
    $script:scenarioState = Get-Content -LiteralPath $statePath -Raw |
        ConvertFrom-Json -AsHashtable
    if ($scenarioState.schemaVersion -ne 1 -or $scenarioState.profile -cne 'servicebus-scenario' -or
        $scenarioState.subscriptionId -ine $subscription -or
        $scenarioState.environmentName -cne $EnvironmentName -or
        $scenarioState.foundationEnvironment -cne $FoundationEnvironment -or
        $scenarioState.groupName -cne $groupName -or
        $scenarioState.groupId -ine "/subscriptions/$subscription/resourceGroups/$groupName") {
        throw 'The Service Bus manifest does not match the requested subscription or environment.'
    }
    $null = [guid]::Parse($scenarioState.ownerToken)
    $null = [guid]::Parse($scenarioState.tenantId)
}

function Get-VerifiedFoundation {
    $foundationPath = Join-Path $repositoryRoot ".azure\$FoundationEnvironment\retailtx-state.json"
    if (-not (Test-Path -LiteralPath $foundationPath -PathType Leaf)) {
        throw 'The retained Stage 0 manifest is missing.'
    }
    $foundation = Get-Content -LiteralPath $foundationPath -Raw | ConvertFrom-Json -AsHashtable
    $account = Invoke-Azure @('account', 'show')
    if ($account.id -ine $subscription -or $account.tenantId -ine $foundation.tenantId -or
        $foundation.subscriptionId -ine $subscription -or
        $foundation.environmentName -cne $FoundationEnvironment -or
        $foundation.outputs.SRE_AGENT_ID -notmatch (
            '^/subscriptions/' + [regex]::Escape($subscription) +
            '/resourceGroups/' + [regex]::Escape($foundationGroupName) +
            '/providers/Microsoft\.App/agents/[^/]+$'
        ) -or
        -not $foundation.outputs.WORKSPACE_ID -or -not $foundation.outputs.DCE_ID) {
        throw 'The retained Stage 0 subscription, tenant, SRE Agent resource ID, or required outputs do not match.'
    }
    $group = Invoke-Azure @('group', 'show', '--name', $foundationGroupName)
    if ($group.id -ine "/subscriptions/$subscription/resourceGroups/$foundationGroupName" -or
        $group.location -ine 'swedencentral' -or $group.tags.demo -cne 'retailtx' -or
        $group.tags.environmentId -cne $FoundationEnvironment -or
        $group.tags.ownerToken -cne $foundation.ownerToken -or
        $group.tags.managedBy -cne 'retailtx-stage0') {
        throw 'The retained Stage 0 resource group failed its ownership check.'
    }
    $vnetName = "vnet-retailtx-$FoundationEnvironment"
    $vnet = Invoke-Azure @('network', 'vnet', 'show', '--resource-group', $foundationGroupName, '--name', $vnetName)
    $expectedVnet = "$($group.id)/providers/Microsoft.Network/virtualNetworks/$vnetName"
    if ($vnet.id -ine $expectedVnet -or $vnet.tags.ownerToken -cne $foundation.ownerToken) {
        throw 'The retained Stage 0 VNet failed its ownership check.'
    }
    $endpointSubnet = @($vnet.subnets | Where-Object { $_.name -ceq 'private-endpoints' })
    if ($endpointSubnet.Count -ne 1 -or $endpointSubnet[0].addressPrefix -cne '10.84.1.0/24') {
        throw 'The expected private endpoint subnet is missing or has drifted.'
    }
    return @{
        state = $foundation
        group = $group
        virtualNetworkId = $vnet.id
        privateEndpointSubnetId = $endpointSubnet[0].id
        tenantId = $foundation.tenantId
    }
}

function Get-OwnedScenarioGroup {
    $exists = Invoke-Azure @('group', 'exists', '--name', $groupName)
    if (-not $exists) { return $null }
    $group = Invoke-Azure @('group', 'show', '--name', $groupName)
    if (-not $scenarioState -or
        $group.id -ine $scenarioState.groupId -or
        $group.location -ine 'swedencentral' -or
        $group.tags.demo -cne 'retailtx' -or
        $group.tags.environmentId -cne $EnvironmentName -or
        $group.tags.ownerToken -cne $scenarioState.ownerToken -or
        $group.tags.profile -cne 'servicebus' -or
        $group.tags.managedBy -cne 'retailtx') {
        throw 'Service Bus resource group ownership validation failed; no adoption or mutation is permitted.'
    }
    return $group
}

function Assert-ServiceBusPrivateDnsOwnership {
    $zones = @(Invoke-Azure @(
        'network', 'private-dns', 'zone', 'list', '--query',
        "[?name=='privatelink.servicebus.windows.net']"
    ))
    if ($zones.Count -gt 1) {
        throw 'Multiple Service Bus private DNS zones exist. Refusing to choose or mutate one.'
    }
    if ($zones.Count -eq 1) {
        $zone = $zones[0]
        $expectedZoneId = "$($scenarioState.groupId)/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net"
        if ($zone.id -ine $expectedZoneId -or
            $zone.resourceGroup -ine $groupName -or
            $zone.tags.demo -cne 'retailtx' -or
            $zone.tags.environmentId -cne $EnvironmentName -or
            $zone.tags.profile -cne 'servicebus' -or
            $zone.tags.ownerToken -cne $scenarioState.ownerToken -or
            $zone.tags.managedBy -cne 'retailtx') {
            throw 'The Service Bus private DNS zone ID or ownership tags do not match this manifest. Refusing to adopt or mutate it.'
        }
    }
}

function Get-ServiceBusFoundationDnsLockPath {
    param([Parameter(Mandatory)][string]$VirtualNetworkId)
    if ($VirtualNetworkId -cnotmatch (
        '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+$'
    )) {
        throw 'Cannot derive the shared DNS lock from an invalid foundation VNet resource ID.'
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($VirtualNetworkId.ToLowerInvariant())
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $lockDirectory = Join-Path $repositoryRoot '.azure\shared-locks'
    $null = New-Item -ItemType Directory -Path $lockDirectory -Force
    return Join-Path $lockDirectory "servicebus-dns-$hash.lock"
}

function Enter-ServiceBusFoundationDnsLock {
    param([Parameter(Mandatory)][string]$VirtualNetworkId)
    $path = Get-ServiceBusFoundationDnsLockPath -VirtualNetworkId $VirtualNetworkId
    try {
        return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw 'Another Service Bus lifecycle operation holds the shared foundation-VNet DNS lock. Retry after it finishes.'
    }
}

function Get-ServiceBusActionGate {
    [pscustomobject]@{
        scenario = 'private-servicebus-send-recovery'
        environmentId = $EnvironmentName
        readiness = 'Blocked'
        autonomousResponsePlan = 'NotConfiguredByThisScript'
        queueStatusMutation = 'NotAuthorized'
        preInvocationEnforcement = $false
        blockers = @(
            'A verified pre-invocation tool hook or equivalent native enforcement API is not available in the checked-in implementation.'
            'Global SRE tool policies do not constrain queue/status arguments; a broad queue write grant is not an acceptable substitute.'
            'PostToolUse hooks run after a tool call and cannot prevent an unsafe queue mutation.'
            'No automatic incident trigger is configured by these files; the metric alert has no action group.'
        )
    }
}

function Get-ServiceBusDoctorResult {
    param(
        [Parameter()][hashtable]$State,
        [Parameter()][object]$Group,
        [Parameter(Mandatory)][object]$ActionGate
    )
    [pscustomobject]@{
        scenario = 'private-servicebus-send-recovery'
        foundation = 'Verified'
        fixture = if ($Group) { 'ManifestAndGroupVerified' } else { 'NotDeployed' }
        savedManifestStatus = if ($State) { $State.status } else { $null }
        deploymentHealth = 'NotChecked'
        queueHealth = 'NotChecked'
        ready = $false
        queueId = if ($State -and $State.outputs) { $State.outputs.QUEUEID } else { $null }
        actionGate = $ActionGate
    }
}

function Assert-ServiceBusActionGate {
    $gate = Get-ServiceBusActionGate
    if (-not $gate.preInvocationEnforcement) {
        throw "Blocked at Arm: no verified pre-invocation policy can constrain the action to the exact scenario queue, Active status, and fault run. No fault was injected. Use -Operation Doctor for the gate report."
    }
}

function Invoke-ServiceBusUp {
    if (-not $ProbePrincipalId) {
        throw 'Up requires the system-assigned managed identity principal ID of the private probe host.'
    }
    $principalId = [guid]::Parse($ProbePrincipalId).ToString()
    $initialFoundation = Get-VerifiedFoundation
    $script:sharedDnsLock = Enter-ServiceBusFoundationDnsLock -VirtualNetworkId $initialFoundation.virtualNetworkId
    $foundation = Get-VerifiedFoundation
    if ($foundation.virtualNetworkId -ine $initialFoundation.virtualNetworkId) {
        throw 'The retained Stage 0 VNet changed while acquiring its shared DNS lock.'
    }
    Assert-ServiceBusPrivateDnsOwnership
    if ($scenarioState) {
        if ($scenarioState.tenantId -ine $foundation.tenantId -or
            $scenarioState.probePrincipalId -ine $principalId -or
            ($scenarioState.foundationVirtualNetworkId -and
             $scenarioState.foundationVirtualNetworkId -ine $foundation.virtualNetworkId)) {
            throw 'Existing Service Bus manifest tenant or probe identity changed.'
        }
        $scenarioState.foundationVirtualNetworkId = $foundation.virtualNetworkId
    } else {
        if (Invoke-Azure @('group', 'exists', '--name', $groupName)) {
            throw 'A resource group exists without this local manifest. Refusing to adopt it.'
        }
        $script:scenarioState = @{
            schemaVersion = 1
            profile = 'servicebus-scenario'
            subscriptionId = $subscription
            tenantId = $foundation.tenantId
            environmentName = $EnvironmentName
            foundationEnvironment = $FoundationEnvironment
            foundationVirtualNetworkId = $foundation.virtualNetworkId
            groupName = $groupName
            groupId = "/subscriptions/$subscription/resourceGroups/$groupName"
            ownerToken = [guid]::NewGuid().ToString()
            probePrincipalId = $principalId
            createdAt = [DateTimeOffset]::UtcNow.ToString('o')
            expiresAt = [DateTimeOffset]::UtcNow.AddHours(24).ToString('o')
            status = 'Provisioning'
        }
    }

    if (-not $PSCmdlet.ShouldProcess($scenarioState.groupId, 'Create private Service Bus probe fixture')) {
        return
    }
    Save-State
    $group = Get-OwnedScenarioGroup
    if (-not $group) {
        $null = Invoke-Azure @(
            'group', 'create', '--name', $groupName, '--location', 'swedencentral', '--tags',
            'demo=retailtx', "environmentId=$EnvironmentName", 'profile=servicebus',
            "ownerToken=$($scenarioState.ownerToken)", 'managedBy=retailtx',
            "expiresAt=$($scenarioState.expiresAt)"
        ) -TimeoutSeconds 120
        $group = Get-OwnedScenarioGroup
    }
    if (-not $group) { throw 'The owned scenario group was not created.' }

    $template = Join-Path $repositoryRoot 'infra\servicebus-scenario.bicep'
    $deployment = Invoke-Azure @(
        'deployment', 'group', 'create', '--resource-group', $groupName,
        '--name', 'servicebus-scenario', '--template-file', $template, '--parameters',
        "environmentName=$EnvironmentName", "ownerToken=$($scenarioState.ownerToken)",
        "expiresAt=$($scenarioState.expiresAt)",
        "privateEndpointSubnetId=$($foundation.privateEndpointSubnetId)",
        "virtualNetworkId=$($foundation.virtualNetworkId)",
        "probeSystemIdentityPrincipalId=$principalId",
        'location=swedencentral'
    ) -TimeoutSeconds 1800
    if ($deployment.properties.provisioningState -cne 'Succeeded') {
        throw 'Service Bus deployment did not complete successfully; retained manifest is required for safe reconciliation or Down.'
    }
    $outputs = ConvertFrom-RetailDeploymentOutputs $deployment.properties.outputs
    $expectedQueueId = "$($scenarioState.groupId)/providers/Microsoft.ServiceBus/namespaces/$($outputs.NAMESPACENAME)/queues/$($outputs.QUEUENAME)"
    if ($outputs.QUEUEID -ine $expectedQueueId -or
        $outputs.PROBESENDERROLEASSIGNMENTID -notlike "$expectedQueueId/providers/Microsoft.Authorization/roleAssignments/*" -or
        $outputs.PROBERECEIVERROLEASSIGNMENTID -notlike "$expectedQueueId/providers/Microsoft.Authorization/roleAssignments/*") {
        throw 'Deployment outputs do not match the expected isolated namespace, queue, and queue-scoped probe roles.'
    }
    $scenarioState.outputs = $outputs
    $scenarioState.status = 'Ready'
    $scenarioState.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Save-State
    return [pscustomobject]@{
        status = $scenarioState.status
        resourceGroupId = $scenarioState.groupId
        namespaceName = $outputs.NAMESPACENAME
        queueName = $outputs.QUEUENAME
        queueId = $outputs.QUEUEID
        alertId = $outputs.SENDFAILUREALERTID
        readiness = (Get-ServiceBusActionGate).readiness
    }
}

function Invoke-ServiceBusDown {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        if (Invoke-Azure @('group', 'exists', '--name', $groupName)) {
            throw 'The scenario group exists without its ownership manifest. Refusing deletion.'
        }
        return [pscustomobject]@{ status = 'Absent'; residuals = @() }
    }
    Read-State
    $account = Invoke-Azure @('account', 'show')
    if ($account.id -ine $subscription -or $account.tenantId -ine $scenarioState.tenantId) {
        throw 'Down target subscription or tenant does not match the ownership manifest.'
    }
    $expectedFoundationVnetId = "/subscriptions/$subscription/resourceGroups/$foundationGroupName/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-$FoundationEnvironment"
    if ($scenarioState.foundationVirtualNetworkId -and
        $scenarioState.foundationVirtualNetworkId -ine $expectedFoundationVnetId) {
        throw 'The manifest foundation VNet ID does not match the selected retained environment.'
    }
    $script:sharedDnsLock = Enter-ServiceBusFoundationDnsLock -VirtualNetworkId $expectedFoundationVnetId
    Assert-ServiceBusPrivateDnsOwnership
    $group = Get-OwnedScenarioGroup
    if (-not $PSCmdlet.ShouldProcess($scenarioState.groupId, 'Delete exact owned Service Bus scenario resource group')) {
        return
    }
    if ($group) {
        $null = Invoke-Azure @('group', 'delete', '--name', $groupName, '--yes') -TimeoutSeconds 1800
        if (Invoke-Azure @('group', 'exists', '--name', $groupName)) {
            throw 'Owned resource group deletion has not completed; keep the manifest and retry Down.'
        }
    }
    $archiveDirectory = Join-Path $repositoryRoot '.azure\archive'
    New-Item -ItemType Directory -Path $archiveDirectory -Force | Out-Null
    $archivePath = Join-Path $archiveDirectory "servicebus-$EnvironmentName-$($scenarioState.ownerToken).json"
    Move-Item -LiteralPath $statePath -Destination $archivePath -ErrorAction Stop
    return [pscustomobject]@{ status = 'Deleted'; residuals = @(); archive = $archivePath }
}

if ($Operation -in @('Arm', 'Fault', 'Incident', 'Recover', 'Reset')) {
    Assert-ServiceBusActionGate
}
if ($Operation -in @('Up', 'Down') -and
    -not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$lockStream = $null
try {
    if ($Operation -in @('Up', 'Down')) {
        $lockStream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Read-State
    } elseif ($Operation -in @('Doctor', 'Down')) {
        $scenarioState = $null
    }

    switch ($Operation) {
        'Up' {
            Invoke-ServiceBusUp
        }
        'Doctor' {
            $null = Get-VerifiedFoundation
            $group = if ($scenarioState) { Get-OwnedScenarioGroup } else { $null }
            Get-ServiceBusDoctorResult -State $scenarioState -Group $group -ActionGate (Get-ServiceBusActionGate)
        }
        { $_ -in @('Arm', 'Fault', 'Incident', 'Recover', 'Reset') } {
            Assert-ServiceBusActionGate
        }
        'Down' {
            Invoke-ServiceBusDown
        }
    }
} finally {
    if ($sharedDnsLock) { $sharedDnsLock.Dispose() }
    if ($lockStream) { $lockStream.Dispose() }
}
