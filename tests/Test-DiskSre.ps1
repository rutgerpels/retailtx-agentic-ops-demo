#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = Join-Path $PSScriptRoot '..\scripts\disk\DiskSre.ps1'
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
. $path
$checks = 0
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe SRE configuration was accepted.' }
    $script:checks++
}
$EnvironmentName = 'demo03'
$arcId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/example/providers/Microsoft.HybridCompute/machines/disk-demo03'
$configuration = @{ customAgentName = 'retailtx-disk-demo03'; filterName = 'retailtx-disk-demo03'; instructions = 'Owned read-only investigation.' }
$investigator = @{ name = $configuration.customAgentName
    properties = @{ instructions = $configuration.instructions; enableVanillaMode = $true; handoffs = @() } }
$plan = @{ name = $configuration.filterName; properties = @{
    agentMode = 'review'; handlingAgent = $configuration.customAgentName; titleContains = $EnvironmentName
    azMonitorFilterSettings = @{ targetResourceType = 'Microsoft.HybridCompute/machines'; targetResource = $arcId }
} }
Assert-DiskSreAgent $investigator $configuration
Assert-DiskSrePlan $plan $configuration
$checks += 2
foreach ($key in @('instructions', 'enableVanillaMode', 'handoffs')) {
    $original = $investigator.properties[$key]
    $investigator.properties[$key] = if ($key -ceq 'enableVanillaMode') { $false } else { 'foreign' }
    Assert-Rejected { Assert-DiskSreAgent $investigator $configuration }
    $investigator.properties[$key] = $original
}
$investigator.name = 'foreign'
Assert-Rejected { Assert-DiskSreAgent $investigator $configuration }
$investigator.name = $configuration.customAgentName
foreach ($key in @('agentMode', 'handlingAgent', 'titleContains')) {
    $original = $plan.properties[$key]
    $plan.properties[$key] = 'foreign'
    Assert-Rejected { Assert-DiskSrePlan $plan $configuration }
    $plan.properties[$key] = $original
}
foreach ($key in @('targetResourceType', 'targetResource')) {
    $original = $plan.properties.azMonitorFilterSettings[$key]
    $plan.properties.azMonitorFilterSettings[$key] = 'foreign'
    Assert-Rejected { Assert-DiskSrePlan $plan $configuration }
    $plan.properties.azMonitorFilterSettings[$key] = $original
}
Assert-Rejected { Invoke-DiskSreRequest @{} GET 'https://foreign.example/api/' }
Assert-Rejected { Invoke-DiskSreRequest @{} GET '/api/../foreign' }
function Invoke-Azure { return @{ accessToken = 'offline-test-placeholder' } }
$script:response = @{ StatusCode = 200; Content = '{"actual":"response"}' }
function Invoke-WebRequest {
    param($Uri, $Method, $Authentication, $Token, $MaximumRedirection, $TimeoutSec, [switch]$SkipHttpErrorCheck, $ContentType, $Body)
    if ($Authentication -cne 'Bearer' -or $MaximumRedirection -ne 0 -or $TimeoutSec -ne 90 -or
        $Token -isnot [securestring] -or -not $SkipHttpErrorCheck) { throw 'Unsafe API request options.' }
    return $script:response
}
$connection = @{ endpoint = 'https://test.azuresre.ai' }
if ((Invoke-DiskSreRequest $connection GET '/api/test').actual -cne 'response') { throw 'Response was not returned.' }
$checks++
foreach ($code in @(401, 403, 404, 500)) {
    $script:response.StatusCode = $code
    Assert-Rejected { Invoke-DiskSreRequest $connection GET '/api/test' }
}
$script:response.StatusCode = 404
if ($null -ne (Invoke-DiskSreRequest $connection GET '/api/test' -AllowMissing)) { throw 'Explicit absence was not recognized.' }
$checks++
Assert-Rejected { Invoke-DiskSreRequest $connection DELETE '/api/test' -AllowMissing }
$script:response = @{ StatusCode = 204; Content = '' }
$null = Invoke-DiskSreRequest $connection DELETE '/api/test'
$checks++
& {
    $directory='offline'
    function Save-RetailState {}
    $script:response = @{ StatusCode = 200; Content = '{"success":true,"incidentType":"AzMonitor"}' }
    if (-not (Wait-DiskSrePlatform $connection).success) { throw 'Connected platform was rejected.' }
    $script:checks++
    $script:response.Content='{"success":false,"incidentType":"AzMonitor","errorMessage":"Denied"}'
    Assert-Rejected {Wait-DiskSrePlatform $connection}
    $script:response.StatusCode=403
    Assert-Rejected {Wait-DiskSrePlatform $connection}
}
& {
    $groupId='/subscriptions/example/resourceGroups/rg-retailtx-disk-demo03-swedencentral'
    $baseline=@{identity='owned-identity';managedResources=@('foundation')}
    $configuration=@{knowledgeGraph=$baseline;incidentConfiguration=$null;exclusiveOwner=$true;ownerToken='owner'}
    $resource=@{tags=@{retailtxDiskOwner='owner'};properties=@{
        knowledgeGraphConfiguration=@{managedResources=@('foundation',$groupId);identity='owned-identity'}
        incidentManagementConfiguration=@{type='AzMonitor';connectionName='azmonitor';oboUser='';apiConnectionName=$null;connectionKey='';connectionUrl=$null}
    }}
    Assert-DiskSreSharedSettings $resource $configuration
    $script:checks++
    $resource.properties.knowledgeGraphConfiguration.managedResources+= '/subscriptions/example/resourceGroups/rg-retailtx-disk-demo04-swedencentral'
    Assert-Rejected {Assert-DiskSreSharedSettings $resource $configuration}
    $resource.properties.knowledgeGraphConfiguration.managedResources=@('foundation',$groupId)
    $resource.properties.incidentManagementConfiguration.connectionName='another-consumer'
    Assert-Rejected {Assert-DiskSreSharedSettings $resource $configuration}
    $resource.properties.incidentManagementConfiguration.connectionName='azmonitor'
    $resource.tags.retailtxDiskOwner='another-owner'
    Assert-Rejected {Assert-DiskSreSharedSettings $resource $configuration}
    $resource.tags.retailtxDiskOwner='owner'
    if(Test-DiskSreRestored $resource $configuration){throw 'Applied configuration appeared restored'}
    $script:checks++
    $resource.properties.knowledgeGraphConfiguration=$baseline
    $resource.properties.incidentManagementConfiguration=$null
    if(Test-DiskSreRestored $resource $configuration){throw 'Exclusive owner tag survived an accepted restoration'}
    $script:checks++
    $resource.tags.Remove('retailtxDiskOwner')
    if(-not (Test-DiskSreRestored $resource $configuration)){throw 'Original shared settings were not recognized'}
    $script:checks++
}
& {
    $groupId='/subscriptions/example/resourceGroups/rg-retailtx-disk-demo03-swedencentral'
    $state=@{ownerToken='owner';agentId='agent'}
    $configuration.phase='armed'
    $configuration.platformChanged=$true
    $configuration.ownerToken='owner'
    $configuration.exclusiveOwner=$true
    $configuration.knowledgeGraph=@{managedResources=@('foundation')}
    $configuration.incidentConfiguration=$null
    $resource=@{tags=@{retailtxDiskOwner='owner'};properties=@{
        knowledgeGraphConfiguration=@{managedResources=@('foundation',$groupId)}
        incidentManagementConfiguration=@{type='AzMonitor';connectionName='azmonitor';oboUser='';apiConnectionName=$null;connectionKey='';connectionUrl=$null}
    }}
    $mutations=[Collections.Generic.List[string]]::new()
    $foreignPlans=@(@{name='another-consumer'})
    function Get-DiskSreConnection {return @{resource=$resource}}
    function Get-DiskSreState {return $configuration}
    function Save-DiskSreState {}
    function Invoke-Azure {param($Arguments);$mutations.Add('ARM mutation');throw 'Unexpected ARM mutation'}
    function Invoke-DiskSreRequest {
        param($Connection,$Method,$Path,$Body,[switch]$AllowMissing)
        if ($Method -cne 'GET') {$mutations.Add($Method);throw 'Unexpected data-plane mutation'}
        if ($Path -ceq '/api/v2/incidentManagement/incidentFilters') {
            return @{value=@($plan)+$foreignPlans;nextLink=$null}
        }
        if ($Path -like '*/incidentFilters/*') {return $plan}
        if ($Path -like '*/extendedAgent/agents/*') {return $investigator}
        throw 'Unexpected request'
    }
    Assert-Rejected {Disconnect-DiskSre}
    if ($mutations.Count) {throw 'Foreign plan was detected after mutation'}
    $script:checks++
    $foreignPlans=@()
    $resource.properties.incidentManagementConfiguration.connectionName='changed'
    Assert-Rejected {Disconnect-DiskSre}
    if ($mutations.Count) {throw 'Shared drift was detected after mutation'}
    $script:checks++
    $resource.properties.incidentManagementConfiguration=$null
    $resource.properties.knowledgeGraphConfiguration=$configuration.knowledgeGraph
    $resource.tags.Remove('retailtxDiskOwner')
    $configuration.phase='restore-pending'
    Disconnect-DiskSre
    if ($configuration.phase -cne 'removed' -or $mutations.Count) {throw 'Restoration was replayed instead of reconciled'}
    $script:checks++
    $resource.tags.retailtxDiskOwner='another-owner'
    Assert-Rejected {Connect-DiskSre}
    if ($mutations.Count) {throw 'A second owner was allowed to mutate shared settings'}
    $script:checks++
}
& {
    $state=@{agentId='/subscriptions/example/resourceGroups/foundation/providers/Microsoft.SreAgent/agents/example'}
    $script:response=@{StatusCode=403;Content='{}'}
    try {
        Invoke-DiskSreArmUpdate @{properties=@{}}
        throw 'Rejected ARM update was accepted'
    } catch {
        if ($_.Exception.Data['AzureStatusCode'] -ne 403) {throw}
    }
    $script:checks++
    $script:response=@{StatusCode=202;Content='{}'}
    Invoke-DiskSreArmUpdate @{properties=@{}}
    $script:checks++
}
& {
    $state=@{ownerToken='owner';agentId='agent'}
    $configuration.phase='platform-rejected'
    $configuration.platformChanged=$true
    $configuration.exclusiveOwner=$true
    $configuration.knowledgeGraph=@{managedResources=@('foundation')}
    $configuration.incidentConfiguration=$null
    $resource=@{tags=@{};properties=@{
        knowledgeGraphConfiguration=$configuration.knowledgeGraph;incidentManagementConfiguration=$null
    }}
    $deleted=[Collections.Generic.List[string]]::new()
    function Get-DiskSreConnection {return @{resource=$resource}}
    function Get-DiskSreState {return $configuration}
    function Save-DiskSreState {}
    function Invoke-DiskSreArmUpdate {throw 'Rejected update caused an unnecessary restore'}
    function Invoke-DiskSreRequest {
        param($Connection,$Method,$Path,$Body,[switch]$AllowMissing)
        if ($Method -ceq 'DELETE') {$deleted.Add('investigator');return}
        if ($Path -like '*/incidentFilters/*') {return $null}
        if ($Path -like '*/extendedAgent/agents/*') {
            if ($deleted.Count) {return $null}
            return $investigator
        }
        throw 'Unexpected request'
    }
    Disconnect-DiskSre
    if ($configuration.phase -cne 'removed' -or $deleted.Count -ne 1) {
        throw 'Definitively rejected initial update blocked owned investigator cleanup'
    }
    $script:checks++
}
& {
    $state=@{agentId='agent'}
    function Invoke-Azure {throw 'Token acquisition failed'}
    try {
        Invoke-DiskSreArmUpdate @{}
        throw 'Token acquisition failure was ignored'
    } catch {
        if (-not $_.Exception.Data['AzureRequestNotSubmitted']) {throw}
    }
    $script:checks++
    function Invoke-Azure {return @{accessToken='offline-test-placeholder'}}
    function Invoke-WebRequest {throw [TimeoutException]::new('Unknown transport outcome')}
    try {
        Invoke-DiskSreArmUpdate @{}
        throw 'Transport failure was ignored'
    } catch {
        if ($_.Exception.Data['AzureRequestNotSubmitted'] -or $_.Exception -isnot [TimeoutException]) {throw}
    }
    $script:checks++
}
& {
    $subscription='11111111-1111-1111-1111-111111111111'
    $directory='offline'
    $now=[DateTimeOffset]::UtcNow
    $state=@{ownerToken='owner';activeRunId='22222222-2222-2222-2222-222222222222'
        faultRunId='22222222-2222-2222-2222-222222222222'
        faultRequestedAt=$now.AddMinutes(-10).ToString('o');alertId="$arcId/rule"}
    $configuration=@{phase='armed'}
    $alertGuid='33333333-3333-3333-3333-333333333333'
    $expectedId="$arcId/providers/Microsoft.AlertsManagement/alerts/$alertGuid"
    $candidate=@{id=$expectedId;properties=@{essentials=@{
        targetResource=$arcId;alertRule=$state.alertId;startDateTime=$now.AddMinutes(-8).ToString('o')
        monitorCondition='Fired'
    }}}
    $detail=@{id=$expectedId;properties=@{essentials=@{
        targetResource=$arcId;alertRule=$state.alertId;startDateTime=$now.AddMinutes(-8).ToString('o')
        monitorCondition='Resolved';monitorConditionResolvedDateTime=$now.AddMinutes(-1).ToString('o');alertState='New'
    }}}
    $fixtureIncident=@{id=$alertGuid;alertId=$expectedId;targetResourceId=$arcId;alertRuleResourceId=$state.alertId
        createdAt=$now.AddMinutes(-8).ToString('o');threadId='44444444-4444-4444-4444-444444444444'
        acknowledgementState='AuthorizationBlocked';status='new'}
    $list=@{value=@($candidate)}
    $records=[Collections.Generic.List[object]]::new()
    $requests=[Collections.Generic.List[string]]::new()
    $errorMode='none'
    function Get-DiskSreState {return $configuration}
    function Get-DiskSreConnection {return @{resource=@{}}}
    function Assert-DiskSreSharedSettings {}
    function Save-RetailState {
        param($Value,$Path)
        if ($errorMode -ceq 'save') {throw 'Evidence write failed'}
        $records.Add(@{value=$Value;path=$Path})
    }
    function Invoke-Azure {
        param($Arguments)
        if ($Arguments[0] -cne 'rest' -or $Arguments[2] -cne 'get') {throw 'Observer attempted an Azure mutation'}
        $requests.Add($Arguments[4])
        if ($Arguments[4] -like '*&targetResource=*') {
            if ($errorMode -ceq 'list') {throw 'Discovery failed'}
            return $list
        }
        if ($Arguments[4] -ceq "https://management.azure.com${expectedId}?api-version=2019-05-05-preview") {
            if ($errorMode -ceq 'detail') {throw 'Detail failed'}
            return $detail
        }
        throw 'Observer requested an unvalidated URL'
    }
    function Invoke-DiskSreRequest {
        param($Connection,$Method,$Path,[switch]$AllowMissing)
        if ($Method -cne 'GET' -or $Path -cne "/api/v2/incidentManagement/incidents?incidentId=$alertGuid" -or
            -not $AllowMissing) {throw 'Observer used a mutation or guessed incident'}
        if ($errorMode -ceq 'sre') {throw 'SRE authorization failed'}
        return $fixtureIncident
    }
    $first=Get-DiskIncident
    $second=Get-DiskIncident
    if ($first.monitorCondition -cne 'resolved' -or $first.threadId -cne $fixtureIncident.threadId -or
        $first.alertState -cne 'New' -or $first.acknowledgementState -cne 'AuthorizationBlocked' -or
        $records.Count -ne 2 -or $records[0].path -ceq $records[1].path -or $requests.Count -ne 4 -or
        $records[0].value.runId -cne $state.activeRunId) {throw 'Exact-detail state or retained run evidence was lost'}
    $script:checks++
    $originalCulture=[Threading.Thread]::CurrentThread.CurrentCulture
    try {
        foreach ($culture in @('en-US','nl-NL')) {
            [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($culture)
            $state=$state | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
            $list=$list | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
            $detail=$detail | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
            $fixtureIncident=$fixtureIncident | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
            if ((Get-DiskIncident).monitorCondition -cne 'resolved') {
                throw 'JSON-deserialized dates changed incident attribution with culture'
            }
            $script:checks++
        }
    } finally {
        [Threading.Thread]::CurrentThread.CurrentCulture=$originalCulture
    }
    $list.value=@($candidate)
    foreach ($mode in @('list','detail','sre','save')) {
        $errorMode=$mode
        $recordCount=$records.Count
        Assert-Rejected {Get-DiskIncident}
        if ($records.Count -ne $recordCount) {throw 'Failed observation wrote success-shaped evidence'}
        $script:checks++
    }
    $errorMode='none'
    Assert-DiskIncidentReset
    $script:checks++
    $detail.properties.essentials.monitorCondition='Fired'
    Assert-Rejected {Assert-DiskIncidentReset}
    $detail.properties.essentials.monitorCondition='Resolved'
    $fixtureIncident=$null
    if ((Get-DiskIncident).threadId) {throw 'Missing incident was reported as an investigation'}
    $script:checks++
    $list.value=@()
    if ((Get-DiskIncident).monitorCondition -cne 'awaiting') {throw 'No alert was not reported as awaiting'}
    $script:checks++
    Assert-Rejected {Assert-DiskIncidentReset}
    $list.value=@($candidate)
    $candidate.properties.essentials.startDateTime=$now.AddMinutes(-11).ToString('o')
    if ((Get-DiskIncident).monitorCondition -cne 'awaiting') {throw 'An old alert was attributed to the new run'}
    $script:checks++
    $candidate.properties.essentials.startDateTime=$now.AddMinutes(-8).ToString('o')
    $list.nextLink='another-page'
    Assert-Rejected {Get-DiskIncident}
    $list.Remove('nextLink')
    $list.value=@($candidate,$candidate)
    Assert-Rejected {Get-DiskIncident}
    $list.value=@($candidate)
    foreach ($key in @('targetResource','startDateTime')) {
        $original=$candidate.properties.essentials[$key]
        $candidate.properties.essentials[$key]=if($key -ceq 'startDateTime'){$now.AddHours(1).ToString('o')}else{'foreign'}
        Assert-Rejected {Get-DiskIncident}
        $candidate.properties.essentials[$key]=$original
    }
    $candidate.id="https://foreign.example/$alertGuid"
    Assert-Rejected {Get-DiskIncident}
    $candidate.id=$expectedId
    foreach ($key in @('targetResource','alertRule','monitorCondition','startDateTime','monitorConditionResolvedDateTime')) {
        $original=$detail.properties.essentials[$key]
        $detail.properties.essentials[$key]=if($key -like '*Time'){$now.AddMinutes(-12).ToString('o')}else{'foreign'}
        Assert-Rejected {Get-DiskIncident}
        $detail.properties.essentials[$key]=$original
    }
    $fixtureIncident=@{id=$alertGuid;alertId=$expectedId;targetResourceId=$arcId;alertRuleResourceId=$state.alertId
        createdAt=$now.AddMinutes(-8).ToString('o');threadId='44444444-4444-4444-4444-444444444444'}
    foreach ($key in @('id','alertId','targetResourceId','alertRuleResourceId','createdAt','threadId')) {
        $original=$fixtureIncident[$key]
        $fixtureIncident[$key]=if($key -ceq 'createdAt'){$now.AddMinutes(-12).ToString('o')}else{'foreign'}
        Assert-Rejected {Get-DiskIncident}
        $fixtureIncident[$key]=$original
    }
    $state.faultRequestedAt=$now.AddDays(-2).ToString('o')
    Assert-Rejected {Get-DiskIncident}
    $state.faultRequestedAt=$now.AddMinutes(-10).ToString('o')
    $state.activeRunId='55555555-5555-5555-5555-555555555555'
    Assert-Rejected {Get-DiskIncident}
    $state.activeRunId=$state.faultRunId
    $state.Remove('faultRequestedAt')
    Assert-Rejected {Get-DiskIncident}
    Assert-DiskIncidentReset
    $script:checks++
}
& {
    $lifecycle = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\scripts\Invoke-DiskScenario.ps1'), [ref]$null, [ref]$null)
    $armBranch = @($lifecycle.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -ceq '$Operation -ceq ''Arm'''
    }, $true))
    if ($armBranch.Count -ne 1 -or -not $armBranch[0].ElseClause) { throw 'Fault dispatch was not found' }
    $faultText = $armBranch[0].ElseClause.Extent.Text
    $faultBranch = [scriptblock]::Create($faultText.Substring(1, $faultText.Length - 2))
    $directory = 'offline'
    $state = @{phase='armed';activeRunId='22222222-2222-2222-2222-222222222222'}
    $alert = @{properties=@{enabled=$true}}
    $events = [Collections.Generic.List[string]]::new()
    $gatePermitted = $false
    function Assert-DiskSreArmed {}
    function Assert-DiskIncidentReset { if (-not $gatePermitted) { throw 'Previous alert still fired' } }
    function Save-State { $events.Add('save') }
    function Save-RetailState { param($Value,$Path); $events.Add('evidence') }
    function Invoke-GuestController {
        param($Action,$FaultId)
        if ($Action -cne 'Fault' -or $state.faultRunId -cne $FaultId.ToString() -or
            $state.activeRunId -cne $state.faultRunId -or $state.phase -cne 'fault-requested' -or
            $events.Count -ne 1 -or $events[0] -cne 'save') {
            throw 'Fault submission preceded durable exact-run binding'
        }
        $events.Add('fault')
        return @{runId=$FaultId.ToString();phase='pressure';freePercent=8;deadline='deadline'}
    }
    Assert-Rejected { & $faultBranch }
    if ($events.Count -ne 0 -or $state.phase -cne 'armed' -or $state.ContainsKey('faultRunId') -or
        $state.activeRunId -cne '22222222-2222-2222-2222-222222222222') {
        throw 'Rejected reset changed the current run or submitted a fault'
    }
    $script:checks++
    $gatePermitted = $true
    $null = & $faultBranch
    if ($state.phase -cne 'fault-active' -or ($events -join ',') -cne 'save,fault,save,evidence') {
        throw 'Verified reset did not preserve fault dispatch ordering'
    }
    $script:checks++
}
Write-Output "Disk SRE regression checks passed: $checks"
