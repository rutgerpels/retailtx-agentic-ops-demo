#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:checks = 0
$script:mockGraph = $null
$script:failAfterApplicationCreate = $false
$script:scenarioUnderTest = $null
$script:savedIdentityState = $null
$script:assignmentNextLink = $null

Import-Module (Join-Path $PSScriptRoot '..\scripts\servicebus\EntraExecutorIdentity.psm1') -Force

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    $script:checks++
    if (-not $Condition) { throw $Message }
}

function Copy-MockGraphValue {
    param([Parameter()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.ICollection] -and $Value.Count -eq 0) { return ,@() }
    return ConvertFrom-Json -AsHashtable -InputObject ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Invoke-MockGraph {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][hashtable]$Body
    )
    $script:mockGraph.calls.Add(@{ method = $Method; path = $Path; body = $Body })
    if ($Path -match '^/applications\?') {
        return @{
            value = @($script:mockGraph.applications | ForEach-Object { Copy-MockGraphValue $_ })
        }
    }
    if ($Method -eq 'POST' -and $Path -ceq '/applications') {
        if (-not $script:savedIdentityState.executorIdentity -or
            $script:savedIdentityState.executorIdentity.phase -cne 'ApplicationCreatePending') {
            throw 'The ownership manifest was not persisted before app creation.'
        }
        $application = Copy-MockGraphValue $Body
        $application.id = [guid]::NewGuid().ToString()
        $application.appId = [guid]::NewGuid().ToString()
        $script:mockGraph.applications.Add($application)
        if ($script:failAfterApplicationCreate) {
            $script:failAfterApplicationCreate = $false
            throw 'Simulated response loss after Graph committed the app registration.'
        }
        return Copy-MockGraphValue $application
    }
    if ($Path -match '^/applications/([^?]+)') {
        $applicationId = $Matches[1]
        $application = @($script:mockGraph.applications | Where-Object id -CEQ $applicationId) |
            Select-Object -First 1
        if ($Method -eq 'GET') {
            if (-not $application) { throw '404 Request_ResourceNotFound' }
            return Copy-MockGraphValue $application
        }
        if ($Method -eq 'PATCH') {
            if (-not $application) { throw '404 Request_ResourceNotFound' }
            foreach ($key in $Body.Keys) { $application[$key] = Copy-MockGraphValue $Body[$key] }
            return $null
        }
        if ($Method -eq 'DELETE') {
            $script:mockGraph.applications = @($script:mockGraph.applications |
                Where-Object id -CNE $applicationId)
            return $null
        }
    }
    if ($Path -match '^/servicePrincipals\?') {
        $applicationId = [regex]::Match($Path, "appId eq '([^']+)'").Groups[1].Value
        return @{
            value = @($script:mockGraph.servicePrincipals |
                Where-Object appId -CEQ $applicationId |
                ForEach-Object { Copy-MockGraphValue $_ })
        }
    }
    if ($Method -eq 'POST' -and $Path -ceq '/servicePrincipals') {
        if ($script:savedIdentityState.executorIdentity.phase -cne 'ServicePrincipalPending') {
            throw 'The executor app registration was not persisted before service-principal creation.'
        }
        $servicePrincipal = @{
            id = [guid]::NewGuid().ToString()
            appId = $Body.appId
            displayName = ($script:mockGraph.applications |
                Where-Object appId -CEQ $Body.appId | Select-Object -First 1).displayName
        }
        $script:mockGraph.servicePrincipals.Add($servicePrincipal)
        return Copy-MockGraphValue $servicePrincipal
    }
    if ($Path -match '^/servicePrincipals/([^/]+)/appRoleAssignedTo') {
        $resourceId = $Matches[1]
        if ($Method -eq 'GET') {
            if ($Path.Contains('$filter=')) { throw 'The live Graph endpoint rejects principalId filtering.' }
            return @{
                value = @($script:mockGraph.assignments | Where-Object {
                    $_.resourceId -CEQ $resourceId
                } | ForEach-Object { Copy-MockGraphValue $_ })
                '@odata.nextLink' = $script:assignmentNextLink
            }
        }
        if ($Method -eq 'POST' -and $Path -notmatch '\?') {
            if ($script:savedIdentityState.executorIdentity.phase -cne 'RoleAssignmentPending') {
                throw 'The exact executor grant was not persisted as pending before role assignment.'
            }
            $assignment = @{
                id = [guid]::NewGuid().ToString()
                principalId = $Body.principalId
                resourceId = $Body.resourceId
                appRoleId = $Body.appRoleId
            }
            $script:mockGraph.assignments.Add($assignment)
            return Copy-MockGraphValue $assignment
        }
        if ($Method -eq 'DELETE' -and $Path -match '/appRoleAssignedTo/([^/?]+)$') {
            $assignmentId = $Matches[1]
            $script:mockGraph.assignments = @($script:mockGraph.assignments |
                Where-Object id -CNE $assignmentId)
            return $null
        }
    }
    if ($Path -match '^/servicePrincipals/([^/?]+)$' -and $Method -eq 'DELETE') {
        $servicePrincipalId = $Matches[1]
        $script:mockGraph.servicePrincipals = @($script:mockGraph.servicePrincipals |
            Where-Object id -CNE $servicePrincipalId)
        return $null
    }
    throw "Unexpected mock Graph request: $Method $Path"
}

