#Requires -Version 7.2
<#
.SYNOPSIS
    Repeats fault/repair cycles (and optionally one VM reboot cycle) against the native,
    non-Arc guest-service fixture to prove three-cycle repeatability and cross-reboot
    watchdog acceptance.

.DESCRIPTION
    Invoke-GuestService.ps1 implements the fixture's lifecycle and a single Fault, Repair,
    Reset or Status operation per invocation; it does not loop. This wrapper shells out to
    it repeatedly and adds the one behaviour it deliberately omits: looping, with evidence
    assertions between iterations. It never stands up or tears down the fixture itself -
    run Invoke-GuestService.ps1 Up first, and Down afterwards when done.

    Each fault/repair cycle:
      1. Confirms the fixture is state.phase='ready' with a proven watchdog
         (evidence.watchdogProof).
      2. Issues a non-canary Fault and captures the fault's RunId.
      3. Polls Status until the guest confirms the fault is active for that RunId.
      4. Issues an operator Repair for that exact RunId.
      5. Polls Status until the guest confirms marker.phase='recovered',
         marker.recoveryReason='repair' and state.phase='ready'.

    If the watchdog has not yet been proven (evidence.watchdogProof is false) and
    -Bootstrap is specified, a one-time 60-second canary Fault is issued first and the
    wrapper waits for the independent in-guest watchdog to self-recover it
    (recoveryReason='deadline') before any requested cycles begin.

    When -IncludeRebootCycle is set, one additional cycle runs after the fault/repair
    cycles: it issues a Fault, restarts the VM through the Azure control plane (never the
    guest), and polls Status - tolerating the guest-command failures expected while the VM
    is unreachable - until the independent watchdog reports marker.phase='recovered' with
    marker.recoveryReason='reboot' and marker.recoveredBy='watchdog'. This is the only
    proof that recovery survives a reboot, since the operator never runs Repair in this
    cycle.

    Every cycle's outcome is recorded in the returned summary. A precondition failure
    (fixture not Up, or watchdog unproven without -Bootstrap) is a terminating error before
    any cycle starts. Once cycles are underway, a failed cycle stops the remaining cycles
    (continuing to inject faults on an unrecovered fixture is unsafe) but the summary for
    every cycle attempted so far is still returned.

.PARAMETER SubscriptionId
    Azure subscription GUID that owns the fixture.

.PARAMETER EnvironmentName
    Fixture environment name. Must already be Up; this script never provisions it.

.PARAMETER FoundationEnvironment
    Name of the Stage 0 foundation environment the fixture reads shared configuration from.

.PARAMETER Cycles
    Number of fault/repair cycles to run before any reboot cycle. Default 3.

.PARAMETER IncludeRebootCycle
    After the fault/repair cycles succeed, run one additional cycle that reboots the VM
    and waits for the independent in-guest watchdog - not the operator - to recover it.

.PARAMETER Bootstrap
    If the fixture has not yet proven its watchdog (evidence.watchdogProof is false),
    issue the one-time 60-second canary Fault and wait for it to self-recover before
    starting the requested cycles. Without this switch, an unproven watchdog is a
    terminating error.

.PARAMETER FaultDurationSeconds
    Duration passed to each non-canary Fault. Default 300, matching
    Invoke-GuestService.ps1's own default and validation range (120-600).

