# Shared retained-fixture presenter operations; never deploys or changes SRE configuration.
function Get-GuestPresenterJson {
    param([string]$Path)
    $value = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable -DateKind String
    if ($value -isnot [hashtable]) { throw 'Presenter input must be a JSON object.' }
    return $value
}

function Initialize-GuestPresenter {
    param([string]$Profile, [hashtable]$Configuration)
    $script:presenterProfile = if ($Configuration) { $Configuration } else { Get-GuestPresenterJson $Profile }
    if ($script:presenterProfile.schemaVersion -ne 1 -or
        $script:presenterProfile.scenario -cne 'guest-service' -or
        (Get-FileHash -LiteralPath $script:presenterProfile.guidancePath).Hash -cne
        $script:presenterProfile.guidanceSha256) { throw 'Presenter profile or guidance snapshot changed.' }
    $script:presenterGuidance = Get-GuestPresenterJson $script:presenterProfile.guidancePath
    $script:presenterStatePath = $script:presenterGuidance.statePath
    $script:state = Get-GuestPresenterJson $script:presenterStatePath
    $script:subscription = ([guid]$script:state.subscriptionId).ToString()
    $script:vmId = $script:state.vmId
    $script:EnvironmentName = $script:state.environmentName
    Assert-RetailEnvironmentName $EnvironmentName
    foreach ($id in @($script:state.ownerToken, $script:state.tenantId,
        $script:state.agentPrincipalId, $script:state.workspaceCustomerId,
        $script:state.currentFault.runId, $script:state.currentFault.actor)) { $null = [guid]::Parse($id) }
    if ($script:presenterGuidance.phase -cne 'InstalledAndReadbackVerified' -or
        $script:presenterGuidance.ownerToken -cne $script:state.ownerToken -or
        $script:presenterGuidance.agentId -ine $script:state.agentId -or
        $script:state.schemaVersion -ne 2 -or $script:state.profile -cne 'guest-service' -or
        $script:state.faultLifetime -cne 'Manual' -or
        $script:state.monitorReadMode -cne 'Operator' -or
        -not $script:state.withSreExecution -or -not $script:state.withMonitoring -or
        $vmId -cne "$($script:state.groupId)/providers/Microsoft.Compute/virtualMachines/vm-retailtx-guest-$EnvironmentName" -or
        $script:state.groupId -cne "/subscriptions/$subscription/resourceGroups/rg-retailtx-guest-$EnvironmentName-$($script:state.location)") {
        throw 'Presenter operations require the exact owned Manual/Operator fixture and verified guidance.'
    }
    $names = @('controller.py', 'bootstrap.py', 'worker.py', 'retailtx-demo-posting-worker.service',
        'retailtx-guest-watchdog.service', 'retailtx-guest-watchdog.timer',
        'retailtx-guest-observer.service', 'retailtx-guest-observer.timer')
    if ($script:state.sourceHashes.Count -ne $names.Count) { throw 'Protected source file set changed.' }
    $originalRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $script:presenterStatePath) '..\..'))
    foreach ($name in $names) {
        if ($script:state.sourceHashes[$name] -cnotmatch '^[a-f0-9]{64}$' -or
            (Get-FileHash -LiteralPath (Join-Path $originalRoot "scripts\guest\$name")).Hash.ToLowerInvariant() -cne
            $script:state.sourceHashes[$name]) { throw 'Frozen guest source differs; no rehash or adoption.' }
    }
    foreach ($field in @('sourceHashes', 'artifactHashes')) {
        if ((ConvertTo-DiskSreCanonicalJson $script:state[$field]) -cne
            (ConvertTo-DiskSreCanonicalJson $script:presenterGuidance[$field])) {
            throw 'Frozen manifest differs from the installed guidance snapshot.'
        }
    }
    $script:directory = Split-Path -Parent $script:presenterProfile.journalPath
    $script:presenterJournal = if (Test-Path -LiteralPath $script:presenterProfile.journalPath) {
        Get-GuestPresenterJson $script:presenterProfile.journalPath
    } else { @{ schemaVersion = 1; ownerToken = $script:state.ownerToken; phase = 'Prepared' } }
    if ($script:presenterJournal.schemaVersion -ne 1 -or
        $script:presenterJournal.ownerToken -cne $script:state.ownerToken) { throw 'Foreign presenter journal.' }
}