function Reset-MockGraph {
    $script:mockGraph = @{
        applications = [Collections.Generic.List[object]]::new()
        servicePrincipals = [Collections.Generic.List[object]]::new()
        assignments = [Collections.Generic.List[object]]::new()
        calls = [Collections.Generic.List[object]]::new()
    }
}

$environmentName = 'demo01'
$ownerToken = [guid]::NewGuid().ToString()
$srePrincipalObjectId = [guid]::NewGuid().ToString()
$state = @{
    ownerToken = $ownerToken
    environmentName = $environmentName
    srePrincipalObjectId = $srePrincipalObjectId
}
$script:scenarioUnderTest = $state
$graph = { param($Method, $Path, $Body) Invoke-MockGraph $Method $Path $Body }
$save = {
    $script:saveCount++
    $script:savedIdentityState = ConvertFrom-Json -AsHashtable -InputObject (
        $script:scenarioUnderTest | ConvertTo-Json -Depth 20 -Compress
    )
}
$script:saveCount = 0

Reset-MockGraph
$script:failAfterApplicationCreate = $true
$lostCreateResponse = $false
try {
    $null = Set-ServiceBusEntraIdentity `
        -ScenarioState $state `
        -EnvironmentName $environmentName `
        -SrePrincipalObjectId $srePrincipalObjectId `
        -InvokeGraph $graph `
        -SaveState $save
} catch {
    $lostCreateResponse = $_.Exception.Message -match 'Simulated response loss'
}
Assert-True $lostCreateResponse 'The mock did not simulate a lost create response.'
Assert-True (-not $state.executorIdentity.applicationObjectId) 'The create-response-loss fixture should retain no assumed app ID.'
Assert-True ($script:mockGraph.applications.Count -eq 1) 'The committed app registration should exist after response loss.'
$identity = Set-ServiceBusEntraIdentity `
    -ScenarioState $state `
    -EnvironmentName $environmentName `
    -SrePrincipalObjectId $srePrincipalObjectId `
    -InvokeGraph $graph `
    -SaveState $save
Assert-True ($identity.phase -ceq 'Ready') 'The owned identity lifecycle did not reach Ready.'
Assert-True ($state.executorAudience -ceq "api://$($identity.applicationId)") 'The custom API audience was not saved.'
Assert-True ($script:mockGraph.applications.Count -eq 1) 'Expected exactly one owned executor app registration.'
Assert-True ($script:mockGraph.servicePrincipals.Count -eq 1) 'Expected exactly one executor service principal.'
Assert-True ($script:mockGraph.assignments.Count -eq 1) 'Expected exactly one SRE app-role assignment.'
Assert-True ($script:mockGraph.assignments[0].principalId -ceq $srePrincipalObjectId) 'The app role was not assigned to the exact SRE principal.'
Assert-True ($script:mockGraph.calls.Where({ $_.method -eq 'POST' -and $_.path -ceq '/applications' }).Count -eq 1) 'The app registration create call was not bounded after retry.'
Assert-True ($script:mockGraph.calls.Where({ $_.method -eq 'POST' -and $_.path -ceq '/servicePrincipals' }).Count -eq 1) 'The service-principal create call was not bounded.'

$callsBeforeRepeat = $script:mockGraph.calls.Count
$null = Set-ServiceBusEntraIdentity `
    -ScenarioState $state `
    -EnvironmentName $environmentName `
    -SrePrincipalObjectId $srePrincipalObjectId `
    -InvokeGraph $graph `
    -SaveState $save
Assert-True (
    $script:mockGraph.calls.Where({ $_.method -eq 'POST' }).Count -eq 3
) 'Idempotent Ensure unexpectedly repeated a Graph create or assignment.'
$identityStatus = Get-ServiceBusEntraIdentityStatus -ScenarioState $state -InvokeGraph $graph
Assert-True ($identityStatus.ready -and
    $identityStatus.status -ceq 'RoleAssignmentPresentTokenRefreshUnverified') `
    'Identity Doctor did not report assignment present with token propagation unverified.'

$script:assignmentNextLink = 'https://graph.microsoft.com/v1.0/next-page'
$rejectedIncomplete = $false
try {
    $null = Get-ServiceBusEntraIdentityStatus -ScenarioState $state -InvokeGraph $graph
} catch {
    $rejectedIncomplete = $_.Exception.Message -match 'lookup is incomplete'
}
Assert-True $rejectedIncomplete 'Readiness accepted a partial Graph role-assignment collection.'
$script:assignmentNextLink = $null

Remove-ServiceBusEntraIdentity -ScenarioState $state -InvokeGraph $graph -SaveState $save
Assert-True ($state.executorIdentity.phase -ceq 'Removed') 'Teardown did not persist the Removed phase.'
Assert-True ($script:mockGraph.assignments.Count -eq 0) 'Teardown did not remove the exact SRE role grant.'
Assert-True ($script:mockGraph.servicePrincipals.Count -eq 0) 'Teardown did not remove the owned service principal.'
Assert-True ($script:mockGraph.applications.Count -eq 0) 'Teardown did not remove the owned app registration.'
Assert-True (
    $script:mockGraph.calls.Where({
        $_.method -eq 'DELETE' -and $_.path -match '/appRoleAssignedTo/[^/?]+$'
    }).Count -eq 1
) 'Teardown must delete the exact appRoleAssignedTo relationship without an unrelated $ref route.'

Remove-ServiceBusEntraIdentity -ScenarioState $state -InvokeGraph $graph -SaveState $save
Assert-True ($state.executorIdentity.phase -ceq 'Removed') 'Repeated teardown was not idempotent.'
$unexpectedIdentity = {
    param($Method, $Path, $Body)
    return @{ value = @(@{ id = 'unexpected'; appId = $state.executorIdentity.applicationId }) }
}
$rejectedRemovedDrift = $false
try {
    Remove-ServiceBusEntraIdentity -ScenarioState $state -InvokeGraph $unexpectedIdentity -SaveState $save
} catch {
    $rejectedRemovedDrift = $_.Exception.Message -match 'absence cannot be verified'
}
Assert-True $rejectedRemovedDrift 'Repeated teardown trusted the Removed marker without verifying live absence.'

Reset-MockGraph
$foreign = @{
    id = [guid]::NewGuid().ToString()
    appId = [guid]::NewGuid().ToString()
    displayName = 'retailtx-broker-executor-demo01'
    description = 'not owned by this scenario'
    tags = @('retailtx')
    signInAudience = 'AzureADMyOrg'
    identifierUris = @()
    appRoles = @()
}
$script:mockGraph.applications.Add($foreign)
$foreignState = @{
    ownerToken = [guid]::NewGuid().ToString()
    environmentName = $environmentName
    srePrincipalObjectId = $srePrincipalObjectId
}
$rejectedForeign = $false
try {
    $null = Set-ServiceBusEntraIdentity `
        -ScenarioState $foreignState `
        -EnvironmentName $environmentName `
        -SrePrincipalObjectId $srePrincipalObjectId `
        -InvokeGraph $graph `
        -SaveState $save
} catch {
    $rejectedForeign = $_.Exception.Message -match 'reserved executor display name'
}
Assert-True $rejectedForeign 'Ensure adopted a foreign application with the reserved display name.'
Assert-True (-not $foreignState.ContainsKey('executorIdentity')) 'Foreign-name rejection wrote an adoption manifest.'
Assert-True (
    $script:mockGraph.calls.Where({ $_.method -in @('POST', 'PATCH', 'DELETE') }).Count -eq 0
) 'Foreign-name rejection performed a Graph write.'

Reset-MockGraph
$scenarioState = @{
    ownerToken = $ownerToken
    environmentName = $environmentName
    srePrincipalObjectId = $srePrincipalObjectId
}
$script:scenarioUnderTest = $scenarioState
$owned = Set-ServiceBusEntraIdentity `
    -ScenarioState $scenarioState `
    -EnvironmentName $environmentName `
    -SrePrincipalObjectId $srePrincipalObjectId `
    -InvokeGraph $graph `
    -SaveState $save
$script:mockGraph.assignments.Add(@{
    id = [guid]::NewGuid().ToString()
    principalId = [guid]::NewGuid().ToString()
    resourceId = $owned.servicePrincipalObjectId
    appRoleId = $owned.appRoleId
})
$assignmentCount = $script:mockGraph.assignments.Count
$rejectedForeignGrant = $false
try {
    Remove-ServiceBusEntraIdentity -ScenarioState $scenarioState -InvokeGraph $graph -SaveState $save
} catch {
    $rejectedForeignGrant = $_.Exception.Message -match 'Other principals use the owned executor app'
}
Assert-True $rejectedForeignGrant 'Teardown removed an executor application assigned to another principal.'
Assert-True ($script:mockGraph.assignments.Count -eq $assignmentCount) 'Teardown changed grants after detecting foreign use.'

Write-Output "Service Bus Entra identity lifecycle tests passed ($script:checks assertions)."
