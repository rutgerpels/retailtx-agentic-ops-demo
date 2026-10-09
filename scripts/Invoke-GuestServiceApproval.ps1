#Requires -Version 7.2
<#
.SYNOPSIS
Propose and inspect human-approved native SRE guest repair.
.DESCRIPTION
Uses an isolated Review-mode fixture. Never approves actions or authorizes OBO.
Guest evidence is operator-collected; every SRE guest command requires its own
human approval. A pending card is not recovery acceptance.
.PARAMETER Operation
Configure installs approval policies on the owned isolated agent before faults.
Propose creates one durable thread intent, Read saves evidence, Verify checks
the native result and Azure caller before supplying recovery evidence.
.PARAMETER SubscriptionId
Explicit authorized subscription.
.PARAMETER EnvironmentName
Owned fixture created with WithSreExecution.
.EXAMPLE
.\scripts\Invoke-GuestServiceApproval.ps1 Propose -SubscriptionId <guid> -EnvironmentName demo20
.OUTPUTS
Thread identity, exact native execution records, and approval state.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('Configure', 'Propose', 'Read', 'Verify')][string]$Operation,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo20'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
if ($WhatIfPreference) {
    $null = $PSCmdlet.ShouldProcess($EnvironmentName, "$Operation supervised SRE guest approval (no preflight or local writes)")
    return
}
$directory = Join-Path (Split-Path -Parent $PSScriptRoot) ".azure\$EnvironmentName"
$statePath = Join-Path $directory 'guest-service-state.json'
$requestPath = Join-Path $directory 'guest-approval-request.json'
$followupPath = Join-Path $directory 'guest-approval-recovery.json'
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
$account = Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments @('account', 'show') -TimeoutSeconds 90
if ($state.schemaVersion -ne 2 -or $state.profile -cne 'guest-service' -or
    $state.subscriptionId -ine $SubscriptionId.ToString() -or $state.tenantId -ine $account.tenantId -or
    $state.environmentName -cne $EnvironmentName -or -not $state['withSreExecution'] -or
    $state.agentId -notlike "$($state.groupId)/providers/Microsoft.App/agents/*") {
    throw 'Expected an owned isolated execution fixture; shared SRE is not an execution target.'
}
$owner = [guid]::Parse($state.ownerToken).ToString()
$principal = [guid]::Parse($state.agentPrincipalId).ToString()
if ($state.groupId -ine "/subscriptions/$SubscriptionId/resourceGroups/rg-retailtx-guest-$EnvironmentName-swedencentral" -or
    $state.vmId -ine "$($state.groupId)/providers/Microsoft.Compute/virtualMachines/vm-retailtx-guest-$EnvironmentName") {
    throw 'Guest repair target does not match owned fixture naming and scope.'
}
$vm = Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments @(
    'resource', 'show', '--ids', $state.vmId, '--api-version', '2025-11-01'
) -TimeoutSeconds 90
if ($vm.tags.ownerToken -cne $owner -or $vm.tags.profile -cne 'guest-service' -or
    $vm.tags.environmentId -cne $EnvironmentName) {
    throw 'Live VM is not the owned guest-service fixture.'
}
$agent = Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments @(
    'resource', 'show', '--ids', $state.agentId, '--api-version', '2026-01-01'
) -TimeoutSeconds 90
if ($agent.tags.ownerToken -cne $owner -or $agent.properties.actionConfiguration.mode -cne 'Review' -or
    $agent.properties.actionConfiguration.identity -ine $state.agentIdentityId) {
    throw 'Owned SRE Review mode or action identity changed.'
}
$uri = [uri]$agent.properties.agentEndpoint
if ($uri.Scheme -cne 'https' -or -not $uri.Host.EndsWith('.azuresre.ai', [StringComparison]::OrdinalIgnoreCase) -or
    $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
    throw 'Unexpected SRE endpoint; refusing authentication.'
}
$endpoint = $uri.AbsoluteUri.TrimEnd('/')
$marker = "RetailTx approved guest proof owner $owner."
$lock = [IO.File]::Open((Join-Path $directory 'guest-approval.lock'), 'OpenOrCreate', 'ReadWrite', 'None')

