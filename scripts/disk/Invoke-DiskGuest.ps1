#Requires -Version 5.1
<#
.SYNOPSIS
Inject or undo bounded pressure on the owned, disposable four-GiB data disk.
.DESCRIPTION
Never fills C: or the Windows temporary disk. A SYSTEM scheduled task cleans up
expired pressure independently of Arc, SRE and the operator's laptop. IIS stays
healthy: this scenario demonstrates a capacity incident, not a retail outage.
.PARAMETER Operation
Install, Status, SafetyTest, Fault, Recover or Watchdog. Install is provisioning-only.
SafetyTest creates only a one-MiB canary for independent timer/reboot recovery.
.PARAMETER OwnerToken
Ownership GUID from this host's deployment manifest.
.PARAMETER RunId
Unique fault GUID; required for Fault and Recover to reject stale remediation.
.PARAMETER DurationSeconds
Maximum pressure duration, including injection time. Watchdog runs every minute.
.PARAMETER Undo
Equivalent to Recover, with the same required RunId.
.EXAMPLE
.\Invoke-DiskGuest.ps1 Recover -OwnerToken <guid> -RunId <guid>
.OUTPUTS
JSON status and real Windows Application events. No synthetic observations.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Install', 'Status', 'SafetyTest', 'Fault', 'Recover', 'Watchdog')][string]$Operation = 'Status',
    [Parameter(Mandatory)][guid]$OwnerToken,
    [guid]$RunId = [guid]::Empty,
    [ValidateRange(60, 1800)][int]$DurationSeconds = 1200,
    [switch]$Undo
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Undo) { $Operation = 'Recover' }
$directory = 'C:\ProgramData\RetailTxDisk'
$statePath = "$directory\disk-state.json"
$dataDirectory = 'R:\RetailTxDisk'
$taskName = 'RetailTxDiskWatchdog'
$owner = $OwnerToken.ToString()
if ($Operation -in @('SafetyTest', 'Fault', 'Recover') -and (-not $RunId -or $RunId -eq [guid]::Empty)) { throw 'A specific fault RunId is required.' }