function Save-GuestPresenterJournal {
    $script:presenterJournal.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Save-RetailState $script:presenterJournal $script:presenterProfile.journalPath
}

function Get-GuestPresenterRoles {
    param($Items)
    return @($Items | ForEach-Object {
        @{
            id = $_.id.ToLowerInvariant(); scope = $_.scope.ToLowerInvariant()
            principalId = $_.principalId.ToLowerInvariant()
            roleDefinitionId = $_.roleDefinitionId.ToLowerInvariant(); principalType = $_.principalType
            condition = if ($_['condition']) { $_.condition } else { $null }
            conditionVersion = if ($_['conditionVersion']) { $_.conditionVersion } else { $null }
            delegatedManagedIdentityResourceId = if ($_['delegatedManagedIdentityResourceId']) {
                $_.delegatedManagedIdentityResourceId
            } else { $null }
        }
    } | Sort-Object { $_.id })
}

function Assert-GuestPresenterConfiguration {
    $account = Invoke-Azure @('account', 'show')
    if ($account.id -ine $subscription -or $account.tenantId -ine $script:state.tenantId) {
        throw 'Azure CLI account must select the manifest subscription and tenant.'
    }
    $vm = Invoke-Azure @('vm', 'show', '--ids', $vmId)
    if ($vm.id -ine $vmId -or $vm.tags.ownerToken -cne $script:state.ownerToken -or
        $vm.tags.environmentId -cne $EnvironmentName) { throw 'VM ownership changed.' }
    $view = Invoke-Azure @('vm', 'get-instance-view', '--ids', $vmId)
    if (-not @($view.instanceView.statuses | Where-Object code -CEQ 'PowerState/running').Count) {
        throw 'Fixture VM is not running; presenter commands never start it.'
    }
    $connection = Get-GuestMonitorConnection
    if ($connection.resource.properties.runningState -cne 'Running' -or
        $connection.resource.properties.incidentManagementConfiguration.type -cne 'AzMonitor') {
        throw 'Intended SRE Agent must be running with Azure Monitor intake.'
    }
    $ids = @(Invoke-Azure @('resource', 'list', '--resource-type', 'Microsoft.App/agents', '--query', '[].id'))
    if (-not ($ids -icontains $script:state.agentId)) {
        throw 'SRE inventory did not include the intended agent.'
    }
    foreach ($id in $ids) {
        if ($id -ieq $script:state.agentId) { continue }
        $other = Invoke-Azure @('resource', 'show', '--ids', $id, '--api-version', '2026-01-01')
        if ($other.properties.runningState -cne 'Stopped') {
            throw 'Another SRE Agent is not Stopped. Settle it and stop it manually before this demo; no agents were changed.'
        }
    }
    $identity = Invoke-Azure @('identity', 'show', '--ids', $script:state.agentIdentityId)
    if ($identity.principalId -ine $script:state.agentPrincipalId) { throw 'Action identity changed.' }
    $expected = $script:presenterGuidance.after
    $liveSkill = Invoke-DiskSreRequest $connection GET '/api/v2/extendedAgent/skills/guest-service-recovery'
    Assert-GuestRecoverySkillSpecification $liveSkill $expected.Skill
    if ($liveSkill.properties.skillContent -notmatch 'PY" --no-wait --output json') {
        throw 'Presenter requires the reviewed non-waiting repair guidance.'
    }
    $liveAgent = Invoke-DiskSreRequest $connection GET "/api/v2/extendedAgent/agents/retailtx-guest-$EnvironmentName"
    Assert-GuestRecoveryInvestigator $liveAgent $expected.Agent
    $plan = Get-GuestMonitorPlan $connection
    $policy = Invoke-DiskSreRequest $connection GET '/api/v2/agent/settings/global'
    Assert-GuestMonitorPolicy $policy
    foreach ($pair in @(@($plan, $expected.Plan), @($policy, $expected.Policy))) {
        if ((ConvertTo-DiskSreCanonicalJson $pair[0]) -cne
            (ConvertTo-DiskSreCanonicalJson $pair[1])) { throw 'Routing or approval policy drift.' }
    }
    if ($plan.properties.isEnabled -ne $true) { throw 'Response plan is disabled.' }
    $rule = Invoke-Azure @('resource', 'show', '--ids', $script:state.alertId, '--api-version', '2023-12-01')
    if ($rule.tags.ownerToken -cne $script:state.ownerToken -or $rule.properties.enabled -ne $true) {
        throw 'Owned alert rule is disabled or changed.'
    }
    $roles = @(Invoke-Azure @('role', 'assignment', 'list', '--all', '--query',
        "[?principalId=='$($script:state.agentPrincipalId)']"))
    if ((ConvertTo-DiskSreCanonicalJson (Get-GuestPresenterRoles $roles)) -cne
        (ConvertTo-DiskSreCanonicalJson (Get-GuestPresenterRoles $expected.Roles))) { throw 'Action grants drift.' }
    return $connection
}

