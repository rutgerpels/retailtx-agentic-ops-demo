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
    [ValidateSet('Up', 'Status', 'Fault', 'Repair', 'Reset', 'Down')][string]$Operation,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo16',
    [string]$FoundationEnvironment = 'stage0',
    [ValidateRange(120, 600)][int]$FaultDurationSeconds = 300,
    [guid]$RunId,
    [switch]$Canary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Stage0.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
Assert-Stage0Name $FoundationEnvironment
if ($EnvironmentName -ceq $FoundationEnvironment) { throw 'Fixture must not reuse the foundation environment.' }
if ($Canary -and $Operation -cne 'Fault') { throw 'Canary applies only to Fault.' }
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
    'retailtx-guest-watchdog.service', 'retailtx-guest-watchdog.timer')

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
        'infra\guest-service-target.bicep', 'scripts\Azure.Common.psm1', 'scripts\Stage0.Common.psm1')) {
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
    if ($script:state.schemaVersion -ne 1 -or $script:state.profile -cne 'guest-service' -or
        $script:state.subscriptionId -ine $subscription -or $script:state.tenantId -ine $account.tenantId -or
        $script:state.environmentName -cne $EnvironmentName -or $script:state.location -cne $location -or
        $script:state.groupId -ine $groupId -or $script:state.vmId -ine $vmId) {
        throw 'Guest-service manifest does not match the explicit environment.'
    }
    $null = [guid]::Parse($script:state.ownerToken)
    $null = [guid]::Parse($script:state.agentPrincipalId)
    if ($script:state.agentId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.App/agents/*" -or
        $script:state.agentIdentityId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.ManagedIdentity/userAssignedIdentities/*") {
        throw 'Retained action identity binding is invalid.'
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
    if ($script:state -and $script:state.phase -cne 'deleted' -and
        ($script:state.agentId -ine $agentId -or $script:state.agentIdentityId -ine $identityId -or
            $script:state.agentPrincipalId -ine $principal)) {
        throw 'Guest manifest is bound to a different retained SRE action identity.'
    }
    return @{ agentId = $agentId; agentIdentityId = $identityId; agentPrincipalId = $principal }
}

function Assert-GuestReader {
    $assignments = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $groupId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
    $expectedRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
    $matches = @($assignments | Where-Object {
        $_.scope -ieq $groupId -and $_.principalId -ieq $script:state.agentPrincipalId -and $_.roleDefinitionId -ieq $expectedRole
    })
    if ($matches.Count -ne 1) { throw 'Exact guest group Reader grant to retained action identity is missing or ambiguous.' }
    foreach ($assignment in $assignments) {
        if ($assignment.principalId -ieq $script:state.agentPrincipalId -and
            ($assignment.scope -ine $groupId -or $assignment.roleDefinitionId -ine $expectedRole)) {
            throw 'Unexpected guest-scope action identity privilege; refusing guest proof.'
        }
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
    $policyId = "$vmId/extensions/AzurePolicyforLinux"
    $resources = @(Invoke-Azure @('resource', 'list', '--resource-group', $groupName))
    $seen = @{}
    foreach ($resource in $resources) {
        if ($seen.ContainsKey($resource.id)) { throw 'Duplicate teardown inventory ID.' }
        $seen[$resource.id] = $true
        if ($resource.id -ieq $policyId) {
            if ($resource.type -ine 'Microsoft.Compute/virtualMachines/extensions') {
                throw 'Unexpected policy child resource type.'
            }
            continue
        }
        if (-not $expected.ContainsKey($resource.id) -or $resource.type -ine $expected[$resource.id] -or
            $resource.location -ine $location -or $resource.tags.demo -cne 'retailtx' -or
            $resource.tags.environmentId -cne $EnvironmentName -or $resource.tags.profile -cne 'guest-service' -or
            $resource.tags.managedBy -cne 'retailtx' -or $resource.tags.ownerToken -cne $script:state.ownerToken) {
            throw 'Foreign or unexpected resource in owned group; refusing group deletion.'
        }
    }
    if ($seen.ContainsKey($vmId)) {
        $extensionResponse = Invoke-Azure @('rest', '--method', 'get', '--url', "$vmId/extensions?api-version=2024-11-01")
        $extensions = @($extensionResponse.value)
        if ($extensions.Count -gt 1) { throw 'Unexpected VM child extensions; refusing group deletion.' }
        if ($seen.ContainsKey($policyId) -and $extensions.Count -ne 1) {
            throw 'Policy extension inventory did not resolve to exact child.'
        }
        foreach ($extension in $extensions) {
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
    if ($nsg.tags.ownerToken -cne $script:state.ownerToken -or @($nsg.securityRules).Count -ne 5) {
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
        $script:state.phase = 'deleting'
        Add-GuestJournal @{ action = 'delete'; intentAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); outcome = 'intent' }
        if ($group) { $null = Invoke-Azure @('group', 'delete', '--name', $groupName, '--yes') -TimeoutSeconds 600 }
        if (Invoke-Azure @('group', 'exists', '--name', $groupName)) { throw 'Guest fixture resource group still exists.' }
        $residuals = @(Invoke-Azure @('resource', 'list', '--tag', "ownerToken=$($script:state.ownerToken)"))
        if ($residuals.Count -ne 0) { throw 'Owned resources remain outside the deleted group; no absence claim.' }
        $script:state.phase = 'deleted'
        $script:state.absenceVerifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
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
    $sourceHashes = Get-SourceHash
    $artifactHashes = Get-ArtifactHash
    if ($script:state -and $script:state.phase -cne 'deleted') {
        Assert-ExactHash $script:state.sourceHashes $sourceHashes
        Assert-ExactHash $script:state.artifactHashes $artifactHashes
    }
    if (-not $PSCmdlet.ShouldProcess($vmId, "$Operation operator Action Run Command fixture")) { return }
    if ($group) { $null = Get-OwnedVm; Assert-GuestNetwork }
    if ($Operation -eq 'Up') {
        $binding = Get-RetainedGuestIdentity $foundation
        if ($script:state -and $script:state.phase -cne 'deleted') {
            if (-not $group -or $script:state.phase -in @('provisioning', 'deleting')) {
                throw 'Incomplete deployment intent cannot be replayed blindly; use Down then Up.'
            }
            if ($script:state.pendingCommand -and $script:state.pendingCommand.action -cne 'configure') {
                throw 'Outstanding guest fault/repair intent; use Status or Down.'
            }
            Assert-GuestReader
            $evidence = Get-GuestStatus
        } else {
            if ($group) { throw 'Deleted manifest has live resources; refusing recreation.' }
            $script:state = @{
                schemaVersion = 1; profile = 'guest-service'; environmentName = $EnvironmentName
                subscriptionId = $subscription; tenantId = $account.tenantId; location = $location
                groupId = $groupId; vmId = $vmId; ownerToken = [guid]::NewGuid().ToString()
                phase = 'provisioning'; sourceHashes = $sourceHashes; artifactHashes = $artifactHashes
                expiresAt = [DateTimeOffset]::UtcNow.AddHours(4).ToString('o')
                journal = @(); pendingCommand = $null; currentFault = $null; lastEvidence = $null
                agentId = $binding.agentId; agentIdentityId = $binding.agentIdentityId
                agentPrincipalId = $binding.agentPrincipalId
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
            $parameters = @{
                environmentName = @{ value = $EnvironmentName }; location = @{ value = $location }
                ownerToken = @{ value = $script:state.ownerToken }; expiresAt = @{ value = $script:state.expiresAt }
                adminSshPublicKey = @{ value = $publicKey }
                agentPrincipalId = @{ value = $script:state.agentPrincipalId }
            }
            $parameterPath = Join-Path $directory 'guest-service.parameters.json'
            @{ parameters = $parameters } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameterPath -Encoding utf8NoBOM
            Add-GuestJournal @{ action = 'deploy'; intentAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); outcome = 'intent' }
            $deployment = Invoke-Azure @('deployment', 'sub', 'create', '--name', "retailtx-guest-$EnvironmentName",
                '--location', $location, '--template-file', (Join-Path $root 'infra\guest-service.bicep'),
                '--parameters', "@$parameterPath") -TimeoutSeconds 1200
            if ($deployment.properties.provisioningState -cne 'Succeeded') { throw 'Deployment completion not verified; use Down.' }
            $script:state.journal[-1].outcome = 'deployment-succeeded'
            $script:state.phase = 'configuring'
            $outputs = ConvertFrom-RetailDeploymentOutputs $deployment.properties.outputs
            $script:state.readerAssignmentId = $outputs.READERASSIGNMENTID
            Save-RetailState $script:state $statePath
            Assert-GuestNetwork
            Assert-GuestReader
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
        $evidence = Get-GuestStatus
        if ($Operation -ne 'Status') {
            if ($script:state.pendingCommand) { throw 'Unresolved command; writes remain blocked. Use Status or Down.' }
            $operatorIdentity = Invoke-Azure @('rest', '--method', 'get', '--url',
                'https://graph.microsoft.com/v1.0/me?$select=id')
            $actor = [guid]::Parse($operatorIdentity.id).ToString()
            $request = @{ action = $Operation.ToLowerInvariant(); ownerToken = $script:state.ownerToken
                sourceHashes = $sourceHashes; actor = $actor }
            if ($Operation -eq 'Fault') {
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
        }
    }
    Get-GuestOutput -GroupExists $true -PowerState 'PowerState/running' -Evidence $evidence
} finally {
    $lease.Dispose()
}