function Invoke-ApprovalRequest {
    param([ValidateSet('Get', 'Post', 'Put')][string]$Method, [string]$Path, [hashtable]$Body, [hashtable]$Headers)
    $parameters = @{ Uri = "$endpoint$Path"; Method = $Method; Authentication = 'Bearer'
        Token = $token; MaximumRedirection = 0; TimeoutSec = 60 }
    if ($Body) { $parameters.ContentType = 'application/json'; $parameters.Body = $Body | ConvertTo-Json -Depth 35 }
    if ($Headers) { $parameters.Headers = $Headers }
    try {
        $response = Invoke-RestMethod @parameters
        return ($response | ConvertTo-Json -Depth 80 | ConvertFrom-Json -AsHashtable)
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        throw "SRE HTTP failure ($([int]$_.Exception.Response.StatusCode)); preserve intent and never replay a POST."
    }
}

function Assert-ApprovalPolicy {
    param([hashtable]$Settings)
    if (-not $Settings.ContainsKey('permissions') -or
        $Settings.permissions -isnot [hashtable] -or -not $Settings.permissions.ContainsKey('allow') -or
        $Settings.permissions.allow -isnot [array] -or @($Settings.permissions.allow).Count -ne 0) {
        throw 'Tool Allow rules can bypass Review; refusing approval proof.'
    }
    foreach ($rule in @('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)')) {
        if ($rule -cnotin $Settings.permissions.ask) { throw "Required approval policy missing: $rule." }
    }
    foreach ($rule in @('RunInTerminal', 'RunShellCommand', 'ExecutePythonCode')) {
        if ($rule -cnotin $Settings.permissions.deny) { throw "Alternative execution channel is not denied: $rule." }
    }
}

function New-ApprovedRepairCommand {
    param([hashtable]$Fixture, [hashtable]$Guest)
    if ($Guest.marker.phase -cne 'fault-active' -or $Guest.active -ne $false -or $Guest.healthy -ne $false -or
        $Guest.marker.canary -ne $false -or
        [DateTimeOffset]$Guest.marker.deadlineUtc -le [DateTimeOffset]::UtcNow.AddSeconds(120) -or
        [DateTimeOffset]$Guest.observedAtUtc -lt [DateTimeOffset]::UtcNow.AddMinutes(-3) -or
        [DateTimeOffset]$Guest.observedAtUtc -gt [DateTimeOffset]::UtcNow.AddSeconds(30)) {
        throw 'Proposal requires fresh active non-canary fault with enough human approval time.'
    }
    $repair = @{ action = 'repair'; ownerToken = $Fixture.ownerToken
        actor = ([guid]$Fixture.agentPrincipalId).ToString(); runId = ([guid]$Guest.marker.runId).ToString()
        expectedDeadlineUtc = ([DateTimeOffset]$Guest.marker.deadlineUtc).ToUniversalTime().ToString('o') }
    $json = $repair | ConvertTo-Json -Depth 10 -Compress
    $code = "import base64,json,subprocess`nr=$json`nr['sourceHashes']=json.load(open('/opt/retailtx-guest/config.json'))['sourceHashes']`nsubprocess.run(['python3','/opt/retailtx-guest/controller.py',base64.b64encode(json.dumps(r).encode()).decode()],check=True)"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($code))
    return "az vm run-command invoke --ids $($Fixture.vmId) --subscription $($Fixture.subscriptionId) --command-id RunShellScript --scripts 'echo $encoded | base64 --decode | python3' --output json"
}

