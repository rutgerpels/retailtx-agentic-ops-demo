#Requires -Version 7.2
<#
.SYNOPSIS
Provision and probe an isolated Windows Arc scenario host.
.DESCRIPTION
Uses the retained foundation's private subnet and Arc private-link scope.
Native Compute Run Command is provisioning-only. Probe uses HybridCompute
after Azure guest management is disabled. No disk fault is injected by Up.
Temporary onboarding permissions are removed after connection or by Down.
Up records and grants the exact Arc identity workspace query access before
guest probes and safety preparation; effective access is still checked by Arm.
.PARAMETER Operation
Up, Status, Probe, Install, Reconcile, Doctor, SafetyTest, Recover, Monitor,
Telemetry, Incident, Connect, Disconnect, Arm, Fault or Down.
Reconcile verifies the intended installed controller and fresh healthy guest
state after an uncertain installation; it never resubmits installation.
Monitor configures collection and a disabled alert; Telemetry requires real,
fresh private Perf and Event records. Neither operation injects a fault.
Connect creates an owned investigator and disabled Review response plan,
preserving the shared SRE settings for restoration by Down.
Disconnect restores only the recorded SRE changes and leaves the guest intact.
Arm requires healthy private telemetry and an independent safety proof.
Fault injects real R: pressure for at most twenty minutes; never replay an
uncertain request. Recover requires its exact run ID.
Incident saves one read-only snapshot of current-fault alert details and its
linked SRE incident. It neither runs guest commands nor acknowledges alerts.
Failed bootstrap is intentionally not replayed: Down
and recreate instead of layering recovery transports onto an unknown guest.
.PARAMETER SubscriptionId
Explicit authorized subscription, checked against the saved foundation tenant.
.PARAMETER EnvironmentName
Generic fixture name, separate from the retained foundation.
.PARAMETER FoundationEnvironment
Owned foundation manifest supplying private network and SRE integration IDs.
.PARAMETER RunId
Exact current run to recover; never inferred from an arbitrary pressure file.
.PARAMETER Scenario
Select the retained disk fixture or the owned IIS price-service fixture. Existing
manifests default to disk; the selected value must match the saved manifest.
.PARAMETER RebootDuringSafetyTest
SafetyTest only: use a five-minute one-MiB canary, restart the owned backing
VM, and require a new guest boot followed by independent watchdog recovery.
.EXAMPLE
.\scripts\Invoke-DiskScenario.ps1 Up -SubscriptionId <guid>
.OUTPUTS
Owned state or real command evidence; never a simulated incident result.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('Up', 'Status', 'Probe', 'Install', 'Reconcile', 'Doctor', 'SafetyTest', 'Recover', 'Monitor', 'Telemetry', 'Incident', 'Connect', 'Disconnect', 'Arm', 'Fault', 'Down')][string]$Operation,
    [ValidateSet('disk', 'price-service')][string]$Scenario = 'disk',
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo03',
    [string]$FoundationEnvironment = 'stage0',
    [guid]$RunId = [guid]::Empty,
    [switch]$RebootDuringSafetyTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($RebootDuringSafetyTest -and $Operation -cne 'SafetyTest') {
    throw 'RebootDuringSafetyTest is valid only for SafetyTest.'
}
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
Assert-RetailEnvironmentName $FoundationEnvironment
if ($EnvironmentName.Length -gt 10 -or $EnvironmentName -ceq $FoundationEnvironment) {
    throw 'Use a distinct environment of at most ten characters for the Windows computer name.'
}
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root ".azure\$EnvironmentName"
$statePath = Join-Path $directory 'disk-scenario-state.json'
$subscription = $SubscriptionId.ToString()
$groupName = "rg-retailtx-disk-$EnvironmentName-swedencentral"
$groupId = "/subscriptions/$subscription/resourceGroups/$groupName"
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-retailtx-disk-$EnvironmentName"
$arcId = "$groupId/providers/Microsoft.HybridCompute/machines/disk-$EnvironmentName"
$arcApi = '2024-07-10'
$state = $null
function Invoke-Azure {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 90)
    Invoke-RetailAzure -SubscriptionId $subscription -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}
