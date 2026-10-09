#Requires -Version 7.2
<#
.SYNOPSIS
Propose, inspect, or decide one exact native VM-start action in SRE Review mode.
.DESCRIPTION
This is an integration harness, not a custom remediation executor. Azure SRE
Agent executes the command under its identity. AutomatedApproval explicitly
labels a programmatic decision; it does not establish a human rehearsal.
The native execution action/status API is the deployed SRE UI's API, not a
published stable SDK contract. Unknown payloads fail closed.
.PARAMETER Operation
Propose requests live hybrid diagnosis and a pending start card. Read saves
thread evidence. Approve/Deny decide only that exact card from an owned thread.
Verify requests a read-only recovery check and incident note after completion.
.PARAMETER SubscriptionId
Explicit authorized subscription.
.PARAMETER EnvironmentName
Existing disposable native-action environment.
.PARAMETER ThreadId
SRE thread created by Propose, required except when proposing.
.PARAMETER AutomatedApproval
Required to approve programmatically. Omit and use the SRE UI for a human decision.
.EXAMPLE
.\scripts\Invoke-SreProof.ps1 Propose -SubscriptionId <guid> -EnvironmentName demo02
.EXAMPLE
.\scripts\Invoke-SreProof.ps1 Approve -SubscriptionId <guid> -ThreadId <guid> -AutomatedApproval
.OUTPUTS
Thread ID, state, exact native execution records and visible response text.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('Propose', 'Read', 'Approve', 'Deny', 'Verify')]
    [string]$Operation,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo02',
    [guid]$ThreadId,
    [switch]$AutomatedApproval
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root ".azure\$EnvironmentName"
$state = Get-Content -LiteralPath (Join-Path $directory 'native-action-state.json') -Raw | ConvertFrom-Json -AsHashtable
$subscription = $SubscriptionId.ToString()
$groupId = "/subscriptions/$subscription/resourceGroups/rg-retailtx-action-$EnvironmentName-swedencentral"
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-retailtx-action-$EnvironmentName"
if ($state.profile -cne 'native-action' -or $state.schemaVersion -ne 1 -or
    $state.subscriptionId -ine $subscription -or $state.environmentName -cne $EnvironmentName -or
    $state.vmId -ine $vmId -or $state.groupId -ine $groupId) { throw 'Mismatched native action manifest.' }
$ownerToken = [guid]::Parse($state.ownerToken).ToString()
$marker = "RetailTx native-action proof owner $ownerToken."
$expectedCommand = "az vm start --ids $vmId --subscription $subscription"
if ($Operation -ne 'Propose' -and $ThreadId -eq [guid]::Empty) { throw 'An owned proof ThreadId is required.' }
if ($Operation -eq 'Approve' -and -not $AutomatedApproval) {
    throw 'Programmatic approval requires -AutomatedApproval; otherwise use the SRE UI.'
}

function Invoke-Azure {
    param([string[]]$Arguments)
    Invoke-RetailAzure -SubscriptionId $subscription -Arguments $Arguments -TimeoutSeconds 90
}

function Assert-ExactStartCommand {
    param([hashtable]$Execution, [string]$ExpectedCommand)
    $null = [guid]::Parse($Execution.id)
    $call = $Execution.originalFunctionCall | ConvertFrom-Json -AsHashtable
    if ($Execution.command -cne $ExpectedCommand -or
        $call.Name -cne 'RunAzCliWriteCommands' -or $call.Arguments.command -cne $ExpectedCommand -or
        @($call.Arguments.Keys).Count -ne 1 -or $Execution.requiredScopes) {
        throw 'Not the exact managed-identity VM-start command.'
    }
}

function Assert-ExactStartProposal {
    param([hashtable]$Execution, [string]$ExpectedCommand)
    Assert-ExactStartCommand $Execution $ExpectedCommand
    if ($Execution.status -cne 'Pending' -or $Execution.expiredByTimeout -ne $false -or
        $Execution.startedTimestamp -or $Execution.completedTimestamp) {
        throw 'Not an exact, unexecuted managed-identity VM-start proposal; no decision was submitted.'
    }
}

