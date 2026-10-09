#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Run this test using Windows PowerShell 5.1 powershell.exe, not pwsh.'
}
$guestPath = Join-Path $PSScriptRoot '..\scripts\price\Invoke-PriceGuest.ps1'
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($guestPath, [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
foreach ($name in @('Assert-HealthyPriceObservation','Invoke-PriceWatchdogCycle')) {
    $function = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    if (-not $function) { throw "Missing controller function: $name" }
    Invoke-Expression $function.Extent.Text
}
$endpoint = 'http://127.0.0.1:18081/price/basket-a/'
$observation = @{
    phase='healthy';endpoint=$endpoint;serviceStatus=200;baselineHttpStatus=200
    contractValid=$true;poolState='Started'
}
$checks = 0
foreach ($case in @(
    @{phase='healthy';minutes=$null;expected='healthy-pool-restored';calls=1},
    @{phase='fault-active';minutes=5;expected='active-fault-preserved';calls=0},
    @{phase='safety-test';minutes=5;expected='active-fault-preserved';calls=0},
    @{phase='fault-active';minutes=-1;expected='expired-fault-recovered';calls=1},
    @{phase='recovering';minutes=-1;expected='recovery-resumed';calls=1}
)) {
    $deadline = if ($null -ne $case.minutes) {
        [DateTimeOffset]::UtcNow.AddMinutes($case.minutes).ToString('o')
    } else { $null }
    $state = @{phase=$case.phase;runId=[guid]::NewGuid().ToString();deadline=$deadline;recoveryActor=$null} |
        ConvertTo-Json | ConvertFrom-Json
    if ($state -isnot [pscustomobject]) { throw 'Test did not deserialize the real guest state type.' }
    $runId = $state.runId
    $script:calls = 0
    $result = Invoke-PriceWatchdogCycle -State $state -Now ([DateTimeOffset]::UtcNow) `
        -GetPoolState { 'Stopped' } `
        -CompleteRecovery {
            $script:calls++
            $state.phase='healthy'
            $state.recoveryActor='independent-watchdog'
            $observation
        } -AssertHealthy { $observation }
    $persisted = $state | ConvertTo-Json | ConvertFrom-Json
    if ($result -cne $case.expected -or $calls -ne $case.calls -or $persisted.runId -cne $runId -or
        ($case.calls -eq 1 -and ($persisted.phase -cne 'healthy' -or
            $persisted.recoveryActor -cne 'independent-watchdog')) -or
        ($case.calls -eq 0 -and $persisted.phase -cne $case.phase)) {
        throw "Windows PowerShell persisted state behavior failed for $($case.phase)."
    }
    $checks++
}
$state = '{"phase":"fault-active","deadline":"invalid"}' | ConvertFrom-Json
$rejected = $false
try {
    Invoke-PriceWatchdogCycle -State $state -Now ([DateTimeOffset]::UtcNow) `
        -GetPoolState { 'Stopped' } -CompleteRecovery { throw 'Invalid deadline must not trigger recovery.' } `
        -AssertHealthy { $observation }
} catch { $rejected = $true }
if (-not $rejected) { throw 'Malformed persisted fault deadline was accepted.' }
$checks++

$operationDispatch = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -ceq "`$Operation -eq 'Watchdog'"
}, $true)
if (-not $operationDispatch) { throw 'Actual guest Watchdog operation dispatch not found.' }
$script:priceState = '{"phase":"healthy","runId":"persisted-run","deadline":null,"watchdogAt":null}' | ConvertFrom-Json
$script:savedState = $null
$script:operationRecoveries = 0
function Get-PricePoolState { return 'Stopped' }
function Complete-PriceRecovery {
    param($Actor)
    if ($Actor -cne 'independent-watchdog') { throw 'Watchdog dispatch changed the recovery actor.' }
    $script:operationRecoveries++
    $script:priceState.phase = 'healthy'
    $observation
}
function Assert-HealthyPriceService { return $observation }
function Save-PriceState {
    $script:savedState = $script:priceState | ConvertTo-Json | ConvertFrom-Json
}
function Write-PriceObservation {
    param($EventName)
    if ($EventName -cne 'watchdog') { throw 'Unexpected observer operation.' }
    return $observation
}
$dispatchSource = ($operationDispatch.Clauses[0].Item2.Statements |
    ForEach-Object { $_.Extent.Text }) -join "`n"
& ([scriptblock]::Create($dispatchSource))
if ($operationRecoveries -ne 1 -or -not $savedState.watchdogAt -or
    [DateTimeOffset]$savedState.watchdogAt -lt [DateTimeOffset]::UtcNow.AddMinutes(-1)) {
    throw 'Actual Watchdog dispatch did not execute recovery and persist its heartbeat.'
}
$checks++
Write-Output "Windows PowerShell $($PSVersionTable.PSVersion) watchdog checks passed: $checks"
