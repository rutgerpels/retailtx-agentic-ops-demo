#Requires -Version 7.2
<#
.SYNOPSIS
Repeat the supervised native SRE VM-start integration gate against an existing fixture.
.DESCRIPTION
Stops the owned fixture, requests a native SRE proposal and explicitly approves
only the exact command through Invoke-SreProof. The independent fault job must
observe recovery without intervening. Evidence remains in ignored .azure files.
This is automated authorization, not a human/customer rehearsal. Inspect the
saved hybrid evidence and Azure Activity Log identity separately before accepting
the wider demo gate. Leaves the fixture running; invoke Down to remove it.
.PARAMETER SubscriptionId
Authorized Azure subscription containing the existing native-action fixture.
.PARAMETER EnvironmentName
Existing fixture environment.
.PARAMETER Cycles
Number of consecutive attempts. A failed attempt stops the test.
.PARAMETER AutomatedApproval
Explicit acknowledgement that this test programmatically approves native actions.
.EXAMPLE
.\tests\Test-SreProof.Live.ps1 -SubscriptionId <guid> -AutomatedApproval
.OUTPUTS
Per-attempt thread ID, UTC times and measured recovery duration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo02',
    [ValidateRange(1, 3)][int]$Cycles = 3,
    [switch]$AutomatedApproval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $AutomatedApproval) { throw 'This live test requires explicit -AutomatedApproval.' }
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\Azure.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
$lifecycle = Join-Path $root 'scripts\Invoke-NativeAction.ps1'
$proof = Join-Path $root 'scripts\Invoke-SreProof.ps1'
$directory = Join-Path $root ".azure\$EnvironmentName"
$statePath = Join-Path $directory 'native-action-state.json'
$parameters = @{ SubscriptionId = $SubscriptionId; EnvironmentName = $EnvironmentName }
$runId = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$results = @()
for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $started = [DateTimeOffset]::UtcNow
    $guard = Start-Job -ArgumentList $lifecycle, $SubscriptionId, $EnvironmentName -ScriptBlock {
        param($Path, $Subscription, $Environment)
        $ErrorActionPreference = 'Stop'
        & $Path Fault -SubscriptionId $Subscription -EnvironmentName $Environment -FaultDurationSeconds 600
    }
    $threadId = $null
    $approved = $false
    $verificationSent = $false
    try {
        do {
            if ($guard.State -in @('Completed', 'Failed', 'Stopped')) {
                $null = Receive-Job $guard -ErrorAction Stop
                throw 'Fault guard ended before a new supervised fault became active.'
            }
            if ([DateTimeOffset]::UtcNow -gt $started.AddMinutes(2)) { throw 'Fault startup timed out.' }
            Start-Sleep -Seconds 2
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        } until ($state.phase -ceq 'fault-active' -and [DateTimeOffset]$state.faultStartedAt -ge $started)
        $proposed = & $proof Propose @parameters
        $threadId = $proposed.threadId
        do {
            if ([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$state.faultDeadline) {
                throw 'SRE did not finish within the supervised fault window.'
            }
            Start-Sleep -Seconds 10
            $observed = & $proof Read @parameters -ThreadId $threadId
            $pending = @($observed.executions | Where-Object status -In @('Pending', 'PendingAuthorization'))
            if (-not $approved -and $pending.Count -gt 0) {
                $null = & $proof Approve @parameters -ThreadId $threadId -AutomatedApproval
                $approved = $true
            }
            if (@($observed.startExecutions | Where-Object status -In @('Failed', 'Cancelled')).Count -gt 0) {
                throw 'Native execution failed or was cancelled.'
            }
            if ($approved -and -not $verificationSent -and $observed.state -ceq 'Idle' -and
                @($observed.startExecutions | Where-Object status -CEQ 'Completed').Count -eq 1) {
                $observed = & $proof Verify @parameters -ThreadId $threadId
                $verificationSent = $true
            }
        } until ($verificationSent -and $observed.state -ceq 'Idle' -and $observed.lastAgentMessageAt -and
            [DateTimeOffset]$observed.lastAgentMessageAt -gt [DateTimeOffset]$observed.verificationRequestedAt)
        if (-not (Wait-Job $guard -Timeout 60)) { throw 'Recovery guard did not finish after native completion.' }
        $null = Receive-Job $guard -ErrorAction Stop
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        if ($state.operatorRecovery -ne $false -or -not $state.faultEndedAt) {
            throw 'Operator fallback is not successful SRE recovery.'
        }
        $status = & $lifecycle Status @parameters
        if ($status.powerState -cne 'PowerState/running') { throw 'Independent VM recovery check failed.' }
        $result = @{
            cycle = $cycle; threadId = $threadId; authorization = 'automated-not-human'
            faultStartedAt = $state.faultStartedAt; faultEndedAt = $state.faultEndedAt
            completedAt = [DateTimeOffset]::UtcNow.ToString('o')
            recoverySeconds = ([DateTimeOffset]$state.faultEndedAt - [DateTimeOffset]$state.faultStartedAt).TotalSeconds
            totalSeconds = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$state.faultStartedAt).TotalSeconds
            operatorRecovery = $state.operatorRecovery
        }
        if ($result.totalSeconds -gt 720) { throw 'Recovery and incident note exceeded the 12-minute target.' }
        $results += $result
        Save-RetailState @{ runId = $runId; results = $results } (Join-Path $directory "sre-rehearsal-$runId.json")
        [pscustomobject]$result
    } finally {
        # Do not kill the independent recovery job when diagnosis or approval fails.
        if (-not (Wait-Job $guard -Timeout 660)) {
            throw 'Recovery guard exceeded its deadline; inspect the VM and use Reset after releasing its lock.'
        }
        try { $null = Receive-Job $guard -ErrorAction Stop }
        finally { Remove-Job $guard }
    }
}
