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
    'Get-OwnedGroup', 'Assert-GuestTeardownInventory', 'Get-OwnedVm', 'Assert-GuestNetwork',
    'Get-PowerState', 'Add-GuestJournal', 'ConvertFrom-GuestJson', 'ConvertFrom-GuestResult',
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
    journal = @(); pendingCommand = $null; currentFault = $null
    phase = 'ready'; agentPrincipalId = '66666666-6666-6666-6666-666666666666'
    agentId = "/subscriptions/$subscription/resourceGroups/foundation/providers/Microsoft.App/agents/sre-fixture"
    agentIdentityId = "/subscriptions/$subscription/resourceGroups/foundation/providers/Microsoft.ManagedIdentity/userAssignedIdentities/retained-action"
}
$script:agent = @{ properties = @{ actionConfiguration = @{ mode = 'Review'; identity = $script:state.agentIdentityId } } }
$script:identity = @{ id = $script:state.agentIdentityId; principalId = $script:state.agentPrincipalId; tenantId = $account.tenantId }
$readerRole = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
$script:assignments = @(@{ scope = $groupId; principalId = $script:state.agentPrincipalId; roleDefinitionId = $readerRole })
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
        'group exists --name' { return $true }
        'group show --name' { return $script:group }
        'vm list --resource-group' { return $script:vm }
        'network nic show' { return $script:nic }
        'network vnet subnet' { return $script:subnet }
        'network nsg show' { return $script:nsg }
        'network nat gateway' { return $script:nat }
        'network public-ip show' { return $script:pip }
        'resource show --ids' { return $script:agent }
        'resource list --resource-group' { return $script:inventory }
        'rest --method get' { return @{ value = $script:extensions } }
        'identity show --ids' { return $script:identity }
        'role assignment list' {
            if ($Arguments -contains '--all' -or $Arguments -notcontains '--scope' -or
                $Arguments -notcontains '--fill-principal-name') { throw 'Scoped Reader readback CLI syntax changed.' }
            return $script:assignments
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
Assert-GuestManifest
$foundation = @{ outputs = @{ SRE_AGENT_ID = $script:state.agentId } }
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
$template = Get-Content (Join-Path $root 'infra\guest-service-target.bicep') -Raw
if ($template -match 'publicIPAddressResourceId|start/action|stop/action|runCommand/action' -or
    $template -notmatch "acdd72a7-3385-48ef-bd42-f606fba81ae7" -or
    ([regex]::Matches($template, "Microsoft.Authorization/roleAssignments@")).Count -ne 1 -or
    $template -notmatch 'principalId: agentPrincipalId' -or
    $template -notmatch 'allowExtensionOperations: true' -or $template -notmatch 'natGatewayResourceId: nat.id' -or
    $template -notmatch 'defaultOutboundAccess: false') { throw 'Fixture infrastructure boundary changed.' }
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
[pscustomobject]@{ checks = $script:checks; outcome = 'passed'; azureWrites = 0 }