function Save-State { Save-RetailState $state $statePath }
function Archive-DeletedDiskEvidence {
    if (-not $state -or $state.phase -cne 'deleted') { return }
    $archive = Join-Path $directory "history\$($state.ownerToken)"
    $null = New-Item -ItemType Directory -Path $archive -Force
    Copy-Item -LiteralPath $statePath -Destination (Join-Path $archive 'disk-scenario-state.json') -Force -ErrorAction Stop
    foreach ($file in (Get-ChildItem -LiteralPath $directory -File)) {
        if ($file.Name -notin @('disk-scenario.lock', 'disk-scenario-state.json')) {
            Move-Item -LiteralPath $file.FullName -Destination (Join-Path $archive $file.Name) -ErrorAction Stop
        }
    }
}
. (Join-Path $PSScriptRoot 'disk\DiskSre.ps1')
. (Join-Path $PSScriptRoot 'price\PriceScenario.ps1')
function Test-ArcConnection {
    param([hashtable]$Machine)
    return $Machine -and $Machine.ContainsKey('properties') -and $Machine.properties -and
        $Machine.properties.ContainsKey('status') -and $Machine.properties.status -ceq 'Connected'
}
function Get-OwnedGroup {
    if (-not (Invoke-Azure @('group', 'exists', '--name', $groupName))) { return $null }
    $group = Invoke-Azure @('group', 'show', '--name', $groupName)
    if (-not $state -or $group.id -ine $groupId -or $group.location -ine 'swedencentral' -or
        $group.tags.ownerToken -cne $state.ownerToken -or $group.tags.profile -cne 'disk-scenario' -or
        $group.tags.environmentId -cne $EnvironmentName -or $group.tags.managedBy -cne 'retailtx' -or
        $group.tags.demo -cne 'retailtx') { throw 'Disk fixture group ownership mismatch.' }
    return $group
}
function Assert-Manifest {
    param([hashtable]$Value, [ValidateSet('disk', 'price-service')][string]$ExpectedScenario = 'disk')
    $recordedScenario = if ($Value.ContainsKey('workloadScenario')) { $Value.workloadScenario } else { 'disk' }
    if ($Value.schemaVersion -ne 1 -or $Value.profile -cne 'disk-scenario' -or
        $Value.subscriptionId -ine $subscription -or $Value.environmentName -cne $EnvironmentName -or
        $Value.groupId -ine $groupId -or $Value.vmId -ine $vmId -or $Value.arcId -ine $arcId -or
        $Value.foundationEnvironment -cne $FoundationEnvironment -or $recordedScenario -cne $ExpectedScenario) {
        throw 'Arc scenario manifest mismatch; select the exact scenario recorded by this fixture.'
    }
    $null = [guid]::Parse($Value.ownerToken)
    $null = [guid]::Parse($Value.privateLinkRoleName)
    $expectedScope = "/subscriptions/$subscription/resourceGroups/rg-retailtx-$FoundationEnvironment-swedencentral/providers/Microsoft.HybridCompute/privateLinkScopes/pls-retailtx-$FoundationEnvironment-arc"
    if ($Value.privateLinkScopeId -ine $expectedScope -or
        $Value.privateLinkRoleId -ine "$expectedScope/providers/Microsoft.Authorization/roleAssignments/$($Value.privateLinkRoleName)") {
        throw 'External bootstrap scope does not match the foundation.'
    }
    $foundationId = "/subscriptions/$subscription/resourceGroups/rg-retailtx-$FoundationEnvironment-swedencentral"
    if ($Value.workspaceId -ine "$foundationId/providers/Microsoft.OperationalInsights/workspaces/law-retailtx-$FoundationEnvironment" -or
        $Value.dceId -ine "$foundationId/providers/Microsoft.Insights/dataCollectionEndpoints/dce-retailtx-$FoundationEnvironment") {
        throw 'Monitoring resources differ from the retained foundation.'
    }
    $null = [guid]::Parse($Value.workspaceCustomerId)
    if ($Value.ContainsKey('monitorRoles')) {
        foreach ($entry in $Value.monitorRoles.GetEnumerator()) {
            if ($entry.Key -notin @('arc', 'alert')) { throw 'Unknown monitoring role target.' }
            $role = $entry.Value
            $null = [guid]::Parse($role.name)
            $null = [guid]::Parse($role.principalId)
            if ($role.id -ine "$($Value.workspaceId)/providers/Microsoft.Authorization/roleAssignments/$($role.name)") {
                throw 'Monitoring permission has an unexpected scope.'
            }
        }
    }
}
function Get-OwnedMachine {
    param([switch]$Arc)
    if (-not (Get-OwnedGroup)) { throw 'Owned disk fixture does not exist.' }
    $id = if ($Arc) { $arcId } else { $vmId }
    $api = if ($Arc) { $arcApi } else { '2024-11-01' }
    $machine = Invoke-Azure @('resource', 'show', '--ids', $id, '--api-version', $api)
    if ($machine.id -ine $id -or $machine.tags.ownerToken -cne $state.ownerToken -or
        $machine.tags.profile -cne 'disk-scenario') { throw 'Disk fixture machine ownership mismatch.' }
    if ($Arc -and (-not $machine.properties.ContainsKey('privateLinkScopeResourceId') -or
        $machine.properties.privateLinkScopeResourceId -ine $state.privateLinkScopeId)) {
        throw 'Arc private-link scope differs from the owned foundation.'
    }
    return $machine
}
function Remove-BootstrapAccess {
    if (-not $state.ContainsKey('bootstrapPrincipalId')) { return }
    $assignments = @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--assignee-object-id', $state.bootstrapPrincipalId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
    $targets = [Collections.Generic.List[string]]::new()
    foreach ($assignment in $assignments) {
        if ($assignment.id -ieq $state.privateLinkRoleId) {
            if ($assignment.scope -ine $state.privateLinkScopeId -or
                $assignment.principalId -ine $state.bootstrapPrincipalId -or
                $assignment.roleDefinitionId -notlike '*/acdd72a7-3385-48ef-bd42-f606fba81ae7') {
                throw 'External bootstrap role changed; refusing deletion.'
            }
            $targets.Add($assignment.id)
        } elseif ($assignment.scope -ieq $groupId -and
            $assignment.roleDefinitionId -like '*/b64e21ea-ac4e-4cdf-9dc9-5b892992bee7') {
            if ($assignment.principalId -ine $state.bootstrapPrincipalId) { throw 'Bootstrap principal mismatch.' }
            $targets.Add($assignment.id)
        }
    }
    foreach ($id in $targets) { $null = Invoke-Azure @('role', 'assignment', 'delete', '--ids', $id) }
    $remaining = @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--assignee-object-id', $state.bootstrapPrincipalId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false') |
        Where-Object { $_.id -ieq $state.privateLinkRoleId -or
            ($_.scope -ieq $groupId -and $_.roleDefinitionId -like '*/b64e21ea-ac4e-4cdf-9dc9-5b892992bee7') })
    if ($remaining.Count) { throw 'Bootstrap permissions remain.' }
    $state.bootstrapAccessRemoved = $true
    Save-State
}
function Get-ArcCommand {
    param([string]$CommandId)
    $credentials = Invoke-Azure @('account', 'get-access-token', '--resource', 'https://management.azure.com/')
    $token = ConvertTo-SecureString $credentials.accessToken -AsPlainText -Force
    $credentials = $null
    try {
        $response = Invoke-WebRequest -Uri "https://management.azure.com${CommandId}?api-version=$arcApi" `
            -Authentication Bearer -Token $token -MaximumRedirection 0 -TimeoutSec 60 -SkipHttpErrorCheck
    } finally { $token = $null }
    $result = $response.Content | ConvertFrom-Json -AsHashtable
    Save-RetailState $result (Join-Path $directory 'command-read.json')
    # Arc can return HCRP404 immediately after accepting PUT, before its first guest result.
    if ($response.StatusCode -eq 404 -and $result.error.code -ceq 'HCRP404') {
        Write-Warning "Arc command result is not visible yet; waiting for the same command, not resubmitting: $CommandId"
        return $null
    }
    if ($response.StatusCode -ne 200) { throw "Arc command read failed with HTTP $($response.StatusCode); inspect saved evidence." }
    if ($result.id -ine $CommandId) { throw 'Arc command result identity mismatch.' }
    return $result
}
function Invoke-ArcCommand {
    param(
        [ValidateSet('probe', 'install', 'status', 'safety-test', 'fault', 'recover', 'telemetry',
            'price-install', 'price-reconcile', 'price-status', 'price-safety-test', 'price-fault', 'price-recover', 'price-telemetry')][string]$Purpose,
        [string]$Script
    )
    $machine = Get-OwnedMachine -Arc
    if (-not (Test-ArcConnection $machine)) { throw 'Arc host is not Connected.' }
    if ($state.ContainsKey('workloadScenario') -and $state.workloadScenario -ceq 'price-service') {
        Remove-CompletedPriceCommand
    }
    $nonce = [guid]::NewGuid().ToString()
    $marker = "RETAILTX_GUEST_RESULT:$nonce"
    $commandName = "$Purpose-$([guid]::NewGuid().ToString('N'))"
    $commandId = "$arcId/runCommands/$commandName"
    $bodyPath = Join-Path $directory "$commandName.request.json"
    $guest = @"
`$ErrorActionPreference = 'Stop'
if ((Get-Content 'C:\ProgramData\RetailTxDisk\owner.txt' -Raw).Trim() -cne '$($state.ownerToken)') { throw 'Owner mismatch' }
$Script
Write-Output '$marker'
"@
    $body = @{ location = 'swedencentral'; properties = @{
        source = @{ script = $guest }; timeoutInSeconds = 180; asyncExecution = $false
    } }
    # Keep the exact nonsecret request: polling failure does not cancel an accepted command.
    Save-RetailState $body $bodyPath
    $state.lastCommandId = $commandId
    Save-State
    $null = Invoke-Azure @('rest', '--method', 'put', '--url',
        "https://management.azure.com${commandId}?api-version=$arcApi", '--body', "@$bodyPath")
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(4)
    do {
        $command = Get-ArcCommand $commandId
        $view = if ($command -and $command.properties.ContainsKey('instanceView')) { $command.properties.instanceView } else { $null }
        if ($view -and $view.executionState -ceq 'Succeeded') {
            $output = $view.output.TrimEnd()
            if ($view.exitCode -ne 0 -or $view.error -or
                -not ($output -ceq $marker -or $output.EndsWith("`n$marker", [StringComparison]::Ordinal)) -or
                $command.properties.source.script -cne $guest) {
                throw 'Arc command did not return the exact guest nonce and unchanged script with a successful exit.'
            }
            Save-RetailState $command (Join-Path $directory "$commandName.result.json")
            Save-RetailState $command (Join-Path $directory "last-$Purpose.json")
            return @{ nonce = $nonce; commandId = $commandId; transport = 'HybridCompute'
                output = $output.Substring(0, $output.Length - $marker.Length).Trim()
                executionState = $view.executionState; exitCode = $view.exitCode; timestamp = [DateTimeOffset]::UtcNow.ToString('o') }
        }
        if (($view -and $view.executionState -in @('Failed', 'Canceled', 'TimedOut')) -or
            ($command -and $command.properties.provisioningState -ceq 'Failed')) { throw 'Arc command failed; inspect saved evidence.' }
        Start-Sleep -Seconds 10
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Arc command exceeded four minutes; the remote operation may still run. Inspect saved evidence before recovery or Down.'
}
function Invoke-ArcProbe {
    $guest = @'
$service = Get-CimInstance Win32_Service -Filter "Name='WindowsAzureGuestAgent'"
if ($service.State -ne 'Stopped' -or $service.StartMode -ne 'Disabled') { throw 'Azure guest agent not disabled' }
$rule = Get-NetFirewallRule -Name RetailTxBlockAzureIMDS
if ($rule.Enabled -ne 'True' -or $rule.Action -ne 'Block' -or $rule.Direction -ne 'Outbound') { throw 'IMDS block absent' }
$addresses = @(($rule | Get-NetFirewallAddressFilter).RemoteAddress)
if ($addresses.Count -ne 2 -or (Compare-Object @('169.254.169.254', '169.254.169.253') $addresses)) { throw 'IMDS block addresses differ' }
if (@(Get-NetFirewallProfile | Where-Object Enabled -NE 'True').Count) { throw 'Windows firewall profile disabled' }
if ((Invoke-WebRequest 'http://localhost/health.txt' -UseBasicParsing -TimeoutSec 10).StatusCode -ne 200) { throw 'IIS unhealthy' }
'@
    $result = Invoke-ArcCommand -Purpose probe -Script $guest
    if ($result.output) { throw 'Probe returned unexpected output.' }
    Remove-BootstrapAccess
    $state.probeCount = [int]$state.probeCount + 1
    if ($state.phase -in @('provisioning', 'arc-connected', 'arc-probed')) { $state.phase = 'arc-probed' }
    Save-State
    return $result
}
function Invoke-GuestController {
    param(
        [ValidateSet('Install', 'Status', 'SafetyTest', 'Fault', 'Recover')][string]$Action,
        [guid]$FaultId = [guid]::Empty,
        [switch]$Reconcile,
        [ValidateSet(60, 300)][int]$SafetyDurationSeconds = 60
    )
    if ($Reconcile -and $Action -cne 'Status') { throw 'Reconciliation must only inspect guest state.' }
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'disk\Invoke-DiskGuest.ps1') -Raw
    $bytes = [Text.Encoding]::UTF8.GetBytes($source)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    $scriptPath = 'C:\ProgramData\RetailTxDisk\Invoke-DiskGuest.ps1'
    $preparation = ''
    if ($Action -ceq 'Install') {
        if ($state.probeCount -lt 3 -or -not $state.bootstrapAccessRemoved) { throw 'Install requires three successful Arc probes and removed bootstrap grants.' }
        if ($state.ContainsKey('pendingControllerSha256')) { throw 'Installation was already attempted; Reconcile this revision or Down and recreate, never resubmit blindly.' }
        $state.pendingControllerSha256 = $hash
        Save-State
        $payload = [Convert]::ToBase64String($bytes)
        $preparation = @"
if (Test-Path -LiteralPath '$scriptPath') { throw 'Controller already exists; inspect it instead of overwriting.' }
if ((Get-Item -LiteralPath 'C:\ProgramData\RetailTxDisk' -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Bootstrap directory is a reparse point' }
[IO.File]::WriteAllBytes('$scriptPath', [Convert]::FromBase64String('$payload'))
"@
    } elseif ($Reconcile) {
        if ($Action -cne 'Status' -or -not $state.ContainsKey('pendingControllerSha256') -or
            $state.pendingControllerSha256 -cne $hash) { throw 'Reconciliation requires the exact intended installation revision.' }
        if ($state.ContainsKey('controllerSha256') -and $state.controllerSha256 -cne $hash) {
            throw 'Reconciliation cannot replace a different recorded controller revision.'
        }
    } elseif (-not $state.ContainsKey('controllerSha256') -or $state.controllerSha256 -cne $hash) {
        throw 'Guest controller is not installed from this revision; do not silently replace the recovery script.'
    }
    $arguments = "-Operation $Action -OwnerToken $($state.ownerToken)"
    if ($Action -in @('SafetyTest', 'Fault', 'Recover')) {
        if (-not $FaultId -or $FaultId -eq [guid]::Empty) { throw 'Specific recovery/test RunId required.' }
        $arguments += " -RunId $FaultId"
    }
    if ($Action -ceq 'SafetyTest') { $arguments += " -DurationSeconds $SafetyDurationSeconds" }
    if ($Action -ceq 'Fault') { $arguments += ' -DurationSeconds 1200' }
    $guest = @"
$preparation
if ((Get-Item -LiteralPath '$scriptPath' -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Controller is a reparse point' }
if ((Get-FileHash -LiteralPath '$scriptPath' -Algorithm SHA256).Hash -cne '$hash') { throw 'Controller hash differs' }
& '$scriptPath' $arguments
"@
    $purpose = if ($Action -ceq 'SafetyTest') { 'safety-test' } else { $Action.ToLowerInvariant() }
    $result = Invoke-ArcCommand -Purpose $purpose -Script $guest
    $observation = $result.output | ConvertFrom-Json -AsHashtable
    if ($observation.ownerToken -cne $state.ownerToken -or $observation.volume -cne 'R:' -or
        $observation.iisHttpStatus -ne 200 -or
        [DateTimeOffset]$observation.observedAt -lt [DateTimeOffset]::UtcNow.AddMinutes(-2) -or
        [DateTimeOffset]$observation.observedAt -gt [DateTimeOffset]::UtcNow.AddSeconds(30)) {
        throw 'Guest evidence has wrong ownership, unhealthy IIS, or an invalid observation time.'
    }
    if ($Reconcile -and ($observation.phase -cne 'healthy' -or $observation.runId -or
        $observation.freePercent -lt 75 -or -not $observation.watchdogAt -or
        [DateTimeOffset]$observation.watchdogAt -lt [DateTimeOffset]::UtcNow.AddSeconds(-90) -or
        [DateTimeOffset]$observation.watchdogAt -gt [DateTimeOffset]::UtcNow.AddSeconds(30))) {
        throw 'Reconciliation requires an untouched healthy volume and fresh independent watchdog evidence.'
    }
    if ($Action -ceq 'Install' -or $Reconcile) {
        $state.controllerSha256 = $hash
        $state.phase = 'guest-installed'
        Save-State
    }
    Save-RetailState $observation (Join-Path $directory 'guest-observation.json')
    return $observation
}
function Wait-DiskMonitorAgent {
    param([string]$ExtensionId)
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(10)
    do {
        $extension = Invoke-Azure @('rest', '--method', 'get', '--url',
            "https://management.azure.com${ExtensionId}?api-version=$arcApi")
        if ($extension.id -ine $ExtensionId -or $extension.properties.publisher -cne 'Microsoft.Azure.Monitor' -or
            $extension.properties.type -cne 'AzureMonitorWindowsAgent') { throw 'Unexpected existing monitoring extension.' }
        $phase = $extension.properties.provisioningState
        if ($phase -ceq 'Succeeded') { return }
        if ($phase -cnotin @('Creating', 'Updating')) { throw "Existing monitoring extension reached $phase; refusing deployment retry." }
        Start-Sleep -Seconds 20
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Existing monitoring extension did not settle within ten minutes; no deployment retry was submitted.'
}
function Invoke-DiskMonitorDeployment {
    param(
        [Parameter(Mandatory)][string]$ParameterFile,
        [string]$TemplateFile = 'infra\disk-monitor.bicep',
        [string]$DeploymentName = 'disk-monitor'
    )
    $arguments = @('deployment', 'group', 'create', '--resource-group', $groupName,
        '--name', $DeploymentName, '--template-file', (Join-Path $root $TemplateFile),
        '--parameters', "@$ParameterFile")
    $extensionId = "$arcId/extensions/AzureMonitorWindowsAgent"
    $extensions = Invoke-Azure @('rest', '--method', 'get', '--url',
        "https://management.azure.com$arcId/extensions?api-version=$arcApi")
    $existing = @($extensions.value | Where-Object { $_.properties.type -ceq 'AzureMonitorWindowsAgent' })
    if ($existing.Count) {
        if ($existing.Count -ne 1 -or $existing[0].id -ine $extensionId) { throw 'Unexpected existing monitoring extension identity.' }
        Wait-DiskMonitorAgent $extensionId
        $arguments += 'deployMonitoringAgent=false'
    }
    try { return Invoke-Azure $arguments -TimeoutSeconds 900 } catch {
        $failure = $_
        $deployment = Invoke-Azure @('deployment', 'group', 'show', '--resource-group', $groupName, '--name', $DeploymentName)
        if ($deployment.properties.provisioningState -cne 'Failed') { throw $failure }
        $operations = @(Invoke-Azure @('deployment', 'operation', 'group', 'list',
            '--resource-group', $groupName, '--name', $DeploymentName))
        $failed = @($operations | Where-Object { $_.properties.provisioningState -ceq 'Failed' })
        if (-not $failed.Count -or $existing.Count) { throw $failure }
        foreach ($operation in $failed) {
            $properties = $operation.properties
            if (-not $properties.targetResource -or $properties.targetResource.id -ine $extensionId -or
                -not $properties.statusMessage -or -not $properties.statusMessage.error -or
                $properties.statusMessage.error.code -cne 'HCRP409') { throw $failure }
        }
        Write-Warning 'AMA is already being provisioned; waiting for that extension before one declarative deployment retry.'
        Wait-DiskMonitorAgent $extensionId
        return Invoke-Azure ($arguments + @('deployMonitoringAgent=false')) -TimeoutSeconds 900
    }
}
function Set-MonitorAccess {
    param([ValidateSet('arc', 'alert')][string]$Target, [guid]$PrincipalId)
    if (-not $state.ContainsKey('monitorRoles')) { $state.monitorRoles = @{} }
    if (-not $state.monitorRoles.ContainsKey($Target)) {
        $name = [guid]::NewGuid().ToString()
        $state.monitorRoles[$Target] = @{
            name = $name; principalId = $PrincipalId.ToString()
            id = "$($state.workspaceId)/providers/Microsoft.Authorization/roleAssignments/$name"
        }
        Save-State
    }
    $role = $state.monitorRoles[$Target]
    if ($role.principalId -ine $PrincipalId.ToString()) { throw 'Monitoring identity changed; do not adopt new permissions.' }
    $assignments = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $state.workspaceId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
    $existing = @($assignments | Where-Object id -IEQ $role.id)
    if ($existing.Count) {
        if ($existing.Count -ne 1 -or $existing[0].scope -ine $state.workspaceId -or
            $existing[0].principalId -ine $role.principalId -or
            $existing[0].roleDefinitionId -notlike '*/73c42c96-874c-492b-b04d-ab87d138a893' -or
            $existing[0].description -cne "retailtx:disk:$($state.ownerToken):$Target") {
            throw 'Recorded monitoring grant differs from the exact owned workspace permission.'
        }
        return
    }
    $null = Invoke-Azure @('role', 'assignment', 'create', '--name', $role.name,
        '--assignee-object-id', $role.principalId, '--assignee-principal-type', 'ServicePrincipal',
        '--role', '73c42c96-874c-492b-b04d-ab87d138a893', '--scope', $state.workspaceId,
        '--description', "retailtx:disk:$($state.ownerToken):$Target")
}
function Remove-MonitorAccess {
    if (-not $state.ContainsKey('monitorRoles')) { return }
    $ownedIds = @($state.monitorRoles.Values | ForEach-Object { $_.id })
    $assignments = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $state.workspaceId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'))
    $targets = [Collections.Generic.List[string]]::new()
    foreach ($entry in $state.monitorRoles.GetEnumerator()) {
        $role = $entry.Value
        $found = @($assignments | Where-Object id -IEQ $role.id)
        foreach ($assignment in $found) {
            if ($assignment.scope -ine $state.workspaceId -or $assignment.principalId -ine $role.principalId -or
                $assignment.roleDefinitionId -notlike '*/73c42c96-874c-492b-b04d-ab87d138a893' -or
                $assignment.description -cne "retailtx:disk:$($state.ownerToken):$($entry.Key)") {
                throw 'Monitoring permission ownership changed; refusing deletion.'
            }
            $targets.Add($assignment.id)
        }
    }
    foreach ($id in $targets) { $null = Invoke-Azure @('role', 'assignment', 'delete', '--ids', $id) }
    $remaining = @(Invoke-Azure @('role', 'assignment', 'list', '--scope', $state.workspaceId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false') |
        Where-Object { $_.id -iin $ownedIds })
    if ($remaining.Count) { throw 'Owned workspace permissions remain.' }
}
function Assert-FreshTelemetry {
    param([hashtable]$Evidence)
    if ($Evidence.workspaceId -ine $state.workspaceCustomerId -or $Evidence.arcResourceId -ine $arcId) {
        throw 'Telemetry query scope mismatch.'
    }
    $disk = @($Evidence.rows | Where-Object kind -CEQ 'disk')
    $guest = @($Evidence.rows | Where-Object kind -CEQ 'guest')
    if ($disk.Count -ne 1 -or $guest.Count -ne 1) { throw 'Both disk counters and guest events are required.' }
    foreach ($row in @($disk[0], $guest[0])) {
        if (-not $row.observedAt -or [DateTimeOffset]$row.observedAt -lt [DateTimeOffset]::UtcNow.AddMinutes(-3) -or
            [DateTimeOffset]$row.observedAt -gt [DateTimeOffset]::UtcNow.AddSeconds(30)) {
            throw 'Telemetry is missing, stale, or future-dated.'
        }
    }
    $detail = $guest[0].details
    if ($detail -is [string]) { $detail = $detail | ConvertFrom-Json -AsHashtable }
    if (-not $detail -or $detail.ownerToken -cne $state.ownerToken -or $detail.volume -cne 'R:' -or
        $detail.iisHttpStatus -ne 200 -or -not $detail.watchdogAt -or
        [DateTimeOffset]$detail.watchdogAt -lt [DateTimeOffset]::UtcNow.AddMinutes(-3) -or
        [DateTimeOffset]$detail.watchdogAt -gt [DateTimeOffset]::UtcNow.AddSeconds(30) -or
        -not $detail.observedAt -or [DateTimeOffset]$detail.observedAt -lt [DateTimeOffset]::UtcNow.AddMinutes(-3) -or
        [DateTimeOffset]$detail.observedAt -gt [DateTimeOffset]::UtcNow.AddSeconds(30)) {
        throw 'Guest telemetry does not establish fresh owned observations and a live watchdog.'
    }
    if ($null -eq $disk[0].freePercent -or -not [double]::IsFinite([double]$disk[0].freePercent) -or
        $disk[0].freePercent -lt 0 -or $disk[0].freePercent -gt 100) { throw 'Invalid disk counter.' }
    return @{ freePercent = $disk[0].freePercent; diskObservedAt = $disk[0].observedAt
        eventObservedAt = $guest[0].observedAt; guest = $detail; privateAddresses = $Evidence.privateAddresses }
}
function Get-PrivateTelemetry {
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'disk\Get-DiskTelemetry.ps1') -Raw
    $script = "& {`n$source`n} -WorkspaceId '$($state.workspaceCustomerId)' -ArcResourceId '$arcId'"
    $result = Invoke-ArcCommand -Purpose telemetry -Script $script
    $evidence = $result.output | ConvertFrom-Json -AsHashtable
    Save-RetailState $evidence (Join-Path $directory 'private-telemetry-query.json')
    $fresh = Assert-FreshTelemetry $evidence
    Save-RetailState $fresh (Join-Path $directory 'fresh-telemetry.json')
    return $fresh
}
function Assert-SafetyRecovery {
    param([hashtable]$Observation, [guid]$FaultId, [hashtable]$Reboot)
    if ($Observation.runId -cne $FaultId.ToString() -or $Observation.phase -cne 'healthy' -or
        $Observation.recoveryActor -cne 'independent-watchdog' -or
        $null -eq $Observation.freePercent -or
        -not [double]::IsFinite([double]$Observation.freePercent) -or
        $Observation.freePercent -lt 75 -or $Observation.freePercent -gt 100) {
        throw 'Safety test did not demonstrate independent healthy recovery for this run.'
    }
    if ($Reboot -and ([DateTimeOffset]$Observation.bootTime -le [DateTimeOffset]$Reboot.bootBefore -or
        [DateTimeOffset]$Observation.bootTime -lt [DateTimeOffset]$Reboot.canaryObservedAt -or
        [DateTimeOffset]$Observation.recoveredAt -lt [DateTimeOffset]$Observation.bootTime -or
        [DateTimeOffset]$Observation.recoveredAt -lt [DateTimeOffset]$Reboot.deadline)) {
        throw 'Safety test lacks a new guest boot followed by expired-canary watchdog recovery.'
    }
}
function Assert-DiskFaultReadiness {
    param([hashtable]$Telemetry, [hashtable]$SafetyProof)
    Assert-SafetyRecovery -Observation $SafetyProof -FaultId ([guid]$SafetyProof.runId)
    if ($SafetyProof.ownerToken -cne $state.ownerToken -or $SafetyProof.volume -cne 'R:' -or
        $SafetyProof.iisHttpStatus -ne 200 -or -not $SafetyProof.recoveredAt -or -not $SafetyProof.deadline -or
        -not $SafetyProof.observedAt -or
        [DateTimeOffset]$SafetyProof.recoveredAt -lt [DateTimeOffset]$SafetyProof.deadline -or
        [DateTimeOffset]$SafetyProof.recoveredAt -gt [DateTimeOffset]$SafetyProof.observedAt -or
        [DateTimeOffset]$SafetyProof.observedAt -gt [DateTimeOffset]::UtcNow.AddSeconds(30)) {
        throw 'Independent safety proof does not belong to this healthy recovered fixture.'
    }
    if ($Telemetry.guest.ownerToken -cne $state.ownerToken -or $Telemetry.guest.phase -cne 'healthy' -or
        $null -eq $Telemetry.freePercent -or $null -eq $Telemetry.guest.freePercent -or
        -not [double]::IsFinite([double]$Telemetry.freePercent) -or
        -not [double]::IsFinite([double]$Telemetry.guest.freePercent) -or
        $Telemetry.freePercent -gt 100 -or $Telemetry.guest.freePercent -gt 100 -or
        $Telemetry.freePercent -lt 75 -or $Telemetry.guest.freePercent -lt 75 -or
        [DateTimeOffset]$state.expiresAt -le [DateTimeOffset]::UtcNow.AddMinutes(25)) {
        throw 'Fault requires healthy capacity and at least twenty-five minutes before fixture expiry.'
    }
}
function Get-DiskAlert {
    $expected = "$groupId/providers/Microsoft.Insights/scheduledQueryRules/alert-retailtx-disk-$EnvironmentName"
    if (-not $state.ContainsKey('alertId') -or $state.alertId -ine $expected) { throw 'No expected scenario alert is recorded.' }
    $alert = Invoke-Azure @('resource', 'show', '--ids', $state.alertId, '--api-version', '2023-12-01')
    if ($alert.id -ine $expected -or $alert.tags.ownerToken -cne $state.ownerToken -or
        $alert.tags.profile -cne 'disk-scenario' -or @($alert.properties.scopes).Count -ne 1 -or
        $alert.properties.scopes[0] -ine $state.workspaceId -or
        $alert.identity.principalId -ine $state.monitorRoles.alert.principalId) {
        throw 'Scenario alert ownership, workspace or identity changed.'
    }
    return $alert
}
function Assert-DiskRecoveryRun {
    param([guid]$RequestedId, [hashtable]$Observation)
    if ($RequestedId -eq [guid]::Empty) { throw 'Recovery requires an explicit run ID.' }
    if ($state.phase -in @('fault-requested', 'fault-active') -and
        $RequestedId.ToString() -cne $state.activeRunId) {
        throw 'Recovery must address the locally pending fault, not a previous healthy run.'
    }
    if ($Observation -and ($Observation.runId -cne $RequestedId.ToString() -or $Observation.phase -cne 'healthy')) {
        throw 'Recovery evidence does not establish healthy state for the requested run.'
    }
}

$operationDescription = if ($RebootDuringSafetyTest) { 'SafetyTest with backing VM restart' } else { $Operation }
if ($WhatIfPreference) {
    $null = $PSCmdlet.ShouldProcess($groupId, "$operationDescription isolated Arc disk fixture")
    return
}
$account = Invoke-Azure @('account', 'show')
if (-not $PSCmdlet.ShouldProcess($groupId, "$operationDescription isolated Arc disk fixture")) { return }
$null = New-Item -ItemType Directory -Path $directory -Force
$lease = [IO.File]::Open((Join-Path $directory 'disk-scenario.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
$sharedLease = $null
try {
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        Assert-Manifest $state -ExpectedScenario $Scenario
        if ($state.tenantId -ine $account.tenantId) { throw 'Disk fixture tenant mismatch.' }
    }
    if (-not $state -and $Operation -ne 'Up') { throw 'No owned disk fixture manifest exists.' }
    if ($Operation -in @('Connect', 'Disconnect', 'Arm', 'Fault', 'Down')) {
        $sharedLease = [IO.File]::Open((Join-Path $root ".azure\$FoundationEnvironment\sre-configuration.lock"),
            'OpenOrCreate', 'ReadWrite', 'None')
    }
    if ($Operation -eq 'Up') {
        $foundation = Get-Content -LiteralPath (Join-Path $root ".azure\$FoundationEnvironment\retailtx-state.json") -Raw |
            ConvertFrom-Json -AsHashtable
        if ($foundation.subscriptionId -ine $subscription -or $foundation.tenantId -ine $account.tenantId) {
            throw 'Foundation identity mismatch.'
        }
        $foundationGroup = Invoke-Azure @('group', 'show', '--name', $foundation.resourceGroupName)
        if ($foundationGroup.tags.ownerToken -cne $foundation.ownerToken) { throw 'Foundation ownership mismatch.' }
        $agent = Invoke-Azure @('resource', 'show', '--ids', $foundation.outputs.SRE_AGENT_ID, '--api-version', '2026-01-01')
        if ($agent.properties.actionConfiguration.mode -cne 'Review') { throw 'SRE Agent must remain in Review.' }
        $identity = Invoke-Azure @('identity', 'show', '--ids', $agent.properties.actionConfiguration.identity)
        $group = Get-OwnedGroup
        if ($state -and $state.phase -ne 'deleted') {
            if ($state.phase -in @('arc-connected', 'arc-probed', 'guest-installed', 'monitor-configured')) { $null = Get-OwnedMachine -Arc; $state; return }
            throw 'An incomplete bootstrap is not replayable; run Down before retrying Up.'
        }
        if ($group) { throw 'Existing group prevents fresh provisioning.' }
        Archive-DeletedDiskEvidence
        $state = @{
            schemaVersion = 1; profile = 'disk-scenario'; workloadScenario = $Scenario
            subscriptionId = $subscription; tenantId = $account.tenantId
            environmentName = $EnvironmentName; foundationEnvironment = $FoundationEnvironment
            ownerToken = [guid]::NewGuid().ToString(); groupId = $groupId; vmId = $vmId; arcId = $arcId
            privateLinkScopeId = $foundation.outputs.ARC_PRIVATE_LINK_SCOPE_ID
            privateLinkRoleName = [guid]::NewGuid().ToString(); phase = 'provisioning'; probeCount = 0
            agentId = $foundation.outputs.SRE_AGENT_ID; agentPrincipalId = $identity.principalId
            workspaceId = $foundation.outputs.WORKSPACE_ID; workspaceCustomerId = $foundation.outputs.WORKSPACE_CUSTOMER_ID
            dceId = $foundation.outputs.DCE_ID
            expiresAt = [DateTimeOffset]::UtcNow.AddHours(4).ToString('o')
        }
        $state.privateLinkRoleId = "$($state.privateLinkScopeId)/providers/Microsoft.Authorization/roleAssignments/$($state.privateLinkRoleName)"
        Assert-Manifest $state -ExpectedScenario $Scenario
        Save-State
        $tags = @{ demo = 'retailtx'; environmentId = $EnvironmentName; ownerToken = $state.ownerToken
            managedBy = 'retailtx'; profile = 'disk-scenario'; expiresAt = $state.expiresAt }
        $tagArguments = @($tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
        $null = Invoke-Azure (@('group', 'create', '--name', $groupName, '--location', 'swedencentral', '--tags') + $tagArguments)
        $compiled = Join-Path $directory 'disk-scenario.compiled.json'
        & bicep build (Join-Path $root 'infra\disk-scenario.bicep') --outfile $compiled
        if ($LASTEXITCODE -ne 0) { throw 'Disk fixture Bicep compilation failed.' }
        # Submit the one-time Windows bootstrap password in memory, not a file or process argument.
        $credentials = Invoke-Azure @('account', 'get-access-token', '--resource', 'https://management.azure.com/')
        $token = ConvertTo-SecureString $credentials.accessToken -AsPlainText -Force
        $credentials = $null
        $password = "Rt9!$([Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36)))"
        $parameters = @{
            environmentName = @{ value = $EnvironmentName }; tags = @{ value = $tags }
            subnetId = @{ value = "$($foundationGroup.id)/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-$FoundationEnvironment/subnets/host" }
            agentPrincipalId = @{ value = $identity.principalId }; adminPassword = @{ value = $password }
        }
        $deploymentId = "$groupId/providers/Microsoft.Resources/deployments/disk-scenario"
        $body = @{ properties = @{ mode = 'Incremental'; parameters = $parameters
            template = (Get-Content -LiteralPath $compiled -Raw | ConvertFrom-Json -AsHashtable) } }
        try {
            $null = Invoke-RestMethod -Uri "https://management.azure.com${deploymentId}?api-version=2025-04-01" `
                -Method Put -Authentication Bearer -Token $token -MaximumRedirection 0 -TimeoutSec 90 `
                -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 100)
        } finally { $password = $null; $parameters = $null; $body = $null; $token = $null }
        $deadline = [DateTimeOffset]::UtcNow.AddMinutes(15)
        do {
            Start-Sleep -Seconds 15
            $deployment = Invoke-Azure @('deployment', 'group', 'show', '--resource-group', $groupName, '--name', 'disk-scenario')
            if ($deployment.properties.provisioningState -in @('Failed', 'Canceled')) { throw 'Disk fixture deployment failed.' }
        } while ($deployment.properties.provisioningState -cne 'Succeeded' -and [DateTimeOffset]::UtcNow -lt $deadline)
        if ($deployment.properties.provisioningState -cne 'Succeeded') { throw 'Disk fixture provisioning exceeded fifteen minutes.' }
        $state.bootstrapPrincipalId = $deployment.properties.outputs.bootstrapPrincipalId.value
        Save-State
        $null = Invoke-Azure @('role', 'assignment', 'create', '--name', $state.privateLinkRoleName,
            '--assignee-object-id', $state.bootstrapPrincipalId, '--assignee-principal-type', 'ServicePrincipal',
            '--role', 'acdd72a7-3385-48ef-bd42-f606fba81ae7', '--scope', $state.privateLinkScopeId)
        $configuration = ConvertTo-RetailGuestPayload @{
            subscriptionId = $subscription; tenantId = $state.tenantId; groupName = $groupName
            machineName = "disk-$EnvironmentName"; environmentName = $EnvironmentName
            ownerToken = $state.ownerToken; privateLinkScopeId = $state.privateLinkScopeId
            expiresAt = $state.expiresAt
        }
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'disk\Initialize-ArcDiskHost.ps1') -Raw
        $commandPath = Join-Path $directory 'bootstrap-command.ps1'
        try {
            "& {`n$source`n} -Configuration '$configuration'" | Set-Content -LiteralPath $commandPath -Encoding utf8NoBOM
            $result = Invoke-Azure @('vm', 'run-command', 'invoke', '--ids', $vmId, '--command-id', 'RunPowerShellScript',
                '--scripts', "@$commandPath") -TimeoutSeconds 900
            Save-RetailState $result (Join-Path $directory 'bootstrap-command-result.json')
            if (-not (($result.value.message -join "`n").Contains("RETAILTX_PREPARED:$($state.ownerToken)"))) {
                throw 'Guest preparation failed; inspect bootstrap result before Down.'
            }
        } finally {
            if (Test-Path -LiteralPath $commandPath) { Remove-Item -LiteralPath $commandPath }
        }
        $extensions = @(Invoke-Azure @('vm', 'extension', 'list', '--resource-group', $groupName, '--vm-name', "vm-retailtx-disk-$EnvironmentName"))
        foreach ($extension in $extensions) {
            $null = Invoke-Azure @('vm', 'extension', 'delete', '--ids', $extension.id) -TimeoutSeconds 180
        }
        $deadline = [DateTimeOffset]::UtcNow.AddMinutes(10)
        $arc = $null
        do {
            Start-Sleep -Seconds 20
            $machines = Invoke-Azure @('rest', '--method', 'get', '--url',
                "https://management.azure.com$groupId/providers/Microsoft.HybridCompute/machines?api-version=$arcApi")
            $matches = @($machines.value | Where-Object id -IEQ $arcId)
            if ($matches.Count -eq 1) { $arc = $matches[0] }
        } while (-not (Test-ArcConnection $arc) -and [DateTimeOffset]::UtcNow -lt $deadline)
        if (-not (Test-ArcConnection $arc)) { throw 'Arc bootstrap did not connect within ten minutes; no fault was injected.' }
        $machine = Get-OwnedMachine -Arc
        Set-MonitorAccess -Target arc -PrincipalId $machine.identity.principalId
        Remove-BootstrapAccess
        $state.phase = 'arc-connected'
        Save-State
        $state
    } elseif ($Scenario -ceq 'price-service' -and $Operation -cne 'Down') {
        Invoke-PriceScenarioOperation -Operation $Operation
    } elseif ($Operation -eq 'Probe') {
        Invoke-ArcProbe
    } elseif ($Operation -eq 'Monitor') {
        $group = Get-OwnedGroup
        $machine = Get-OwnedMachine -Arc
        if (-not $state.ContainsKey('controllerSha256')) { throw 'Install the guarded guest controller before configuring monitoring.' }
        if ($state.ContainsKey('alertEnabled') -and $state.alertEnabled) { throw 'Do not reconfigure monitoring during an armed incident.' }
        $parameters = @{
            environmentName = $EnvironmentName; tags = $group.tags
            workspaceId = $state.workspaceId; dceId = $state.dceId; enableAlert = $false
        }
        $parameterFile = Join-Path $directory 'disk-monitor.parameters.json'
        $wrapped = @{}
        foreach ($key in $parameters.Keys) { $wrapped[$key] = @{ value = $parameters[$key] } }
        Save-RetailState @{parameters=$wrapped} $parameterFile
        $deployment = Invoke-DiskMonitorDeployment -ParameterFile $parameterFile
        $expectedAlert = "$groupId/providers/Microsoft.Insights/scheduledQueryRules/alert-retailtx-disk-$EnvironmentName"
        if ($deployment.properties.provisioningState -cne 'Succeeded' -or
            $deployment.properties.outputs.alertId.value -ine $expectedAlert) { throw 'Monitoring deployment did not establish the expected alert.' }
        $state.alertId = $expectedAlert
        $state.alertEnabled = $false
        Save-State
        Set-MonitorAccess -Target arc -PrincipalId $machine.identity.principalId
        Set-MonitorAccess -Target alert -PrincipalId $deployment.properties.outputs.alertPrincipalId.value
        $state.phase = 'monitor-configured'
        Save-State
        $state
    } elseif ($Operation -eq 'Telemetry') {
        Get-PrivateTelemetry
    } elseif ($Operation -eq 'Incident') {
        $null = Get-OwnedMachine -Arc
        $null = Get-DiskAlert
        Get-DiskIncident
    } elseif ($Operation -eq 'Connect') {
        $null = Get-OwnedMachine -Arc
        if (-not $state.ContainsKey('alertId') -or $state.alertEnabled) {
            throw 'Connect requires configured monitoring with the alert disabled.'
        }
        Connect-DiskSre
    } elseif ($Operation -eq 'Disconnect') {
        if ($state.ContainsKey('alertEnabled') -and $state.alertEnabled) {
            throw 'Do not disconnect SRE while the scenario alert is armed.'
        }
        Disconnect-DiskSre
    } elseif ($Operation -in @('Arm', 'Fault')) {
        if ($state.phase -in @('fault-requested', 'fault-active')) {
            throw 'A fault was already requested; inspect Telemetry and recover that exact run, never replay injection.'
        }
        $null = Get-OwnedMachine -Arc
        $alert = Get-DiskAlert
        $telemetry = Get-PrivateTelemetry
        $proof = Get-Content -LiteralPath (Join-Path $directory 'watchdog-safety-proof.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-DiskFaultReadiness $telemetry $proof
        if ($Operation -ceq 'Arm') {
            Enable-DiskSrePlan
            $request = Join-Path $directory 'alert-enable-request.json'
            Save-RetailState @{properties=@{enabled=$true}} $request
            $state.alertEnabled = $true
            Save-State
            $null = Invoke-Azure @('rest', '--method', 'patch', '--url',
                "https://management.azure.com$($state.alertId)?api-version=2023-12-01", '--body', "@$request")
            if ((Get-DiskAlert).properties.enabled -ne $true) { throw 'Scenario alert enablement is not verified.' }
            $state.phase = 'armed'
            Save-State
            $state
        } else {
            if ($state.phase -cne 'armed' -or $alert.properties.enabled -ne $true) { throw 'Arm the verified alert/Review plan before injection.' }
            Assert-DiskSreArmed
            Assert-DiskIncidentReset
            $faultId = [guid]::NewGuid()
            $state.activeRunId = $faultId.ToString()
            $state.faultRunId = $faultId.ToString()
            $state.phase = 'fault-requested'
            $state.faultRequestedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Save-State
            $observation = Invoke-GuestController -Action Fault -FaultId $faultId
            if ($observation.runId -cne $faultId.ToString() -or $observation.phase -cne 'pressure' -or
                $observation.freePercent -ge 10) { throw 'The requested real disk pressure is not established.' }
            $state.phase = 'fault-active'
            $state.faultDeadline = $observation.deadline
            Save-State
            Save-RetailState $observation (Join-Path $directory 'fault-observation.json')
            $observation
        }
    } elseif ($Operation -in @('Install', 'Reconcile', 'Doctor', 'Recover')) {
        if ($Operation -ceq 'Recover') { Assert-DiskRecoveryRun $RunId }
        $action = if ($Operation -in @('Doctor', 'Reconcile')) { 'Status' } else { $Operation }
        $observation = Invoke-GuestController -Action $action -FaultId $RunId -Reconcile:($Operation -ceq 'Reconcile')
        if ($Operation -ceq 'Recover') {
            Assert-DiskRecoveryRun $RunId $observation
            $state.phase = if ($state.ContainsKey('alertEnabled') -and $state.alertEnabled) { 'armed' } else { 'guest-installed' }
            Save-State
            Save-RetailState $observation (Join-Path $directory 'recovery-observation.json')
        }
        $observation
    } elseif ($Operation -eq 'SafetyTest') {
        if ($state.phase -in @('fault-requested', 'fault-active')) {
            throw 'SafetyTest cannot replace the identity of a pending or active fault.'
        }
        $faultId = [guid]::NewGuid()
        $state.activeRunId = $faultId.ToString()
        Save-State
        $duration = if ($RebootDuringSafetyTest) { 300 } else { 60 }
        $initial = Invoke-GuestController -Action SafetyTest -FaultId $faultId -SafetyDurationSeconds $duration
        $reboot = $null
        if ($RebootDuringSafetyTest) {
            if ($initial.runId -cne $faultId.ToString() -or $initial.phase -cne 'safety-test' -or
                [DateTimeOffset]::UtcNow.AddSeconds(30) -ge [DateTimeOffset]$initial.deadline) {
                throw 'Canary is not active with enough time remaining for a supervised restart.'
            }
            $null = Get-OwnedMachine
            $reboot = @{ runId = $faultId.ToString(); bootBefore = $initial.bootTime
                canaryObservedAt = $initial.observedAt; deadline = $initial.deadline
                requestedAt = [DateTimeOffset]::UtcNow.ToString('o') }
            Save-RetailState $reboot (Join-Path $directory 'safety-reboot-request.json')
            $null = Invoke-Azure @('vm', 'restart', '--ids', $vmId, '--no-wait')
            Start-Sleep -Seconds 90
        }
        $deadline = ([DateTimeOffset]$initial.deadline).AddMinutes(3)
        do {
            Start-Sleep -Seconds 20
            $observation = Invoke-GuestController -Action Status
            if ($observation.runId -cne $faultId.ToString()) { throw 'Safety-test run changed during observation.' }
            if ($observation.phase -ceq 'healthy') {
                Assert-SafetyRecovery -Observation $observation -FaultId $faultId -Reboot $reboot
                $proofName = if ($RebootDuringSafetyTest) { 'watchdog-reboot-proof.json' } else { 'watchdog-safety-proof.json' }
                Save-RetailState $observation (Join-Path $directory $proofName)
                $observation
                return
            }
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        throw 'Independent safety recovery was not observed; inspect the exact run before Recover or Down.'
    } elseif ($Operation -eq 'Down') {
        $group = Get-OwnedGroup
        Disconnect-DiskSre
        Remove-MonitorAccess
        Remove-BootstrapAccess
        if ($group) { $null = Invoke-Azure @('group', 'delete', '--name', $groupName, '--yes') -TimeoutSeconds 900 }
        if (Get-OwnedGroup) { throw 'Disk fixture remains after teardown.' }
        $state.phase = 'deleted'
        $state.deletedAt = [DateTimeOffset]::UtcNow.ToString('o')
        Save-State
        $state
    } else {
        @{ state = $state; groupExists = [bool](Get-OwnedGroup) }
    }
} finally {
    if ($sharedLease) { $sharedLease.Dispose() }
    $lease.Dispose()
}
