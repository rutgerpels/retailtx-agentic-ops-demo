#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:checks = 0
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'An unsafe action was accepted.' }
    $script:checks++
}
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '..\scripts\Invoke-NativeAction.ps1'), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
foreach ($name in @('Get-OwnedGroup', 'Get-OwnedRole', 'Get-OwnedVm', 'Get-PowerState',
    'Restore-OwnedVm', 'Complete-FaultRecovery', 'Remove-OwnedActionResources')) {
    $function = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}
$subscription = '11111111-1111-1111-1111-111111111111'
$EnvironmentName = 'demo02'
$location = 'swedencentral'
$groupName = 'rg-retailtx-action-demo02-swedencentral'
$groupId = "/subscriptions/$subscription/resourceGroups/$groupName"
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-retailtx-action-demo02"
$script:state = @{
    ownerToken = '22222222-2222-2222-2222-222222222222'
    roleDefinitionName = '33333333-3333-3333-3333-333333333333'
    roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/33333333-3333-3333-3333-333333333333"
    agentPrincipalId = '55555555-5555-5555-5555-555555555555'
}
$script:group = @{
    id = $groupId; location = $location
    tags = @{ demo = 'retailtx'; environmentId = $EnvironmentName; profile = 'native-action'
        managedBy = 'retailtx'; ownerToken = $script:state.ownerToken }
}
$script:role = @{
    id = $script:state.roleDefinitionId; roleType = 'CustomRole'
    description = "RetailTx native action proof; ownerToken=$($script:state.ownerToken)"
    assignableScopes = @($groupId)
    permissions = @(@{ actions = @('Microsoft.Compute/virtualMachines/start/action')
        notActions = @(); dataActions = @(); notDataActions = @() })
}
$script:vm = @{ id = $vmId; tags = @{ ownerToken = $script:state.ownerToken; profile = 'native-action' } }
$script:statuses = @(@{ code = 'PowerState/running' })
$script:exists = $true
$script:powerFailures = 0
$script:starts = 0
$script:deletes = [Collections.Generic.List[string]]::new()
$script:assignments = @()
function Invoke-Azure {
    param([string[]]$Arguments)
    switch ("$($Arguments[0]) $($Arguments[1])") {
        'group exists' { return $script:exists }
        'group show' { return $script:group }
        'role definition' {
            if ($Arguments[2] -eq 'delete') { $script:deletes.Add('role'); $script:role = $null; return }
            if ($script:role) { return $script:role }; return
        }
        'role assignment' {
            if ($Arguments[2] -eq 'delete') { $script:deletes.Add('assignment'); return }
            return $script:assignments
        }
        'group delete' { $script:deletes.Add('group'); $script:exists = $false; return }
        'vm list' { if ($script:vm) { return $script:vm }; return }
        'vm start' { $script:starts++; $script:statuses = @(@{ code = 'PowerState/running' }); return }
        'vm get-instance-view' {
            if ($script:powerFailures -gt 0) { $script:powerFailures--; throw [TimeoutException]::new('Simulated CLI timeout.') }
            return @{ instanceView = @{ statuses = $script:statuses } }
        }
        default { throw 'Unexpected mutation in read-only boundary check.' }
    }
}
$null = Get-OwnedGroup
$null = Get-OwnedRole
$null = Get-OwnedVm
if ((Get-PowerState) -cne 'PowerState/running') { throw 'Power state was not read.' }
$script:checks++
foreach ($key in @('demo', 'environmentId', 'profile', 'managedBy', 'ownerToken')) {
    $old = $script:group.tags[$key]
    $script:group.tags[$key] = 'foreign'
    Assert-Rejected { Get-OwnedGroup }
    $script:group.tags[$key] = $old
}
$script:vm.tags.ownerToken = 'foreign'
Assert-Rejected { Get-OwnedVm }
Assert-Rejected { Get-OwnedVm -AllowAbsent }
Assert-Rejected { Restore-OwnedVm }
if ($script:starts -ne 0) { throw 'Recovery must not mutate a foreign VM.' }
$script:vm.tags.ownerToken = $script:state.ownerToken
$ownedVm = $script:vm
$script:vm = $null
if (Get-OwnedVm -AllowAbsent) { throw 'Confirmed VM absence must permit partial deployment recovery.' }
$script:checks++
Assert-Rejected { Get-OwnedVm }
$script:vm = $ownedVm
$script:powerFailures = 1
if (-not (Restore-OwnedVm -WarningAction SilentlyContinue) -or $script:starts -ne 1) {
    throw 'A power-state timeout must attempt the owned idempotent recovery.'
}
$script:checks++
if (Restore-OwnedVm) { throw 'A running VM must not be attributed to operator recovery.' }
$script:checks++
$statePath = 'unused-test-state'
function Save-RetailState { param([hashtable]$State, [string]$Path) }
$script:state.faultEndedAt = $null
Assert-Rejected { Complete-FaultRecovery }
if ($script:state.phase -cne 'recovery-required' -or $script:state.faultEndedAt -or $script:starts -ne 2) {
    throw 'An uncertain stop followed by a running snapshot must not publish recovery.'
}
$script:checks++
# A late stop still needs recovery rather than trusting the earlier running snapshot.
$script:statuses = @(@{ code = 'PowerState/stopped' })
if (-not (Complete-FaultRecovery -StopConfirmed) -or $script:state.phase -cne 'ready' -or $script:starts -ne 3) {
    throw 'Confirmed late stop was not recovered.'
}
$script:checks++
$script:role.assignableScopes = @("/subscriptions/$subscription")
Assert-Rejected { Get-OwnedRole }
$script:role.assignableScopes = @($groupId)
$script:role.permissions[0].actions += '*'
Assert-Rejected { Get-OwnedRole }
$script:role.permissions[0].actions = @('Microsoft.Compute/virtualMachines/start/action')
$script:role.description = 'foreign owner'
Assert-Rejected { Get-OwnedRole }
$script:role.description = "RetailTx native action proof; ownerToken=$($script:state.ownerToken)"
$script:role.permissions[0].dataActions = @('*')
Assert-Rejected { Get-OwnedRole }
$script:role.permissions[0].dataActions = @()
$script:statuses = @()
Assert-Rejected { Get-PowerState }
$script:statuses = @(@{ code = 'PowerState/running' }, @{ code = 'PowerState/stopped' })
Assert-Rejected { Get-PowerState }
$ownedRole = $script:role
$script:assignments = @(@{ id = 'owned-assignment'; scope = $vmId; principalId = $script:state.agentPrincipalId },
    @{ id = 'unexpected-assignment'; scope = $groupId; principalId = $script:state.agentPrincipalId })