function Assert-TestDisk {
    param($Disk)
    if ($Disk.IsBoot -or $Disk.IsSystem -or $Disk.Size -ne 4GB -or $Disk.BusType -notin @('SCSI', 'SAS')) {
        throw 'Not the dedicated four-GiB SCSI/SAS data disk; refusing disk operations.'
    }
}
function Assert-PlainPath {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse points are not allowed: $Path" }
}
function Get-TestVolume {
    $partition = Get-Partition -DriveLetter R
    $disk = Get-Disk -Number $partition.DiskNumber
    Assert-TestDisk $disk
    $volume = Get-Volume -DriveLetter R
    if ($volume.FileSystemLabel -cne 'RETAILTXTEST' -or $volume.FileSystemType -ne 'NTFS' -or
        $disk.UniqueId -cne $script:state.diskUniqueId -or $volume.UniqueId -cne $script:state.volumeUniqueId -or
        $partition.PartitionNumber -ne $script:state.partitionNumber -or $volume.Size -gt 4GB -or $volume.Size -lt 3GB) {
        throw 'Test volume identity or filesystem changed.'
    }
    foreach ($path in @('R:\', $dataDirectory, "$dataDirectory\owner.txt")) { Assert-PlainPath $path }
    if ((Get-Content -LiteralPath "$dataDirectory\owner.txt" -Raw).Trim() -cne $owner) { throw 'Test volume owner mismatch.' }
    return $volume
}
function Save-GuestState {
    $script:state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$statePath.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$statePath.tmp" -Destination $statePath -Force
}
function New-PressureFile {
    param([guid]$FaultId)
    # Reserve the ID for the fixture lifetime, including failed attempts.
    $receipt = [IO.File]::Open("$directory\run-$FaultId.id", 'CreateNew', 'Write', 'None')
    $receipt.Dispose()
    return [IO.File]::Open("$dataDirectory\pressure-$FaultId.bin", 'CreateNew', 'Write', 'None')
}
function Remove-Pressure {
    param([string]$Actor)
    $null = Get-TestVolume
    $run = [guid]::Parse($script:state.runId).ToString()
    $path = "$dataDirectory\pressure-$run.bin"
    if (Test-Path -LiteralPath $path) {
        Assert-PlainPath $path
        Remove-Item -LiteralPath $path -Force
    }
    if (Test-Path -LiteralPath $path) { throw 'Pressure file remains after recovery.' }
    $volume = Get-TestVolume
    if ($volume.SizeRemaining / $volume.Size -lt 0.75) { throw 'Volume is not healthy after owned-file removal.' }
    $script:state.phase = 'healthy'
    $script:state.recoveryActor = $Actor
    $script:state.recoveredAt = [DateTimeOffset]::UtcNow.ToString('o')
    Save-GuestState
}
function Write-Observation {
    param([string]$Event)
    $volume = Get-TestVolume
    $http = (Invoke-WebRequest -Uri 'http://localhost/health.txt' -UseBasicParsing -TimeoutSec 10).StatusCode
    $result = [ordered]@{
        event = $Event; ownerToken = $owner; runId = $script:state.runId; phase = $script:state.phase
        observedAt = [DateTimeOffset]::UtcNow.ToString('o'); volume = 'R:'
        freeBytes = $volume.SizeRemaining; freePercent = [Math]::Round(100 * $volume.SizeRemaining / $volume.Size, 2)
        iisHttpStatus = $http; deadline = $script:state.deadline
        recoveryActor = $script:state.recoveryActor; recoveredAt = $script:state.recoveredAt
        watchdogAt = $script:state.watchdogAt
        bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    }
    $json = $result | ConvertTo-Json -Compress
    Write-EventLog -LogName Application -Source RetailTxDisk -EventId 2100 -EntryType Information -Message $json
    return $json
}

if (-not $PSCmdlet.ShouldProcess('Owned R: test volume', $Operation)) { return }
Assert-PlainPath $directory
Assert-PlainPath "$directory\owner.txt"
if ((Get-Content -LiteralPath "$directory\owner.txt" -Raw).Trim() -cne $owner) { throw 'Host owner mismatch.' }
$lease = [IO.File]::Open("$directory\disk.lock", 'OpenOrCreate', 'ReadWrite', 'None')
try {
    if ($Operation -eq 'Install') {
        if (Test-Path -LiteralPath $statePath) { throw 'Guest installation already exists; inspect Status instead of reinstalling.' }
        if (Get-Volume | Where-Object DriveLetter -EQ R) { throw 'Drive R: is already assigned; refusing adoption.' }
        $disks = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.Size -eq 4GB -and $_.PartitionStyle -eq 'RAW' })
        if ($disks.Count -ne 1) { throw 'Expected exactly one empty four-GiB data disk.' }
        $disk = $disks[0]
        Assert-TestDisk $disk
        $disk | Initialize-Disk -PartitionStyle GPT
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter R
        $null = $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel RETAILTXTEST -Confirm:$false
        $volume = Get-Volume -DriveLetter R
        $null = New-Item -ItemType Directory -Path $dataDirectory
        & icacls.exe $dataDirectory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict test data permissions.' }
        $owner | Set-Content -LiteralPath "$dataDirectory\owner.txt" -Encoding ASCII
        $script:state = [ordered]@{
            ownerToken = $owner; diskUniqueId = (Get-Disk -Number $disk.Number).UniqueId
            volumeUniqueId = $volume.UniqueId; partitionNumber = $partition.PartitionNumber
            phase = 'healthy'; runId = $null; deadline = $null; recoveryActor = $null; recoveredAt = $null; watchdogAt = $null
        }
        Save-GuestState
        if (-not [Diagnostics.EventLog]::SourceExists('RetailTxDisk')) {
            New-EventLog -LogName Application -Source RetailTxDisk
        }
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $directory\Invoke-DiskGuest.ps1 -Operation Watchdog -OwnerToken $owner"
        $triggers = @(
            (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15) -RepetitionInterval (New-TimeSpan -Minutes 1)),
            (New-ScheduledTaskTrigger -AtStartup)
        )
        $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
            -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings
        Write-Observation 'installed'
        return
    }
    Assert-PlainPath $statePath
    $script:state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($script:state.ownerToken -cne $owner) { throw 'Guest state owner mismatch.' }
    $volume = Get-TestVolume
    if ($Operation -eq 'Watchdog') {
        if ($script:state.phase -in @('injecting', 'pressure', 'safety-test') -and [DateTimeOffset]::UtcNow -ge [DateTimeOffset]$script:state.deadline) {
            Remove-Pressure 'independent-watchdog'
        }
        $script:state.watchdogAt = [DateTimeOffset]::UtcNow.ToString('o')
        Save-GuestState
    } elseif ($Operation -eq 'Recover') {
        if ($script:state.runId -cne $RunId.ToString()) { throw 'Recovery refers to a different fault; refusing stale remediation.' }
        if ($script:state.phase -ne 'healthy') { Remove-Pressure 'operator-script' }
        elseif ($volume.SizeRemaining / $volume.Size -lt 0.75) { throw 'The volume is no longer healthy; refusing a stale success.' }
    } elseif ($Operation -in @('Fault', 'SafetyTest')) {
        if ($script:state.phase -cne 'healthy' -or $volume.SizeRemaining / $volume.Size -lt 0.75) {
            throw 'Fault requires a healthy test volume.'
        }
        $task = Get-ScheduledTask -TaskName $taskName
        if ($task.State -eq 'Disabled' -or -not $script:state.watchdogAt -or
            [DateTimeOffset]::UtcNow.AddSeconds(-90) -gt [DateTimeOffset]$script:state.watchdogAt) {
            throw 'A recent independent watchdog observation is required before injection.'
        }
        if ($script:state.runId -ceq $RunId.ToString()) { throw 'Fault RunId cannot be reused.' }
        $stream = $null
        $created = $false
        try {
            $stream = New-PressureFile $RunId
            $created = $true
            $script:state.runId = $RunId.ToString()
            $script:state.deadline = [DateTimeOffset]::UtcNow.AddSeconds($DurationSeconds).ToString('o')
            $script:state.phase = 'injecting'
            $script:state.recoveryActor = $null
            $script:state.recoveredAt = $null
            Save-GuestState
            $buffer = New-Object byte[] 1MB
            $target = if ($Operation -eq 'SafetyTest') { 1MB } else { [long]($volume.SizeRemaining - [Math]::Ceiling($volume.Size * 0.08)) }
            if ($target -le 0 -or $target -gt 3800MB) { throw 'Pressure allocation exceeds fixed bound.' }
            $started = [DateTimeOffset]::UtcNow
            while ($stream.Length -lt $target) {
                if ([DateTimeOffset]::UtcNow -ge [DateTimeOffset]$script:state.deadline -or
                    [DateTimeOffset]::UtcNow -ge $started.AddSeconds(120)) { throw 'Bounded injection window elapsed.' }
                $free = ([IO.DriveInfo]::new('R')).AvailableFreeSpace
                if ($free -lt 257MB) { throw 'Minimum test-volume reserve reached unexpectedly.' }
                $count = [int][Math]::Min([long]$buffer.Length, $target - $stream.Length)
                $stream.Write($buffer, 0, $count)
            }
            $stream.Flush($true)
            $stream.Dispose()
            $stream = $null
            $volume = Get-TestVolume
            if ($Operation -eq 'Fault' -and $volume.SizeRemaining / $volume.Size -ge 0.10) { throw 'The real disk-pressure threshold was not reached.' }
            $script:state.phase = if ($Operation -eq 'SafetyTest') { 'safety-test' } else { 'pressure' }
            Save-GuestState
        } catch {
            if ($stream) { $stream.Dispose(); $stream = $null }
            if ($created) { Remove-Pressure 'injection-error-cleanup' }
            throw
        } finally { if ($stream) { $stream.Dispose() } }
    }
    Write-Observation $Operation
} finally { $lease.Dispose() }
