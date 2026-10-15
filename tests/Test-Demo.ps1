#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'scripts\Invoke-Demo.ps1'), [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
foreach ($name in @('Get-DemoRouting', 'Assert-DemoArmSettled', 'Test-DemoNativeRemovalNeeded')) {
    $node = $ast.Find({
        param($candidate)
        $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$EnvironmentName = 'demo01'
$script:agent = @{ tags = @{ ownerToken = 'owner' }; properties = @{
    agentEndpoint = 'https://demo.azuresre.ai'; actionConfiguration = @{ mode = 'Review'; identity = 'identity' }
    incidentManagementConfiguration = @{ type = 'AzMonitor' }
} }
$script:plan = @{ name = 'retailtx-guest-demo01'; properties = @{
    agentMode = 'review'; handlingAgent = 'retailtx-guest-demo01'; titleContains = 'demo01'
    mergeEnabled = $false; isEnabled = $true
    azMonitorFilterSettings = @{ targetResource = 'vm'; targetResourceType = 'Microsoft.Compute/virtualMachines' }
} }
$script:alert = @{ tags = @{ ownerToken = 'owner' }; properties = @{ enabled = $true } }
$state = @{ ownerToken = 'owner'; agentId = 'agent'; agentIdentityId = 'identity'; vmId = 'vm'; alertId = 'alert'
    groupId = 'group'; journal = @() }
$script:azureCalls = 0
function Invoke-Azure {
    param([string[]]$Arguments)
    $script:azureCalls++
    if ($Arguments[0] -ceq 'deployment') { return $script:deployment }
    if ($Arguments -contains 'agent') { return $script:agent }
    return $script:alert
}
function Invoke-DiskSreRequest { return $script:plan }
if (-not (Get-DemoRouting $state).armed) { throw 'Valid route rejected.' }
$checks = 1
foreach ($target in @('alert', 'plan', 'platform')) {
    switch ($target) {
        alert { $script:alert.properties.enabled = $false }
        plan { $script:plan.properties.isEnabled = $false }
        platform { $script:agent.properties.incidentManagementConfiguration.type = 'None' }
    }
    $blocked = $false
    try { $blocked = -not (Get-DemoRouting $state).armed } catch { $blocked = $true }
    if (-not $blocked) { throw 'Disabled intake accepted.' }
    $script:alert.properties.enabled = $true
    $script:plan.properties.isEnabled = $true
    $script:agent.properties.incidentManagementConfiguration.type = 'AzMonitor'
    $checks++
}
$state.journal = @(@{ action = 'monitor-deploy'; enabled = $true; outcome = 'intent'
    intentAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o') })
$script:deployment = @{ properties = @{
    provisioningState = 'Succeeded'; timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    parameters = @{ enableAlert = @{ value = $true } }; outputs = @{ alertId = @{ value = 'alert' } }
} }
Assert-DemoArmSettled $state
$checks++
foreach ($status in @('Running', 'Failed', 'Canceled')) {
    $script:deployment.properties.provisioningState = $status
    $blocked = $false
    try { Assert-DemoArmSettled $state } catch { $blocked = $true }
    if (-not $blocked) { throw 'Unsettled Arm accepted.' }
    $checks++
}
$before = $script:azureCalls
$state.journal[0].outcome = 'deployment-succeeded'
Assert-DemoArmSettled $state
if ($before -ne $script:azureCalls) { throw 'Settled Arm unnecessarily queried/replayed deployment.' }
$checks++
$config = @{ endpoint = 'https://demo.azuresre.ai' }
$native = @{ ownerToken = 'owner'; endpoint = $config.endpoint; phase = 'Removed' }
$script:groupPresent = $false
$script:parentPresent = $false
function Invoke-Azure {
    param([string[]]$Arguments)
    if ($Arguments[0] -ceq 'group') { return $script:groupPresent }
    if ($Arguments[0] -ceq 'resource' -and $Arguments[1] -ceq 'list') {
        if ($script:parentPresent) { return @{ id = 'agent' } }
        return @()
    }
    throw 'Deleted parent teardown tried to call its former endpoint.'
}
if (Test-DemoNativeRemovalNeeded $state $native $config) { throw 'Deleted group requires an unavailable endpoint.' }
$script:groupPresent = $true
if (Test-DemoNativeRemovalNeeded $state $native $config) { throw 'Absent agent requires an unavailable endpoint.' }
$script:parentPresent = $true
if (-not (Test-DemoNativeRemovalNeeded $state $native $config)) { throw 'Existing agent should be independently checked.' }
$native.phase = 'ConfiguredNotLiveAccepted'
if (-not (Test-DemoNativeRemovalNeeded $state $native $config)) { throw 'Unremoved native assets skipped.' }
$native.ownerToken = 'foreign'
$blocked = $false
try { $null = Test-DemoNativeRemovalNeeded $state $native $config } catch { $blocked = $true }
if (-not $blocked) { throw 'Foreign native journal accepted.' }
$checks += 5
$name = 'dry' + [guid]::NewGuid().ToString('N').Substring(0, 8)
& (Join-Path $root 'scripts\Invoke-Demo.ps1') Up -SubscriptionId ([guid]::NewGuid()) -EnvironmentName $name -WhatIf
if (Test-Path (Join-Path $root ".azure\$name")) { throw 'WhatIf wrote local deployment state.' }
$checks++
Write-Output "Demo wrapper passed ($checks checks; mocked reads and no live writes)."
