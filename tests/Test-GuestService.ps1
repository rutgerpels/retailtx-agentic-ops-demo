#Requires -Version 7.2
# Local AST-extracted lifecycle tests. No Azure or guest writes.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\Azure.Common.psm1') -Force
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'scripts\Invoke-GuestService.ps1'), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
foreach ($name in @('Assert-ExactHash', 'Assert-GuestManifest', 'Get-RetainedGuestIdentity', 'Assert-GuestReader',
    'Get-OwnedGuestActionRole', 'Get-GuestSubnetDelegationServiceName',
    'Assert-GuestExecutionAgent', 'Assert-GuestExecutionNetwork',
    'Assert-GuestExecutionAssignmentsForTeardown', 'Remove-GuestExecutionRoleAssignments', 'Remove-GuestExecutionRole',
    'Get-OwnedGroup', 'Assert-GuestTeardownInventory', 'Get-OwnedVm', 'Assert-GuestNetwork',
    'Get-PowerState', 'Add-GuestJournal', 'Get-GuestBaseDeploymentParameters', 'Save-GuestTeardownUnknown',
    'Invoke-GuestGroupDeletion', 'ConvertFrom-GuestJson', 'ConvertFrom-GuestResult',
    'Assert-GuestCommandEvidence', 'Invoke-GuestCommand', 'Get-GuestStatus')) {
    $node = $ast.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:checks = 0
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe action accepted.' }
    $script:checks++
}
$EnvironmentName = 'demo16'
$location = 'swedencentral'
$subscription = '11111111-1111-1111-1111-111111111111'
$account = @{ tenantId = '22222222-2222-2222-2222-222222222222' }
$groupName = 'rg-retailtx-guest-demo16-swedencentral'
$groupId = "/subscriptions/$subscription/resourceGroups/$groupName"
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-retailtx-guest-demo16"
$script:state = @{
    schemaVersion = 1; profile = 'guest-service'; subscriptionId = $subscription; tenantId = $account.tenantId
    environmentName = $EnvironmentName; location = $location; groupId = $groupId; vmId = $vmId
    ownerToken = '33333333-3333-3333-3333-333333333333'; sourceHashes = @{ 'worker.py' = 'a' * 64 }
    expiresAt = [DateTimeOffset]::UtcNow.AddHours(4).ToString('o')
    journal = @(); pendingCommand = $null; currentFault = $null
    phase = 'ready'; agentPrincipalId = '66666666-6666-6666-6666-666666666666'
    agentId = "/subscriptions/$subscription/resourceGroups/foundation/providers/Microsoft.App/agents/sre-fixture"
    agentIdentityId = "/subscriptions/$subscription/resourceGroups/foundation/providers/Microsoft.ManagedIdentity/userAssignedIdentities/retained-action"
}
$script:agent = @{ properties = @{ actionConfiguration = @{ mode = 'Review'; identity = $script:state.agentIdentityId } } }
$script:identity = @{ id = $script:state.agentIdentityId; principalId = $script:state.agentPrincipalId; tenantId = $account.tenantId }
$script:state.retainedAgentPrincipalId = $script:state.agentPrincipalId
$baseParameters = Get-GuestBaseDeploymentParameters -AdminSshPublicKey 'ssh-ed25519 test-key'
if ($baseParameters.agentPrincipalId.value -ine $script:state.retainedAgentPrincipalId) {
    throw 'Default-mode base deployment did not bind Reader to the retained foundation identity.'
}
$script:checks++
$script:state.schemaVersion = 2
$script:state.withSreExecution = $true
$script:state.agentPrincipalId = $null
$baseParameters = Get-GuestBaseDeploymentParameters -AdminSshPublicKey 'ssh-ed25519 test-key'
if ($baseParameters.agentPrincipalId.value -ine $script:state.retainedAgentPrincipalId) {
    throw 'Opt-in base deployment did not bind Reader to the retained foundation identity.'
}
$script:checks++
$script:state.schemaVersion = 1
$script:state.Remove('withSreExecution')
$script:state.agentPrincipalId = $script:state.retainedAgentPrincipalId
$readerRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
$script:assignments = @(@{ scope = $groupId; principalId = $script:state.agentPrincipalId; roleDefinitionId = $readerRole })
$script:executionRole = $null
$script:executionAgent = $null
$script:executionIdentity = $null
$script:executionIdentityUnavailable = $false
$script:executionAssignments = @()
$script:executionSystemAssignments = @()
$script:executionAdminAssignments = @()
$script:executionRoleAssignments = @()
$script:executionVnet = $null
$script:executionSubnet = $null
$script:executionNat = $null
$script:executionPip = $null
$script:executionRoleDeleted = $false
$script:executionDeleteCalls = 0
$script:groupExistsResponses = @()
$script:groupDeleteArguments = @()
$script:groupDeleteFails = $false
$script:inventory = @()
$script:extensions = @()
$tags = @{ demo = 'retailtx'; environmentId = $EnvironmentName; profile = 'guest-service'
    managedBy = 'retailtx'; ownerToken = $script:state.ownerToken }
