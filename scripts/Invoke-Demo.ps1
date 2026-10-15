#Requires -Version 7.5
<#
.SYNOPSIS
Deploy, prepare, inspect or remove an independent single-agent demo.
.DESCRIPTION
Composes the owned Bicep-backed guest lifecycle. Up never injects a fault.
Unknown writes remain blocked rather than being replayed. GitHub runtime
activation and human repair approval are separate acceptance gates.
.PARAMETER Operation
Up, Ready, ConfigureGitHub, Reset or Down.
.PARAMETER SubscriptionId
Explicit authorized Azure subscription.
.PARAMETER EnvironmentName
Neutral deployment identifier; never an existing retained fixture.
.PARAMETER RunId
Exact current fault ID, mandatory for Reset.
.PARAMETER Repository
Trusted GitHub repository for ConfigureGitHub; never taken from issue content.
.PARAMETER CleanupFailedGitHub
Down only: explicitly authorize exact-owned cleanup of a proven terminal failed
Bicep caller deployment. In-progress and unknown submissions still block.
.EXAMPLE
.\scripts\Invoke-Demo.ps1 Up -SubscriptionId <guid> -EnvironmentName demo01
.OUTPUTS
Lifecycle results and a JSON readiness receipt.
.NOTES
PowerShell 7.5, Azure CLI and Bicep are required. No foundation manifest is used.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Up', 'Ready', 'ConfigureGitHub', 'Reset', 'Down')][string]$Operation,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][string]$EnvironmentName,
    [guid]$RunId,
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'rutgerpels/retailtx-agentic-ops-demo',
    [switch]$CleanupFailedGitHub
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
. (Join-Path $PSScriptRoot 'disk\DiskSre.ps1')
Assert-RetailEnvironmentName $EnvironmentName
if ($PSBoundParameters.ContainsKey('RunId') -and $Operation -cne 'Reset') {
    throw 'RunId applies only to Reset.'
}
if ($Operation -ceq 'Reset' -and -not $PSBoundParameters.ContainsKey('RunId')) {
    throw 'Reset requires the exact current RunId.'
}
if ($CleanupFailedGitHub -and $Operation -cne 'Down') { throw 'CleanupFailedGitHub applies only to Down.' }
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root ".azure\$EnvironmentName"
$manifest = Join-Path $directory 'guest-service-state.json'
$lifecycle = Join-Path $PSScriptRoot 'Invoke-GuestService.ps1'
$parameters = @{ SubscriptionId = $SubscriptionId; EnvironmentName = $EnvironmentName }
function Get-DemoState {
    if (-not (Test-Path -LiteralPath $manifest)) { return }
    $value = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json -AsHashtable -DateKind String
    if ($value['standalone'] -ne $true -or $value.subscriptionId -ine $SubscriptionId.ToString() -or
        $value.environmentName -cne $EnvironmentName) {
        throw 'This entry point only manages its own standalone deployment; retained fixtures are excluded.'
    }
    return $value
}
function Invoke-DemoStep {
    param([string]$Step, [hashtable]$Additional = @{})
    $null = & $lifecycle $Step @parameters @Additional -Confirm:$false
}
function Invoke-Azure {
    param([string[]]$Arguments)
    Invoke-RetailAzure -SubscriptionId $SubscriptionId -TimeoutSeconds 90 -Arguments $Arguments
}
function Get-DemoRouting {
    param([hashtable]$State)
    $agent = Invoke-Azure @('resource', 'show', '--ids', $State.agentId, '--api-version', '2026-01-01')
    if ($agent.tags.ownerToken -cne $State.ownerToken -or
        $agent.properties.actionConfiguration.mode -cne 'Review' -or
        $agent.properties.actionConfiguration.identity -ine $State.agentIdentityId -or
        $agent.properties.incidentManagementConfiguration.type -cne 'AzMonitor') {
        throw 'Owned agent Review identity or Azure Monitor intake differs.'
    }
    $endpoint = [uri]$agent.properties.agentEndpoint
    if ($endpoint.Scheme -cne 'https' -or -not $endpoint.Host.EndsWith('.azuresre.ai') -or
        $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.Port -ne 443 -or
        $endpoint.AbsolutePath -cne '/') { throw 'Unexpected SRE endpoint.' }
    $connection = @{ endpoint = $endpoint.AbsoluteUri.TrimEnd('/') }
    $plan = Invoke-DiskSreRequest $connection GET "/api/v2/incidentManagement/incidentFilters/retailtx-guest-$EnvironmentName"
    if ($plan.name -cne "retailtx-guest-$EnvironmentName" -or $plan.properties.agentMode -cne 'review' -or
        $plan.properties.handlingAgent -cne "retailtx-guest-$EnvironmentName" -or
        $plan.properties.titleContains -cne $EnvironmentName -or $plan.properties.mergeEnabled -ne $false -or
        $plan.properties.azMonitorFilterSettings.targetResource -ine $State.vmId -or
        $plan.properties.azMonitorFilterSettings.targetResourceType -cne 'Microsoft.Compute/virtualMachines' -or
        $plan.properties.isEnabled -isnot [bool]) { throw 'Owned response plan changed.' }
    $alert = Invoke-Azure @('resource', 'show', '--ids', $State.alertId, '--api-version', '2023-12-01')
    if ($alert.tags.ownerToken -cne $State.ownerToken -or $alert.properties.enabled -isnot [bool]) {
        throw 'Owned alert changed.'
    }
    return @{ armed = $plan.properties.isEnabled -and $alert.properties.enabled; connection = $connection }
}
function Assert-DemoArmSettled {
    param([hashtable]$State)
    $pending = @($State.journal | Where-Object {
        $_.action -ceq 'monitor-deploy' -and $_['enabled'] -eq $true -and $_.outcome -cne 'deployment-succeeded'
    })
    if (-not $pending.Count) { return }
    $deployment = Invoke-Azure @('deployment', 'group', 'show', '--resource-group', ($State.groupId -split '/')[-1],
        '--name', 'guest-monitor')
    if ($pending.Count -ne 1 -or $deployment.properties.provisioningState -cne 'Succeeded' -or
        $deployment.properties.parameters.enableAlert.value -ne $true -or
        [DateTimeOffset]$deployment.properties.timestamp -lt [DateTimeOffset]$pending[0].intentAtUtc -or
        $deployment.properties.outputs.alertId.value -ine $State.alertId) {
        throw 'Arm deployment is unsettled or failed; no submission will be replayed.'
    }
    Write-Warning 'Previously uncertain Arm deployment reconciled as Succeeded by read-only evidence.'
}
function Invoke-DemoPython {
    param([string[]]$Arguments)
    Push-Location $root
    try {
        & python @Arguments
        if ($LASTEXITCODE -ne 0) { throw 'GitHub lifecycle failed; reconcile its journal without replaying admission.' }
    } finally { Pop-Location }
}
function Get-DemoGitHubConfiguration {
    param([hashtable]$State)
    $path = Join-Path $directory 'github-config.json'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Missing owned GitHub configuration.' }
    $config = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable -DateKind String
    if ($config.binding.ownerToken -cne $State.ownerToken -or $config.binding.agentId -ine $State.agentId -or
        $config.binding.vmId -ine $State.vmId -or $config.environment -cne $EnvironmentName -or
        $config.repository -cne $Repository) { throw 'GitHub binding differs from the owned deployment.' }
    return $config
}
function Test-DemoNativeRemovalNeeded {
    param([hashtable]$State, [hashtable]$Native, [hashtable]$Config)
    if ($Native.ownerToken -cne $State.ownerToken -or $Native.endpoint -cne $Config.endpoint) {
        throw 'GitHub native ownership journal differs.'
    }
    if ($Native.phase -cne 'Removed') { return $true }
    $groupExists = Invoke-Azure @('group', 'exists', '--name', ($State.groupId -split '/')[-1])
    if (-not $groupExists) { return $false }
    $resources = @(Invoke-Azure @('resource', 'list', '--resource-group', ($State.groupId -split '/')[-1]))
    return @($resources | Where-Object { $_.id -ieq $State.agentId }).Count -gt 0
}
function Assert-DemoHealthy {
    $state = Get-DemoState
    if (-not $state -or $state.phase -cne 'ready' -or $state.pendingCommand -or
        ($state['nativeRead'] -and $state.nativeRead.phase -cne 'ResultReceived')) {
        throw 'Deployment or command is not settled; reconcile it without replay before readiness.'
    }
    Invoke-DemoStep Inspect
    Invoke-DemoStep Telemetry
    $state = Get-DemoState
    if (-not $state.lastEvidence.active -or -not $state.lastEvidence.healthy -or
        ($state.lastEvidence.marker -and $state.lastEvidence.marker.phase -cne 'recovered')) {
        throw 'Fresh telemetry has not established a healthy baseline.'
    }
    $inventory = @(Invoke-RetailAzure -SubscriptionId $SubscriptionId -TimeoutSeconds 90 -Arguments @(
        'resource', 'list', '--resource-type', 'Microsoft.App/agents', '--query', '[].id'))
    if ($state.agentId -inotIn $inventory) { throw 'Intended SRE Agent missing from inventory.' }
    foreach ($id in $inventory) {
        $agent = Invoke-RetailAzure -SubscriptionId $SubscriptionId -TimeoutSeconds 90 -Arguments @(
            'resource', 'show', '--ids', $id, '--api-version', '2026-01-01')
        $expected = if ($id -ieq $state.agentId) { 'Running' } else { 'Stopped' }
        if ($agent.properties.runningState -cne $expected) {
            throw 'Single-intake readiness requires the intended agent Running and every other agent Stopped. No agent was changed.'
        }
    }
    Invoke-DemoStep SkillCheck
    Assert-DemoArmSettled $state
    if (-not (Get-DemoRouting $state).armed) { throw 'Response plan and alert must both be enabled before Ready.' }
    if ($state.currentFault) {
        $incident = & $lifecycle Incident @parameters -Confirm:$false
        if ($incident.monitorCondition -cne 'Resolved') {
            throw 'Previous alert has not naturally resolved.'
        }
    }
    return @{ phase = 'Ready'; environment = $EnvironmentName; vmName = ($state.vmId -split '/')[-1]
        agentName = ($state.agentId -split '/')[-1]; observedAtUtc = $state.lastEvidence.observedAtUtc
        githubRuntime = 'SeparateAcceptanceRequired'; faultInjected = $false }
}
$state = Get-DemoState
if ($Operation -ceq 'Ready') { Assert-DemoHealthy | ConvertTo-Json; return }
if (-not $PSCmdlet.ShouldProcess($EnvironmentName, "$Operation owned standalone demo; never approve an SRE repair")) { return }
if ($Operation -ceq 'Up') {
    if (-not $state -or $state.phase -ceq 'deleted') {
        Invoke-DemoStep Up @{ Standalone = $true; WithSreExecution = $true
            WithMonitoring = $true; MonitorTransport = 'Public'; MonitorReadMode = 'Operator' }
        $state = Get-DemoState
    } else {
        if ($state.phase -cne 'ready' -or $state.pendingCommand) {
            throw 'Incomplete provisioning cannot be resubmitted. Inspect the recorded operation or use owned Down.'
        }
        Invoke-DemoStep Inspect
    }
    if (-not $state['monitorConfigured']) { Invoke-DemoStep Monitor }
    Invoke-DemoStep Telemetry
    $state = Get-DemoState
    if (-not $state['monitorConnectAttempted']) {
        Invoke-DemoStep Connect @{ WithRecoverySkill = $true }
    }
    Invoke-DemoStep SkillCheck
    $state = Get-DemoState
    Assert-DemoArmSettled $state
    if (-not (Get-DemoRouting $state).armed) { Invoke-DemoStep Arm }
    Assert-DemoHealthy | ConvertTo-Json
    return
}
if (-not $state) { throw 'No owned standalone manifest.' }
if ($Operation -ceq 'ConfigureGitHub') {
    if ($state.phase -cne 'ready' -or $state.pendingCommand -or -not $state.workspaceCustomerId) {
        throw 'GitHub setup requires settled guest provisioning and an owned workspace.'
    }
    $configPath = Join-Path $directory 'github-config.json'
    $repositoryPath = Join-Path $directory 'github-repository.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        $repositoryJson = & gh api "repos/$Repository"
        if ($LASTEXITCODE -ne 0) { throw 'Cannot verify trusted GitHub repository.' }
        $repositoryInfo = $repositoryJson | ConvertFrom-Json -AsHashtable
        $oidcJson = & gh api "repos/$Repository/actions/oidc/customization/sub"
        if ($LASTEXITCODE -ne 0) { throw 'Cannot verify repository OIDC subject configuration.' }
        $oidc = $oidcJson | ConvertFrom-Json -AsHashtable
        if ($repositoryInfo.full_name -cne $Repository -or $repositoryInfo.private -ne $false -or
            $oidc.use_default -ne $true -or $oidc.use_immutable_subject -isnot [bool]) {
            throw 'Only the verified public repository and default OIDC subject modes are supported.'
        }
        $subject = if ($oidc.use_immutable_subject) {
            "repo:$($repositoryInfo.owner.login)@$($repositoryInfo.owner.id)/$($repositoryInfo.name)@$($repositoryInfo.id):environment:sre-github-intake"
        } else { "repo:${Repository}:environment:sre-github-intake" }
        $config = @{
            schemaVersion = 1; repository = $Repository; repositoryId = $repositoryInfo.id
            oidc = @{ repositoryOwnerId = $repositoryInfo.owner.id; subject = $subject }
            environment = $EnvironmentName; endpoint = $state.agentEndpoint.TrimEnd('/')
            tokenResource = 'https://azuresre.dev'; tokenAudience = '59f0a04a-b322-4310-adc9-39ac41e9631e'
            triggerId = 'configure-owned-trigger'; runtimeVerified = $false; knowledgeRetrievalVerified = $false
            binding = @{ subscriptionId = $state.subscriptionId; ownerToken = $state.ownerToken
                vmId = $state.vmId; workspaceId = $state.workspaceId; workspaceCustomerId = $state.workspaceCustomerId
                agentId = $state.agentId; service = 'retailtx-demo-posting-worker'; faultLifetime = 'Manual' }
        }
        Save-RetailState $repositoryInfo $repositoryPath
        Save-RetailState $config $configPath
    }
    $null = Get-DemoGitHubConfiguration $state
    Invoke-DemoPython @('-m', 'scripts.github.federation', 'deploy-bicep', '--config', $configPath,
        '--state', (Join-Path $directory 'github-federation.json'), '--repository-evidence', $repositoryPath,
        '--location', $state.location, '--expires-at', $state.expiresAt)
    Invoke-DemoPython @('-m', 'scripts.github.lifecycle', 'configure', '--config', $configPath,
        '--state', (Join-Path $directory 'github-ownership.json'))
    @{ phase = 'GitHubConfiguredDisabledNotLiveAccepted'; environment = $EnvironmentName
        limitation = 'No repository gate, secret or native trigger was enabled; OIDC and retrieval still require acceptance.' } |
        ConvertTo-Json
    return
}
if ($Operation -ceq 'Reset') {
    Invoke-DemoStep Reset @{ RunId = $RunId }
    Assert-DemoHealthy | ConvertTo-Json
    return
}
$githubState = Join-Path $directory 'github-ownership.json'
$githubConfig = Join-Path $directory 'github-config.json'
$federationState = Join-Path $directory 'github-federation.json'
if ((Test-Path -LiteralPath $githubState) -or (Test-Path -LiteralPath $federationState)) {
    $config = Get-DemoGitHubConfiguration $state
    $gateJson = & gh api "repos/$Repository/actions/variables/SRE_INTAKE_ENABLED"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot establish that repository intake is disabled; no teardown.' }
    $gate = $gateJson | ConvertFrom-Json -AsHashtable
    if ($gate.value -cne 'false') { throw 'Disable repository GitHub intake before teardown; no settings were changed.' }
    if (Test-Path -LiteralPath $githubState) {
        $native = Get-Content -Raw -LiteralPath $githubState | ConvertFrom-Json -AsHashtable
        if (Test-DemoNativeRemovalNeeded $state $native $config) {
            Invoke-DemoPython @('-m', 'scripts.github.lifecycle', 'down', '--config', $githubConfig, '--state', $githubState)
        }
    }
    if (Test-Path -LiteralPath $federationState) {
        $arguments = @('-m', 'scripts.github.federation', 'down', '--config', $githubConfig, '--state', $federationState)
        if ($CleanupFailedGitHub) { $arguments += '--allow-failed-bicep' }
        Invoke-DemoPython $arguments
    }
}
Invoke-DemoStep Down
Invoke-DemoStep Down
@{ phase = 'DeletedAbsenceVerified'; environment = $EnvironmentName } | ConvertTo-Json