function Get-GuestPresenterReceipt {
    $query = "Syslog | where _ResourceId =~ '$vmId' and ProcessName == 'RetailTxGuest' | extend receipt = parse_json(SyslogMessage) | where tostring(receipt.ownerToken) == '$($script:state.ownerToken)' | extend observedAt = todatetime(receipt.observedAtUtc) | summarize arg_max(observedAt, *) | project receipt=tostring(receipt)"
    $rows = @(Invoke-Azure @('monitor', 'log-analytics', 'query', '--workspace',
        $script:state.workspaceCustomerId, '--timespan', 'PT10M', '--analytics-query', $query))
    if ($rows.Count -ne 1 -or -not $rows[0]['receipt']) { throw 'No unambiguous telemetry; wait and repeat the read-only command.' }
    $receipt = $rows[0].receipt | ConvertFrom-Json -AsHashtable -DateKind String
    $marker = $receipt['marker']
    if ($receipt.schemaVersion -ne 1 -or $receipt.ownerToken -cne $script:state.ownerToken -or
        $receipt.service -cne 'retailtx-demo-posting-worker' -or
        $receipt.active -isnot [bool] -or $receipt.healthy -isnot [bool] -or
        $receipt.faultLifetime -cne 'Manual' -or
        $receipt.watchdogEnabled -isnot [bool] -or $receipt.watchdogEnabled -or
        $receipt.watchdogActive -isnot [bool] -or $receipt.watchdogActive -or -not $marker -or
        $marker.faultLifetime -cne 'Manual' -or $marker.canary -isnot [bool] -or $marker.canary -or
        ($marker.durationSeconds -isnot [int] -and $marker.durationSeconds -isnot [long]) -or
        $marker.durationSeconds -ne 0 -or $marker.deadlineUtc -or
        $marker.runId -cne $script:state.currentFault.runId -or
        $marker.actor -cne $script:state.currentFault.actor) { throw 'Foreign, incomplete or mismatched Manual receipt.' }
    $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$receipt.observedAtUtc).TotalSeconds
    if ($age -gt 180 -or $age -lt -30) { throw 'Telemetry is stale or future-dated; repeat Status/Ready later, never Fault.' }
    return $receipt
}

