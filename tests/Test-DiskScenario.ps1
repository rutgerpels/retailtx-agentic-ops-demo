#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:checks = 0
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe disk fixture operation was accepted.' }
    $script:checks++
}
$errors = $null
$path = Join-Path $PSScriptRoot '..\scripts\Invoke-DiskScenario.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
foreach ($entry in @('Assert-DiskFaultReadiness', 'Get-DiskAlert', 'Assert-DiskRecoveryRun')) {
    if (-not @($ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $entry
    }).Count) { throw "$entry is not available at script scope." }
    $script:checks++
}
foreach ($name in @('Assert-Manifest', 'Get-OwnedGroup', 'Get-OwnedMachine', 'Remove-BootstrapAccess',
    'Archive-DeletedDiskEvidence', 'Wait-DiskMonitorAgent', 'Invoke-DiskMonitorDeployment', 'Set-MonitorAccess', 'Remove-MonitorAccess', 'Assert-FreshTelemetry', 'Assert-SafetyRecovery', 'Assert-DiskFaultReadiness', 'Assert-DiskRecoveryRun', 'Test-ArcConnection', 'Get-ArcCommand', 'Invoke-ArcCommand', 'Invoke-GuestController')) {
    $function = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}
$subscription = '11111111-1111-1111-1111-111111111111'
& {
    $state = @{ownerToken='owned';workspaceId="/subscriptions/$subscription/resourceGroups/foundation/providers/Microsoft.OperationalInsights/workspaces/test"}
    $calls = [Collections.Generic.List[object]]::new()
    $assignment = $null
    function Save-State { $script:earlyGrantSaved = $true }
    function Invoke-Azure {
        param($Arguments)
        if (-not $script:earlyGrantSaved) { throw 'Grant was not recorded before creation' }
        if ($Arguments[2] -ceq 'list') {
            if ($assignment) { return $assignment }
            return @()
        }
        $calls.Add($Arguments)
    }
    $script:earlyGrantSaved = $false
    $principal = [guid]'22222222-2222-2222-2222-222222222222'
    Set-MonitorAccess -Target arc -PrincipalId $principal
    $assignment = @{id=$state.monitorRoles.arc.id;scope=$state.workspaceId;principalId=$principal.ToString()
        roleDefinitionId='/roles/73c42c96-874c-492b-b04d-ab87d138a893';description='retailtx:disk:owned:arc'}
    Set-MonitorAccess -Target arc -PrincipalId $principal
    if ($calls.Count -ne 1 -or
        $calls[0][6] -cne $principal.ToString() -or
        $calls[0][10] -cne '73c42c96-874c-492b-b04d-ab87d138a893' -or
        $calls[0][12] -cne $state.workspaceId -or $calls[0][14] -cne 'retailtx:disk:owned:arc') {
        throw 'Early grant changed identity, ownership, scope or idempotent assignment'
    }
    $script:checks++
    Assert-Rejected { Set-MonitorAccess -Target arc -PrincipalId ([guid]::NewGuid()) }
    if ($calls.Count -ne 1) { throw 'Identity drift created another grant' }
    $script:checks++
    foreach ($key in @('scope','principalId','roleDefinitionId','description')) {
        $original = $assignment[$key]
        $assignment[$key] = 'foreign'
        Assert-Rejected { Set-MonitorAccess -Target arc -PrincipalId $principal }
        $assignment[$key] = $original
    }
}
$startupGrant = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -ceq 'Set-MonitorAccess -Target arc -PrincipalId $machine.identity.principalId'
}, $true))
if ($startupGrant.Count -ne 2 -or $startupGrant[0].Extent.StartLineNumber -ge
    $startupGrant[1].Extent.StartLineNumber -or -not $ast.Extent.Text.Replace("`r`n", "`n").Contains(
        "`$machine = Get-OwnedMachine -Arc`n        Set-MonitorAccess -Target arc -PrincipalId `$machine.identity.principalId")) {
    throw 'Early Arc grant must follow exact ownership verification and remain reconciled by Monitor'
}
$script:checks++
$EnvironmentName = 'demo03'
$FoundationEnvironment = 'stage0'
$groupName = 'rg-retailtx-disk-demo03-swedencentral'
$groupId = "/subscriptions/$subscription/resourceGroups/$groupName"
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-retailtx-disk-demo03"
$arcId = "$groupId/providers/Microsoft.HybridCompute/machines/disk-demo03"
$arcApi = '2024-07-10'
$scope = "/subscriptions/$subscription/resourceGroups/rg-retailtx-stage0-swedencentral/providers/Microsoft.HybridCompute/privateLinkScopes/pls-retailtx-stage0-arc"
$state = @{
    schemaVersion=1; profile='disk-scenario'; subscriptionId=$subscription; environmentName=$EnvironmentName
    foundationEnvironment=$FoundationEnvironment; groupId=$groupId; vmId=$vmId; arcId=$arcId
    ownerToken='22222222-2222-2222-2222-222222222222'
    privateLinkRoleName='33333333-3333-3333-3333-333333333333'
    privateLinkScopeId=$scope
    privateLinkRoleId="$scope/providers/Microsoft.Authorization/roleAssignments/33333333-3333-3333-3333-333333333333"
    bootstrapPrincipalId='44444444-4444-4444-4444-444444444444'
    workspaceId="/subscriptions/$subscription/resourceGroups/rg-retailtx-stage0-swedencentral/providers/Microsoft.OperationalInsights/workspaces/law-retailtx-stage0"
    workspaceCustomerId='66666666-6666-6666-6666-666666666666'
    dceId="/subscriptions/$subscription/resourceGroups/rg-retailtx-stage0-swedencentral/providers/Microsoft.Insights/dataCollectionEndpoints/dce-retailtx-stage0"
}
$script:group = @{
    id=$groupId; location='swedencentral'
    tags=@{demo='retailtx';environmentId=$EnvironmentName;ownerToken=$state.ownerToken;profile='disk-scenario';managedBy='retailtx'}
}
$script:exists=$true
$script:machine=@{id=$arcId;tags=@{ownerToken=$state.ownerToken;profile='disk-scenario'}
    properties=@{privateLinkScopeResourceId=$scope}}
