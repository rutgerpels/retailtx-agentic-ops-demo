#Requires -Version 7.5
# Mocked Azure/SRE calls only; fault/reset requests never leave this process.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\Azure.Common.psm1') -Force
. (Join-Path $root 'scripts\disk\DiskSre.ps1')
. (Join-Path $root 'scripts\guest\GuestMonitor.ps1')
. (Join-Path $root 'scripts\guest\GuestRecoverySkill.ps1')
. (Join-Path $root 'scripts\guest\GuestNativeRead.ps1')
. (Join-Path $root 'scripts\guest\GuestPresenter.ps1')
$temporary = Join-Path ([IO.Path]::GetTempPath()) "retailtx-presenter-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path (Join-Path $temporary '.azure\demo01') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $temporary 'scripts\guest') -Force
$script:checks = 0
$script:azureWrites = @()
$script:otherRunning = $false
$script:stale = $false
$script:unsettled = $false
$script:failSubmission = $false
$script:auditVisible = $false
$script:healthy = $true
$script:resolved = $true
$script:receiptRun = $null
$script:grantDrift = $false
function Copy-TestValue { param($Value) $Value | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable -DateKind String }
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe presenter operation was accepted.' }
    $script:checks++
}
function Get-TestReceipt {
    $marker = @{ runId = if ($script:receiptRun) { $script:receiptRun } else { $script:state.currentFault.runId }
        actor = $script:state.currentFault.actor; faultLifetime = 'Manual'; durationSeconds = 0
        canary = $false; deadlineUtc = $null; phase = if ($script:healthy) { 'recovered' } else { 'fault-active' }
        recoveredBy = if ($script:presenterJournal['reset'] -and $script:healthy) {
            $script:presenterJournal.reset.request.actor
        } else { $script:state.agentPrincipalId }
        recoveryReason = if ($script:presenterJournal['reset'] -and $script:healthy) { 'reset' } else { 'repair' } }
    return @{ schemaVersion = 1; ownerToken = $script:state.ownerToken; service = 'retailtx-demo-posting-worker'
        faultLifetime = 'Manual'; watchdogEnabled = $false; watchdogActive = $false
        active = $script:healthy; healthy = $script:healthy; marker = $marker
        observedAtUtc = [DateTimeOffset]::UtcNow.AddSeconds($(if ($script:stale) { -200 } else { 0 })).ToString('o') }
}
function Invoke-Azure {
    param([string[]]$Arguments)
    switch ("$($Arguments[0]) $($Arguments[1])") {
        'account show' { return @{ id = $subscription; tenantId = $script:state.tenantId } }
        'account get-access-token' {
            $claims = @{ oid = $script:state.currentFault.actor; tid = $script:state.tenantId; aud = 'https://management.azure.com/' }
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress)))
            return @{ accessToken = "header.$payload.signature" }
        }
        'vm show' { return @{ id = $vmId; tags = @{ ownerToken = $script:state.ownerToken; environmentId = $EnvironmentName } } }
        'vm get-instance-view' { return @{ instanceView = @{ statuses = @(@{ code = 'PowerState/running' }) } } }
        'resource list' { return @($script:state.agentId, "$($script:state.groupId)/providers/Microsoft.App/agents/other") }
        'resource show' {
            $id = $Arguments[3]
            if ($id -ceq $script:state.agentId) { return $script:testAgentResource }
            if ($id -ceq $script:state.alertId) { return @{ tags = @{ ownerToken = $script:state.ownerToken }; properties = @{ enabled = $true } } }
            return @{ properties = @{ runningState = if ($script:otherRunning) { 'Running' } else { 'Stopped' } } }
        }
        'identity show' { return @{ principalId = $script:state.agentPrincipalId } }
        'role assignment' {
            if ($script:grantDrift) { return @() }
            return $script:presenterGuidance.after.Roles
        }
        'monitor log-analytics' { return @(@{ receipt = (Get-TestReceipt | ConvertTo-Json -Depth 10 -Compress) }) }
        'monitor activity-log' {
            if (-not $script:auditVisible) { return @() }
            $requestedStart = [DateTimeOffset]$Arguments[([array]::IndexOf($Arguments, '--start-time') + 1)]
            $record = @(
                foreach ($key in @('fault', 'reset')) {
                    if ($script:presenterJournal[$key] -and
                        [DateTimeOffset]$script:presenterJournal[$key].submittedAtUtc -eq $requestedStart) {
                        $script:presenterJournal[$key]
                    }
                }
            )[0]
            $start = [DateTimeOffset]$record.submittedAtUtc
            return @(
                @{ resourceId = $vmId; caller = 'operator@example.invalid'; claims = @{ 'http://schemas.microsoft.com/identity/claims/objectidentifier' = $record.request.actor }; correlationId = 'one'; operationName = @{ value = 'Microsoft.Compute/virtualMachines/runCommand/action' }; status = @{ value = 'Started' }; eventTimestamp = $start.ToString('o') },
                @{ resourceId = $vmId; caller = 'operator@example.invalid'; claims = @{ 'http://schemas.microsoft.com/identity/claims/objectidentifier' = $record.request.actor }; correlationId = 'one'; operationName = @{ value = 'Microsoft.Compute/virtualMachines/runCommand/action' }; status = @{ value = 'Succeeded' }; eventTimestamp = $start.ToString('o') }
            )
        }
        'vm run-command' {
            $script:azureWrites += ,$Arguments
            if ($script:failSubmission) { throw 'Mock unknown submission result.' }
            return
        }
        default { throw "Unexpected mock Azure operation: $($Arguments[0]) $($Arguments[1])" }
    }
}
function Invoke-DiskSreRequest {
    param($Connection, $Method, $Path)
    if ($Method -cne 'GET') { throw 'Presenter attempted an SRE mutation.' }
    switch -Regex ($Path) {
        '/skills/guest-service-recovery$' { return $script:presenterGuidance.after.Skill }
        '/extendedAgent/agents/' { return $script:presenterGuidance.after.Agent }
        '/incidentFilters/' { return $script:presenterGuidance.after.Plan }
        '/settings/global$' { return $script:presenterGuidance.after.Policy }
        '/threads/' { return @{ state = if ($script:unsettled) { 'Running' } else { 'Idle' }; value = @() } }
        default { throw 'Unexpected mock SRE read.' }
    }
}
function Get-GuestMonitorIncident {
    return @{ threadId = [guid]::Empty.ToString(); monitorCondition = if ($script:resolved) { 'Resolved' } else { 'Fired' } }
}
try {
    $script:subscription = [guid]::NewGuid().ToString()
    $script:EnvironmentName = 'demo01'
    $group = "/subscriptions/$subscription/resourceGroups/rg-retailtx-guest-demo01-swedencentral"
    $script:vmId = "$group/providers/Microsoft.Compute/virtualMachines/vm-retailtx-guest-demo01"
    $script:state = @{ schemaVersion = 2; profile = 'guest-service'; subscriptionId = $subscription
        tenantId = [guid]::NewGuid().ToString(); ownerToken = [guid]::NewGuid().ToString()
        environmentName = $EnvironmentName; location = 'swedencentral'; groupId = $group; vmId = $vmId
        agentId = "$group/providers/Microsoft.App/agents/guest"; agentIdentityId = "$group/providers/Microsoft.ManagedIdentity/userAssignedIdentities/guest"
        agentPrincipalId = [guid]::NewGuid().ToString(); workspaceCustomerId = [guid]::NewGuid().ToString()
        workspaceId = "$group/providers/Microsoft.OperationalInsights/workspaces/guest"
        alertId = "$group/providers/Microsoft.Insights/scheduledQueryRules/guest"
        phase = 'ready'; pendingCommand = $null; sourceHashes = @{}; artifactHashes = @{ preserved = 'original' }
        withSreExecution = $true; withMonitoring = $true; faultLifetime = 'Manual'; monitorReadMode = 'Operator'
        monitorTransport = 'Public'
        currentFault = @{ runId = [guid]::NewGuid().ToString(); actor = [guid]::NewGuid().ToString()
            canary = $false; startBeforeUtc = [DateTimeOffset]::UtcNow.ToString('o') } }
    foreach ($name in @('controller.py', 'bootstrap.py', 'worker.py', 'retailtx-demo-posting-worker.service',
        'retailtx-guest-watchdog.service', 'retailtx-guest-watchdog.timer', 'retailtx-guest-observer.service',
        'retailtx-guest-observer.timer')) {
        $file = Join-Path $temporary "scripts\guest\$name"
        Set-Content -LiteralPath $file -Value 'frozen test source'
        $script:state.sourceHashes[$name] = (Get-FileHash $file).Hash.ToLowerInvariant()
    }
    $statePath = Join-Path $temporary '.azure\demo01\guest-service-state.json'
    Save-RetailState $script:state $statePath
    $role = @{ id = "$group/providers/Microsoft.Authorization/roleAssignments/test"; scope = $group
        principalId = $script:state.agentPrincipalId; roleDefinitionId = "$group/providers/Microsoft.Authorization/roleDefinitions/test"
        principalType = 'ServicePrincipal' }
    $guidance = @{ phase = 'InstalledAndReadbackVerified'; statePath = $statePath
        ownerToken = $script:state.ownerToken; agentId = $script:state.agentId
        sourceHashes = $script:state.sourceHashes; artifactHashes = $script:state.artifactHashes
        after = @{ Skill = New-GuestRecoverySkillSpecification; Agent = New-GuestRecoveryInvestigator
            Plan = @{ name = 'retailtx-guest-demo01'; properties = @{ agentMode = 'review'; handlingAgent = 'retailtx-guest-demo01'
                mergeEnabled = $false; titleContains = 'demo01'; isEnabled = $true
                azMonitorFilterSettings = @{ targetResourceType = 'Microsoft.Compute/virtualMachines'; targetResource = $vmId } } }
            Policy = @{ permissions = @{ allow = @(); ask = @('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)')
                deny = @('RunInTerminal', 'RunShellCommand', 'ExecutePythonCode') } }; Roles = @($role) } }
    $guidancePath = Join-Path $temporary 'guidance.json'
    Save-RetailState $guidance $guidancePath
    $profilePath = Join-Path $temporary 'profile.json'
    Save-RetailState @{ schemaVersion = 1; scenario = 'guest-service'; guidancePath = $guidancePath
        guidanceSha256 = (Get-FileHash $guidancePath).Hash; journalPath = "$profilePath.session.json" } $profilePath
    $script:testAgentResource = @{ tags = @{ ownerToken = $script:state.ownerToken }
        properties = @{ agentEndpoint = 'https://demo.azuresre.ai/'; runningState = 'Running'
            actionConfiguration = @{ mode = 'Review'; identity = $script:state.agentIdentityId }
            incidentManagementConfiguration = @{ type = 'AzMonitor' } } }
    Initialize-GuestPresenter $profilePath
    if ((Test-GuestPresenterReady).phase -cne 'Ready' -or $script:azureWrites.Count) { throw 'Ready was not read-only.' }
    foreach ($phase in @('Accepted', 'SubmissionUnknown')) {
        $script:state.nativeRead = @{ phase = $phase }
        Assert-Rejected { Test-GuestPresenterReady }
        Assert-Rejected { Invoke-GuestPresenterFault -PresenterTriggered -Confirm:$false }
    }
    $script:state.Remove('nativeRead')
    $script:otherRunning = $true
    Assert-Rejected { Invoke-GuestPresenterFault -PresenterTriggered -Confirm:$false }
    $script:otherRunning = $false
    $script:stale = $true
    Assert-Rejected { Test-GuestPresenterReady }
    $script:stale = $false
    $script:grantDrift = $true
    Assert-Rejected { Invoke-GuestPresenterFault -PresenterTriggered -Confirm:$false }
    $script:grantDrift = $false
    $script:unsettled = $true
    Assert-Rejected { Invoke-GuestPresenterFault -PresenterTriggered -Confirm:$false }
    $script:unsettled = $false
    $script:resolved = $false
    Assert-Rejected { Invoke-GuestPresenterFault -PresenterTriggered -Confirm:$false }
    $script:resolved = $true
    Assert-Rejected { Invoke-GuestPresenterFault -Confirm:$false }
    Invoke-GuestPresenterFault -PresenterTriggered -WhatIf
    if ($script:azureWrites.Count -or $script:presenterJournal['fault']) { throw 'WhatIf created fault intent.' }
    $script:failSubmission = $true
    Assert-Rejected { Invoke-GuestPresenterFault -PresenterTriggered -Confirm:$false }
    if ($script:azureWrites.Count -ne 1 -or -not $script:state.pendingCommand) { throw 'Unknown submission was not persisted.' }
    $run = $script:presenterJournal.fault.request.runId
    $payloadIndex = [array]::IndexOf($script:azureWrites[0], '--scripts') + 1
    $encoded = ($script:azureWrites[0][$payloadIndex] -split "'")[1]
    $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json -AsHashtable
    if ($request.action -cne 'fault' -or $request.canary -ne $false -or $request.durationSeconds -ne 0 -or
        -not ($script:azureWrites[0] -ccontains '--no-wait')) { throw 'Presenter fault contract changed.' }
    Initialize-GuestPresenter $profilePath
    Assert-Rejected { Invoke-GuestPresenterFault -PresenterTriggered -Confirm:$false }
    Assert-Rejected { Invoke-GuestPresenterReset -RunId ([guid]::NewGuid()) -Confirm:$false }
    $script:failSubmission = $false
    $script:healthy = $false
    $script:resolved = $false
    $null = Update-GuestPresenterStatus
    if (-not $script:state.pendingCommand) { throw 'Missing audit cleared unknown command.' }
    Assert-Rejected { Invoke-GuestPresenterReset -RunId $run -Confirm:$false }
    $script:auditVisible = $true
    $null = Update-GuestPresenterStatus
    if ($script:state.pendingCommand) { throw 'Exact fault receipt and terminal audit did not settle admission.' }
    $foreign = @{ action = 'repair'; request = @{ action = 'repair'; runId = $run }; outcome = 'submission-unknown' }
    $script:state.pendingCommand = $foreign
    Assert-Rejected { Update-GuestPresenterStatus }
    Assert-Rejected { Invoke-GuestPresenterReset -RunId $run -Confirm:$false }
    if ($script:state.pendingCommand -ne $foreign) { throw 'Foreign pending command was erased.' }
    $script:state.pendingCommand = @{ action = 'fault'; presenterJournal = $script:presenterProfile.journalPath
        request = @{ action = 'fault'; runId = [guid]::NewGuid().ToString() } }
    Assert-Rejected { Update-GuestPresenterStatus }
    if (-not $script:state.pendingCommand) { throw 'Mismatched presenter request was erased.' }
    $script:state.pendingCommand = $null
    foreach ($phase in @('Accepted', 'SubmissionUnknown')) {
        $script:state.nativeRead = @{ phase = $phase }
        Assert-Rejected { Invoke-GuestPresenterReset -RunId $run -Confirm:$false }
        Assert-Rejected { Submit-GuestPresenterCommand @{ action = 'reset' } 'reset' }
    }
    $script:state.Remove('nativeRead')
    $script:unsettled = $true
    Assert-Rejected { Invoke-GuestPresenterReset -RunId $run -Confirm:$false }
    $script:unsettled = $false
    Invoke-GuestPresenterReset -RunId $run -WhatIf
    if ($script:azureWrites.Count -ne 1) { throw 'Reset WhatIf mutated Azure.' }
    $null = Invoke-GuestPresenterReset -RunId $run -Confirm:$false
    if ($script:azureWrites.Count -ne 2) { throw 'Fallback reset was not single submission.' }
    Assert-Rejected { Invoke-GuestPresenterReset -RunId $run -Confirm:$false }
    if ($script:azureWrites.Count -ne 2) { throw 'Reset replay occurred.' }
    $script:healthy = $true
    $script:resolved = $true
    $null = Update-GuestPresenterStatus
    if ($script:state.pendingCommand) { throw 'Confirmed operator reset did not settle.' }
    $archive = Join-Path $directory "presenter-$run.json"
    $conflict = Copy-TestValue $script:presenterJournal
    $conflict.ownerToken = [guid]::NewGuid().ToString()
    Save-RetailState $conflict $archive
    Assert-Rejected { Invoke-GuestPresenterReset -RunId $run -Confirm:$false }
    Save-RetailState $script:presenterJournal $archive
    $archived = Invoke-GuestPresenterReset -RunId $run -Confirm:$false
    if ($archived.phase -cne 'ArchivedHealthy' -or $script:azureWrites.Count -ne 2) {
        throw 'Interrupted local archive could not finish without a guest write.'
    }
    $null = Invoke-GuestPresenterReset -RunId $run -Confirm:$false
    $null = Test-GuestPresenterReady
    if ($script:presenterJournal['fault'] -or $script:azureWrites.Count -ne 2) { throw 'Archived run could not be reused safely.' }
    $null = Invoke-GuestPresenterFault -PresenterTriggered -Confirm:$false
    $nextRun = $script:presenterJournal.fault.request.runId
    if ($nextRun -ceq $run -or $script:azureWrites.Count -ne 3) { throw 'New presentation did not get a distinct run.' }
    $null = Update-GuestPresenterStatus
    $archived = Invoke-GuestPresenterReset -RunId $nextRun -Confirm:$false
    if ($archived.phase -cne 'ArchivedHealthy' -or $script:azureWrites.Count -ne 3) {
        throw 'SRE-recovered run archive submitted an unnecessary operator reset.'
    }
    $script:receiptRun = [guid]::NewGuid().ToString()
    Assert-Rejected { Get-GuestPresenterReceipt }
    $script:receiptRun = $null
    $frozenPath = Join-Path $temporary 'scripts\guest\controller.py'
    Set-Content -LiteralPath $frozenPath -Value 'changed'
    Assert-Rejected { Initialize-GuestPresenter $profilePath }
    Write-Output "Guest presenter contracts passed ($script:checks rejection checks; three mocked submissions, no live calls)."
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force }