function Assert-GuestPresenterThread {
    param([hashtable]$Incident, [hashtable]$Connection)
    if (-not $Incident.threadId) { throw 'SRE thread is not available; reset/refault blocked until intake is reconciled.' }
    $thread = Invoke-DiskSreRequest $Connection GET "/api/v1/threads/$($Incident.threadId)/messages"
    if ($thread.state -cne 'Idle' -or -not $thread.ContainsKey('value') -or
        @($thread.value | Where-Object { $_['approval'] -and
            $_.approval.status -cnotin @('Approved', 'Rejected', 'Expired') }).Count -or
        @($thread.value | Where-Object { $_['azCliExecution'] -and
            $_.azCliExecution.status -cnotin @('Completed', 'Failed') }).Count) {
        throw 'SRE thread, approval or action is unsettled; reject pending cards in SRE and wait.'
    }
    Assert-GuestRecoveryResetSafe (Get-GuestPresenterReceipt) -RequireSkillGuard
}

function Get-GuestPresenterOperator {
    $credentials = Invoke-Azure @('account', 'get-access-token', '--resource', 'https://management.azure.com/')
    $parts = $credentials.accessToken.Split('.')
    if ($parts.Count -ne 3) { throw 'Malformed operator token.' }
    $encoded = $parts[1].Replace('-', '+').Replace('_', '/')
    $encoded = $encoded.PadRight($encoded.Length + (4 - $encoded.Length % 4) % 4, '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) |
        ConvertFrom-Json -AsHashtable
    $credentials = $null
    if ($claims.tid -ine $script:state.tenantId -or
        $claims.aud.TrimEnd('/') -cne 'https://management.azure.com') { throw 'Wrong presenter token context.' }
    return ([guid]$claims.oid).ToString()
}

function Get-GuestPresenterAudit {
    param([hashtable]$Record)
    $start = [DateTimeOffset]$Record.submittedAtUtc
    $events = @(Invoke-Azure @('monitor', 'activity-log', 'list', '--resource-id', $vmId,
        '--start-time', $start.ToUniversalTime().ToString('o'),
        '--end-time', $start.AddMinutes(30).ToUniversalTime().ToString('o'), '--max-events', '100'))
    $action = @($events | Where-Object { $_.resourceId -ieq $vmId -and
        $_.operationName.value -ieq 'Microsoft.Compute/virtualMachines/runCommand/action' -and
        $_['claims'] -and
        $_.claims['http://schemas.microsoft.com/identity/claims/objectidentifier'] -ieq $Record.request.actor })
    $ids = @($action | Where-Object { $_.status.value -iin @('Started', 'Accepted') -and
        [DateTimeOffset]$_.eventTimestamp -ge $start -and
        [DateTimeOffset]$_.eventTimestamp -le $start.AddMinutes(2) } |
        ForEach-Object correlationId | Select-Object -Unique)
    if ($ids.Count -gt 1) { throw 'Ambiguous presenter command audit; never replay.' }
    if ($ids.Count -eq 0) { return }
    $terminal = @($action | Where-Object { $_.correlationId -ceq $ids[0] -and
        $_.status.value -iin @('Succeeded', 'Failed', 'Canceled') })
    if ($terminal.Count -gt 1) { throw 'Conflicting terminal audit; never replay.' }
    if ($terminal.Count -eq 1) { return $terminal[0] }
}

function Update-GuestPresenterStatus {
    $pending = $script:state.pendingCommand
    if ($pending) {
        $record = if ($pending.action -cin @('fault', 'reset')) {
            $script:presenterJournal[$pending.action]
        } else { $null }
        if (-not $record -or $pending['presenterJournal'] -cne $script:presenterProfile.journalPath -or
            (ConvertTo-DiskSreCanonicalJson $pending.request) -cne
            (ConvertTo-DiskSreCanonicalJson $record.request)) {
            throw 'Pending command is not this presenter intent. It was preserved; reconcile its own journal without replay.'
        }
    }
    $receipt = Get-GuestPresenterReceipt
    if ($script:presenterJournal['fault']) {
        foreach ($key in @('fault', 'reset')) {
            if (-not $script:presenterJournal[$key]) { continue }
            $record = $script:presenterJournal[$key]
            if (-not $record['audit']) { $record.audit = Get-GuestPresenterAudit $record }
            if ($record.audit -and $record.audit.status.value -cne 'Succeeded') {
                throw 'Presenter command has a terminal failure; reconcile this run instead of repeating it.'
            }
        }
        $resetSettled = -not $script:presenterJournal['reset']
        if (-not $resetSettled -and $script:presenterJournal.reset.audit) {
            $reset = $script:presenterJournal.reset
            $resetSettled = $receipt.marker.phase -ceq 'recovered' -and $receipt.active -and $receipt.healthy -and
                $receipt.marker.recoveryReason -ceq 'reset' -and
                $receipt.marker.recoveredBy -ceq $reset.request.actor -and
                [DateTimeOffset]$receipt.observedAtUtc -ge [DateTimeOffset]$reset.audit.eventTimestamp
            if (-not $resetSettled) { Write-Warning 'Reset audit arrived; exact post-reset health is still pending. Use Status, never repeat Reset.' }
        }
        if ($script:presenterJournal.fault.audit -and $resetSettled) {
            $script:state.pendingCommand = $null
            $script:state.phase = if ($receipt.marker.phase -ceq 'fault-active') { 'fault-active' } else { 'ready' }
        }
    }
    $script:state.lastEvidence = $receipt
    $script:state.observedAtUtc = $receipt.observedAtUtc
    Save-RetailState $script:state $script:presenterStatePath
    Save-GuestPresenterJournal
    return $receipt
}

function Test-GuestPresenterReady {
    Assert-GuestNativeReadSettled
    $connection = Assert-GuestPresenterConfiguration
    $receipt = Update-GuestPresenterStatus
    if ($script:state.pendingCommand -or $script:state.phase -cne 'ready' -or
        -not $receipt.active -or -not $receipt.healthy -or $receipt.marker.phase -cne 'recovered') {
        throw 'Fixture is not settled and healthy. Use Status; do not trigger another fault.'
    }
    $incident = Get-GuestMonitorIncident
    if ($incident.monitorCondition -cne 'Resolved') { throw 'Previous alert is not naturally Resolved.' }
    Assert-GuestPresenterThread $incident $connection
    return @{ phase = 'Ready'; vmName = ($vmId -split '/')[-1]; agentName = ($script:state.agentId -split '/')[-1]
        observedAtUtc = $receipt.observedAtUtc; runId = $receipt.marker.runId }
}

function Submit-GuestPresenterCommand {
    param([hashtable]$Request, [string]$Key)
    Assert-GuestNativeReadSettled
    if ($script:state.pendingCommand -or $script:presenterJournal[$Key]) {
        throw 'An intent already exists; use Status, never replay the command.'
    }
    $record = @{ request = $Request; submittedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); phase = 'SubmissionUnknown' }
    $script:presenterJournal[$Key] = $record
    Save-GuestPresenterJournal
    $script:state.pendingCommand = @{ action = $Request.action; request = $Request
        outcome = 'submission-unknown'; presenterJournal = $script:presenterProfile.journalPath }
    $script:state.phase = 'outcome-unknown'
    if ($Key -ceq 'fault') { $script:state.currentFault = $Request.Clone() }
    Save-RetailState $script:state $script:presenterStatePath
    $payload = ConvertTo-RetailGuestPayload $Request
    try {
        $null = Invoke-Azure @('vm', 'run-command', 'invoke', '--ids', $vmId, '--command-id', 'RunShellScript',
            '--scripts', "python3 /opt/retailtx-guest/controller.py '$payload'", '--no-wait')
    } catch {
        Write-Warning "Submission outcome unknown for run $($Request.runId). Use Status; do not repeat $Key."
        throw
    }
    $record.phase = 'Submitted'
    Save-GuestPresenterJournal
    return @{ phase = 'SubmittedNotVerified'; action = $Request.action; runId = $Request.runId
        next = 'Use Status to observe this same run. Do not repeat the trigger.' }
}