.EXAMPLE
    ./Invoke-GuestServiceCycleTest.ps1 -SubscriptionId $subId -EnvironmentName demo16 `
        -Bootstrap -IncludeRebootCycle

    Proves the watchdog once, runs three fault/repair cycles, then one reboot cycle.

.OUTPUTS
    [pscustomobject] with EnvironmentName, TotalCycles, Success (overall boolean) and
    Cycles (an array of per-cycle [pscustomobject] results: Cycle label, RunId, Success,
    StartedAtUtc, CompletedAtUtc, Attempts, Evidence, and Error when Success is $false).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [string]$EnvironmentName = 'demo16',

    [string]$FoundationEnvironment = 'stage0',

    [ValidateRange(1, 10)]
    [int]$Cycles = 3,

    [switch]$IncludeRebootCycle,

    [switch]$Bootstrap,

    [ValidateRange(120, 600)]
    [int]$FaultDurationSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Stage0.Common.psm1') -Force

Assert-RetailEnvironmentName $EnvironmentName
Assert-Stage0Name $FoundationEnvironment
if ($EnvironmentName -ceq $FoundationEnvironment) {
    throw 'Fixture must not reuse the foundation environment.'
}

$subscription = $SubscriptionId.ToString()
$location = 'swedencentral'
$groupName = "rg-retailtx-guest-$EnvironmentName-$location"
$vmName = "vm-retailtx-guest-$EnvironmentName"
$vmId = "/subscriptions/$subscription/resourceGroups/$groupName/providers/Microsoft.Compute/virtualMachines/$vmName"
$guestServicePath = Join-Path $PSScriptRoot 'Invoke-GuestService.ps1'

function Invoke-Azure {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [int]$TimeoutSeconds = 180
    )
    Invoke-RetailAzure -SubscriptionId $subscription -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Invoke-GuestServiceOp {
    <#
        Shells out to Invoke-GuestService.ps1 for a single Status, Fault or Repair
        operation, always suppressing its own confirmation prompt - this wrapper's single
        top-level ShouldProcess gate already covers the whole run.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Status', 'Fault', 'Repair')]
        [string]$Operation,

        [guid]$RunId,

        [switch]$Canary
    )
    $splat = @{
        SubscriptionId        = $SubscriptionId
        EnvironmentName       = $EnvironmentName
        FoundationEnvironment = $FoundationEnvironment
        Confirm               = $false
    }
    if ($Operation -eq 'Fault') {
        $splat.FaultDurationSeconds = $FaultDurationSeconds
        if ($Canary) { $splat.Canary = $true }
    }
    if ($PSBoundParameters.ContainsKey('RunId')) { $splat.RunId = $RunId }
    & $guestServicePath $Operation @splat
}

function Wait-GuestServiceCondition {
    <#
        Polls Status until $Condition returns $true. Tolerates (and records, without
        failing immediately on) exceptions from Invoke-GuestServiceOp, because the native
        Run Command transport cannot distinguish "VM rebooting" from any other transient
        outage - the only expected failure mode here is the VM being briefly unreachable
        across a restart. Only a full timeout is a terminating error.
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Condition,

        [string]$Description = 'condition',

        [int]$TimeoutSeconds = 600,

        [int]$PollSeconds = 20
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = $null
    $attempts = 0
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $attempts++
        try {
            $status = Invoke-GuestServiceOp -Operation Status
            $lastError = $null
            if (& $Condition $status) {
                return [pscustomobject]@{ Status = $status; Attempts = $attempts; LastError = $null }
            }
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds $PollSeconds
    }
    throw "Timed out waiting for $Description after $attempts attempt(s). Last error: $lastError"
}

function Assert-FixtureReady {
    param([Parameter(Mandatory)]$Status)
    if ($Status.groupExists -ne $true) {
        throw 'Guest-service fixture is not Up. Run Invoke-GuestService.ps1 Up before this wrapper.'
    }
    if ($Status.state.phase -cne 'ready') {
        throw "Fixture is not in a ready state (state.phase='$($Status.state.phase)'). Resolve or Reset before running cycles."
    }
}

function Test-WatchdogProof {
    param($Status)
    [bool]($Status.evidence -and $Status.evidence.watchdogProof)
}

function Invoke-WatchdogBootstrap {
    $startedAtUtc = [DateTimeOffset]::UtcNow
    $faultResult = Invoke-GuestServiceOp -Operation Fault -Canary
    $runId = [guid]::Parse($faultResult.evidence.marker.runId)
    $wait = Wait-GuestServiceCondition -Description 'canary watchdog self-recovery' -TimeoutSeconds 300 -Condition {
        param($s)
        $s.evidence.marker -and $s.evidence.marker.runId -ceq $runId.ToString() -and
            $s.evidence.marker.phase -ceq 'recovered' -and
            $s.evidence.marker.recoveryReason -ceq 'deadline' -and
            $s.evidence.watchdogProof
    }
    [pscustomobject]@{
        Cycle         = 'bootstrap-canary'; RunId = $runId; Success = $true
        StartedAtUtc  = $startedAtUtc; CompletedAtUtc = [DateTimeOffset]::UtcNow
        Attempts      = $wait.Attempts; Evidence = $wait.Status.evidence; Error = $null
    }
}

function Invoke-FaultRepairCycle {
    param([Parameter(Mandatory)][string]$CycleLabel)

    $startedAtUtc = [DateTimeOffset]::UtcNow
    $preStatus = Invoke-GuestServiceOp -Operation Status
    Assert-FixtureReady -Status $preStatus
    if (-not (Test-WatchdogProof $preStatus)) {
        throw "Watchdog proof was lost before $CycleLabel; re-run with -Bootstrap."
    }

    $faultResult = Invoke-GuestServiceOp -Operation Fault
    $runId = [guid]::Parse($faultResult.evidence.marker.runId)

    $null = Wait-GuestServiceCondition -Description "$CycleLabel fault-active confirmation" -TimeoutSeconds 180 -Condition {
        param($s)
        $s.evidence.marker -and $s.evidence.marker.runId -ceq $runId.ToString() -and
            $s.evidence.marker.phase -cnotin @('recovered', 'cancelled')
    }

    $null = Invoke-GuestServiceOp -Operation Repair -RunId $runId

    $repairWait = Wait-GuestServiceCondition -Description "$CycleLabel repair confirmation" -TimeoutSeconds 180 -Condition {
        param($s)
        $s.evidence.marker -and $s.evidence.marker.runId -ceq $runId.ToString() -and
            $s.evidence.marker.phase -ceq 'recovered' -and
            $s.evidence.marker.recoveryReason -ceq 'repair' -and
            $s.state.phase -ceq 'ready'
    }

    [pscustomobject]@{
        Cycle         = $CycleLabel; RunId = $runId; Success = $true
        StartedAtUtc  = $startedAtUtc; CompletedAtUtc = [DateTimeOffset]::UtcNow
        Attempts      = $repairWait.Attempts; Evidence = $repairWait.Status.evidence; Error = $null
    }
}

function Invoke-RebootCycle {
    $startedAtUtc = [DateTimeOffset]::UtcNow
    $preStatus = Invoke-GuestServiceOp -Operation Status
    Assert-FixtureReady -Status $preStatus
    if (-not (Test-WatchdogProof $preStatus)) {
        throw 'Watchdog proof was lost before the reboot cycle; re-run with -Bootstrap.'
    }

    $faultResult = Invoke-GuestServiceOp -Operation Fault
    $runId = [guid]::Parse($faultResult.evidence.marker.runId)
    $deadline = [DateTimeOffset]::Parse($faultResult.evidence.marker.deadlineUtc)

    if ([DateTimeOffset]::UtcNow.AddSeconds(90) -ge $deadline) {
        throw "Reboot cycle aborted: fault deadline $deadline leaves too little headroom for a safe restart. Increase -FaultDurationSeconds."
    }

    $null = Invoke-Azure @('vm', 'restart', '--ids', $vmId, '--no-wait')
    Start-Sleep -Seconds 90

    $pollTimeout = [Math]::Max(300, [int]($deadline - [DateTimeOffset]::UtcNow).TotalSeconds + 300)
    $rebootWait = Wait-GuestServiceCondition -Description 'post-reboot watchdog recovery' `
        -TimeoutSeconds $pollTimeout -PollSeconds 20 -Condition {
        param($s)
        $s.evidence.marker -and $s.evidence.marker.runId -ceq $runId.ToString() -and
            $s.evidence.marker.phase -ceq 'recovered' -and
            $s.evidence.marker.recoveryReason -ceq 'reboot' -and
            $s.evidence.marker.recoveredBy -ceq 'watchdog'
    }

    [pscustomobject]@{
        Cycle         = 'reboot'; RunId = $runId; Success = $true
        StartedAtUtc  = $startedAtUtc; CompletedAtUtc = [DateTimeOffset]::UtcNow
        Attempts      = $rebootWait.Attempts; Evidence = $rebootWait.Status.evidence; Error = $null
    }
}