function Get-StartExecution {
    param([object[]]$Executions, [string]$ExpectedCommand)
    return @($Executions | Where-Object command -CEQ $ExpectedCommand)
}

function Assert-CurrentFault {
    param([hashtable]$Latest, [hashtable]$ThreadState, [string]$OwnerToken, [string]$VmId)
    if ($Latest.ownerToken -cne $OwnerToken -or $Latest.vmId -ine $VmId -or
        $Latest.phase -cne 'fault-active' -or -not $ThreadState.faultStartedAt -or
        -not $ThreadState.faultDeadline -or
        [DateTimeOffset]$Latest.faultStartedAt -ne [DateTimeOffset]$ThreadState.faultStartedAt -or
        [DateTimeOffset]$Latest.faultDeadline -ne [DateTimeOffset]$ThreadState.faultDeadline -or
        [DateTimeOffset]::UtcNow.AddSeconds(60) -ge [DateTimeOffset]$Latest.faultDeadline) {
        throw 'The proposal is not bound to the current supervised approval window.'
    }
}

function Invoke-Sre {
    param([ValidateSet('Get', 'Post')][string]$Method, [string]$Path, [hashtable]$Body)
    $parameters = @{
        Uri = "$endpoint$Path"; Method = $Method; Authentication = 'Bearer'; Token = $token
        TimeoutSec = 60; MaximumRedirection = 0
    }
    if ($Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = $Body | ConvertTo-Json -Depth 20
    }
    try {
        $response = Invoke-RestMethod @parameters
        return ($response | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable)
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        throw "SRE API HTTP failure ($([int]$_.Exception.Response.StatusCode)); no successful decision is assumed."
    }
}