Assert-Rejected { Remove-OwnedActionResources $script:group $script:role }
if ($script:deletes.Count -ne 0) { throw 'All assignments must be validated before any deletion.' }
$script:assignments = @($script:assignments[0])
Remove-OwnedActionResources $script:group $script:role
if (($script:deletes -join ',') -cne 'assignment,role,group') { throw 'Incorrect teardown ordering.' }
$script:checks++
$script:deletes.Clear()
Remove-OwnedActionResources $null $null
if ($script:deletes.Count -ne 0) { throw 'Repeat teardown must not perform deletes.' }
$script:checks++
$script:role = $ownedRole
$script:assignments = @()
Remove-OwnedActionResources $null $script:role
if (($script:deletes -join ',') -cne 'role') { throw 'External-role-only cleanup failed.' }
$script:checks++
$script:deletes.Clear()
$script:exists = $true
Remove-OwnedActionResources $script:group $null
if (($script:deletes -join ',') -cne 'group') { throw 'Group-only partial cleanup failed.' }
$script:checks++
$script:exists = $false
$script:role = $null
if ((Get-OwnedGroup) -or (Get-OwnedRole)) { throw 'Repeat teardown must accept confirmed absence.' }
$script:checks++
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '..\scripts\Invoke-SreProof.ps1'), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
$confirmation = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Extent.Text -like '*ShouldProcess($execution.command*'
}, $true)
$refresh = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Invoke-Sre' -and $node.Extent.Text -like '*/status"*'
}, $true)
if (-not $confirmation -or -not $refresh -or $confirmation.Extent.StartOffset -ge $refresh.Extent.StartOffset) {
    throw 'Live approval revalidation must occur after any interactive confirmation.'
}
$script:checks++
foreach ($name in @('Assert-ExactStartCommand', 'Assert-ExactStartProposal', 'Get-StartExecution')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$expected = "az vm start --ids $vmId --subscription $subscription"
$execution = @{
    id = '44444444-4444-4444-4444-444444444444'; status = 'Pending'; command = $expected
    originalFunctionCall = (@{ Name = 'RunAzCliWriteCommands'; Arguments = @{ command = $expected } } | ConvertTo-Json -Depth 5)
    expiredByTimeout = $false; startedTimestamp = $null; completedTimestamp = $null; requiredScopes = $null
}
Assert-ExactStartProposal $execution $expected
$script:checks++
$readExecution = @{ command = "az vm get-instance-view --ids $vmId"; status = 'Completed' }
if (@(Get-StartExecution @($readExecution, $execution) $expected).Count -ne 1) {
    throw 'Completed read-only CLI cards must not be counted as VM-start executions.'
}
$script:checks++
foreach ($command in @("$expected; az vm delete", "$expected --no-wait", $expected.Replace('demo02', 'demo03'),
    $expected.Replace('start', 'restart'), $expected.Replace($subscription, '55555555-5555-5555-5555-555555555555'))) {
    $execution.command = $command
    Assert-Rejected { Assert-ExactStartProposal $execution $expected }
}
$execution.command = $expected
$execution.originalFunctionCall = (@{ Name = 'RunInTerminal'; Arguments = @{ command = $expected } } | ConvertTo-Json -Depth 5)
Assert-Rejected { Assert-ExactStartProposal $execution $expected }
$execution.originalFunctionCall = (@{ Name = 'RunAzCliWriteCommands'; Arguments = @{ command = "$expected; echo unexpected" } } | ConvertTo-Json -Depth 5)
Assert-Rejected { Assert-ExactStartProposal $execution $expected }
$execution.originalFunctionCall = (@{ Name = 'RunAzCliWriteCommands'; Arguments = @{ command = $expected; extra = 'unexpected' } } | ConvertTo-Json -Depth 5)
Assert-Rejected { Assert-ExactStartProposal $execution $expected }
$execution.originalFunctionCall = (@{ Name = 'RunAzCliWriteCommands'; Arguments = @{ command = $expected } } | ConvertTo-Json -Depth 5)
foreach ($status in @('PendingAuthorization', 'Running', 'Completed', 'Cancelled', 'Failed')) {
    $execution.status = $status
    Assert-Rejected { Assert-ExactStartProposal $execution $expected }
}
$execution.status = 'Pending'
$execution.expiredByTimeout = $true
Assert-Rejected { Assert-ExactStartProposal $execution $expected }
$execution.expiredByTimeout = $false
$execution.startedTimestamp = '2026-01-01T00:00:00Z'
Assert-Rejected { Assert-ExactStartProposal $execution $expected }
$execution.startedTimestamp = $null
$execution.requiredScopes = @('user_impersonation')
Assert-Rejected { Assert-ExactStartProposal $execution $expected }
$definition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-CurrentFault'
}, $true)
. ([scriptblock]::Create($definition.Extent.Text))
$latest = @{
    ownerToken = $script:state.ownerToken; vmId = $vmId; phase = 'fault-active'
    faultStartedAt = [DateTimeOffset]::UtcNow.ToString('o')
    faultDeadline = [DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o')
}
$threadState = @{ faultStartedAt = $latest.faultStartedAt; faultDeadline = $latest.faultDeadline }
Assert-CurrentFault $latest $threadState $script:state.ownerToken $vmId
$script:checks++
$threadState.faultStartedAt = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
Assert-Rejected { Assert-CurrentFault $latest $threadState $script:state.ownerToken $vmId }
$threadState.faultStartedAt = $latest.faultStartedAt
$threadState.faultDeadline = [DateTimeOffset]::UtcNow.AddMinutes(4).ToString('o')
Assert-Rejected { Assert-CurrentFault $latest $threadState $script:state.ownerToken $vmId }
$threadState.faultDeadline = $latest.faultDeadline
Assert-Rejected { Assert-CurrentFault $latest $threadState 'foreign' $vmId }
Assert-Rejected { Assert-CurrentFault $latest $threadState $script:state.ownerToken "$vmId-foreign" }
$latest.phase = 'healthy'
Assert-Rejected { Assert-CurrentFault $latest $threadState $script:state.ownerToken $vmId }
$latest.phase = 'fault-active'
$latest.faultDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30).ToString('o')
$threadState.faultDeadline = $latest.faultDeadline
Assert-Rejected { Assert-CurrentFault $latest $threadState $script:state.ownerToken $vmId }
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '..\scripts\Azure.Common.psm1'), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
$definition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-RetailAzure'
}, $true)
. ([scriptblock]::Create($definition.Extent.Text))
$script:fakeAzureExecutable = (Get-Command python -ErrorAction Stop).Source
function Get-Command {
    param([string]$Name, [string]$ErrorAction)
    if ($Name -cne 'az') { throw 'Unexpected executable lookup.' }
    return @{ Source = $script:fakeAzureExecutable }
}
$arguments = @('a path with spaces', 'https://example.invalid/?a=1&b=two words', 'a "quoted" value')
$received = @(Invoke-RetailAzure -SubscriptionId $subscription -TimeoutSeconds 10 -Arguments (
    @('-c', 'import sys,json; assert sys.stdin.read() == ""; print(json.dumps(sys.argv[1:]))') + $arguments))
for ($index = 0; $index -lt $arguments.Count; $index++) {
    if ($received[$index] -cne $arguments[$index]) { throw 'CLI argument-array handling changed argument data.' }
}
$script:checks++
$timer = [Diagnostics.Stopwatch]::StartNew()
Assert-Rejected { Invoke-RetailAzure -SubscriptionId $subscription -TimeoutSeconds 1 -Arguments @('-c', 'import time; time.sleep(10)') }
if ($timer.Elapsed.TotalSeconds -gt 5) { throw 'CLI timeout did not bound the child process.' }
"Passed $script:checks native-action ownership and state checks."