$script:group = @{ id = $groupId; location = $location; tags = $tags.Clone() }
$nicId = "$groupId/providers/Microsoft.Network/networkInterfaces/nic-retailtx-guest-demo16"
$script:vm = @{
    id = $vmId; location = $location; tags = $tags.Clone()
    osProfile = @{ allowExtensionOperations = $true; linuxConfiguration = @{
        provisionVMAgent = $true; disablePasswordAuthentication = $true } }
    storageProfile = @{ imageReference = @{ publisher = 'Canonical'; offer = 'ubuntu-24_04-lts'
        sku = 'server'; version = '24.04.202609040' } }
    networkProfile = @{ networkInterfaces = @(@{ id = $nicId }) }
}
$script:nic = @{ tags = $tags.Clone(); enableIPForwarding = $false
    ipConfigurations = @(@{ publicIPAddress = $null; subnet = @{
        id = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-demo16/subnets/host" } }) }
$script:subnet = @{
    id = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-demo16/subnets/host"
    defaultOutboundAccess = $false
    networkSecurityGroup = @{ id = "$groupId/providers/Microsoft.Network/networkSecurityGroups/nsg-retailtx-guest-demo16" }
    natGateway = @{ id = "$groupId/providers/Microsoft.Network/natGateways/nat-retailtx-guest-demo16" }
}
$natId = "$groupId/providers/Microsoft.Network/natGateways/nat-retailtx-guest-demo16"
$pipId = "$groupId/providers/Microsoft.Network/publicIPAddresses/pip-retailtx-guest-demo16-egress"
$script:nat = @{
    id = $natId; location = $location; tags = $tags.Clone(); sku = @{ name = 'Standard' }
    idleTimeoutInMinutes = 4; publicIpAddresses = @(@{ id = $pipId }); subnets = @(@{ id = $script:subnet.id })
}
$script:pip = @{
    id = $pipId; location = $location; tags = $tags.Clone(); sku = @{ name = 'Standard'; tier = 'Regional' }
    publicIPAllocationMethod = 'Static'; publicIPAddressVersion = 'IPv4'; natGateway = @{ id = $natId }
}
$script:nsg = @{ tags = $tags.Clone(); securityRules = @(
    @{ name = 'AzureHttps'; direction = 'Outbound'; access = 'Allow'; priority = 100; protocol = 'Tcp'
        destinationPortRange = '443'; destinationAddressPrefix = 'AzureCloud'; sourceAddressPrefix = '*'; sourcePortRange = '*' },
    @{ name = 'AzureVmAgent'; direction = 'Outbound'; access = 'Allow'; priority = 110; protocol = 'Tcp'
        destinationPortRanges = @('80', '32526'); destinationAddressPrefix = '168.63.129.16'; sourceAddressPrefix = '*'; sourcePortRange = '*' },
    @{ name = 'AzureDns'; direction = 'Outbound'; access = 'Allow'; priority = 120; protocol = '*'
        destinationPortRange = '53'; destinationAddressPrefix = '168.63.129.16'; sourceAddressPrefix = '*'; sourcePortRange = '*' },
    @{ name = 'DenyInbound'; direction = 'Inbound'; access = 'Deny'; priority = 4096; protocol = '*'
        destinationPortRange = '*'; destinationAddressPrefix = '*'; sourceAddressPrefix = '*'; sourcePortRange = '*' },
    @{ name = 'DenyOutbound'; direction = 'Outbound'; access = 'Deny'; priority = 4096; protocol = '*'
        destinationPortRange = '*'; destinationAddressPrefix = '*'; sourceAddressPrefix = '*'; sourcePortRange = '*' }
) }
$script:evidence = @{
    schemaVersion = 1; ownerToken = $script:state.ownerToken; observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    service = 'retailtx-demo-posting-worker'; active = $true; healthy = $true
    watchdogActive = $true; watchdogEnabled = $true; marker = $null; watchdogProof = $null
    sourceHashes = $script:state.sourceHashes.Clone()
}
$script:timeout = $false
$script:commands = 0
function New-RawResult {
    return @{ value = @(@{ code = 'ProvisioningState/succeeded'
        message = "Enable succeeded:`n[stdout]`nRETAILTX_GUEST=$($script:evidence | ConvertTo-Json -Depth 10 -Compress)`n`n[stderr]`n" }) }
}
function Invoke-Azure {
    param([string[]]$Arguments, [int]$TimeoutSeconds)
    switch ($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' ') {
        'group exists --name' {
            if ($script:groupExistsResponses.Count -gt 0) {
                $response = $script:groupExistsResponses[0]
                $script:groupExistsResponses = @($script:groupExistsResponses | Select-Object -Skip 1)
                return $response
            }
            return $true
        }
        'group show --name' { return $script:group }
        'group delete --name' {
            $script:groupDeleteArguments = @($Arguments)
            if ($script:groupDeleteFails) { throw 'simulated Azure CLI submission failure' }
            return $null
        }
        'vm list --resource-group' { return $script:vm }
        'network nic show' { return $script:nic }
        'network vnet subnet' {
            if ($script:state.ContainsKey('sreSubnetId') -and $script:state.sreSubnetId -and
                $Arguments -contains '--ids' -and $Arguments -contains $script:state.sreSubnetId) { return $script:executionSubnet }
            return $script:subnet
        }
        'network vnet show' { return $script:executionVnet }
        'network nat gateway' {
            if ($script:state.withSreExecution) { return $script:executionNat }
            return $script:nat
        }
        'network public-ip show' {
            if ($script:state.withSreExecution) { return $script:executionPip }
            return $script:pip
        }
        'network nsg show' { return $script:nsg }
        'network nat gateway' { return $script:nat }
        'network public-ip show' { return $script:pip }
        'resource show --ids' {
            if ($script:state -and $script:state.ContainsKey('withSreExecution') -and
                $script:state.withSreExecution -and $Arguments -contains $script:state.agentId) { return $script:executionAgent }
            return $script:agent
        }
        'resource list --resource-group' { return $script:inventory }
        'rest --method get' { return @{ value = $script:extensions } }
        'identity show --ids' {
            if ($script:state -and $script:state.ContainsKey('withSreExecution') -and
                $script:state.withSreExecution -and $Arguments -contains $script:state.agentIdentityId) {
                if ($script:executionIdentityUnavailable) { throw 'Managed identity not found.' }
                return $script:executionIdentity
            }
            return $script:identity
        }
        'role definition list' {
            if ($script:executionRoleDeleted) { return @() }
            return @($script:executionRole)
        }
        'role assignment list' {
            if ($Arguments -contains '--assignee-object-id') {
                $index = [Array]::IndexOf($Arguments, '--assignee-object-id') + 1
                if ($Arguments[$index] -ieq $script:state.agentPrincipalId) { return $script:executionAssignments }
                if ($Arguments[$index] -ieq $script:state.systemPrincipalId) { return $script:executionSystemAssignments }
            }
            if ($Arguments -contains '--role') { return $script:executionRoleAssignments }
            if ($Arguments -contains '--scope') {
                $index = [Array]::IndexOf($Arguments, '--scope') + 1
                if ($Arguments[$index] -ieq $script:state.agentId) { return $script:executionAdminAssignments }
                if ($Arguments[$index] -ieq $groupId) {
                    if ($Arguments -contains '--all' -or $Arguments -notcontains '--fill-principal-name') {
                        throw 'Scoped Reader readback CLI syntax changed.'
                    }
                    return $script:assignments
                }
                if ($Arguments[$index] -ieq $vmId) { return @($script:executionAssignments | Where-Object { $_.scope -ieq $vmId }) }
                if ($Arguments[$index] -ieq $script:state.sreSubnetId) { return @($script:executionAssignments | Where-Object { $_.scope -ieq $script:state.sreSubnetId }) }
            }
            throw "Unexpected role assignment query: $($Arguments -join ' ')"
        }
        'role assignment delete' {
            $script:executionDeleteCalls++
            $index = [Array]::IndexOf($Arguments, '--ids') + 1
            $deleteId = $Arguments[$index]
            $script:executionAssignments = @($script:executionAssignments | Where-Object id -INE $deleteId)
            $script:executionSystemAssignments = @($script:executionSystemAssignments | Where-Object id -INE $deleteId)
            $script:executionAdminAssignments = @($script:executionAdminAssignments | Where-Object id -INE $deleteId)
            $script:executionRoleAssignments = @($script:executionRoleAssignments | Where-Object id -INE $deleteId)
            $script:assignments = @($script:assignments | Where-Object id -INE $deleteId)
            return $null
        }
        'role definition delete' {
            $script:executionRoleDeleted = $true
            return $null
        }
        'vm get-instance-view --ids' { return @{ instanceView = @{ statuses = @(@{ code = 'PowerState/running' }) } } }
        'vm run-command invoke' {
            if ($TimeoutSeconds -ne 180 -or $Arguments -notcontains 'RunShellScript') { throw 'Unexpected transport.' }
            $script:commands++
            if ($script:timeout) { throw [TimeoutException]::new('unknown outcome') }
            return New-RawResult
        }
        default { throw "Unexpected operation: $($Arguments -join ' ')" }
    }
}
$foundation = @{ outputs = @{ SRE_AGENT_ID = $script:state.agentId } }
$savedState = $script:state
$script:state = $null
$null = Get-RetainedGuestIdentity $foundation
$script:state = $savedState
Assert-GuestManifest
$null = Get-RetainedGuestIdentity $foundation
Assert-GuestReader
$script:checks++
$script:agent.properties.actionConfiguration.mode = 'Autonomous'
Assert-Rejected { Get-RetainedGuestIdentity $foundation }
$script:agent.properties.actionConfiguration.mode = 'Review'
$script:identity.principalId = [guid]::NewGuid().ToString()
Assert-Rejected { Get-RetainedGuestIdentity $foundation }
$script:identity.principalId = $script:state.agentPrincipalId
$script:assignments[0].roleDefinitionId = 'foreign-write-role'
Assert-Rejected { Assert-GuestReader }
$script:assignments[0].roleDefinitionId = $readerRole
Assert-GuestTeardownInventory
$script:checks++
$script:inventory = @(@{ id = $vmId; type = 'Microsoft.Compute/virtualMachines'; location = $location
    tags = @{ demo = 'retailtx'; environmentId = $EnvironmentName; profile = 'guest-service'
        managedBy = 'retailtx'; ownerToken = $script:state.ownerToken } })
$policyId = "$vmId/extensions/AzurePolicyforLinux"
$policyExtension = @{ id = $policyId; name = 'AzurePolicyforLinux'; type = 'Microsoft.Compute/virtualMachines/extensions'
    location = $location; tags = @{}; properties = @{ publisher = 'Microsoft.GuestConfiguration'; type = 'ConfigurationforLinux' } }
$script:extensions = @($policyExtension)
Assert-GuestTeardownInventory
$script:checks++
$script:inventory += @{ id = $policyId; type = 'Microsoft.Compute/virtualMachines/extensions'; tags = @{} }
Assert-GuestTeardownInventory
$script:checks++
$script:inventory[0].tags.ownerToken = 'foreign'
Assert-Rejected { Assert-GuestTeardownInventory }
$script:inventory[0].tags.ownerToken = $script:state.ownerToken
$script:inventory += @{ id = "$groupId/providers/Microsoft.Storage/storageAccounts/foreign"; type = 'Microsoft.Storage/storageAccounts'
    location = $location; tags = $script:inventory[0].tags.Clone() }
Assert-Rejected { Assert-GuestTeardownInventory }
$script:inventory = @($script:inventory[0..1])
foreach ($field in @('publisher', 'type')) {
    $old = $policyExtension.properties[$field]
    $policyExtension.properties[$field] = 'foreign'
    Assert-Rejected { Assert-GuestTeardownInventory }
    $policyExtension.properties[$field] = $old
}
$policyExtension.name = 'foreign-extension'
Assert-Rejected { Assert-GuestTeardownInventory }
$policyExtension.name = 'AzurePolicyforLinux'
$policyExtension.id = "$vmId/extensions/foreign"
Assert-Rejected { Assert-GuestTeardownInventory }
$policyExtension.id = $policyId
$script:extensions += $policyExtension.Clone()
Assert-Rejected { Assert-GuestTeardownInventory }
$script:extensions = @($policyExtension)
$script:inventory = @($script:inventory[1])
Assert-Rejected { Assert-GuestTeardownInventory }
$script:inventory = @()
$script:extensions = @()
foreach ($entry in @(
    @('Microsoft.Network/publicIPAddresses', 'pip-retailtx-guest-demo16-egress'),
    @('Microsoft.Network/natGateways', 'nat-retailtx-guest-demo16'),
    @('Microsoft.Network/networkSecurityGroups', 'nsg-retailtx-guest-demo16'),
    @('Microsoft.Network/virtualNetworks', 'vnet-retailtx-guest-demo16'),
    @('Microsoft.Network/networkInterfaces', 'nic-retailtx-guest-demo16'),
    @('Microsoft.Compute/virtualMachines', 'vm-retailtx-guest-demo16'),
    @('Microsoft.Compute/disks', 'osdisk-retailtx-guest-demo16')
)) {
    $script:inventory += @{ id = "$groupId/providers/$($entry[0])/$($entry[1])"; type = $entry[0]
        location = $location; tags = @{ demo = 'retailtx'; environmentId = $EnvironmentName; profile = 'guest-service'
            managedBy = 'retailtx'; ownerToken = $script:state.ownerToken } }
}
Assert-GuestTeardownInventory
$script:checks++
$script:inventory[0].type = 'Microsoft.Compute/disks'
Assert-Rejected { Assert-GuestTeardownInventory }
$script:inventory[0].type = 'Microsoft.Network/publicIPAddresses'
$script:inventory += $script:inventory[0].Clone()
Assert-Rejected { Assert-GuestTeardownInventory }
$script:inventory = @()
$null = Get-OwnedVm
$script:checks++
foreach ($key in @('demo', 'environmentId', 'profile', 'managedBy', 'ownerToken')) {
    $old = $script:group.tags[$key]
    $script:group.tags[$key] = 'foreign'
    Assert-Rejected { Get-OwnedGroup }
    $script:group.tags[$key] = $old
}
$script:vm.tags.ownerToken = 'foreign'
Assert-Rejected { Get-OwnedVm }
$script:vm.tags.ownerToken = $script:state.ownerToken
$script:nic.ipConfigurations[0].publicIPAddress = @{ id = 'foreign-public-ip' }
Assert-Rejected { Get-OwnedVm }
$script:nic.ipConfigurations[0].publicIPAddress = $null
$script:vm.osProfile.allowExtensionOperations = $false
Assert-Rejected { Get-OwnedVm }
$script:vm.osProfile.allowExtensionOperations = $true
Assert-GuestNetwork
$script:checks++
$script:subnet.defaultOutboundAccess = $true
Assert-Rejected { Assert-GuestNetwork }
$script:subnet.defaultOutboundAccess = $false
$script:nsg.securityRules[3].access = 'Allow'
Assert-Rejected { Assert-GuestNetwork }
$script:nsg.securityRules[3].access = 'Deny'
$script:nsg.securityRules[2].destinationAddressPrefix = 'AzurePlatformDNS'
Assert-Rejected { Assert-GuestNetwork }
$script:nsg.securityRules[2].destinationAddressPrefix = '168.63.129.16'
$script:subnet.routeTable = @{ id = 'foreign-route' }
Assert-Rejected { Assert-GuestNetwork }
$script:subnet.Remove('routeTable')
foreach ($target in @($script:nat, $script:pip)) {
    $target.tags.ownerToken = 'foreign'
    Assert-Rejected { Assert-GuestNetwork }
    $target.tags.ownerToken = $script:state.ownerToken
    $target.location = 'foreign'
    Assert-Rejected { Assert-GuestNetwork }
    $target.location = $location
}
$script:nat.publicIpAddresses[0].id = 'foreign-public-ip'
Assert-Rejected { Assert-GuestNetwork }
$script:nat.publicIpAddresses[0].id = $pipId
$script:nat.publicIpPrefixes = @(@{ id = 'foreign-prefix' })
Assert-Rejected { Assert-GuestNetwork }
$script:nat.Remove('publicIpPrefixes')
$script:pip.publicIPAllocationMethod = 'Dynamic'
Assert-Rejected { Assert-GuestNetwork }
$script:pip.publicIPAllocationMethod = 'Static'
$script:pip.natGateway.id = 'foreign-nat'
Assert-Rejected { Assert-GuestNetwork }
$script:pip.natGateway.id = $natId
$script:pip.ipConfiguration = @{ id = 'vm-public-inbound-attachment' }
Assert-Rejected { Assert-GuestNetwork }
$script:pip.Remove('ipConfiguration')
Assert-ExactHash @{ a = 'digest' } @{ a = 'digest' }
Assert-Rejected { Assert-ExactHash @{ a = 'digest' } @{ a = 'foreign' } }
Assert-Rejected { Assert-ExactHash @{ a = 'digest'; b = 'digest' } @{ a = 'digest' } }
$null = ConvertFrom-GuestResult (New-RawResult)
$script:checks++
$script:evidence.ownerToken = 'foreign'
Assert-Rejected { ConvertFrom-GuestResult (New-RawResult) }
$script:evidence.ownerToken = $script:state.ownerToken
$script:evidence.observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
Assert-Rejected { ConvertFrom-GuestResult (New-RawResult) }
$script:evidence.observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
Assert-Rejected { ConvertFrom-GuestResult @{ value = @(@{ code = 'ProvisioningState/succeeded'; message = '[stdout] truncated' }) } }
Assert-Rejected { ConvertFrom-GuestResult @{ value = @(@{ code = 'ProvisioningState/failed'; message = 'failure' }) } }
$directory = Join-Path $root ".azure\guest-local-tests-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $directory
$statePath = Join-Path $directory 'guest-service-state.json'
try {
    $request = @{ action = 'fault'; ownerToken = $script:state.ownerToken; sourceHashes = $script:state.sourceHashes
        runId = '44444444-4444-4444-4444-444444444444'; actor = '55555555-5555-5555-5555-555555555555'
        startBeforeUtc = [DateTimeOffset]::UtcNow.AddSeconds(90).ToString('o'); durationSeconds = 60; canary = $true }
    Assert-Rejected { Assert-GuestCommandEvidence $request $script:evidence }
    $script:timeout = $true
    Assert-Rejected { Invoke-GuestCommand $request }
    if (-not $script:state.pendingCommand -or $script:state.journal[0].outcome -cne 'unknown' -or
        -not (Test-Path $script:state.journal[0].commandFile)) { throw 'Intent not durable before uncertain transport.' }
    $saved = Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable
    if ($saved.pendingCommand.request.runId -cne $request.runId) { throw 'Exact intent not persisted.' }
    $before = $script:commands
    Assert-Rejected { Invoke-GuestCommand $request }
    if ($script:commands -ne $before) { throw 'Timed-out fault was blindly replayed.' }
    $script:timeout = $false
    $null = Get-GuestStatus
    if (-not $script:state.pendingCommand) { throw 'Absent marker incorrectly treated as failed fault/no late command.' }
    $started = [DateTimeOffset]::UtcNow
    $script:evidence.marker = @{
        runId = $request.runId; actor = $request.actor; startBeforeUtc = $request.startBeforeUtc
        deadlineUtc = $started.AddSeconds(60).ToString('o')
        startedAtUtc = $started.ToString('o'); durationSeconds = 60; canary = $true; phase = 'fault-active'
    }
    $script:evidence.active = $false
    $script:evidence.healthy = $false
    $null = Get-GuestStatus
    if ($script:state.pendingCommand -or $script:state.phase -cne 'fault-active') { throw 'Exact readback did not reconcile fault.' }
    Assert-GuestCommandEvidence $request $script:evidence
    $script:checks++
    $wrongRequest = $request.Clone()
    $wrongRequest.runId = [guid]::NewGuid().ToString()
    Assert-Rejected { Assert-GuestCommandEvidence $wrongRequest $script:evidence }
    $script:checks++
    $script:evidence.marker.phase = 'recovered'
    $script:evidence.active = $true
    $script:evidence.healthy = $true
    foreach ($action in @('repair', 'reset')) {
        $recoveryRequest = @{ action = $action; runId = $request.runId; actor = $request.actor }
        $script:state.pendingCommand = @{ commandId = [guid]::NewGuid().ToString(); action = $action
            request = $recoveryRequest; outcome = 'unknown' }
        $script:evidence.marker.recoveredBy = 'watchdog'
        $script:evidence.marker.recoveryReason = 'deadline'
        $null = Get-GuestStatus
        if (-not $script:state.pendingCommand) { throw 'Watchdog recovery cleared unknown operator recovery intent.' }
        Assert-Rejected { Assert-GuestCommandEvidence $recoveryRequest $script:evidence }
        $script:evidence.marker.recoveredBy = $request.actor
        $script:evidence.marker.recoveryReason = if ($action -ceq 'repair') { 'reset' } else { 'repair' }
        $null = Get-GuestStatus
        if (-not $script:state.pendingCommand) { throw 'Wrong recovery action cleared pending intent.' }
        $script:evidence.marker.recoveryReason = $action
        $script:evidence.marker.recoveredBy = [guid]::NewGuid().ToString()
        $null = Get-GuestStatus
        if (-not $script:state.pendingCommand) { throw 'Wrong operator actor cleared pending intent.' }
        $script:evidence.marker.recoveredBy = $request.actor
        $null = Get-GuestStatus
        if ($script:state.pendingCommand) { throw 'Exact actor/action/run recovery did not reconcile.' }
        Assert-GuestCommandEvidence $recoveryRequest $script:evidence
        $script:checks++
    }
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
$script:state.schemaVersion = 2
$script:state.withSreExecution = $true
$script:state.retainedAgentId = $script:state.agentId
$script:state.retainedAgentIdentityId = $script:state.agentIdentityId
$script:state.retainedAgentPrincipalId = $script:state.agentPrincipalId
$script:state.readerAssignmentId = "$groupId/providers/Microsoft.Authorization/roleAssignments/abababab-abab-abab-abab-abababababab"
$script:state.agentId = "$groupId/providers/Microsoft.App/agents/sre-retailtx-guest-agent-$EnvironmentName"
$script:state.agentIdentityId = "$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-retailtx-guest-agent-$EnvironmentName"
$script:state.agentPrincipalId = '77777777-7777-7777-7777-777777777777'
$script:state.actionClientId = '88888888-8888-8888-8888-888888888888'
$script:state.systemPrincipalId = '99999999-9999-9999-9999-999999999999'
$script:state.adminObjectId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$script:state.actionRoleDefinitionName = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
$script:state.actionRoleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$($script:state.actionRoleDefinitionName)"
$script:state.actionRoleAssignmentId = "$vmId/providers/Microsoft.Authorization/roleAssignments/cccccccc-cccc-cccc-cccc-cccccccccccc"
$script:state.actionReaderAssignmentId = "$groupId/providers/Microsoft.Authorization/roleAssignments/dddddddd-dddd-dddd-dddd-dddddddddddd"
$script:state.systemReaderAssignmentId = "$groupId/providers/Microsoft.Authorization/roleAssignments/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
$script:state.networkAssignmentId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName/subnets/sre/providers/Microsoft.Authorization/roleAssignments/ffffffff-ffff-ffff-ffff-ffffffffffff"
$script:state.adminAssignmentId = "$($script:state.agentId)/providers/Microsoft.Authorization/roleAssignments/12121212-1212-1212-1212-121212121212"
$script:state.sreSubnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName/subnets/sre"
$script:state.guestVmId = $vmId
$script:state.sreAdministratorRoleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/e79298df-d852-4c6d-84f9-5d13249d1e55"
$script:state.agentEndpoint = 'https://sre.example.test/'
$readerRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
$networkRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
$adminRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/e79298df-d852-4c6d-84f9-5d13249d1e55"
$script:executionRole = @{
    id = $script:state.actionRoleDefinitionId
    roleType = 'CustomRole'
    roleName = "RetailTx guest repair $EnvironmentName"
    description = "RetailTx guest repair for environment $EnvironmentName; ownerToken=$($script:state.ownerToken)"
    assignableScopes = @($groupId)
    permissions = @(@{ actions = @('Microsoft.Compute/virtualMachines/runCommand/action')
        notActions = @(); dataActions = @(); notDataActions = @() })
}
$script:executionIdentity = @{
    id = $script:state.agentIdentityId; location = $location; tenantId = $account.tenantId
    principalId = $script:state.agentPrincipalId; clientId = $script:state.actionClientId
    tags = $tags.Clone()
}
$script:executionAgent = @{
    id = $script:state.agentId; location = $location; tags = $tags.Clone()
    identity = @{ principalId = $script:state.systemPrincipalId }
    properties = @{
        agentEndpoint = $script:state.agentEndpoint
        actionConfiguration = @{ mode = 'Review'; accessLevel = 'Low'; identity = $script:state.agentIdentityId }
        knowledgeGraphConfiguration = @{ identity = $script:state.agentIdentityId; managedResources = @($groupId) }
        vnetConfiguration = @{ subnetResourceId = $script:state.sreSubnetId }
        sandboxConfiguration = @{ egress = @{ mode = 'AzureVNet'; vnetConfiguration = @{ usePrivateDnsResolution = $true } } }
    }
}
$agentReaderId = $script:state.actionReaderAssignmentId
$systemReaderId = $script:state.systemReaderAssignmentId
$actionRoleAssignment = @{ id = $script:state.actionRoleAssignmentId; scope = $vmId
    principalId = $script:state.agentPrincipalId; roleDefinitionId = $script:state.actionRoleDefinitionId }
$script:executionAssignments = @(
    @{ id = $agentReaderId; scope = $groupId; principalId = $script:state.agentPrincipalId; roleDefinitionId = $readerRole }
    $actionRoleAssignment
    @{ id = $script:state.networkAssignmentId; scope = $script:state.sreSubnetId
        principalId = $script:state.agentPrincipalId; roleDefinitionId = $networkRole }
)
$script:executionSystemAssignments = @(@{
    id = $systemReaderId; scope = $groupId; principalId = $script:state.systemPrincipalId; roleDefinitionId = $readerRole
})
$script:executionAdminAssignments = @(@{
    id = $script:state.adminAssignmentId; scope = $script:state.agentId
    principalId = $script:state.adminObjectId; roleDefinitionId = $adminRole
})
$script:executionRoleAssignments = @($actionRoleAssignment)
$script:assignments = @(
    @{ id = $script:state.readerAssignmentId; scope = $groupId
        principalId = $script:state.retainedAgentPrincipalId; roleDefinitionId = $readerRole }
    @{ id = $script:state.actionReaderAssignmentId; scope = $groupId
        principalId = $script:state.agentPrincipalId; roleDefinitionId = $readerRole }
    @{ id = $script:state.systemReaderAssignmentId; scope = $groupId
        principalId = $script:state.systemPrincipalId; roleDefinitionId = $readerRole }
)
$agentVnetId = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-agent-$EnvironmentName"
$agentNatId = "$groupId/providers/Microsoft.Network/natGateways/nat-retailtx-guest-agent-$EnvironmentName"
$agentPipId = "$groupId/providers/Microsoft.Network/publicIPAddresses/pip-retailtx-guest-agent-$EnvironmentName-egress"
$script:executionVnet = @{
    id = $agentVnetId; location = $location; tags = $tags.Clone()
    addressSpace = @{ addressPrefixes = @('10.90.0.0/24') }; virtualNetworkPeerings = @()
}
$script:executionSubnet = @{
    id = $script:state.sreSubnetId; addressPrefix = '10.90.0.0/27'; defaultOutboundAccess = $false
    delegations = @(@{ serviceName = 'Microsoft.App/environments'; actions = @() })
    natGateway = @{ id = $agentNatId }
}
$script:executionNat = @{
    id = $agentNatId; location = $location; tags = $tags.Clone(); sku = @{ name = 'Standard' }
    idleTimeoutInMinutes = 4; publicIpAddresses = @(@{ id = $agentPipId })
    subnets = @(@{ id = $script:state.sreSubnetId })
}
$script:executionPip = @{
    id = $agentPipId; location = $location; tags = $tags.Clone(); sku = @{ name = 'Standard'; tier = 'Regional' }
    publicIPAllocationMethod = 'Static'; publicIPAddressVersion = 'IPv4'; natGateway = @{ id = $agentNatId }
}
$teardownTestDirectory = Join-Path $root ".azure\guest-teardown-tests-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $teardownTestDirectory
$statePath = Join-Path $teardownTestDirectory 'state.json'
$completeAgentState = $script:state
$partialReloadState = $completeAgentState.Clone()
$partialReloadState.phase = 'provisioning'
foreach ($field in @('agentPrincipalId', 'actionClientId', 'systemPrincipalId', 'agentEndpoint',
    'adminObjectId', 'actionRoleAssignmentId', 'actionReaderAssignmentId', 'systemReaderAssignmentId',
    'networkAssignmentId', 'adminAssignmentId', 'sreSubnetId', 'guestVmId', 'sreAdministratorRoleDefinitionId')) {
    $partialReloadState[$field] = $null
}
Save-RetailState $partialReloadState $statePath
$script:state = ConvertFrom-GuestJson (Get-Content -LiteralPath $statePath -Raw)
Assert-GuestManifest
$script:checks++
$script:state.phase = 'configuring'
Assert-Rejected { Assert-GuestManifest }
$script:state = $completeAgentState
Assert-GuestManifest
Assert-GuestReader
Assert-GuestExecutionAgent
$script:checks++
$script:executionSubnet.delegations = @(@{ properties = @{ serviceName = 'Microsoft.App/environments' } })
Assert-GuestExecutionNetwork -SubnetId $script:state.sreSubnetId
$script:checks++
$script:executionSubnet.delegations = @(@{ serviceName = 'Microsoft.App/environments'; actions = @() })
$script:executionSubnet.delegations[0].serviceName = 'Microsoft.App/other'
Assert-Rejected { Assert-GuestExecutionNetwork -SubnetId $script:state.sreSubnetId }
$script:executionSubnet.delegations = @(@{ serviceName = 'Microsoft.App/environments'; actions = @() })
$script:executionAgent.properties.actionConfiguration.mode = 'Autonomous'
Assert-Rejected { Assert-GuestExecutionAgent }
$script:executionAgent.properties.actionConfiguration.mode = 'Review'
$script:executionRole.permissions[0].actions += 'Microsoft.Compute/virtualMachines/start/action'
Assert-Rejected { Get-OwnedGuestActionRole }
$script:executionRole.permissions[0].actions = @('Microsoft.Compute/virtualMachines/runCommand/action')
$script:executionAssignments += @{ id = 'foreign'; scope = $groupId; principalId = $script:state.agentPrincipalId
    roleDefinitionId = '/subscriptions/foreign/providers/Microsoft.Authorization/roleDefinitions/Contributor' }
Assert-Rejected { Assert-GuestExecutionAgent }
$script:executionAssignments = @($script:executionAssignments[0..2])
$script:executionVnet.virtualNetworkPeerings = @(@{ id = 'foreign-peering' })
Assert-Rejected { Assert-GuestExecutionAgent }
$script:executionVnet.virtualNetworkPeerings = @()
$script:inventory = @(
    @{ id = $script:state.agentIdentityId; type = 'Microsoft.ManagedIdentity/userAssignedIdentities'
        location = $location; tags = $tags.Clone() }
    @{ id = $script:state.agentId; type = 'Microsoft.App/agents'; location = $location; tags = $tags.Clone() }
)
Assert-GuestExecutionAssignmentsForTeardown
$script:checks++
$null = Remove-GuestExecutionRoleAssignments
if ($script:state.teardownRoleAssignments.Count -ne 0 -or $script:executionAssignments.Count -ne 0 -or
    $script:executionSystemAssignments.Count -ne 0 -or $script:executionAdminAssignments.Count -ne 0 -or
    $script:assignments.Count -ne 0) { throw 'Exact fixture role assignments were not removed before teardown.' }
$script:checks++
$script:executionAssignments += @{ id = 'foreign'; scope = $groupId; principalId = $script:state.agentPrincipalId
    roleDefinitionId = '/subscriptions/foreign/providers/Microsoft.Authorization/roleDefinitions/Owner' }
Assert-Rejected { Assert-GuestExecutionAssignmentsForTeardown }
$script:executionAssignments = @()
$script:inventory = @()
$script:executionRoleDeleted = $false
$script:executionRoleAssignments = @($actionRoleAssignment)
$beforeRoleDeletes = $script:executionDeleteCalls
$null = Remove-GuestExecutionRole
if (-not $script:executionRoleDeleted -or $script:executionDeleteCalls -ne ($beforeRoleDeletes + 1)) {
    throw 'Owned role teardown did not remove the exact VM grant and custom role.'
}
$script:checks++
$script:state.phase = 'deleting'
$script:groupExistsResponses = @($true, $false)
$script:groupDeleteArguments = @()
Invoke-GuestGroupDeletion -TimeoutMinutes 1 -PollSeconds 0
if ($script:groupDeleteArguments -notcontains '--no-wait' -or
    ($script:state.ContainsKey('teardownStatus') -and $script:state.teardownStatus -eq 'unknown')) {
    throw 'Group deletion did not use bounded asynchronous deletion or left a false unknown report.'
}
$script:checks++
$script:groupDeleteFails = $true
$script:groupExistsResponses = @($true)
Assert-Rejected { Invoke-GuestGroupDeletion -TimeoutMinutes 1 -PollSeconds 0 }
$persistedTeardownState = ConvertFrom-GuestJson (Get-Content -LiteralPath $statePath -Raw)
if ($persistedTeardownState.teardownStatus -cne 'unknown' -or
    -not $persistedTeardownState.retentionReportAtUtc -or
    @($persistedTeardownState.teardownResiduals).Count -eq 0) {
    throw 'Failed group-delete submission did not persist unknown outcome and retention residuals.'
}
$script:groupDeleteFails = $false
$script:groupExistsResponses = @()
$script:checks++
$script:executionRoleDeleted = $false
$script:executionRoleAssignments = @($actionRoleAssignment)
$script:executionIdentityUnavailable = $true
$beforeRoleDeletes = $script:executionDeleteCalls
$null = Remove-GuestExecutionRole
if (-not $script:executionRoleDeleted -or $script:executionDeleteCalls -ne ($beforeRoleDeletes + 1)) {
    throw 'Persisted principal did not support cleanup of the exact VM role assignment after identity deletion.'
}
$script:executionIdentityUnavailable = $false
$script:checks++
$script:executionRoleDeleted = $false
$script:executionRoleAssignments = @(@{ id = 'foreign'; scope = $groupId; principalId = 'foreign'
    roleDefinitionId = $script:state.actionRoleDefinitionId })
$beforeDeletes = $script:executionDeleteCalls
Assert-Rejected { Remove-GuestExecutionRole }
if ($script:executionDeleteCalls -ne $beforeDeletes) { throw 'Teardown deleted a foreign custom-role assignment.' }
$script:checks++

$template = Get-Content (Join-Path $root 'infra\guest-service-target.bicep') -Raw
if ($template -match 'publicIPAddressResourceId|start/action|stop/action|runCommand/action' -or
    $template -notmatch "acdd72a7-3385-48ef-bd42-f606fba81ae7" -or
    ([regex]::Matches($template, "Microsoft.Authorization/roleAssignments@")).Count -ne 1 -or
    $template -notmatch 'principalId: agentPrincipalId' -or
    $template -notmatch 'allowExtensionOperations: true' -or $template -notmatch 'natGatewayResourceId: nat.id' -or
    $template -notmatch 'defaultOutboundAccess: false') { throw 'Fixture infrastructure boundary changed.' }
$script:checks++
$agentTemplate = Get-Content (Join-Path $root 'infra\guest-service-agent-target.bicep') -Raw
$agentWrapper = Get-Content (Join-Path $root 'infra\guest-service-agent.bicep') -Raw
if ($agentTemplate -match 'Contributor' -and $agentTemplate -notmatch 'networkContributorRoleId|sreAdministratorRoleId' -or
    $agentTemplate -notmatch '(?s)scope:\s*vm.*?roleDefinitionId:\s*actionRole\.id' -or
    $agentTemplate -notmatch "delegation:\s*'Microsoft.App/environments'" -or
    $agentTemplate -notmatch "'10\.90\.0\.0/27'" -or $agentTemplate -notmatch 'natGatewayResourceId: nat.id' -or
    $agentTemplate -notmatch "mode:\s*'Review'" -or $agentTemplate -notmatch "mode:\s*'AzureVNet'" -or
    $agentTemplate -notmatch "usePrivateDnsResolution:\s*true" -or
    $agentTemplate -notmatch "accessLevel:\s*'Low'" -or
    $agentTemplate -match 'allowRules|toolAllow|RunInTerminal|RunShellCommand|ExecutePythonCode' -or
    $agentWrapper -notmatch 'Microsoft.Compute/virtualMachines/runCommand/action' -or
    $agentWrapper -notmatch "assignableScopes:\s*\[group\.id\]" -or
    $agentWrapper -notmatch 'ownerToken=\$\{ownerToken\}') {
    throw 'Isolated SRE Agent deployment boundary or native approval posture changed.'
}
$script:checks++
$lifecycleSource = Get-Content (Join-Path $root 'scripts\Invoke-GuestService.ps1') -Raw
if ($lifecycleSource -match "'ad',\s*'signed-in-user'" -or
    $lifecycleSource -notmatch "'rest',\s*'--method',\s*'get',\s*'--url'" -or
    $lifecycleSource -notmatch [regex]::Escape('https://graph.microsoft.com/v1.0/me?$select=id') -or
    $lifecycleSource -notmatch [regex]::Escape('[guid]::Parse($operatorIdentity.id).ToString()')) {
    throw 'Operator identity must use subscription-compatible Graph REST and UUID validation.'
}
$script:checks++
if ($template -match "destinationAddressPrefix:\s*'AzurePlatform(?:DNS|IMDS|LKM)'" -or
    $template -notmatch "(?s)name: 'AzureDns'.*?access: 'Allow'.*?destinationPortRange: '53'.*?destinationAddressPrefix: '168\.63\.129\.16'") {
    throw 'DNS must not use a platform deny-only opt-out tag as an Allow destination.'
}
$script:checks++
$whatIfEnvironment = "dry$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$whatIfDirectory = Join-Path $root ".azure\$whatIfEnvironment"
& (Join-Path $root 'scripts\Invoke-GuestService.ps1') Up -SubscriptionId $subscription `
    -EnvironmentName $whatIfEnvironment -WhatIf
if (Test-Path -LiteralPath $whatIfDirectory) { throw 'Fresh WhatIf created local state or lock.' }
$script:checks++
$whatIfSreEnvironment = "dry$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$whatIfSreDirectory = Join-Path $root ".azure\$whatIfSreEnvironment"
& (Join-Path $root 'scripts\Invoke-GuestService.ps1') Up -SubscriptionId $subscription `
    -EnvironmentName $whatIfSreEnvironment -WithSreExecution -WhatIf
if (Test-Path -LiteralPath $whatIfSreDirectory) { throw 'SRE-enabled WhatIf created local state or lock.' }
$script:checks++
Remove-Item -LiteralPath $teardownTestDirectory -Recurse -Force
[pscustomobject]@{ checks = $script:checks; outcome = 'passed'; azureWrites = 0 }