function Assert-ApprovedExecution {
    param([hashtable]$Execution, [string]$Command)
    $null = [guid]::Parse($Execution.id)
    $call = $Execution.originalFunctionCall | ConvertFrom-Json -AsHashtable
    if ($Execution.command -cne $Command -or $call.Name -cne 'RunAzCliWriteCommands' -or
        $call.Arguments.command -cne $Command -or @($call.Arguments.Keys).Count -ne 1 -or
        $Execution.requiredScopes) {
        throw 'Not the exact native managed-identity repair; OBO or altered commands are not accepted.'
    }
}

function Assert-ApprovalStatus {
    param([hashtable]$Current, [hashtable]$Execution, [string]$Command)
    if ($Current.id -cne $Execution.id -or $Current.command -cne $Command -or
        $Current.status -cne $Execution.status -or $Current.requiredScopes) {
        throw 'Execution changed during observation or requested OBO; Read again.'
    }
    if ($Current.status -ceq 'Pending' -and ($Current.startedTimestamp -or $Current.completedTimestamp)) {
        throw 'Live approval card is not an unexecuted pending action.'
    }
    if ($Current.status -ceq 'Completed' -and (-not $Current.completedTimestamp -or $Current.error)) {
        throw 'Native execution is not confirmed completed successfully.'
    }
}

function Assert-ApprovedRecovery {
    param([hashtable]$Guest, [hashtable]$Initial, [string]$Principal)
    if ($Guest.marker.runId -cne $Initial.runId -or $Guest.marker.actor -cne $Initial.actor -or
        [DateTimeOffset]$Guest.marker.deadlineUtc -ne [DateTimeOffset]$Initial.deadlineUtc -or
        $Guest.marker.phase -cne 'recovered' -or $Guest.marker.recoveryReason -cne 'repair' -or
        $Guest.marker.recoveredBy -cne $Principal -or $Guest.active -ne $true -or $Guest.healthy -ne $true -or
        [DateTimeOffset]$Guest.marker.recoveredAtUtc -ge [DateTimeOffset]$Initial.deadlineUtc -or
        [DateTimeOffset]$Guest.observedAtUtc -lt [DateTimeOffset]::UtcNow.AddMinutes(-3) -or
        [DateTimeOffset]$Guest.observedAtUtc -gt [DateTimeOffset]::UtcNow.AddSeconds(30)) {
        throw 'Recovery is not fresh exact-run SRE repair before watchdog expiry.'
    }
}

