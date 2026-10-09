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
Write-Output "Disk SRE regression checks passed: $checks"
