<#
.SYNOPSIS
Runs the isolated, synthetic local RetailTx stack.
.DESCRIPTION
Uses Docker Compose only. Never calls Azure. Init generates local credentials
without printing them. Down retains PostgreSQL volumes unless -PurgeData is given.
.PARAMETER Operation
Local lifecycle action.
.PARAMETER ProjectName
Owned Compose project. Use a distinct retailtx-test-* project for destructive tests.
.PARAMETER AcceptEmulatorEula
Accepts the Service Bus emulator and SQL Server Linux license terms during Init.
.PARAMETER PurgeData
Deletes this project's local PostgreSQL volumes during Down.
.PARAMETER DurationSeconds
Maximum local posting pause; automatically expires, even if this shell exits.
.PARAMETER Seed
Synthetic transaction dataset identifier. Reusing it repeats the same IDs.
.PARAMETER Count
Number of synthetic checkouts, bounded to 10000.
.PARAMETER Port
Loopback-only checkout API port written by Init.
.EXAMPLE
.\scripts\Invoke-Local.ps1 Init -AcceptEmulatorEula
.EXAMPLE
.\scripts\Invoke-Local.ps1 Up
.EXAMPLE
.\scripts\Invoke-Local.ps1 Down -PurgeData
.OUTPUTS
Docker status and structured JSON application evidence.
.NOTES
Requires PowerShell 7 and Docker Compose with Linux containers.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Init', 'Up', 'Status', 'Doctor', 'Load', 'Scenario', 'Reset', 'Verify', 'Down', 'Replay')]
    [string]$Operation,
    [ValidatePattern('^retailtx-[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$ProjectName = 'retailtx-demo01',
    [switch]$AcceptEmulatorEula,
    [switch]$PurgeData,
    [ValidateRange(1, 300)]
    [int]$DurationSeconds = 60,
    [ValidatePattern('^[a-zA-Z0-9-]{1,64}$')]
    [string]$Seed = 'demo01',
    [ValidateRange(1, 10000)]
    [int]$Count = 12,
    [ValidateRange(1024, 65535)]
    [int]$Port = 8000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$envFile = Join-Path $root ".env.$ProjectName"
$composeFile = Join-Path $root 'compose.local.yaml'

function Invoke-Compose {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & docker compose --env-file $envFile --project-name $ProjectName -f $composeFile @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Local Compose operation failed ($LASTEXITCODE): $($Arguments[0])"
    }
}

function Test-LocalReadiness {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(120)
    do {
        & docker compose --env-file $envFile --project-name $ProjectName -f $composeFile `
            run --rm --no-deps tools python -m retailtx.runtime doctor
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 3
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Local stack did not become ready within 120 seconds. Inspect Compose logs; no success claimed.'
}

if ($Operation -eq 'Init') {
    if (Test-Path -LiteralPath $envFile) {
        Write-Output "Existing local configuration retained: $envFile"
        return
    }
    if (-not $AcceptEmulatorEula.IsPresent) {
        throw 'Read the emulator/SQL license links in docs/local-development.md; Init requires -AcceptEmulatorEula.'
    }
    if ($PSCmdlet.ShouldProcess($envFile, 'Generate local-only credentials and record EULA acceptance')) {
        $cap = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
        $erp = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
        $sql = 'Aa1!' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
        @(
            "COMPOSE_PROJECT_NAME=$ProjectName"
            "CAP_PORT=$Port"
            'ACCEPT_EULA=Y'
            "CAP_DB_PASSWORD=$cap"
            "ERP_DB_PASSWORD=$erp"
            "MSSQL_SA_PASSWORD=$sql"
        ) | Set-Content -LiteralPath $envFile -Encoding utf8NoBOM
        Write-Output "Created ignored local configuration: $envFile"
    }
    return
}
if (-not (Test-Path -LiteralPath $envFile)) { throw 'Run Init for this ProjectName first.' }
if (-not $PSCmdlet.ShouldProcess($ProjectName, "Local $Operation")) { return }

switch ($Operation) {
    'Up' {
        Invoke-Compose -Arguments @('up', '-d', '--build', '--wait', '--wait-timeout', '180')
        Test-LocalReadiness
    }
    'Status' { Invoke-Compose -Arguments @('ps', '--all') }
    'Doctor' {
        Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'tools', 'python', '-m', 'retailtx.runtime', 'doctor')
    }
    'Load' {
        Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'tools', 'python', 'sim/pos_sim.py',
            '--seed', $Seed, '--count', "$Count")
    }
    'Scenario' {
        Test-LocalReadiness
        Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'tools', 'python', 'chaos/backlog.py',
            '--duration-seconds', "$DurationSeconds")
    }
    'Reset' {
        Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'tools', 'python', 'chaos/backlog.py', '--undo')
        Invoke-Compose -Arguments @('start', 'outbox-publisher', 'erp-poster', 'recon-job')
        Test-LocalReadiness
        Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'tools', 'python', '-m', 'retailtx.runtime', 'drain')
    }
    'Replay' {
        Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'tools', 'python', '-m', 'retailtx.runtime', 'replay-unposted')
    }
    'Verify' {
        if ($ProjectName -notmatch '^retailtx-test-') {
            throw 'Verify mutates synthetic data: use a separate retailtx-test-* project and loopback port.'
        }
        Invoke-Compose -Arguments @('build', 'tests')
        Invoke-Compose -Arguments @('stop', 'outbox-publisher', 'erp-poster', 'recon-job')
        try {
            Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'tests')
        } finally {
            Invoke-Compose -Arguments @('start', 'outbox-publisher', 'erp-poster', 'recon-job')
        }
        Test-LocalReadiness
        & python (Join-Path $root 'tests\local\verify_stack.py') --project $ProjectName --env-file $envFile
        if ($LASTEXITCODE -ne 0) { throw 'Real-stack acceptance failed; inspect the reported evidence.' }
    }
    'Down' {
        $arguments = @('down', '--remove-orphans', '--timeout', '20')
        if ($PurgeData.IsPresent) { $arguments += '--volumes' }
        Invoke-Compose -Arguments $arguments
        Invoke-Compose -Arguments @('ps', '--all')
        & docker volume ls --filter "label=com.docker.compose.project=$ProjectName" --format '{{.Name}}'
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect retained local volumes.' }
        if (-not $PurgeData.IsPresent) {
            Write-Output 'PostgreSQL data retained. Emulator queue contents are not durable; run Replay after the next Up.'
        }
    }
}
