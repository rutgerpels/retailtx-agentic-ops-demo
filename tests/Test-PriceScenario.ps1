#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = Join-Path $PSScriptRoot '..\scripts\price\PriceScenario.ps1'
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
. $path
$checks = 0
$endpoint = 'http://127.0.0.1:18081/price/basket-a/'

$guestPath = Join-Path $PSScriptRoot '..\scripts\price\Invoke-PriceGuest.ps1'
$guestErrors = $null
$guestAst = [System.Management.Automation.Language.Parser]::ParseFile($guestPath, [ref]$null, [ref]$guestErrors)
if ($guestErrors) { throw ($guestErrors -join "`n") }
foreach ($functionName in @('Assert-PlainPath', 'New-PriceContentAcl', 'Set-PriceContentAcl', 'Get-PriceHttpFailure',
    'Assert-PriceSiteIdentity', 'Set-PriceSiteIdentity', 'Assert-PriceInstallStage', 'Assert-PriceSiteBinding',
    'Assert-HealthyPriceObservation', 'Invoke-PriceWatchdogCycle')) {
    $definition = $guestAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
    }, $true)
    if (-not $definition) { throw "Guest controller helper not found: $functionName" }
    Invoke-Expression $definition.Extent.Text
}

function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw "Unsafe price scenario evidence or dispatch was accepted: $($Action.ToString())" }
    $script:checks++
}

function New-HealthyObservation {
    param([string]$Owner, [string]$Environment, [string]$Run)
    $now = [DateTimeOffset]::UtcNow
    return @{
        schemaVersion=1; kind='price-probe'; event='recovered'; ownerToken=$Owner
        environmentName=$Environment; runId=$Run; phase='healthy'; observedAt=$now.ToString('o')
        endpoint='http://127.0.0.1:18081/price/basket-a/'; serviceStatus=200
        contentType='application/json'; baselineHttpStatus=200; contractValid=$true; poolState='Started'
        deadline=$now.AddMinutes(-1).ToString('o'); watchdogAt=$now.ToString('o')
        recoveryActor='operator-script'; recoveredAt=$now.AddSeconds(-10).ToString('o')
        bootTime=$now.AddHours(-1).ToString('o')
        response=@{sku='basket-a';currency='EUR';unit_price_cents=199}
    }
}