function New-FailedCycleResult {
    param([Parameter(Mandatory)][string]$CycleLabel, [Parameter(Mandatory)]$ErrorRecord)
    [pscustomobject]@{
        Cycle = $CycleLabel; RunId = $null; Success = $false
        StartedAtUtc = $null; CompletedAtUtc = [DateTimeOffset]::UtcNow
        Attempts = $null; Evidence = $null; Error = $ErrorRecord.Exception.Message
    }
}

$actionDescription = "Run $Cycles fault/repair cycle(s)$(if ($IncludeRebootCycle) { ' plus one reboot cycle' })"
if ($PSCmdlet.ShouldProcess($vmId, $actionDescription)) {
    $initialStatus = Invoke-GuestServiceOp -Operation Status
    Assert-FixtureReady -Status $initialStatus

    $cycleResults = [System.Collections.Generic.List[object]]::new()
    $aborted = $false

    if (-not (Test-WatchdogProof $initialStatus)) {
        if (-not $Bootstrap) {
            throw 'Watchdog has not been proven yet (evidence.watchdogProof is false). Re-run with -Bootstrap to establish it with a one-time 60-second canary fault.'
        }
        try {
            $cycleResults.Add((Invoke-WatchdogBootstrap))
        } catch {
            $cycleResults.Add((New-FailedCycleResult -CycleLabel 'bootstrap-canary' -ErrorRecord $_))
            $aborted = $true
        }
    }

    for ($i = 1; (-not $aborted) -and ($i -le $Cycles); $i++) {
        try {
            $cycleResults.Add((Invoke-FaultRepairCycle -CycleLabel "fault-repair-$i"))
        } catch {
            $cycleResults.Add((New-FailedCycleResult -CycleLabel "fault-repair-$i" -ErrorRecord $_))
            $aborted = $true
        }
    }

    if ($IncludeRebootCycle -and -not $aborted) {
        try {
            $cycleResults.Add((Invoke-RebootCycle))
        } catch {
            $cycleResults.Add((New-FailedCycleResult -CycleLabel 'reboot' -ErrorRecord $_))
            $aborted = $true
        }
    }

    $overallSuccess = -not $aborted -and -not ($cycleResults | Where-Object { -not $_.Success })

    [pscustomobject]@{
        EnvironmentName = $EnvironmentName
        TotalCycles     = $cycleResults.Count
        Success         = [bool]$overallSuccess
        Cycles          = $cycleResults.ToArray()
    }
}