$account = Invoke-Azure @('account', 'show')
if ($state.tenantId -ine $account.tenantId) { throw 'Azure tenant mismatch.' }
$vm = Invoke-Azure @('vm', 'show', '--ids', $vmId)
if ($vm.tags.ownerToken -cne $ownerToken -or $vm.tags.profile -cne 'native-action') {
    throw 'Target VM ownership mismatch.'
}
if ($state.agentId -notlike "/subscriptions/$subscription/resourceGroups/*/providers/Microsoft.App/agents/*") {
    throw 'Invalid SRE Agent resource ID.'
}
$agent = Invoke-Azure @('resource', 'show', '--ids', $state.agentId, '--api-version', '2026-01-01')
if ($agent.properties.actionConfiguration.mode -cne 'Review' -or
    $agent.properties.actionConfiguration.identity -ine $state.agentIdentityId) {
    throw 'SRE Review mode or execution identity changed.'
}
$uri = [uri]$agent.properties.agentEndpoint
if ($uri.Scheme -cne 'https' -or -not $uri.Host.EndsWith('.azuresre.ai', [StringComparison]::OrdinalIgnoreCase) -or
    $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
    throw 'Unexpected live SRE endpoint; refusing to send authentication.'
}
$endpoint = $uri.AbsoluteUri.TrimEnd('/')
$credentials = Invoke-Azure @('account', 'get-access-token', '--resource', 'https://azuresre.dev')
$token = ConvertTo-SecureString $credentials.accessToken -AsPlainText -Force
$credentials = $null
try {
    if ($Operation -eq 'Propose') {
        if ($state.phase -cne 'fault-active' -or
            [DateTimeOffset]::UtcNow -ge [DateTimeOffset]$state.faultDeadline) {
            throw 'Propose requires a live supervised Fault; no unsupervised stopped VM is accepted.'
        }
        $view = Invoke-Azure @('vm', 'get-instance-view', '--ids', $vmId)
        if (@($view.instanceView.statuses | Where-Object code -CEQ 'PowerState/stopped').Count -ne 1) {
            throw 'Expected the owned fixture to be stopped.'
        }
        $faultStartedAt = ([DateTimeOffset]$state.faultStartedAt).ToUniversalTime().ToString('o')
        $faultDeadline = ([DateTimeOffset]$state.faultDeadline).ToUniversalTime().ToString('o')
        $prompt = @"
$marker
This is a supervised native Azure remediation integration test, NOT a retail transaction outage. No customer or sales impact may be inferred.
The operator deliberately stopped only $vmId at $faultStartedAt. An independent operator recovery guard expires at $faultDeadline. Both timestamps are UTC.
Investigate with read-only tools. Inspect that VM's live instance view (az vm get-instance-view returns instanceView.statuses, NOT root statuses) and recent Activity Log. Activity Log ingestion can lag; report missing evidence rather than inventing an event.
Check the Arc machine $($state.arcMachineId) is Connected and obtain its latest Heartbeat within 15 minutes from workspace $($state.workspaceCustomerId).
For the private heartbeat path, use workspace terminal with: az login --identity --client-id $($state.agentClientId) --allow-no-subscriptions --output none; then az monitor log-analytics query. Use this exact KQL: Heartbeat | where TimeGenerated > ago(15m) | where _ResourceId =~ '$($state.arcMachineId)' | top 1 by TimeGenerated desc | project TimeGenerated, Computer, _ResourceId.
Never display tokens. The Arc host is evidence-only: do not invoke guest commands or change it.
Explain what the evidence proves and the narrow cause of this fixture's state. Then request ONE real native RunAzCliWriteCommands approval card for EXACTLY:
$expectedCommand
Keep Review mode. Do not execute until that card is approved. Do not perform writes through terminal/Python/custom tools; do not change configuration or grant permissions; do not propose other commands. After approval, verify the VM actually runs and report the native-action outcome, not retail/business recovery. A programmatic decision is automated test authorization, not a human clicking Approve.
"@
        if (-not $PSCmdlet.ShouldProcess($state.agentId, 'Create native-action proof thread')) { return }
        $created = Invoke-Sre Post '/api/v1/threads' @{
            startMessage = @{ text = $prompt; userId = 'retailtx-automated-gate'
                displayName = 'RetailTx automated integration gate'; agent = ($state.agentId -split '/')[-1] }
        }
        $ThreadId = [guid]::Parse($created.id)
        Save-RetailState @{ ownerToken = $ownerToken; threadId = $ThreadId.ToString()
            agentId = $state.agentId; createdAt = [DateTimeOffset]::UtcNow.ToString('o')
            faultStartedAt = $faultStartedAt; faultDeadline = $faultDeadline
        } (Join-Path $directory "sre-$ThreadId-owner.json")
    }
    $threadState = Get-Content -LiteralPath (Join-Path $directory "sre-$ThreadId-owner.json") -Raw | ConvertFrom-Json -AsHashtable
    if ($threadState.ownerToken -cne $ownerToken -or $threadState.agentId -ine $state.agentId -or
        $threadState.threadId -cne $ThreadId.ToString()) { throw 'The thread is not owned by this proof.' }
    $thread = Invoke-Sre Get "/api/v1/threads/$ThreadId"
    if (-not $thread.startMessage.text.StartsWith($marker, [StringComparison]::Ordinal)) {
        throw 'Live thread does not match the proof marker.'
    }
    $messages = Invoke-Sre Get "/api/v1/threads/$ThreadId/messages"
    Save-RetailState $messages (Join-Path $directory "sre-$ThreadId-messages.json")
    $executions = @($messages.value | Where-Object { $_.azCliExecution } | ForEach-Object { $_.azCliExecution })
    if ($Operation -in @('Approve', 'Deny')) {
        $pending = @($executions | Where-Object status -In @('Pending', 'PendingAuthorization'))
        if ($pending.Count -ne 1) { throw 'Exactly one pending native execution is required.' }
        $execution = $pending[0]
        Assert-ExactStartProposal $execution $expectedCommand
        $id = [guid]::Parse($execution.id).ToString()
        if (-not $PSCmdlet.ShouldProcess($execution.command, "$Operation exact SRE proposal (automated gate)")) { return }
        $current = Invoke-Sre Get "/api/v1/azCliExecution/$ThreadId/$id/status"
        if ($current.id -cne $id -or $current.status -cne 'Pending' -or
            $current.command -cne $expectedCommand -or $current.startedTimestamp -or
            $current.completedTimestamp -or $current.requiredScopes) {
            throw 'Live native execution changed since the proposal was read.'
        }
        if ($Operation -eq 'Approve') {
            # Never run a stale pending card after the independent guard has recovered.
            $latest = Get-Content -LiteralPath (Join-Path $directory 'native-action-state.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert-CurrentFault $latest $threadState $ownerToken $vmId
        }
        $action = if ($Operation -eq 'Approve') { 'run' } else { 'cancel' }
        $decision = Invoke-Sre Post "/api/v1/azCliExecution/$ThreadId/$id/action" @{
            action = $action; user = 'retailtx-automated-gate'; ApproveScope = 'none'
        }
        Save-RetailState @{ decision = $action; authorization = 'automated-integration-test-not-human'
            timestamp = [DateTimeOffset]::UtcNow.ToString('o'); executionId = $id; result = $decision
        } (Join-Path $directory "sre-$ThreadId-decision.json")
        $decision
    } elseif ($Operation -eq 'Verify' -and -not $threadState.ContainsKey('verificationRequestedAt')) {
        $completed = @(Get-StartExecution $executions $expectedCommand)
        if ($completed.Count -ne 1 -or $messages.state -cne 'Idle') {
            throw 'Verify requires one exact native start and an idle thread.'
        }
        Assert-ExactStartCommand $completed[0] $expectedCommand
        if (-not $PSCmdlet.ShouldProcess($ThreadId, 'Request read-only recovery verification and incident note')) { return }
        $id = [guid]::Parse($completed[0].id).ToString()
        $current = Invoke-Sre Get "/api/v1/azCliExecution/$ThreadId/$id/status"
        if ($current.status -cne 'Completed' -or $current.id -cne $id -or
            $current.command -cne $expectedCommand -or -not $current.completedTimestamp -or $current.error) {
            throw 'Native VM start is not confirmed complete.'
        }
        $completedAt = ([DateTimeOffset]$current.completedTimestamp).ToUniversalTime().ToString('o')
        $requestedAt = [DateTimeOffset]::UtcNow.ToString('o')
        $null = Invoke-Sre Post "/api/v1/threads/$ThreadId/messages" @{
            text = "The native execution $id reports Completed at $completedAt (UTC), following automated test authorization, not a human click. Independently verify the VM now runs and refresh the same exact Arc heartbeat through the private path used earlier. Use read-only tools only; do not perform or request any further writes. Provide a concise incident note separating the operator-injected fault, observed hybrid evidence, native action, actual recovery and limits. Do not infer retail/customer impact or claim an audit event that is not yet visible."
            userId = 'retailtx-automated-gate'; displayName = 'RetailTx automated integration gate'
            agent = ($state.agentId -split '/')[-1]
        }
        $threadState.verificationRequestedAt = $requestedAt
        Save-RetailState $threadState (Join-Path $directory "sre-$ThreadId-owner.json")
    }
    $responses = @($messages.value | Where-Object { $_.author.role -eq 'SREAgent' -and
        $_.messageType -ne 'Reasoning' -and $_.text })
    [pscustomobject]@{
        threadId = $ThreadId.ToString(); state = $messages.state; executions = $executions
        startExecutions = @(Get-StartExecution $executions $expectedCommand)
        verificationRequestedAt = $(if ($threadState.ContainsKey('verificationRequestedAt')) { $threadState.verificationRequestedAt } else { $null })
        lastAgentMessageAt = $(if ($responses.Count) { $responses[-1].timeStamp } else { $null })
        response = @($responses | Select-Object -Last 3 | ForEach-Object { $_.text })
    }
} finally { $token.Dispose() }