function Invoke-GuestPresenterFault {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([switch]$PresenterTriggered)
    if (-not $PresenterTriggered) { throw 'The presenter must explicitly trigger Fault with -PresenterTriggered.' }
    if ($script:presenterJournal['fault']) { throw 'This presentation run already has a fault intent; use Status or Reset.' }
    $null = Test-GuestPresenterReady
    if (-not $PSCmdlet.ShouldProcess($vmId, 'Stop the fixture worker until human-approved repair or explicit Reset')) { return }
    $request = @{ action = 'fault'; ownerToken = $script:state.ownerToken; runId = [guid]::NewGuid().ToString()
        actor = Get-GuestPresenterOperator; sourceHashes = $script:state.sourceHashes
        canary = $false; durationSeconds = 0; startBeforeUtc = [DateTimeOffset]::UtcNow.AddSeconds(90).ToString('o') }
    $script:presenterJournal.presenterTriggered = $true
    Submit-GuestPresenterCommand $request 'fault'
}

function Invoke-GuestPresenterReset {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([guid]$RunId)
    $archive = Join-Path $directory "presenter-$RunId.json"
    if (-not $script:presenterJournal['fault']) {
        if (-not (Test-Path -LiteralPath $archive) -or $script:state.currentFault.runId -cne $RunId.ToString()) {
            throw 'Reset requires this exact presenter run ID.'
        }
        $saved = Get-GuestPresenterJson $archive
        if ($saved.ownerToken -cne $script:state.ownerToken -or
            $saved.fault.request.runId -cne $RunId.ToString()) { throw 'Archived presenter run differs.' }
        $null = Test-GuestPresenterReady
        return @{ phase = 'ArchivedHealthy'; guestWrites = 0; alreadyArchived = $true; runId = $RunId.ToString() }
    }
    if (
        $RunId.ToString() -cne $script:presenterJournal.fault.request.runId) { throw 'Reset requires this exact presenter run ID.' }
    Assert-GuestNativeReadSettled
    $connection = Assert-GuestPresenterConfiguration
    $receipt = Update-GuestPresenterStatus
    if ($script:state.pendingCommand) { throw 'Presenter command is unsettled; use Status, not Reset.' }
    $incident = Get-GuestMonitorIncident
    Assert-GuestPresenterThread $incident $connection
    if ($receipt.marker.phase -ceq 'recovered' -and $receipt.active -and $receipt.healthy) {
        if ($incident.monitorCondition -cne 'Resolved') { throw 'Health recovered; wait for natural alert clearance before reset/reuse.' }
        if (-not $PSCmdlet.ShouldProcess($vmId, 'Archive the recovered presenter run locally; no guest command')) { return }
        if (Test-Path -LiteralPath $archive) {
            $saved = Get-GuestPresenterJson $archive
            $current = $script:presenterJournal.Clone()
            $saved.Remove('updatedAtUtc')
            $current.Remove('updatedAtUtc')
            if ((ConvertTo-DiskSreCanonicalJson $saved) -cne (ConvertTo-DiskSreCanonicalJson $current)) {
                throw 'Conflicting presenter archive; refusing overwrite.'
            }
        } else { Save-RetailState $script:presenterJournal $archive }
        $script:presenterJournal = @{ schemaVersion = 1; ownerToken = $script:state.ownerToken; phase = 'Prepared' }
        Save-GuestPresenterJournal
        return @{ phase = 'ArchivedHealthy'; guestWrites = 0; runId = $RunId.ToString() }
    }
    if ($receipt.marker.phase -cne 'fault-active' -or $receipt.active -or $receipt.healthy) { throw 'Reset encountered an ambiguous service state.' }
    if (-not $PSCmdlet.ShouldProcess($vmId, 'Operator fallback: recover only this exact fault, not an SRE-approved action')) { return }
    Submit-GuestPresenterCommand @{ action = 'reset'; ownerToken = $script:state.ownerToken
        runId = $RunId.ToString(); actor = Get-GuestPresenterOperator
        sourceHashes = $script:state.sourceHashes } 'reset'
}