$script:assignments=@()
$script:deletes=[Collections.Generic.List[string]]::new()
function Save-State {}
function Invoke-Azure {
    param([string[]]$Arguments)
    switch ("$($Arguments[0]) $($Arguments[1])") {
        'group exists' { return $script:exists }
        'group show' { return $script:group }
        'resource show' { return $script:machine }
        'role assignment' {
            if($Arguments[2] -ceq 'list') { return $script:assignments }
            if($Arguments[2] -ceq 'delete') {
                $script:deletes.Add($Arguments[4])
                $script:assignments=@($script:assignments|Where-Object id -CNE $Arguments[4])
                return
            }
            throw 'Unexpected role action.'
        }
        default { throw 'Unexpected Azure operation in offline regression.' }
    }
}
Assert-Manifest $state
& {
    $root = Split-Path $PSScriptRoot
    $fixture = @{
        creates=0; reads=0; sleeps=0; rejectFirst=$true; deploymentState='Failed'
        code='HCRP409'; target="$arcId/extensions/AzureMonitorWindowsAgent"
        publisher='Microsoft.Azure.Monitor'; phases=@('Creating', 'Succeeded'); existing=@()
    }
    function Start-Sleep { param($Seconds); $fixture.sleeps++ }
    function Invoke-Azure {
        param($Arguments, $TimeoutSeconds)
        switch ("$($Arguments[0]) $($Arguments[1]) $($Arguments[2])") {
            'deployment group create' {
                $fixture.creates++
                if ($fixture.rejectFirst -and $fixture.creates -eq 1) { throw 'Deployment failed' }
                if (($fixture.creates -eq 2 -or $fixture.existing.Count) -and $Arguments[-1] -cne 'deployMonitoringAgent=false') {
                    throw 'Settled policy extension would be rewritten by the retry'
                }
                return @{properties=@{provisioningState='Succeeded'}}
            }
            'deployment group show' { return @{properties=@{provisioningState=$fixture.deploymentState}} }
            'deployment operation group' {
                return @(@{properties=@{provisioningState='Failed';targetResource=@{id=$fixture.target}
                    statusMessage=@{error=@{code=$fixture.code}}}})
            }
            'rest --method get' {
                if ($Arguments[-1] -like '*/extensions?api-version=*') { return @{value=$fixture.existing} }
                $phase=$fixture.phases[[Math]::Min($fixture.reads, $fixture.phases.Count-1)]
                $fixture.reads++
                return @{id="$arcId/extensions/AzureMonitorWindowsAgent";properties=@{
                    publisher=$fixture.publisher;type='AzureMonitorWindowsAgent';provisioningState=$phase}}
            }
            default { throw 'Unexpected monitoring recovery operation' }
        }
    }
    $result=Invoke-DiskMonitorDeployment -ParameterFile 'offline.json'
    if ($result.properties.provisioningState -cne 'Succeeded' -or $fixture.creates -ne 2 -or
        $fixture.reads -ne 2 -or $fixture.sleeps -ne 1) { throw 'AMA conflict was not settled before one deployment retry' }
    $script:checks++
    foreach ($invalid in @(@{key='code';value='AuthorizationFailed'}, @{key='target';value='foreign'},
        @{key='publisher';value='foreign'}, @{key='phases';value=@('Failed')},
        @{key='deploymentState';value='Running'})) {
        $original=$fixture[$invalid.key]
        $fixture[$invalid.key]=$invalid.value
        $fixture.creates=0; $fixture.reads=0; $fixture.sleeps=0
        Assert-Rejected { Invoke-DiskMonitorDeployment -ParameterFile 'offline.json' }
        if ($fixture.creates -ne 1) { throw 'Unsafe monitoring deployment was retried' }
        $script:checks++
        $fixture[$invalid.key]=$original
    }
    $fixture.creates=0; $fixture.reads=0; $fixture.rejectFirst=$false
    $null=Invoke-DiskMonitorDeployment -ParameterFile 'offline.json'
    if ($fixture.creates -ne 1 -or $fixture.reads) { throw 'Successful monitoring deployment was retried' }
    $script:checks++
    $fixture.existing=@(@{id="$arcId/extensions/AzureMonitorWindowsAgent";properties=@{type='AzureMonitorWindowsAgent'}})
    $fixture.creates=0; $fixture.reads=0
    $null=Invoke-DiskMonitorDeployment -ParameterFile 'offline.json'
    if ($fixture.creates -ne 1 -or $fixture.reads -ne 2) { throw 'Existing AMA was not verified before monitoring deployment' }
    $script:checks++
    $fixture.existing[0].id='foreign'
    $fixture.creates=0
    Assert-Rejected { Invoke-DiskMonitorDeployment -ParameterFile 'offline.json' }
    if ($fixture.creates) { throw 'Monitoring adopted a foreign extension' }
    $script:checks++
}
foreach($partial in @($null,@{},@{properties=@{}},@{properties=@{status='Disconnected'}})){
    if(Test-ArcConnection $partial){throw 'Partial/disconnected Arc resource passed readiness'}
    $script:checks++
}
if(-not (Test-ArcConnection @{properties=@{status='Connected'}})){throw 'Connected Arc resource rejected'}
$script:checks++
$null=Get-OwnedGroup
$null=Get-OwnedMachine -Arc
$script:checks+=3
& {
    $faultId=[guid]::NewGuid()
    $observation=@{runId=$faultId.ToString();phase='healthy';recoveryActor='independent-watchdog';freePercent=99
        bootTime='2026-01-01T10:03:00Z';recoveredAt='2026-01-01T10:06:00Z'}
    $reboot=@{bootBefore='2026-01-01T09:00:00Z';canaryObservedAt='2026-01-01T10:00:00Z'
        deadline='2026-01-01T10:05:00Z'}
    Assert-SafetyRecovery -Observation $observation -FaultId $faultId
    Assert-SafetyRecovery -Observation $observation -FaultId $faultId -Reboot $reboot
    $script:checks+=2
    foreach($invalid in @(@{key='runId';value=[guid]::NewGuid().ToString()},
        @{key='phase';value='safety-test'},@{key='recoveryActor';value='operator-script'},
        @{key='freePercent';value=8},@{key='freePercent';value=$null},
        @{key='freePercent';value=[double]::NaN},@{key='freePercent';value=101},
        @{key='bootTime';value=$reboot.bootBefore},@{key='bootTime';value='2026-01-01T09:30:00Z'},
        @{key='recoveredAt';value='2026-01-01T10:02:00Z'},@{key='recoveredAt';value='2026-01-01T10:04:00Z'})){
        $old=$observation[$invalid.key]
        $observation[$invalid.key]=$invalid.value
        Assert-Rejected {Assert-SafetyRecovery -Observation $observation -FaultId $faultId -Reboot $reboot}
        $observation[$invalid.key]=$old
    }
    Assert-Rejected { & $path Status -SubscriptionId $subscription -RebootDuringSafetyTest -WhatIf }
}
& {
    $state.expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
    $proof = @{runId=[guid]::NewGuid().ToString();phase='healthy';recoveryActor='independent-watchdog';freePercent=99
        ownerToken=$state.ownerToken;volume='R:';iisHttpStatus=200
        deadline=[DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
        recoveredAt=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o');observedAt=[DateTimeOffset]::UtcNow.ToString('o')}
    $telemetry=@{freePercent=99;guest=@{ownerToken=$state.ownerToken;phase='healthy';freePercent=99}}
    Assert-DiskFaultReadiness $telemetry $proof
    $script:checks++
    foreach($bad in @($null, 8, 101, [double]::NaN)) {
        $telemetry.freePercent=$bad
        Assert-Rejected {Assert-DiskFaultReadiness $telemetry $proof}
        $telemetry.freePercent=99
        $telemetry.guest.freePercent=$bad
        Assert-Rejected {Assert-DiskFaultReadiness $telemetry $proof}
        $telemetry.guest.freePercent=99
    }
    foreach($change in @(@{key='ownerToken';value='foreign'},@{key='volume';value='C:'},
        @{key='iisHttpStatus';value=500},@{key='recoveryActor';value='operator-script'},
        @{key='recoveredAt';value=[DateTimeOffset]::UtcNow.AddMinutes(-3).ToString('o')},
        @{key='observedAt';value=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o')})) {
        $old=$proof[$change.key]
        $proof[$change.key]=$change.value
        Assert-Rejected {Assert-DiskFaultReadiness $telemetry $proof}
        $proof[$change.key]=$old
    }
    $telemetry.guest.phase='pressure'
    Assert-Rejected {Assert-DiskFaultReadiness $telemetry $proof}
    $telemetry.guest.phase='healthy'
    $state.expiresAt=[DateTimeOffset]::UtcNow.AddMinutes(20).ToString('o')
    Assert-Rejected {Assert-DiskFaultReadiness $telemetry $proof}
    $state.Remove('expiresAt')
}
& {
    $pending=[guid]::NewGuid()
    $old=[guid]::NewGuid()
    $state.activeRunId=$pending.ToString()
    foreach($phase in @('fault-requested','fault-active')){
        $state.phase=$phase
        Assert-Rejected {Assert-DiskRecoveryRun $old}
        Assert-Rejected {Assert-DiskRecoveryRun $pending @{runId=$old.ToString();phase='healthy'}}
        Assert-Rejected {Assert-DiskRecoveryRun $pending @{runId=$pending.ToString();phase='pressure'}}
        Assert-DiskRecoveryRun $pending @{runId=$pending.ToString();phase='healthy'}
        $script:checks++
    }
    Assert-Rejected {Assert-DiskRecoveryRun ([guid]::Empty)}
    $state.Remove('phase')
    $state.Remove('activeRunId')
}
& {
    $guest=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\disk\Invoke-DiskGuest.ps1') -Raw
    $statement=[regex]::Match($guest,'(?m)^\s*\$count = \[int\]\[Math\]::Min\([^\r\n]+').Value.Trim()
    if(-not $statement){throw 'Missing bounded pressure chunk calculation'}
    $verification=@'
$ErrorActionPreference='Stop'
$target=[long]3910554255
$stream=@{Length=[long]0}
$buffer=@{Length=1048576}
__CALCULATION__
if($count -ne 1048576){throw 'Large remaining capacity did not produce a bounded chunk'}
$stream.Length=$target-17
__CALCULATION__
if($count -ne 17){throw 'Final chunk crossed the target size'}
'@.Replace('__CALCULATION__',$statement)
    & ([scriptblock]::Create($verification))
    if($IsWindows){
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command $verification
        if($LASTEXITCODE -ne 0){throw 'Windows PowerShell 5.1 pressure arithmetic failed'}
    }
    $script:checks+=2
}
foreach($key in @('profile','environmentName','subscriptionId','groupId','vmId','arcId','foundationEnvironment',
    'ownerToken','privateLinkRoleName','privateLinkScopeId','privateLinkRoleId','workspaceId','workspaceCustomerId','dceId')){
    $old=$state[$key]
    $state[$key]='foreign'
    Assert-Rejected {Assert-Manifest $state}
    $state[$key]=$old
}
foreach($key in @('demo','environmentId','ownerToken','managedBy','profile')){
    $old=$script:group.tags[$key]
    $script:group.tags[$key]='foreign'
    Assert-Rejected {Get-OwnedGroup}
    $script:group.tags[$key]=$old
}
$script:exists=$false
if(Get-OwnedGroup){throw 'Absent group was reported present'}
Assert-Rejected {Get-OwnedMachine -Arc}
$script:exists=$true
$script:machine.tags.ownerToken='foreign'
Assert-Rejected {Get-OwnedMachine -Arc}
$script:machine.tags.ownerToken=$state.ownerToken
$script:machine.properties.privateLinkScopeResourceId='foreign'
Assert-Rejected {Get-OwnedMachine -Arc}
$script:machine.properties.privateLinkScopeResourceId=$scope
$ownedAssignment=@{id=$state.privateLinkRoleId;scope=$scope;principalId=$state.bootstrapPrincipalId
    roleDefinitionId="/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"}
foreach($key in @('scope','principalId','roleDefinitionId')){
    $copy=$ownedAssignment.Clone()
    $copy[$key]='foreign'
    $script:assignments=@($copy)
    Assert-Rejected {Remove-BootstrapAccess}
}
if($script:deletes.Count){throw 'Cleanup mutated an invalid assignment'}
$onboarding=@{id="$groupId/providers/Microsoft.Authorization/roleAssignments/55555555-5555-5555-5555-555555555555"
    scope=$groupId;principalId=$state.bootstrapPrincipalId
    roleDefinitionId="/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/b64e21ea-ac4e-4cdf-9dc9-5b892992bee7"}
$invalid=$ownedAssignment.Clone()
$invalid.scope='foreign'
$script:assignments=@($onboarding,$invalid)
Assert-Rejected {Remove-BootstrapAccess}
if($script:deletes.Count){throw 'Cleanup partially mutated grants before detecting an invalid assignment'}
$script:assignments=@($ownedAssignment)
Remove-BootstrapAccess
if($script:deletes.Count -ne 1 -or -not $state.bootstrapAccessRemoved){throw 'Owned bootstrap cleanup did not complete'}
$script:checks++
& {
    $roleName='77777777-7777-7777-7777-777777777777'
    $roleId="$($state.workspaceId)/providers/Microsoft.Authorization/roleAssignments/$roleName"
    $state.monitorRoles=@{arc=@{name=$roleName;id=$roleId;principalId=$state.bootstrapPrincipalId}}
    Assert-Manifest $state
    $script:checks++
    $assignment=@{
        id=$roleId;scope=$state.workspaceId;principalId=$state.bootstrapPrincipalId
        roleDefinitionId="/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/73c42c96-874c-492b-b04d-ab87d138a893"
        description="retailtx:disk:$($state.ownerToken):arc"
    }
    $before=$script:deletes.Count
    foreach($key in @('scope','principalId','roleDefinitionId','description')){
        $invalid=$assignment.Clone()
        $invalid[$key]='foreign'
        $script:assignments=@($invalid)
        Assert-Rejected {Remove-MonitorAccess}
    }
    if($script:deletes.Count -ne $before){throw 'External monitor cleanup deleted an unowned assignment'}
    $state.monitorRoles.arc.id='foreign'
    Assert-Rejected {Assert-Manifest $state}
    $state.monitorRoles.arc.id=$roleId
    $unrelated=$assignment.Clone()
    $unrelated.id="$($state.workspaceId)/providers/Microsoft.Authorization/roleAssignments/88888888-8888-8888-8888-888888888888"
    $script:assignments=@($assignment,$unrelated)
    Remove-MonitorAccess
    Remove-MonitorAccess
    if($script:deletes.Count -ne $before+1 -or $script:assignments.Count -ne 1 -or
        $script:assignments[0].id -cne $unrelated.id){throw 'Monitor cleanup was not exact or idempotent'}
    $script:checks++
    $state.Remove('monitorRoles')
}
& {
    $now=[DateTimeOffset]::UtcNow.ToString('o')
    $detail=@{ownerToken=$state.ownerToken;volume='R:';iisHttpStatus=200;watchdogAt=$now;observedAt=$now}
    $disk=@{kind='disk';observedAt=$now;freePercent=8.0}
    $event=@{kind='guest';observedAt=$now;details=$detail}
    $evidence=@{workspaceId=$state.workspaceCustomerId;arcResourceId=$arcId;privateAddresses=@('10.84.1.10');rows=@($disk,$event)}
    if((Assert-FreshTelemetry $evidence).freePercent -ne 8){throw 'Real low-space counter was not preserved'}
    $script:checks++
    foreach($value in @($null,-1,101,[double]::NaN)){
        $disk.freePercent=$value
        Assert-Rejected {Assert-FreshTelemetry $evidence}
    }
    $disk.freePercent=8
    foreach($row in @($disk,$event,$detail)){
        foreach($date in @([DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o'),
            [DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o'))){
            $row.observedAt=$date
            Assert-Rejected {Assert-FreshTelemetry $evidence}
            $row.observedAt=$now
        }
    }
    $detail.ownerToken='foreign'
    Assert-Rejected {Assert-FreshTelemetry $evidence}
    $detail.ownerToken=$state.ownerToken
    $detail.watchdogAt=[DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')
    Assert-Rejected {Assert-FreshTelemetry $evidence}
    $detail.watchdogAt=$now
    $evidence.workspaceId='foreign'
    Assert-Rejected {Assert-FreshTelemetry $evidence}
    $evidence.workspaceId=$state.workspaceCustomerId
    $evidence.rows=@($disk)
    Assert-Rejected {Assert-FreshTelemetry $evidence}
}
& {
    $directory=$PSScriptRoot
    $commandId="$arcId/runCommands/test"
    $script:response=@{StatusCode=404;Content='{"error":{"code":"HCRP404"}}'}
    function Invoke-Azure {param($Arguments);@{accessToken='unit-test-token'}}
    function Invoke-WebRequest {param($Uri,$Authentication,$Token,$MaximumRedirection,$TimeoutSec,[switch]$SkipHttpErrorCheck);$script:response}
    function Save-RetailState {param($Value,$Path)}
    if(Get-ArcCommand $commandId){throw 'Pending command registration returned success'}
    $script:checks++
    foreach($failure in @(@{StatusCode=403;Content='{"error":{"code":"AuthorizationFailed"}}'},
        @{StatusCode=404;Content='{"error":{"code":"ResourceNotFound"}}'},
        @{StatusCode=200;Content='{"id":"foreign","properties":{}}'})){
        $script:response=$failure
        Assert-Rejected {Get-ArcCommand $commandId}
    }
    $script:response=@{StatusCode=200;Content=(@{id=$commandId;properties=@{provisioningState='Creating'}}|ConvertTo-Json)}
    $result=Get-ArcCommand $commandId
    if($result.id -cne $commandId -or $result.properties.provisioningState -cne 'Creating'){throw 'Pending command evidence was not preserved'}
    $script:checks++
}
& $path Status -SubscriptionId $subscription -EnvironmentName 'dryrun01' -WhatIf
if(Test-Path (Join-Path $PSScriptRoot '..\.azure\dryrun01')){throw 'WhatIf created state'}
$script:checks++
$manifestReads=@($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Get-Content' -and $node.Extent.Text -match '\$statePath'
},$true))
$lockStatement=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text.StartsWith('$lease =')})[0]
$lockedTry=@($ast.EndBlock.Statements|Where-Object {$_ -is [System.Management.Automation.Language.TryStatementAst]})[0]
if($manifestReads.Count -ne 1 -or $manifestReads[0].Extent.StartOffset -le $lockStatement.Extent.EndOffset -or
    $manifestReads[0].Extent.StartOffset -le $lockedTry.Body.Extent.StartOffset -or
    $manifestReads[0].Extent.EndOffset -ge $lockedTry.Body.Extent.EndOffset){
    throw 'Manifest must be loaded under the acquired lease, not before confirmation or locking'
}
$script:checks++
& {
    $state=$state.Clone()
    $source='offline-controller-source'
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source)))
    $directory=$PSScriptRoot
    $now=[DateTimeOffset]::UtcNow.ToString('o')
    $observation=@{ownerToken=$state.ownerToken;volume='R:';iisHttpStatus=200;observedAt=$now
        phase='healthy';runId=$null;freePercent=99;watchdogAt=$now}
    function Join-Path {param($Path,$ChildPath);'offline-controller.ps1'}
    function Get-Content {param($LiteralPath,[switch]$Raw);$source}
    function Invoke-ArcCommand {param($Purpose,$Script)
        if($Purpose -cne 'status' -or $Script.Contains('WriteAllBytes')){throw 'Reconciliation tried to install or mutate guest files'}
        return @{output=($observation|ConvertTo-Json -Compress)}
    }
    function Save-State {}
    function Save-RetailState {param($Value,$Path)}
    Assert-Rejected {Invoke-GuestController -Action Status -Reconcile}
    $state.pendingControllerSha256='foreign'
    Assert-Rejected {Invoke-GuestController -Action Status -Reconcile}
    $state.pendingControllerSha256=$hash
    $state.controllerSha256='foreign'
    Assert-Rejected {Invoke-GuestController -Action Status -Reconcile}
    $state.Remove('controllerSha256')
    foreach($invalid in @(@{key='phase';value='pressure'},@{key='runId';value=[guid]::NewGuid().ToString()},
        @{key='freePercent';value=8},@{key='watchdogAt';value=[DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')},
        @{key='watchdogAt';value=[DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o')})){
        $old=$observation[$invalid.key]
        $observation[$invalid.key]=$invalid.value
        Assert-Rejected {Invoke-GuestController -Action Status -Reconcile}
        $observation[$invalid.key]=$old
    }
    $null=Invoke-GuestController -Action Status -Reconcile
    if($state.controllerSha256 -cne $hash -or $state.phase -cne 'guest-installed'){
        throw 'Verified exact-revision guest reconciliation did not persist installation'
    }
    $script:checks++
    $state.probeCount=3
    Assert-Rejected {Invoke-GuestController -Action Install}
    Assert-Rejected {Invoke-GuestController -Action Install -Reconcile}
}
& {
    $state=$state.Clone()
    $directory='C:\offline-fixture'
    $records=[Collections.Generic.List[object]]::new()
    function Get-OwnedMachine {param([switch]$Arc);@{properties=@{status='Connected'}}}
    function Save-RetailState {param($Value,$Path);$records.Add(@{value=$Value;path=$Path})}
    function Save-State {}
    function Invoke-Azure {
        param($Arguments)
        if($Arguments[0] -cne 'rest' -or $Arguments[2] -cne 'put' -or $records.Count -ne 1){
            throw 'Request was not retained before submission'
        }
    }
    function Get-ArcCommand {param($CommandId);throw 'Simulated post-submission authentication failure'}
    try {
        $null=Invoke-ArcCommand -Purpose status -Script "Write-Output 'offline'"
        throw 'Expected post-submission failure'
    } catch {
        if($_.Exception.Message -cne 'Simulated post-submission authentication failure'){throw}
    }
    $commandName=($state.lastCommandId -split '/')[-1]
    if($records.Count -ne 1 -or $records[0].path -cne "$directory\$commandName.request.json" -or
        $records[0].value.properties.source.script -notmatch 'RETAILTX_GUEST_RESULT:[0-9a-f-]{36}'){
        throw 'Uncertain command lost its exact request and completion nonce'
    }
    $script:checks++
}
& {
    $state=$state.Clone()
    $directory='C:\offline-fixture'
    $fixture=@{request=$null;records=[Collections.Generic.List[object]]::new();puts=0}
    function Get-OwnedMachine {param([switch]$Arc);@{properties=@{status='Connected'}}}
    function Save-State {}
    function Save-RetailState {
        param($Value,$Path)
        $fixture.records.Add(@{value=$Value;path=$Path})
        if($Path.EndsWith('.request.json')){$fixture.request=$Value}
    }
    function Invoke-Azure {
        param($Arguments)
        if($Arguments[0] -cne 'rest' -or $Arguments[2] -cne 'put'){
            throw 'Completed command must remain until owned fixture teardown'
        }
        $fixture.puts++
    }
    function Get-ArcCommand {
        param($CommandId)
        $source=$fixture.request.properties.source.script
        $marker=[regex]::Match($source,'RETAILTX_GUEST_RESULT:[0-9a-f-]{36}').Value
        return @{id=$CommandId;properties=@{provisioningState='Succeeded';source=@{script=$source}
            instanceView=@{executionState='Succeeded';exitCode=0;error='';output="observed`n$marker"}}}
    }
    $first=Invoke-ArcCommand -Purpose status -Script "Write-Output 'observed'"
    $second=Invoke-ArcCommand -Purpose status -Script "Write-Output 'observed'"
    if($fixture.puts -ne 2 -or $fixture.records.Count -ne 6 -or
        $first.commandId -ceq $second.commandId -or $first.nonce -ceq $second.nonce -or
        $first.output -cne 'observed' -or $second.output -cne 'observed'){
        throw 'Independent command evidence was lost or a completed command was replayed'
    }
    $script:checks++
}
& {
    $guest=[System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\scripts\disk\Invoke-DiskGuest.ps1'),[ref]$null,[ref]$null)
    $function=$guest.Find({param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-PressureFile'
    },$true)
    . ([scriptblock]::Create($function.Extent.Text))
    $sandbox=Join-Path $PSScriptRoot ".disk-file-tests-$([guid]::NewGuid().ToString('N'))"
    $directory=Join-Path $sandbox 'control'
    $dataDirectory=Join-Path $sandbox 'data'
    $null=New-Item -ItemType Directory -Path $directory,$dataDirectory
    try {
        $a=[guid]::NewGuid()
        $b=[guid]::NewGuid()
        foreach($id in @($a,$b)){
            $stream=New-PressureFile $id
            $stream.Dispose()
            Remove-Item -LiteralPath "$dataDirectory\pressure-$id.bin"
        }
        Assert-Rejected {New-PressureFile $a}
        $RunId=[guid]::NewGuid()
        $collision="$dataDirectory\pressure-$RunId.bin"
        [IO.File]::WriteAllText($collision,'untouched-existing-file')
        $script:state=@{phase='healthy';runId=$b.ToString();watchdogAt=[DateTimeOffset]::UtcNow.ToString('o')}
        $before=$script:state|ConvertTo-Json -Compress
        $volume=@{Size=4GB;SizeRemaining=3GB}
        $Operation='SafetyTest'
        $DurationSeconds=60
        $taskName='mock-watchdog'
        $script:saved=$false
        $script:cleanupCalled=$false
        function Get-ScheduledTask {param($TaskName);@{State='Ready'}}
        function Save-GuestState {$script:saved=$true}
        function Remove-Pressure {param($Actor);$script:cleanupCalled=$true;throw 'Unowned cleanup attempted'}
        $body=$null
        foreach($statement in $guest.FindAll({param($node)$node -is [System.Management.Automation.Language.IfStatementAst]},$true)){
            foreach($clause in $statement.Clauses){
                if($clause.Item1.Extent.Text -ceq '$Operation -in @(''Fault'', ''SafetyTest'')'){
                    $body=$clause.Item2.Extent.Text
                }
            }
        }
        if(-not $body){throw 'Fault implementation branch not found'}
        $fault=[scriptblock]::Create($body.Substring(1,$body.Length-2))
        Assert-Rejected {& $fault}
        if($script:saved -or $script:cleanupCalled -or ($script:state|ConvertTo-Json -Compress) -cne $before -or
            [IO.File]::ReadAllText($collision) -cne 'untouched-existing-file'){
            throw 'A file collision changed the previous state or deleted/adopted the existing file'
        }
        $script:checks++
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
    }
}
& {
    $guestPath=Join-Path $PSScriptRoot '..\scripts\disk\Invoke-DiskGuest.ps1'
    $errors=$null
    $guest=[System.Management.Automation.Language.Parser]::ParseFile($guestPath,[ref]$null,[ref]$errors)
    if($errors){throw ($errors -join "`n")}
    foreach($name in @('Assert-TestDisk','Assert-PlainPath','Get-TestVolume','Remove-Pressure')){
        $function=$guest.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        },$true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $script:disk=[pscustomobject]@{IsBoot=$false;IsSystem=$false;Size=4GB;BusType='SCSI';UniqueId='owned-disk'}
    Assert-TestDisk $script:disk
    $script:checks++
    $script:disk.BusType='SAS'
    Assert-TestDisk $script:disk
    $script:checks++
    $script:disk.BusType='SCSI'
    foreach($item in @(@{key='IsBoot';value=$true},@{key='IsSystem';value=$true},
        @{key='Size';value=128GB},@{key='Size';value=2GB},@{key='BusType';value='USB'})){
        $old=$script:disk.($item.key)
        $script:disk.($item.key)=$item.value
        Assert-Rejected {Assert-TestDisk $script:disk}
        $script:disk.($item.key)=$old
    }
    $owner='22222222-2222-2222-2222-222222222222'
    $dataDirectory='R:\RetailTxDisk'
    $script:state=@{diskUniqueId='owned-disk';volumeUniqueId='owned-volume';partitionNumber=2
        runId='55555555-5555-5555-5555-555555555555';phase='pressure'}
    $script:volume=@{FileSystemLabel='RETAILTXTEST';FileSystemType='NTFS';UniqueId='owned-volume';Size=4GB;SizeRemaining=3GB}
    $script:partition=@{DiskNumber=2;PartitionNumber=2}
    $script:attributes=[IO.FileAttributes]::Normal
    $script:marker=$owner
    $script:pressurePresent=$true
    $script:removedPath=$null
    function Get-Disk {param($Number);$script:disk}
    function Get-Partition {param($DriveLetter);$script:partition}
    function Get-Volume {param($DriveLetter);$script:volume}
    function Get-Item {param($LiteralPath,[switch]$Force);@{Attributes=$script:attributes}}
    function Get-Content {param($LiteralPath,[switch]$Raw);$script:marker}
    function Test-Path {param($LiteralPath);$script:pressurePresent}
    function Remove-Item {param($LiteralPath,[switch]$Force);$script:removedPath=$LiteralPath;$script:pressurePresent=$false}
    function Save-GuestState {}
    $null=Get-TestVolume
    $script:checks++
    foreach($key in @('diskUniqueId','volumeUniqueId','partitionNumber')){
        $old=$script:state[$key]
        $script:state[$key]='foreign'
        Assert-Rejected {Get-TestVolume}
        $script:state[$key]=$old
    }
    $script:attributes=[IO.FileAttributes]::ReparsePoint
    Assert-Rejected {Get-TestVolume}
    Assert-Rejected {Remove-Pressure 'operator-script'}
    $script:attributes=[IO.FileAttributes]::Normal
    $script:marker='foreign'
    Assert-Rejected {Remove-Pressure 'operator-script'}
    if($script:removedPath){throw 'Recovery deleted through an unsafe volume'}
    $script:marker=$owner
    Remove-Pressure 'operator-script'
    if($script:removedPath -cne 'R:\RetailTxDisk\pressure-55555555-5555-5555-5555-555555555555.bin' -or
        $script:state.phase -cne 'healthy' -or $script:state.recoveryActor -cne 'operator-script'){
        throw 'Recovery did not remove only the current run-owned file'
    }
    $script:checks++
    $script:volume.SizeRemaining=256MB
    Assert-Rejected {Remove-Pressure 'operator-script'}
}
& {
    $directory=Join-Path $PSScriptRoot "disk-evidence-test-$([guid]::NewGuid())"
    $state=@{phase='armed';ownerToken=[guid]::NewGuid().ToString()}
    $statePath=Join-Path $directory 'disk-scenario-state.json'
    $null=New-Item -ItemType Directory -Path $directory
    $lock=$null
    try {
        $lock=[IO.File]::Open((Join-Path $directory 'disk-scenario.lock'),'CreateNew','ReadWrite','None')
        '{"phase":"deleted"}' | Set-Content -LiteralPath $statePath
        $evidence=Join-Path $directory 'sre-configuration-state.json'
        '{"phase":"removed"}' | Set-Content -LiteralPath $evidence
        Archive-DeletedDiskEvidence
        if (-not (Test-Path -LiteralPath $evidence)) {throw 'Live evidence was archived'}
        $state.phase='deleted'
        function Move-Item {param($LiteralPath,$Destination,$ErrorAction);throw 'Interrupted archival'}
        Assert-Rejected {Archive-DeletedDiskEvidence}
        if (-not (Test-Path -LiteralPath $statePath)) {throw 'Interrupted archive lost its deleted-generation manifest'}
        Remove-Item Function:\Move-Item
        Archive-DeletedDiskEvidence
        $archived=Join-Path $directory "history\$($state.ownerToken)\sre-configuration-state.json"
        if ((Test-Path -LiteralPath $evidence) -or
            (Get-Content -LiteralPath $archived -Raw).Trim() -cne '{"phase":"removed"}' -or
            -not (Test-Path -LiteralPath (Join-Path $directory 'disk-scenario.lock'))) {
            throw 'Deleted fixture evidence or active lease was not preserved correctly'
        }
        if (-not (Test-Path -LiteralPath $statePath)) {throw 'Manifest removed before atomic generation replacement'}
        $script:checks+=4
    } finally {
        if ($lock) {$lock.Dispose()}
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}
& {
    $bootstrap=[System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot '..\scripts\disk\Initialize-ArcDiskHost.ps1'),[ref]$null,[ref]$errors)
    if ($errors) {throw ($errors -join "`n")}
    $helper=$bootstrap.Find({param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-VerifiedArcInstaller'
    },$true)
    . ([scriptblock]::Create($helper.Extent.Text))
    $downloads=[Collections.Generic.List[string]]::new()
    $statuses=[Collections.Generic.Queue[string]]::new()
    $subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'
    $downloadExit=0
    function curl.exe {
        if ('--retry-all-errors' -cnotin $args -or '--remove-on-error' -cnotin $args -or
            '--disable' -cnotin $args -or '--output' -cnotin $args -or '=https' -cnotin $args) {
            throw 'Download integrity or HTTPS constraints missing'
        }
        $downloads.Add(($args -join ' '))
        $global:LASTEXITCODE=$downloadExit
    }
    function Get-AuthenticodeSignature {param($LiteralPath);return @{Status=$statuses.Dequeue();SignerCertificate=@{Subject=$subject}}}
    function Get-FileHash {param($LiteralPath,$Algorithm);return @{Hash='offline-test-digest'}}
    $statuses.Enqueue('Valid')
    $null=Get-VerifiedArcInstaller 'offline.msi'
    if ($downloads.Count -ne 1 -or $statuses.Count) {throw 'Downloaded MSI was not verified'}
    $script:checks++
    $downloadExit=18
    Assert-Rejected {Get-VerifiedArcInstaller 'offline.msi'}
    $downloadExit=0
    foreach($status in @('NotSigned','UnknownError','HashMismatch')) {
        $statuses.Enqueue($status)
        Assert-Rejected {Get-VerifiedArcInstaller 'offline.msi'}
    }
    $subject='CN=Untrusted, O=Another Company, C=US'
    $statuses.Enqueue('Valid')
    Assert-Rejected {Get-VerifiedArcInstaller 'offline.msi'}
}
Write-Output "$script:checks disk scenario checks passed."
