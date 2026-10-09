#Requires -Version 7.2
<#
.SYNOPSIS
Manage an isolated Azure VM for the SRE native-action integration gate.
.DESCRIPTION
Reuses only the retained SRE identity, without changing its configuration.
Creates no public IP, peering, application service, or Arc guest command.
The scope-external custom role is explicitly removed before deleting the group.
.PARAMETER Operation
Up, Status, Fault, Reset, or Down. Fault supervises a bounded stop and independently
starts the VM on timeout or error. Keep this process alive until recovery.
.PARAMETER SubscriptionId
Explicit subscription, validated against the CLI tenant and foundation manifest.
.PARAMETER EnvironmentName
Generic name for this disposable proof, distinct from the retained foundation.
.PARAMETER FoundationEnvironment
Existing foundation manifest containing the SRE Agent resource ID.
.PARAMETER FaultDurationSeconds
Maximum supervised stopped interval before operator recovery (60-600 seconds).
.EXAMPLE
.\scripts\Invoke-NativeAction.ps1 Up -SubscriptionId <guid> -EnvironmentName demo02
.OUTPUTS
Non-secret manifest and live power-state evidence.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Up', 'Status', 'Fault', 'Reset', 'Down')]
    [string]$Operation,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo02',
    [string]$FoundationEnvironment = 'stage0',
    [ValidateRange(60, 600)][int]$FaultDurationSeconds = 480
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Stage0.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
Assert-Stage0Name $FoundationEnvironment
if ($EnvironmentName -ceq $FoundationEnvironment) { throw 'The action proof must not reuse the foundation environment.' }
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root ".azure\$EnvironmentName"
$statePath = Join-Path $directory 'native-action-state.json'
$subscription = $SubscriptionId.ToString()
$location = 'swedencentral'
$groupName = "rg-retailtx-action-$EnvironmentName-$location"
$groupId = "/subscriptions/$subscription/resourceGroups/$groupName"
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-retailtx-action-$EnvironmentName"
$script:state = $null

function Invoke-Azure {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $timeout = if ($Operation -in @('Fault', 'Reset')) { 90 } else { 0 }
    Invoke-RetailAzure -SubscriptionId $subscription -Arguments $Arguments -TimeoutSeconds $timeout
}

function Get-OwnedGroup {
    if (-not (Invoke-Azure @('group', 'exists', '--name', $groupName))) { return $null }
    $group = Invoke-Azure @('group', 'show', '--name', $groupName)
    if (-not $script:state -or $group.id -ine $groupId -or $group.location -ine $location -or
        $group.tags.demo -cne 'retailtx' -or $group.tags.environmentId -cne $EnvironmentName -or
        $group.tags.profile -cne 'native-action' -or $group.tags.managedBy -cne 'retailtx' -or
        $group.tags.ownerToken -cne $script:state.ownerToken) {
        throw 'Action group ownership mismatch; refusing adoption or mutation.'
    }
    return $group
}

function Get-OwnedRole {
    if (-not $script:state) { return $null }
    $roles = @(Invoke-Azure @('role', 'definition', 'list', '--name', $script:state.roleDefinitionName))
    if ($roles.Count -eq 0) { return $null }
    $role = $roles[0]
    if ($roles.Count -ne 1 -or $role.id -ine $script:state.roleDefinitionId -or
        $role.roleType -cne 'CustomRole' -or
        $role.description -cne "RetailTx native action proof; ownerToken=$($script:state.ownerToken)" -or
        @($role.assignableScopes).Count -ne 1 -or $role.assignableScopes[0] -ine $groupId -or
        @($role.permissions).Count -ne 1 -or @($role.permissions[0].actions).Count -ne 1 -or
        $role.permissions[0].actions[0] -cne 'Microsoft.Compute/virtualMachines/start/action' -or
        @($role.permissions[0].notActions).Count -ne 0 -or
        @($role.permissions[0].dataActions).Count -ne 0 -or
        @($role.permissions[0].notDataActions).Count -ne 0) {
        throw 'External custom role ownership or permission boundary mismatch.'
    }
    return $role
}