$stageRoot = Join-Path $PSScriptRoot ("price-stage-regression-" + [guid]::NewGuid())
$stageOwner = [guid]::NewGuid().ToString()
$stageDirectory = Join-Path $stageRoot 'PriceService'
$stageController = Join-Path $stageDirectory 'Invoke-PriceGuest.ps1'
function icacls.exe { $global:LASTEXITCODE = 0 }
try {
    $null = New-Item -ItemType Directory -Path $stageRoot
    Set-Content -LiteralPath (Join-Path $stageRoot 'owner.txt') -Value $stageOwner
    $preparation = Get-PriceInstallPreparation -OwnerDirectory $stageRoot -OwnerToken $stageOwner `
        -EnvironmentName 'demo09' -Source (Get-Content -LiteralPath $guestPath -Raw)
    & ([scriptblock]::Create($preparation))
    Assert-PriceInstallStage -Directory $stageDirectory -ControllerPath $stageController `
        -OwnerToken $stageOwner -EnvironmentName 'demo09'
    $checks++
    Assert-Rejected { & ([scriptblock]::Create($preparation)) }
    Assert-Rejected {
        Assert-PriceInstallStage -Directory $stageDirectory -ControllerPath $stageController `
            -OwnerToken ([guid]::NewGuid().ToString()) -EnvironmentName 'demo09'
    }
    Assert-Rejected {
        Assert-PriceInstallStage -Directory $stageDirectory -ControllerPath $stageController `
            -OwnerToken $stageOwner -EnvironmentName 'demo08'
    }
    Set-Content -LiteralPath (Join-Path $stageDirectory 'fixture.json') -Value '{}'
    Assert-Rejected {
        Assert-PriceInstallStage -Directory $stageDirectory -ControllerPath $stageController `
            -OwnerToken $stageOwner -EnvironmentName 'demo09'
    }
    Remove-Item -LiteralPath (Join-Path $stageDirectory 'fixture.json')
    Add-Content -LiteralPath $stageController -Value '# foreign controller mutation'
    Assert-Rejected {
        Assert-PriceInstallStage -Directory $stageDirectory -ControllerPath $stageController `
            -OwnerToken $stageOwner -EnvironmentName 'demo09'
    }
    Remove-Item -LiteralPath (Join-Path $stageDirectory 'install-stage.json')
    Assert-Rejected {
        Assert-PriceInstallStage -Directory $stageDirectory -ControllerPath $stageController `
            -OwnerToken $stageOwner -EnvironmentName 'demo09'
    }
} finally {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
    Remove-Item -LiteralPath Function:\icacls.exe
}

$aclRoot = Join-Path $PSScriptRoot ("price-acl-regression-" + [guid]::NewGuid())
$script:writtenAcls = @{}
function Set-Acl {
    param($LiteralPath, $AclObject, $ErrorAction)
    $script:writtenAcls[$LiteralPath] = $AclObject
}
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $aclRoot 'price\basket-a')
    Set-Content -LiteralPath (Join-Path $aclRoot 'web.config') -Value '<configuration />'
    Set-Content -LiteralPath (Join-Path $aclRoot 'price\basket-a\default.json') -Value '{}'
    $poolSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-82-1-2-3-4-5')
    Set-PriceContentAcl -WebRoot $aclRoot -PoolSid $poolSid
    foreach ($item in @(Get-Item -LiteralPath $aclRoot) + @(Get-ChildItem -LiteralPath $aclRoot -Recurse)) {
        $acl = $script:writtenAcls[$item.FullName]
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        if (-not $acl.AreAccessRulesProtected -or $rules.Count -ne 3) {
            throw 'Content ACL is unprotected or lacks explicit least-privilege grants.'
        }
        foreach ($rule in $rules) {
            $expectedRights = if ($rule.IdentityReference.Value -ceq $poolSid.Value) {
                [Security.AccessControl.FileSystemRights]::ReadAndExecute
            } else { [Security.AccessControl.FileSystemRights]::FullControl }
            if ($rule.IdentityReference.Value -cnotin @('S-1-5-18','S-1-5-32-544',$poolSid.Value) -or
                ($rule.FileSystemRights -band $expectedRights) -ne $expectedRights -or
                $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None -or
                (-not $item.PSIsContainer -and $rule.InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]::None)) {
                throw 'File ACL has inapplicable grants or unwanted access.'
            }
        }
        $checks++
    }
} finally {
    Remove-Item -LiteralPath Function:\Set-Acl
    Remove-Item -LiteralPath $aclRoot -Recurse -Force
}

$httpError = [System.Management.Automation.ErrorRecord]::new(
    [InvalidOperationException]::new('Internal Server Error'), 'HttpFailure',
    [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
$httpError.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('HTTP Error 500.19 - Internal Server Error; Error Code 0x80070005')
$httpFailure = Get-PriceHttpFailure -ErrorRecord $httpError
if ($httpFailure.httpError -cne '500.19' -or $httpFailure.hresult -cne '0x80070005') {
    throw 'HTTP error details discarded the IIS substatus or HRESULT.'
}
$checks++

$script:identitySettings = @{enabled=$false;userName='IUSR';identityType=0}
$script:identityWrites = 0
function Set-WebConfigurationProperty {
    param($PSPath,$Location,$Filter,$Name,$Value,$ErrorAction)
    if ($PSPath -cne 'MACHINE/WEBROOT/APPHOST' -or $Location -cne 'RetailTxPrice-demo11' -or
        $Filter -cne 'system.webServer/security/authentication/anonymousAuthentication') {
        throw 'Identity setter escaped the exact owned site location.'
    }
    $script:identityWrites++
    $script:identitySettings[$Name]=$Value
}
function Get-WebConfigurationProperty {
    param($PSPath,$Location,$Filter,$Name,$ErrorAction)
    if ($PSPath -cne 'MACHINE/WEBROOT/APPHOST' -or $Location -cne 'RetailTxPrice-demo11' -or
        $Filter -cne 'system.webServer/security/authentication/anonymousAuthentication') {
        throw 'Identity readback escaped the exact owned site location.'
    }
    return [pscustomobject]@{Value=$script:identitySettings[$Name]}
}
function Set-ItemProperty {
    param($LiteralPath,$Name,$Value,$ErrorAction)
    if ($LiteralPath -cne 'IIS:\AppPools\RetailTxPrice-demo11' -or $Name -cne 'processModel.identityType') {
        throw 'Pool identity setter escaped the owned application pool.'
    }
    $script:identitySettings.identityType=$Value
}
function Get-Item {
    param($LiteralPath,$ErrorAction)
    if ($LiteralPath -cne 'IIS:\AppPools\RetailTxPrice-demo11') { throw 'Unexpected pool read.' }
    return [pscustomobject]@{processModel=[pscustomobject]@{identityType=$script:identitySettings.identityType}}
}
try {
    Set-PriceSiteIdentity -SiteName 'RetailTxPrice-demo11' -PoolName 'RetailTxPrice-demo11'
    if ($identityWrites -ne 2 -or $identitySettings.enabled -ne $true -or
        $identitySettings.userName -cne '' -or $identitySettings.identityType -ne 4) {
        throw 'Owned site identity settings were not applied and read back.'
    }
    $checks++
    Invoke-Expression 'enum PricePoolIdentityTest { LocalSystem = 0; ApplicationPoolIdentity = 4 }'
    foreach ($identity in @('ApplicationPoolIdentity', [PricePoolIdentityTest]::ApplicationPoolIdentity, 4, '4')) {
        $identitySettings.identityType=$identity
        Assert-PriceSiteIdentity -SiteName 'RetailTxPrice-demo11' -PoolName 'RetailTxPrice-demo11'
        $checks++
    }
    foreach ($identity in @('LocalSystem', 'NetworkService', 'SpecificUser', 'applicationpoolidentity',
        '4.0', 4.0, $true, [PricePoolIdentityTest]::LocalSystem, $null)) {
        $identitySettings.identityType=$identity
        Assert-Rejected { Assert-PriceSiteIdentity -SiteName 'RetailTxPrice-demo11' -PoolName 'RetailTxPrice-demo11' }
    }
    $identitySettings.identityType=4
    foreach ($enabledReadback in @($true, 'True', 'true')) {
        $identitySettings.enabled=$enabledReadback
        Assert-PriceSiteIdentity -SiteName 'RetailTxPrice-demo11' -PoolName 'RetailTxPrice-demo11'
        $checks++
    }
    foreach ($enabledReadback in @($false, 'False', 'invalid', 1, $null)) {
        $identitySettings.enabled=$enabledReadback
        Assert-Rejected { Assert-PriceSiteIdentity -SiteName 'RetailTxPrice-demo11' -PoolName 'RetailTxPrice-demo11' }
    }
    $identitySettings.enabled=$true
    $identitySettings.userName=$null
    Assert-Rejected { Assert-PriceSiteIdentity -SiteName 'RetailTxPrice-demo11' -PoolName 'RetailTxPrice-demo11' }
    $identitySettings.userName=''
    foreach ($mutation in @(
        @{key='enabled';value=$false},@{key='userName';value='IUSR'},@{key='identityType';value=0}
    )) {
        $original=$identitySettings[$mutation.key]
        $identitySettings[$mutation.key]=$mutation.value
        Assert-Rejected { Assert-PriceSiteIdentity -SiteName 'RetailTxPrice-demo11' -PoolName 'RetailTxPrice-demo11' }
        $identitySettings[$mutation.key]=$original
    }
} finally {
    foreach ($mock in @('Set-WebConfigurationProperty','Get-WebConfigurationProperty','Set-ItemProperty','Get-Item')) {
        Remove-Item -LiteralPath "Function:\$mock"
    }
}

$binding = [pscustomobject]@{protocol='http';bindingInformation='127.0.0.1:18081:'}
Assert-PriceSiteBinding -Bindings @($binding) -BindingInformation '127.0.0.1:18081:'
$checks++
foreach ($drift in @(
    @($binding, [pscustomobject]@{protocol='http';bindingInformation='*:18081:'}),
    @([pscustomobject]@{protocol='http';bindingInformation='*:18081:'}),
    @([pscustomobject]@{protocol='https';bindingInformation='127.0.0.1:18081:'}),
    @([pscustomobject]@{protocol='http';bindingInformation='127.0.0.1:18082:'})
)) {
    Assert-Rejected { Assert-PriceSiteBinding -Bindings $drift -BindingInformation '127.0.0.1:18081:' }
}

$watchdogState = @{phase='healthy';runId=[guid]::NewGuid().ToString();deadline=$null}
$poolState = 'Stopped'
$recoveryCalls = 0
$healthyObservation = @{
    phase='healthy';endpoint='http://127.0.0.1:18081/price/basket-a/'
    serviceStatus=200;baselineHttpStatus=200;contractValid=$true;poolState='Started'
}
$healthyRebootAction = Invoke-PriceWatchdogCycle -State $watchdogState -Now ([DateTimeOffset]::UtcNow) `
    -GetPoolState { $poolState } `
    -CompleteRecovery { $script:recoveryCalls++; $script:poolState='Started'; $healthyObservation } `
    -AssertHealthy { throw 'Healthy-reboot watchdog should start the stopped owned pool.' }
if ($healthyRebootAction -cne 'healthy-pool-restored' -or $recoveryCalls -ne 1 -or $poolState -cne 'Started') {
    throw 'Watchdog did not restore the owned price pool after a healthy-state reboot.'
}
$checks++

foreach ($activePhase in @('fault-active','safety-test')) {
    $watchdogState = @{phase=$activePhase;runId=[guid]::NewGuid().ToString();deadline=[DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o')}
    $poolState = 'Stopped'
    $recoveryCalls = 0
    $action = Invoke-PriceWatchdogCycle -State $watchdogState -Now ([DateTimeOffset]::UtcNow) `
        -GetPoolState { $poolState } `
        -CompleteRecovery { $script:recoveryCalls++; $healthyObservation } `
        -AssertHealthy { throw 'An active bounded fault must not be healed before its deadline.' }
    if ($action -cne 'active-fault-preserved' -or $recoveryCalls -ne 0 -or
        $watchdogState.phase -cne $activePhase -or $poolState -cne 'Stopped') {
        throw "Watchdog changed the active '$activePhase' fault before its deadline."
    }
    $checks++
}

$watchdogState = @{phase='fault-active';runId=[guid]::NewGuid().ToString();deadline=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')}
$poolState = 'Stopped'
$recoveryCalls = 0
$expiredRecoveryAction = Invoke-PriceWatchdogCycle -State $watchdogState -Now ([DateTimeOffset]::UtcNow) `
    -GetPoolState { $poolState } `
    -CompleteRecovery { $script:recoveryCalls++; $script:poolState='Started'; $healthyObservation } `
    -AssertHealthy { throw 'Expired-fault reboot must enter watchdog recovery.' }
if ($expiredRecoveryAction -cne 'expired-fault-recovered' -or $recoveryCalls -ne 1 -or $poolState -cne 'Started') {
    throw 'Watchdog did not recover the expired active fault after reboot.'
}
$checks++

$watchdogState = @{phase='healthy';runId=[guid]::NewGuid().ToString();deadline=$null}
$poolState = 'Started'
Assert-Rejected {
    Invoke-PriceWatchdogCycle -State $watchdogState -Now ([DateTimeOffset]::UtcNow) `
        -GetPoolState { $poolState } -CompleteRecovery { $healthyObservation } `
        -AssertHealthy { $badBaseline=$healthyObservation.Clone(); $badBaseline.baselineHttpStatus=503; $badBaseline }
}

$owner = [guid]::NewGuid().ToString()
$environment = 'demo03'
$run = [guid]::NewGuid()
$endpoint = Get-PriceEndpoint $environment
if ($endpoint -cne 'http://127.0.0.1:18081/price/basket-a/') { throw 'Unexpected owned price endpoint.' }
$checks++

$groupId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-retailtx-disk-demo03-swedencentral'
$workspaceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/law-retailtx-stage0"
$EnvironmentName = $environment
$priceState = @{
    ownerToken=$owner; priceEventSource="RetailTxPrice-$environment"; priceEndpoint=$endpoint
    workspaceId=$workspaceId; monitorRoles=@{alert=@{principalId='owned-alert-identity'}}
    alertId="$groupId/providers/Microsoft.Insights/scheduledQueryRules/alert-retailtx-price-service-$environment"
}
$state = $priceState
$script:alertResource = @{
    id="$groupId/providers/Microsoft.Insights/scheduledQueryRules/alert-retailtx-price-service-$environment"
    tags=@{ownerToken=$owner;profile='disk-scenario'}
    identity=@{principalId='owned-alert-identity'}
    properties=@{
        scopes=@($workspaceId); enabled=$false; evaluationFrequency='PT1M'; windowSize='PT5M'
        autoMitigate=$true; severity=2
        criteria=@{allOf=@(@{query="Source == '$($priceState.priceEventSource)' | EventID == 2200 | $owner | $endpoint | phase) == 'fault-active' | serviceStatus) == 503 | baselineHttpStatus) == 200 | poolState) == 'Stopped' | contractValid) == 'false'"})}
    }
}
function Invoke-Azure { return $script:alertResource }
$null = Get-PriceAlert
$checks++
$script:alertResource.properties.criteria.allOf[0].query = "Source == '$($priceState.priceEventSource)' | EventID == 2200"
Assert-Rejected { Get-PriceAlert }
$script:alertResource.properties.criteria.allOf[0].query = "Source == '$($priceState.priceEventSource)' | EventID == 2200 | $owner | $endpoint | phase) == 'fault-active' | serviceStatus) == 503 | baselineHttpStatus) == 200 | poolState) == 'Stopped' | contractValid) == 'false'"

$dcr = @{
    id="$groupId/providers/Microsoft.Insights/dataCollectionRules/dcr-retailtx-price-service-$environment"
    tags=@{ownerToken=$owner;profile='disk-scenario'}
    properties=@{
        dataSources=@{windowsEventLogs=@(@{xPathQueries=@("Application!*[System[Provider[@Name=`"$($priceState.priceEventSource)`"] and (EventID=2200)]]")})}
        dataFlows=@(@{streams=@('Microsoft-Event')})
        destinations=@{logAnalytics=@(@{workspaceResourceId=$workspaceId})}
    }
}
Assert-PriceMonitorOwnership -DataCollectionRule $dcr -AlertRule $script:alertResource
$checks++
$dcr.properties.dataFlows[0].streams=@('Microsoft-Event','Microsoft-Perf')
Assert-Rejected { Assert-PriceMonitorOwnership -DataCollectionRule $dcr -AlertRule $script:alertResource }
$dcr.properties.dataFlows[0].streams=@('Microsoft-Event')
$dcr.tags.ownerToken=[guid]::NewGuid().ToString()
Assert-Rejected { Assert-PriceMonitorOwnership -DataCollectionRule $dcr }

$failure = New-HealthyObservation $owner $environment $run.ToString()
$failure.event = 'fault-injected'
$failure.phase = 'fault-active'
$failure.serviceStatus = 503
$failure.contentType = $null
$failure.contractValid = $false
$failure.poolState = 'Stopped'
$failure.response = $null
Assert-PriceObservation -Observation $failure -OwnerToken $owner -EnvironmentName $environment `
    -RunId $run.ToString() -Expected failure | Out-Null
$checks++

$faultCalls = 0
$script:persistedFault = $null
$dispatched = Invoke-PriceFaultDispatch -RunId $run -OwnerToken $owner -EnvironmentName $environment `
    -InvokeGuest {
        param($requestedRun)
        $script:faultCalls++
        if ($requestedRun.ToString() -cne $run.ToString()) { throw 'Fault dispatcher changed the run identity.' }
        $failure
    } -PersistObservation {
        param($observation)
        $script:persistedFault = $observation
    }
if ($faultCalls -ne 1 -or $dispatched.runId -cne $run.ToString() -or
    $script:persistedFault.runId -cne $run.ToString()) {
    throw 'Price fault dispatcher did not issue and persist exactly one same-run observed failure.'
}
$checks++

foreach ($mutation in @(
    @{key='runId'; value=[guid]::NewGuid().ToString()},
    @{key='ownerToken'; value=[guid]::NewGuid().ToString()},
    @{key='phase'; value='healthy'},
    @{key='serviceStatus'; value=200},
    @{key='baselineHttpStatus'; value=503},
    @{key='poolState'; value='Started'},
    @{key='endpoint'; value='http://foreign.example/price/basket-a/'},
    @{key='observedAt'; value=[DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')}
)) {
    $original = $failure[$mutation.key]
    $failure[$mutation.key] = $mutation.value
    Assert-Rejected {
        Assert-PriceObservation -Observation $failure -OwnerToken $owner -EnvironmentName $environment `
            -RunId $run.ToString() -Expected failure
    }

    $failure[$mutation.key] = $original
}

$wrongRunFailure = $failure.Clone()
$wrongRunFailure.runId = [guid]::NewGuid().ToString()
$script:faultCalls = 0
Assert-Rejected {
    Invoke-PriceFaultDispatch -RunId $run -OwnerToken $owner -EnvironmentName $environment `
        -InvokeGuest { $script:faultCalls++; $wrongRunFailure } -PersistObservation { throw 'Invalid event was persisted.' }
}
if ($script:faultCalls -ne 1) { throw 'Same-run validation did not inspect the dispatched failure.' }

$healthy = New-HealthyObservation $owner $environment $run.ToString()
Assert-PriceObservation -Observation $healthy -OwnerToken $owner -EnvironmentName $environment `
    -RunId $run.ToString() -Expected healthy | Out-Null
$checks++
$telemetry = @{
    workspaceId='workspace-customer-guid'; arcResourceId='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-retailtx-disk-demo03-swedencentral/providers/Microsoft.HybridCompute/machines/disk-demo03'
    rows=@(@{observedAt=$healthy.observedAt;details=$healthy})
}
$expectedWorkspace = $telemetry.workspaceId
$expectedArc = $telemetry.arcResourceId
$verified = Assert-PriceTelemetry -Evidence $telemetry -WorkspaceId $telemetry.workspaceId `
    -ArcResourceId $telemetry.arcResourceId -OwnerToken $owner -EnvironmentName $environment `
    -RunId $run.ToString() -Expected healthy
if ($verified.recoveryActor -cne 'operator-script' -or $verified.response.unit_price_cents -ne 199) {
    throw 'Private event did not verify the exact retailtx.contracts.Price basket-a recovery.'
}
$checks++

foreach ($mutation in @(
    @{key='workspaceId'; value='other-workspace'},
    @{key='arcResourceId'; value='other-arc'},
    @{key='rows'; value=@($telemetry.rows[0],$telemetry.rows[0])}
)) {
    $original = $telemetry[$mutation.key]
    $telemetry[$mutation.key] = $mutation.value
    Assert-Rejected {
        Assert-PriceTelemetry -Evidence $telemetry -WorkspaceId $expectedWorkspace `
            -ArcResourceId $expectedArc -OwnerToken $owner -EnvironmentName $environment `
            -RunId $run.ToString() -Expected healthy
    }
    $telemetry[$mutation.key] = $original
}

foreach ($mutation in @(
    @{key='runId'; value=[guid]::NewGuid().ToString()},
    @{key='ownerToken'; value=[guid]::NewGuid().ToString()},
    @{key='environmentName'; value='demo04'},
    @{key='phase'; value='fault-active'},
    @{key='contractValid'; value=$false}
)) {
    $original = $healthy[$mutation.key]
    $healthy[$mutation.key] = $mutation.value
    Assert-Rejected {
        Assert-PriceTelemetry -Evidence $telemetry -WorkspaceId $telemetry.workspaceId `
            -ArcResourceId $telemetry.arcResourceId -OwnerToken $owner -EnvironmentName $environment `
            -RunId $run.ToString() -Expected healthy
    }
    $healthy[$mutation.key] = $original
}

$script:recoveryRun = $null
$script:recoveryCalls = 0
$recovered = Invoke-PriceRecoveryDispatch -RunId $run -OwnerToken $owner -EnvironmentName $environment `
    -WorkspaceId $telemetry.workspaceId -ArcResourceId $telemetry.arcResourceId `
    -InvokeGuest {
        param($requestedRun)
        $script:recoveryCalls++
        $script:recoveryRun = $requestedRun.ToString()
        $healthy
    } -GetPrivateTelemetry { $telemetry }
if ($script:recoveryCalls -ne 1 -or $script:recoveryRun -cne $run.ToString() -or
    $recovered.privateTelemetry.recoveryActor -cne 'operator-script') {
    throw 'Price recovery dispatch failed to bind the guest action and independent private evidence to one run.'
}
$checks++

$script:recoveryCalls = 0
Assert-Rejected {
    Invoke-PriceRecoveryDispatch -RunId ([guid]::Empty) -OwnerToken $owner -EnvironmentName $environment `
        -WorkspaceId $telemetry.workspaceId -ArcResourceId $telemetry.arcResourceId `
        -InvokeGuest { $script:recoveryCalls++; $healthy } -GetPrivateTelemetry { $telemetry }
}
if ($script:recoveryCalls -ne 0) { throw 'Invalid recovery run reached the guest callback.' }

$wrongActorEvidence = @{
    workspaceId=$telemetry.workspaceId; arcResourceId=$telemetry.arcResourceId
    rows=@(@{observedAt=$healthy.observedAt;details=$healthy.Clone()})
}
$wrongActorEvidence.rows[0].details.recoveryActor='independent-watchdog'
Assert-Rejected {
    Invoke-PriceRecoveryDispatch -RunId $run -OwnerToken $owner -EnvironmentName $environment `
        -WorkspaceId $telemetry.workspaceId -ArcResourceId $telemetry.arcResourceId `
        -InvokeGuest { $healthy } -GetPrivateTelemetry { $wrongActorEvidence }
}

$wrongScriptHash = ('A' * 64)
$rightScriptHash = ('B' * 64)
Assert-PriceControllerHash -ExpectedHash $rightScriptHash -ActualHash $rightScriptHash
$checks++
Assert-Rejected { Assert-PriceControllerHash -ExpectedHash $rightScriptHash -ActualHash $wrongScriptHash }
Assert-Rejected { Assert-PriceControllerHash -ExpectedHash 'malformed' -ActualHash $rightScriptHash }

$watchdogHealthy = New-HealthyObservation $owner $environment $run.ToString()
$watchdogHealthy.recoveryActor = 'independent-watchdog'
$watchdogHealthy.observedAt = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')
$watchdogHealthy.recoveredAt = [DateTimeOffset]::UtcNow.AddMinutes(-6).ToString('o')
$watchdogHealthy.deadline = [DateTimeOffset]::UtcNow.AddMinutes(-7).ToString('o')
$freshPrivate = New-HealthyObservation $owner $environment $run.ToString()
$freshPrivate.recoveryActor = 'independent-watchdog'
Assert-PriceFaultReadiness -Telemetry $freshPrivate -SafetyProof $watchdogHealthy -OwnerToken $owner `
    -EnvironmentName $environment -ExpiresAt ([DateTimeOffset]::UtcNow.AddHours(2))
$checks++

$staleSafetyProof = $watchdogHealthy.Clone()
$staleSafetyProof.observedAt = [DateTimeOffset]::UtcNow.AddDays(-1).AddMinutes(-1).ToString('o')
Assert-Rejected {
    Assert-PriceFaultReadiness -Telemetry $freshPrivate -SafetyProof $staleSafetyProof -OwnerToken $owner `
        -EnvironmentName $environment -ExpiresAt ([DateTimeOffset]::UtcNow.AddHours(2))
}

$staleTelemetry = $freshPrivate.Clone()
$staleTelemetry.observedAt = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
Assert-Rejected {
    Assert-PriceFaultReadiness -Telemetry $staleTelemetry -SafetyProof $watchdogHealthy -OwnerToken $owner `
        -EnvironmentName $environment -ExpiresAt ([DateTimeOffset]::UtcNow.AddHours(2))
}

$badProof = $watchdogHealthy.Clone()
$badProof.recoveryActor = 'operator-script'
Assert-Rejected {
    Assert-PriceFaultReadiness -Telemetry $freshPrivate -SafetyProof $badProof -OwnerToken $owner `
        -EnvironmentName $environment -ExpiresAt ([DateTimeOffset]::UtcNow.AddHours(2))
}

Write-Output "Price-service scenario checks passed: $checks"