try {
    $credentials = Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments @(
        'account', 'get-access-token', '--resource', 'https://azuresre.dev'
    ) -TimeoutSeconds 90
    $token = ConvertTo-SecureString $credentials.accessToken -AsPlainText -Force
    $credentials = $null
    $settings = Invoke-ApprovalRequest Get '/api/v2/agent/settings/global'
    if ($Operation -eq 'Configure') {
        if (Test-Path -LiteralPath $requestPath) { throw 'Do not modify approval policy after proposal creation.' }
        if (-not $PSCmdlet.ShouldProcess($state.agentId, 'Set isolated approval and alternative-channel deny policies')) { return }
        $policy = @{ permissions = @{ allow = @()
            ask = @('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)')
            deny = @('RunInTerminal', 'RunShellCommand', 'ExecutePythonCode') } }
        Save-RetailState @{ ownerToken = $owner; agentId = $state.agentId; before = $settings; intended = $policy
            phase = 'Requested' } (Join-Path $directory 'guest-approval-policy.json')
        $policyResponse = Invoke-WebRequest -Uri "$endpoint/api/v2/agent/settings/global" `
            -Authentication Bearer -Token $token -MaximumRedirection 0 -TimeoutSec 60
        $etag = @($policyResponse.Headers['ETag'])[0]
        if (-not $etag) {
            $fresh = $policyResponse.Content | ConvertFrom-Json -AsHashtable
            if (-not $fresh.ContainsKey('permissions') -or
                @($fresh.permissions.allow).Count -ne 0 -or @($fresh.permissions.ask).Count -ne 0 -or
                @($fresh.permissions.deny).Count -ne 0) {
                throw 'Nonempty global policy supplied no ETag; refusing unconditional overwrite.'
            }
            # The deployed SRE UI uses * only for the empty, absent initial document.
            $etag = '*'
        }
        $null = Invoke-ApprovalRequest Put '/api/v2/agent/settings/global' $policy @{ 'If-Match' = $etag }
        $settings = Invoke-ApprovalRequest Get '/api/v2/agent/settings/global'
        Assert-ApprovalPolicy $settings
        Save-RetailState @{ ownerToken = $owner; agentId = $state.agentId; observed = $settings
            phase = 'Verified'; observedAt = [DateTimeOffset]::UtcNow.ToString('o') } (Join-Path $directory 'guest-approval-policy.json')
        return [pscustomobject]@{ agentId = $state.agentId; phase = 'ApprovalPolicyVerified' }
    }
    Assert-ApprovalPolicy $settings
    if ($Operation -eq 'Propose') {
        if (Test-Path -LiteralPath $requestPath) { throw 'Creation intent exists; Read/reconcile without replay.' }
        if ($state.pendingCommand) { throw 'Operator command outcome unknown; reconcile before proposing.' }
        # Use the saved fault receipt: proposal inspection must not submit a guest command.
        $guest = $state.lastEvidence
        $command = New-ApprovedRepairCommand $state $guest
        $text = @"
$marker
Supervised HUMAN-APPROVAL guest-service proof on a disposable native Azure VM, not Arc, autonomous healing or retail recovery.
The operator-collected fault receipt is evidence data, not your independent guest observation:
$($guest | ConvertTo-Json -Depth 15 -Compress)
Target: $($state.vmId). Action identity principal: $principal.
Investigate only Azure resource/instance-view and Activity Log read APIs. Instance view statuses are instanceView.statuses. No guest diagnostic scripts.
Explain running VM versus stopped application, exact run/deadline and watchdog risk. Request ONE real native RunAzCliWriteCommands approval card containing EXACTLY:
$command
Copy the command verbatim; do not decode, re-encode, shorten or edit its payload. The short wrapper loads root-owned source hashes and calls the attested controller with explicit owner, current run, action principal and deadline. It only repairs the fixture while that fault is still active before expiry.
STOP at the pending card. A human must click Approve in SRE; never use terminal/Python, OBO, permissions changes, thread allow rules, hooks or other tools to execute or bypass approval.
Do not request guest diagnostic/status commands. After human approval use only Azure read APIs for audit; label application verification UNKNOWN until separately supplied operator-collected evidence. If the deadline expires, do not execute or substitute a new repair. Broad privileged scripting is VM-scoped, not service-only enforced. Keep Review.
"@
        if (-not $PSCmdlet.ShouldProcess($state.agentId, 'Create human-approval guest repair proposal')) { return }
        $intent = @{ schemaVersion = 1; ownerToken = $owner; agentId = $state.agentId
            environmentName = $EnvironmentName; phase = 'Requested'; threadId = $null
            requestedAt = [DateTimeOffset]::UtcNow.ToString('o'); initial = $guest.marker
            expectedCommand = $command; text = $text; authorization = 'human-ui-required' }
        Save-RetailState $intent $requestPath
        $created = Invoke-ApprovalRequest Post '/api/v1/threads' @{
            startMessage = @{ text = $text; userId = 'retailtx-operator-adapter'
                displayName = 'RetailTx operator adapter'; agent = ($state.agentId -split '/')[-1] }
        }
        $intent.threadId = [guid]::Parse($created.id).ToString()
        $intent.phase = 'Created'
        Save-RetailState $intent $requestPath
    }
    $saved = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($saved.ownerToken -cne $owner -or $saved.agentId -ine $state.agentId -or
        $saved.environmentName -cne $EnvironmentName -or -not $saved.threadId) {
        throw 'Unconfirmed or foreign thread intent; reconcile without replay.'
    }
    $threadId = [guid]::Parse($saved.threadId).ToString()
    $thread = Invoke-ApprovalRequest Get "/api/v1/threads/$threadId"
    if (-not $thread.startMessage.text.StartsWith($marker, [StringComparison]::Ordinal)) {
        throw 'Live thread owner marker differs.'
    }
    $messages = Invoke-ApprovalRequest Get "/api/v1/threads/$threadId/messages"
    Save-RetailState @{ ownerToken = $owner; threadId = $threadId; observedAt = [DateTimeOffset]::UtcNow.ToString('o')
        messages = $messages } (Join-Path $directory 'guest-approval-messages.json')
    $executions = @($messages.value | Where-Object { $_.azCliExecution } | ForEach-Object { $_.azCliExecution })
    $repairs = @($executions | Where-Object command -CEQ $saved.expectedCommand)
    foreach ($execution in $executions) {
        $call = $execution.originalFunctionCall | ConvertFrom-Json -AsHashtable
        if ($call.Name -ceq 'RunAzCliReadCommands' -and
            $execution.command -notmatch '(?i)run-command|runcommands' -and -not $execution.requiredScopes) {
            continue
        }
        Assert-ApprovedExecution $execution $saved.expectedCommand
    }
    $policyApprovals = @($messages.value | Where-Object { $_.approval } | ForEach-Object { $_.approval })
    foreach ($approval in $policyApprovals | Where-Object status -CEQ 'Pending') {
        if ($approval.command -cne $saved.expectedCommand) {
            throw 'Policy approval contains an altered repair; Reject it in SRE. No approval or execution was submitted.'
        }
        if ($approval.expiredByTimeout -ne $false -or $approval.decisionTimestamp -or
            $approval.approveForThread -ne $false -or $approval.approveScope -cne 'none' -or
            [DateTimeOffset]$saved.initial.deadlineUtc -le [DateTimeOffset]::UtcNow.AddSeconds(90)) {
            throw 'Policy approval expired or widens access; Cancel it in SRE.'
        }
        Save-RetailState @{ownerToken=$owner; threadId=$threadId; approval=$approval
            phase='ExactHumanPolicyApprovalPending'; observedAt=[DateTimeOffset]::UtcNow.ToString('o')
            limitation='Policy card precedes native execution; action identity audit is still required.'} `
            (Join-Path $directory 'guest-approval-before.json')
    }
    foreach ($repair in $repairs) {
        $current = Invoke-ApprovalRequest Get "/api/v1/azCliExecution/$threadId/$($repair.id)/status"
        Assert-ApprovalStatus $current $repair $saved.expectedCommand
    }
    $pending = @($executions | Where-Object { $_.status -in @('Pending', 'PendingAuthorization') })
    if ($pending.Count -gt 0) {
        if ($pending.Count -ne 1 -or $pending[0].command -cne $saved.expectedCommand -or
            $pending[0].status -cne 'Pending' -or $pending[0].expiredByTimeout -ne $false -or
            $pending[0].startedTimestamp -or $pending[0].completedTimestamp -or
            [DateTimeOffset]$saved.initial.deadlineUtc -le [DateTimeOffset]::UtcNow.AddSeconds(60)) {
            throw 'No safe exact pending approval: decline outstanding cards in SRE and tear down; never approve stale/altered/elevated proposals.'
        }
        $beforeApproval = @(Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments @(
            'monitor', 'activity-log', 'list', '--resource-id', $state.vmId, '--start-time',
            ([DateTimeOffset]$saved.requestedAt).ToUniversalTime().ToString('o')
        ) -TimeoutSeconds 90)
        $guestWrites = @($beforeApproval | Where-Object {
            $_.operationName.value -ieq 'Microsoft.Compute/virtualMachines/runCommand/action' -and
            $_.caller -ieq $principal
        })
        if ($guestWrites.Count -gt 0) { throw 'Action identity guest invocation observed before human approval; do not accept this proof.' }
        Save-RetailState @{ ownerToken = $owner; threadId = $threadId; observedAt = [DateTimeOffset]::UtcNow.ToString('o')
            pendingExecution = $current; matchingActionIdentityGuestEvents = $guestWrites
            limitation = 'Activity Log can be delayed; pending native card independently shows no start/completion.' } `
            (Join-Path $directory 'guest-approval-before.json')
    }
    if ($Operation -eq 'Verify') {
        if (Test-Path -LiteralPath $followupPath) { throw 'Recovery follow-up intent exists; Read without replay.' }
        if ($repairs.Count -ne 1 -or $repairs[0].status -cne 'Completed' -or $repairs[0].error -or
            -not $repairs[0].completedTimestamp -or $messages.state -cne 'Idle') {
            throw 'Verify requires exact completed native repair and idle thread.'
        }
        $log = @(Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments @(
            'monitor', 'activity-log', 'list', '--resource-id', $state.vmId, '--start-time',
            ([DateTimeOffset]$saved.requestedAt).ToUniversalTime().ToString('o')
        ) -TimeoutSeconds 90)
        $events = @($log | Where-Object {
            $_.operationName.value -ieq 'Microsoft.Compute/virtualMachines/runCommand/action' -and
            $_.status.value -ieq 'Succeeded' -and $_.caller -ieq $principal -and
            [DateTimeOffset]$_.eventTimestamp -ge [DateTimeOffset]$repairs[0].startedTimestamp -and
            [DateTimeOffset]$_.eventTimestamp -le ([DateTimeOffset]$repairs[0].completedTimestamp).AddMinutes(2)
        })
        if ($events.Count -ne 1) { throw 'Exact native action identity audit missing/ambiguous; wait for ingestion, do not claim recovery.' }
        # Explicit operator collection, never presented as an SRE guest query.
        $result = & (Join-Path $PSScriptRoot 'Invoke-GuestService.ps1') Status `
            -SubscriptionId $SubscriptionId -EnvironmentName $EnvironmentName
        Assert-ApprovedRecovery $result.evidence $saved.initial $principal
        if (-not $PSCmdlet.ShouldProcess($threadId, 'Supply audited operator-collected recovery evidence')) { return }
        $body = @{ text = "Native approved repair audit and operator-collected recovery receipt (not your guest query): $(@{ audit = $events[0]; guest = $result.evidence } | ConvertTo-Json -Depth 20 -Compress)`nRecord the exact run, actual action identity, health and limitations. No more guest commands/writes. Do not claim autonomous or business recovery."
            userId = 'retailtx-operator-adapter'; displayName = 'RetailTx operator adapter'
            agent = ($state.agentId -split '/')[-1] }
        $intent = @{ ownerToken = $owner; threadId = $threadId; phase = 'Requested'; body = $body
            authorization = 'human-ui-required-not-programmatic'; observedAt = [DateTimeOffset]::UtcNow.ToString('o') }
        Save-RetailState $intent $followupPath
        $intent.receipt = Invoke-ApprovalRequest Post "/api/v1/threads/$threadId/messages" $body
        $intent.phase = 'Delivered'
        Save-RetailState $intent $followupPath
    }
    [pscustomobject]@{ threadId = $threadId; agentId = $state.agentId; endpoint = $endpoint
        state = $messages.state; authorization = 'HumanUiRequired'; expectedCommand = $saved.expectedCommand
        deadlineUtc = $saved.initial.deadlineUtc; executions = $executions
        response = @($messages.value | Where-Object { $_.author.role -eq 'SREAgent' -and $_.text -and
            $_.messageType -ne 'Reasoning' } | Select-Object -Last 2 -ExpandProperty text) }
} finally {
    $token = $null
    $lock.Dispose()
}