function Get-OwnedVm {
    param([switch]$AllowAbsent)
    if (-not (Get-OwnedGroup)) {
        if ($AllowAbsent) { return $null }
        throw 'The owned action group does not exist.'
    }
    $vms = @(Invoke-Azure @('vm', 'list', '--resource-group', $groupName) | Where-Object id -IEQ $vmId)
    if ($vms.Count -eq 0 -and $AllowAbsent) { return $null }
    if ($vms.Count -ne 1) { throw 'The exact owned VM was not found.' }
    $vm = $vms[0]
    if ($vm.id -ine $vmId -or $vm.tags.ownerToken -cne $script:state.ownerToken -or
        $vm.tags.profile -cne 'native-action') { throw 'Action VM ownership mismatch.' }
    return $vm
}

function Get-PowerState {
    $view = Invoke-Azure @('vm', 'get-instance-view', '--ids', $vmId)
    $power = @($view.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' })
    if ($power.Count -ne 1) { throw 'No unambiguous live VM power state.' }
    return $power[0].code
}

function Restore-OwnedVm {
    param([switch]$ForceStart)
    $null = Get-OwnedVm
    $powerState = $null
    try { $powerState = Get-PowerState }
    catch [TimeoutException], [System.Management.Automation.RuntimeException] {
        Write-Warning "Power-state read failed; attempting an ownership-validated idempotent start. $($_.Exception.Message)"
    }
    $operatorRecovery = $ForceStart -or $powerState -cne 'PowerState/running'
    if ($operatorRecovery) { $null = Invoke-Azure @('vm', 'start', '--ids', $vmId) }
    if ((Get-PowerState) -cne 'PowerState/running') {
        throw 'Independent operator recovery failed; after this guard releases its lock, run Reset or Down.'
    }
    return $operatorRecovery
}

function Complete-FaultRecovery {
    param([switch]$StopConfirmed)
    $script:state.phase = 'recovery-required'
    $script:state.stopConfirmed = $StopConfirmed.IsPresent
    Save-RetailState $script:state $statePath
    $operatorRecovery = Restore-OwnedVm -ForceStart:(-not $StopConfirmed)
    $script:state.operatorRecovery = $operatorRecovery
    Save-RetailState $script:state $statePath
    if (-not $StopConfirmed) {
        throw 'Stop completion is unconfirmed. An idempotent start was attempted, but a delayed stop may still occur. The fixture remains recovery-required; use Down and redeploy before another proof.'
    }
    $script:state.phase = 'ready'
    $script:state.faultEndedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Save-RetailState $script:state $statePath
    return $operatorRecovery
}

function Reset-DeletedActionState {
    param([hashtable]$State, [object]$Group, [object]$Role)
    if ($State.phase -cne 'deleted') { return }
    if ($Group -or $Role) { throw 'Deleted manifest still has live resources; refusing recreation.' }
    $State.expiresAt = [DateTimeOffset]::UtcNow.AddHours(4).ToString('o')
    foreach ($key in @('faultStartedAt', 'faultDeadline', 'faultEndedAt', 'operatorRecovery', 'stopConfirmed')) {
        $State.Remove($key)
    }
}

function Remove-OwnedActionResources {
    param([object]$Group, [object]$Role)
    if ($Role) {
        $assignments = @(Invoke-Azure @('role', 'assignment', 'list', '--role', $script:state.roleDefinitionId, '--all'))
        foreach ($assignment in $assignments) {
            if ($assignment.scope -ine $vmId -or $assignment.principalId -ine $script:state.agentPrincipalId) {
                throw 'Unexpected assignment of the owned custom role; refusing cleanup.'
            }
        }
        foreach ($assignment in $assignments) {
            $null = Invoke-Azure @('role', 'assignment', 'delete', '--ids', $assignment.id)
        }
        $null = Invoke-Azure @('role', 'definition', 'delete', '--name', $script:state.roleDefinitionName)
    }
    if ($Group) { $null = Invoke-Azure @('group', 'delete', '--name', $groupName, '--yes') }
    if ((Get-OwnedGroup) -or (Get-OwnedRole)) { throw 'Action proof teardown left owned resources.' }
}

$account = Invoke-Azure @('account', 'show')
$foundationPath = Join-Path $root ".azure\$FoundationEnvironment\retailtx-state.json"
# Teardown deliberately does not require a healthy/existing SRE Agent.
$null = New-Item -ItemType Directory -Path $directory -Force
$lease = [IO.File]::Open((Join-Path $directory 'native-action.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    if (Test-Path -LiteralPath $statePath) {
        $script:state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        if ($script:state.schemaVersion -ne 1 -or $script:state.profile -cne 'native-action' -or
            $script:state.subscriptionId -ine $subscription -or $script:state.tenantId -ine $account.tenantId -or
            $script:state.environmentName -cne $EnvironmentName -or $script:state.groupId -ine $groupId -or
            $script:state.vmId -ine $vmId -or $script:state.location -cne $location) {
            throw 'Action manifest does not match the explicit environment.'
        }
        $null = [guid]::Parse($script:state.ownerToken)
        $roleName = [guid]::Parse($script:state.roleDefinitionName).ToString()
        if ($script:state.roleDefinitionId -ine "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$roleName") {
            throw 'Action role ID is outside the manifest boundary.'
        }
    }
    $group = Get-OwnedGroup
    $role = Get-OwnedRole
    if ($Operation -ne 'Up' -and -not $script:state) { throw 'No action proof manifest exists.' }
    if ($Operation -eq 'Status') {
        [pscustomobject]@{ state = $script:state; groupExists = [bool]$group; roleExists = [bool]$role
            powerState = $(if ($group) { $null = Get-OwnedVm; Get-PowerState } else { 'absent' }) }
        return
    }
    if (-not $PSCmdlet.ShouldProcess($groupId, $Operation)) { return }
    if ($Operation -in @('Up', 'Fault') -and $script:state -and
        $script:state.phase -ceq 'recovery-required') {
        throw 'A prior recovery is unresolved. Use Down and redeploy before another proof.'
    }
    if ($Operation -eq 'Up') {
        $null = Get-OwnedVm -AllowAbsent
        $foundation = Get-Content -LiteralPath $foundationPath -Raw | ConvertFrom-Json -AsHashtable
        if ($foundation.subscriptionId -ine $subscription -or $foundation.tenantId -ine $account.tenantId) {
            throw 'Foundation subscription/tenant mismatch.'
        }
        $agentId = $foundation.outputs.SRE_AGENT_ID
        if ($agentId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.App/agents/*") {
            throw 'Invalid retained SRE Agent ID.'
        }
        $agent = Invoke-Azure @('resource', 'show', '--ids', $agentId, '--api-version', '2026-01-01')
        if ($agent.properties.actionConfiguration.mode -cne 'Review') { throw 'SRE must remain in Review mode.' }
        $identityId = $agent.properties.actionConfiguration.identity
        $identity = Invoke-Azure @('identity', 'show', '--ids', $identityId)
        if ($script:state -and ($script:state.agentId -ine $agentId -or
                $script:state.agentPrincipalId -ine $identity.principalId)) {
            throw 'The proof manifest is bound to a different SRE identity.'
        }
        if (-not $script:state) {
            $roleName = [guid]::NewGuid().ToString()
            $script:state = @{
                schemaVersion = 1; profile = 'native-action'; subscriptionId = $subscription
                tenantId = $account.tenantId; environmentName = $EnvironmentName; location = $location
                ownerToken = [guid]::NewGuid().ToString(); groupId = $groupId; vmId = $vmId
                roleDefinitionName = $roleName
                roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$roleName"
                agentId = $agentId; agentPrincipalId = $identity.principalId; agentIdentityId = $identityId
                agentEndpoint = $agent.properties.agentEndpoint; phase = 'created'; outputs = @{}
                expiresAt = [DateTimeOffset]::UtcNow.AddHours(4).ToString('o')
            }
            Save-RetailState $script:state $statePath
        }
        Reset-DeletedActionState $script:state $group $role
        $script:state.agentClientId = $identity.clientId
        $script:state.workspaceCustomerId = $foundation.outputs.WORKSPACE_CUSTOMER_ID
        $script:state.arcMachineId = "/subscriptions/$subscription/resourceGroups/$($foundation.resourceGroupName)/providers/Microsoft.HybridCompute/machines/$($foundation.outputs.ARC_MACHINE_NAME)"
        Save-RetailState $script:state $statePath
        if (-not $script:state.ContainsKey('publicKey')) {
            $keyPath = Join-Path $directory 'native-action-ephemeral-key'
            if (Test-Path -LiteralPath $keyPath) { throw 'An uncleaned ephemeral key exists; refusing overwrite.' }
            try {
                & ssh-keygen -q -t ed25519 -N '' -C 'retailtx-native-action' -f $keyPath
                if ($LASTEXITCODE -ne 0) { throw 'Ephemeral SSH public key generation failed.' }
                $script:state.publicKey = (Get-Content -LiteralPath "$keyPath.pub" -Raw).Trim()
                Save-RetailState $script:state $statePath
            } finally {
                foreach ($path in @($keyPath, "$keyPath.pub")) {
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                }
            }
        }
        $parameters = @{
            environmentName = @{ value = $EnvironmentName }; location = @{ value = $location }
            ownerToken = @{ value = $script:state.ownerToken }; expiresAt = @{ value = $script:state.expiresAt }
            roleDefinitionName = @{ value = $script:state.roleDefinitionName }
            agentPrincipalId = @{ value = $script:state.agentPrincipalId }
            adminSshPublicKey = @{ value = $script:state.publicKey }
        }
        $parameterPath = Join-Path $directory 'native-action.parameters.json'
        @{ parameters = $parameters } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameterPath
        $script:state.phase = 'provisioning'
        Save-RetailState $script:state $statePath
        $deployment = Invoke-Azure @('deployment', 'sub', 'create', '--name', "retailtx-action-$EnvironmentName",
            '--location', $location, '--template-file', (Join-Path $root 'infra\native-action.bicep'),
            '--parameters', "@$parameterPath")
        $script:state.outputs = ConvertFrom-RetailDeploymentOutputs $deployment.properties.outputs
        Save-RetailState $script:state $statePath
        $null = Get-OwnedGroup
        $null = Get-OwnedRole
        $null = Get-OwnedVm
        if ((Get-PowerState) -cne 'PowerState/running') { throw 'New action target is not running.' }
        $script:state.phase = 'ready'
        Save-RetailState $script:state $statePath
        $script:state
    } elseif ($Operation -eq 'Fault') {
        $null = Get-OwnedVm
        if ((Get-PowerState) -cne 'PowerState/running') { throw 'Fault requires a running owned VM.' }
        $script:state.faultStartedAt = [DateTimeOffset]::UtcNow.ToString('o')
        $script:state.faultDeadline = [DateTimeOffset]::UtcNow.AddSeconds($FaultDurationSeconds).ToString('o')
        $script:state.faultEndedAt = $null
        $script:state.operatorRecovery = $null
        $script:state.stopConfirmed = $false
        $script:state.phase = 'fault-starting'
        Save-RetailState $script:state $statePath
        $operatorRecovery = $false
        $stopConfirmed = $false
        try {
            $null = Invoke-Azure @('vm', 'stop', '--ids', $vmId)
            $stopConfirmed = $true
            $script:state.stopConfirmed = $true
            if ((Get-PowerState) -cne 'PowerState/stopped') { throw 'Fault did not stop the owned VM.' }
            $script:state.phase = 'fault-active'
            Save-RetailState $script:state $statePath
            Write-Output 'Owned VM stopped. Independent operator recovery guard is active.'
            while ([DateTimeOffset]::UtcNow -lt [DateTimeOffset]$script:state.faultDeadline) {
                Start-Sleep -Seconds 10
                if ((Get-PowerState) -ceq 'PowerState/running') { break }
            }
        } finally {
            $operatorRecovery = Complete-FaultRecovery -StopConfirmed:$stopConfirmed
        }
        [pscustomobject]@{ powerState = 'PowerState/running'; operatorRecovery = $operatorRecovery
            faultStartedAt = $script:state.faultStartedAt; faultEndedAt = $script:state.faultEndedAt }
    } elseif ($Operation -eq 'Reset') {
        $null = Restore-OwnedVm -ForceStart
        if ($script:state.ContainsKey('stopConfirmed') -and -not $script:state.stopConfirmed) {
            $script:state.phase = 'recovery-required'
            $script:state.operatorRecovery = $true
            Save-RetailState $script:state $statePath
            throw 'VM start completed, but the prior stop outcome is unresolved. Use Down and redeploy; no ready state is claimed.'
        }
        $script:state.phase = 'ready'
        $script:state.operatorRecovery = $true
        $script:state.faultEndedAt = [DateTimeOffset]::UtcNow.ToString('o')
        Save-RetailState $script:state $statePath
        [pscustomobject]@{ recoveryActor = 'operator'; powerState = 'PowerState/running'; vmId = $vmId }
    } elseif ($Operation -eq 'Down') {
        $script:state.phase = 'deleting'
        Save-RetailState $script:state $statePath
        Remove-OwnedActionResources $group $role
        $script:state.phase = 'deleted'
        $script:state.outputs = @{}
        Save-RetailState $script:state $statePath
        [pscustomobject]@{ phase = 'deleted'; groupId = $groupId; customRoleRemoved = $true }
    }
} finally { $lease.Dispose() }
