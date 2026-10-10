#Requires -Version 7.2
Set-StrictMode -Version Latest

$script:graphRoot = 'https://graph.microsoft.com/v1.0'
$script:roleValue = 'ServiceBus.QueueRestore'

function Get-ServiceBusGraphResult {
    param(
        [Parameter(Mandatory)][scriptblock]$InvokeGraph,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][hashtable]$Body
    )
    if (-not $Path.StartsWith('/', [StringComparison]::Ordinal) -or $Path.Contains('..')) {
        throw 'Invalid Microsoft Graph path.'
    }
    return & $InvokeGraph $Method $Path $Body
}

function Save-ServiceBusIdentityState {
    param([Parameter(Mandatory)][scriptblock]$SaveState)
    & $SaveState
}

function Test-ServiceBusGraphCollection {
    param([Parameter(Mandatory)][hashtable]$Collection)
    return $Collection.ContainsKey('value') -and
        (-not $Collection.ContainsKey('nextLink') -or -not $Collection.nextLink) -and
        (-not $Collection.ContainsKey('@odata.nextLink') -or -not $Collection['@odata.nextLink'])
}

function Assert-ServiceBusIdentityManifest {
    param(
        [Parameter(Mandatory)][hashtable]$ScenarioState,
        [Parameter(Mandatory)][hashtable]$Identity
    )
    $null = [guid]::Parse($ScenarioState.ownerToken)
    $null = [guid]::Parse($Identity.ownerToken)
    $null = [guid]::Parse($Identity.srePrincipalObjectId)
    $null = [guid]::Parse($Identity.appRoleId)
    if ($Identity.schemaVersion -ne 1 -or
        $Identity.ownerToken -cne $ScenarioState.ownerToken -or
        $Identity.displayName -cne "retailtx-broker-executor-$($ScenarioState.environmentName)" -or
        $Identity.srePrincipalObjectId -ine $ScenarioState.srePrincipalObjectId) {
        throw 'Executor Entra identity manifest does not match the exact scenario owner, name, and SRE principal.'
    }
    foreach ($property in @('applicationObjectId', 'applicationId', 'servicePrincipalObjectId')) {
        if ($Identity[$property]) { $null = [guid]::Parse($Identity[$property]) }
    }
    if ($Identity.identifierUri -and
        $Identity.identifierUri -cne "api://$($Identity.applicationId)") {
        throw 'Executor audience does not match the exact owned application ID.'
    }
}

function New-ServiceBusIdentitySnapshot {
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$OwnerToken,
        [Parameter(Mandatory)][string]$SrePrincipalObjectId
    )
    $null = [guid]::Parse($OwnerToken)
    $null = [guid]::Parse($SrePrincipalObjectId)
    return @{
        schemaVersion = 1
        ownerToken = $OwnerToken
        displayName = "retailtx-broker-executor-$EnvironmentName"
        srePrincipalObjectId = $SrePrincipalObjectId
        applicationObjectId = $null
        applicationId = $null
        servicePrincipalObjectId = $null
        appRoleId = [guid]::NewGuid().ToString()
        appRoleAssignmentId = $null
        identifierUri = $null
        phase = 'Prepared'
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Assert-ServiceBusOwnedApplication {
    param([Parameter(Mandatory)][hashtable]$Application, [Parameter(Mandatory)][hashtable]$State)
    $ownerTag = "retailtx-owner-$($State.ownerToken)"
    if ($Application.id -ine $State.applicationObjectId -or
        $Application.appId -ine $State.applicationId -or
        $Application.displayName -cne $State.displayName -or
        $Application.signInAudience -cne 'AzureADMyOrg' -or
        $ownerTag -cnotin @($Application.tags) -or
        $Application.description -cnotmatch [regex]::Escape("ownerToken=$($State.ownerToken)")) {
        throw 'Executor app registration does not match the exact owner-token manifest.'
    }
}

function Get-ServiceBusOwnedApplication {
    param(
        [Parameter(Mandatory)][scriptblock]$InvokeGraph,
        [Parameter(Mandatory)][hashtable]$State
    )
    $objectId = $State.applicationObjectId
    if (-not $objectId) { return $null }
    try {
        $application = Get-ServiceBusGraphResult $InvokeGraph GET `
            "/applications/$([uri]::EscapeDataString($objectId))?`$select=id,appId,displayName,description,tags,signInAudience,identifierUris,appRoles"
    } catch {
        if ($_.Exception.Message -match '(?i)\b(404|Request_ResourceNotFound|ResourceNotFound)\b') {
            return $null
        }
        throw
    }
    if (-not $application) { return $null }
    Assert-ServiceBusOwnedApplication $application $State
    return $application
}

function Set-ServiceBusEntraIdentity {
    param(
        [Parameter(Mandatory)][hashtable]$ScenarioState,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$SrePrincipalObjectId,
        [Parameter(Mandatory)][scriptblock]$InvokeGraph,
        [Parameter(Mandatory)][scriptblock]$SaveState
    )
    $null = [guid]::Parse($SrePrincipalObjectId)
    if (-not $ScenarioState.ContainsKey('executorIdentity') -or
        -not $ScenarioState.executorIdentity) {
        $filter = [uri]::EscapeDataString(
            "displayName eq 'retailtx-broker-executor-$EnvironmentName'"
        )
        $existing = Get-ServiceBusGraphResult $InvokeGraph GET `
            "/applications?`$filter=$filter&`$select=id,appId,displayName,description,tags"
        if (-not (Test-ServiceBusGraphCollection $existing) -or
            @($existing.value).Count) {
            throw 'An application already has the reserved executor display name; refusing adoption.'
        }
        $ScenarioState.executorIdentity = New-ServiceBusIdentitySnapshot `
            -EnvironmentName $EnvironmentName -OwnerToken $ScenarioState.ownerToken `
            -SrePrincipalObjectId $SrePrincipalObjectId
        $ScenarioState.executorIdentity.phase = 'ApplicationCreatePending'
        Save-ServiceBusIdentityState $SaveState
    }
    $identity = $ScenarioState.executorIdentity
    Assert-ServiceBusIdentityManifest $ScenarioState $identity
    $filter = [uri]::EscapeDataString("displayName eq '$($identity.displayName)'")
    $applications = Get-ServiceBusGraphResult $InvokeGraph GET `
        "/applications?`$filter=$filter&`$select=id,appId,displayName,description,tags,signInAudience,identifierUris,appRoles"
    if (-not (Test-ServiceBusGraphCollection $applications) -or
        @($applications.value).Count -gt 1) {
        throw 'Executor app registration lookup is incomplete or ambiguous.'
    }
    $application = if ($identity.applicationObjectId) {
        Get-ServiceBusOwnedApplication $InvokeGraph $identity
    } elseif (@($applications.value).Count -eq 1) {
        $candidate = $applications.value[0]
        $ownerTag = "retailtx-owner-$($identity.ownerToken)"
        if ($candidate.displayName -cne $identity.displayName -or
            $ownerTag -cnotin @($candidate.tags) -or
            $candidate.description -cnotmatch [regex]::Escape("ownerToken=$($identity.ownerToken)")) {
            throw 'A foreign app registration occupies the reserved executor name; refusing adoption.'
        }
        $identity.applicationObjectId = $candidate.id
        $identity.applicationId = $candidate.appId
        Save-ServiceBusIdentityState $SaveState
        Get-ServiceBusOwnedApplication $InvokeGraph $identity
    } else {
        $null
    }
    if ($identity.applicationObjectId -and -not $application) {
        throw 'The exact owned executor application ID is missing; refusing to recreate or rebind it.'
    }
    if (-not $application) {
        $role = @{
            allowedMemberTypes = @('Application')
            description = 'Allows the exact SRE managed identity to invoke the fixed Service Bus queue restore API.'
            displayName = $script:roleValue
            id = $identity.appRoleId
            isEnabled = $true
            value = $script:roleValue
        }
        $applicationBody = @{
            displayName = $identity.displayName
            description = "RetailTx fixed-action broker executor; ownerToken=$($identity.ownerToken)"
            tags = @('retailtx', 'profile=servicebus', "environmentId=$EnvironmentName", "retailtx-owner-$($identity.ownerToken)")
            signInAudience = 'AzureADMyOrg'
            appRoles = @($role)
        }
        $created = Get-ServiceBusGraphResult $InvokeGraph POST '/applications' $applicationBody
        if (-not $created.id -or -not $created.appId) {
            throw 'Microsoft Graph did not return the created executor application IDs.'
        }
        $identity.applicationObjectId = $created.id
        $identity.applicationId = $created.appId
        $identity.identifierUri = "api://$($created.appId)"
        $identity.phase = 'ApplicationCreated'
        Save-ServiceBusIdentityState $SaveState
        $application = Get-ServiceBusOwnedApplication $InvokeGraph $identity
    }
    if (-not $identity.identifierUri) { $identity.identifierUri = "api://$($identity.applicationId)" }
    if ($identity.appRoleId -notmatch '^[0-9a-fA-F-]{36}$' -or
        $identity.applicationId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'Executor application or app-role ID is invalid.'
    }
    $identifierUris = if ($application.ContainsKey('identifierUris')) {
        @($application.identifierUris)
    } else { @() }
    if ($identity.identifierUri -notin $identifierUris) {
        $identity.phase = 'ApplicationAudiencePending'
        Save-ServiceBusIdentityState $SaveState
        $applicationBody = @{
            identifierUris = @($identifierUris + $identity.identifierUri | Select-Object -Unique)
        }
        $null = Get-ServiceBusGraphResult $InvokeGraph PATCH `
            "/applications/$($identity.applicationObjectId)" $applicationBody
        $application = Get-ServiceBusOwnedApplication $InvokeGraph $identity
    }
    $roles = @($application.appRoles)
    $roleById = @($roles | Where-Object { $_.id -ceq $identity.appRoleId })
    if ($roleById.Count -gt 1) {
        throw 'Multiple app-role definitions use the owned ServiceBus.QueueRestore role ID.'
    }
    $sameRoleValue = @($roles | Where-Object { $_.value -ceq $script:roleValue })
    if (@($sameRoleValue | Where-Object id -CNE $identity.appRoleId).Count) {
        throw 'A conflicting application role uses the reserved ServiceBus.QueueRestore value.'
    }
    if ($roleById.Count -eq 1 -and
        ($roleById[0].value -cne $script:roleValue -or
         $roleById[0].isEnabled -ne $true -or
         @($roleById[0].allowedMemberTypes) -notcontains 'Application')) {
        throw 'The saved executor app-role ID has conflicting definition properties.'
    }
    if (-not $roleById.Count) {
        $identity.phase = 'ApplicationRolePending'
        Save-ServiceBusIdentityState $SaveState
        $role = @{
            allowedMemberTypes = @('Application')
            description = 'Allows the exact SRE managed identity to invoke the fixed Service Bus queue restore API.'
            displayName = $script:roleValue
            id = $identity.appRoleId
            isEnabled = $true
            value = $script:roleValue
        }
        $null = Get-ServiceBusGraphResult $InvokeGraph PATCH `
            "/applications/$($identity.applicationObjectId)" @{ appRoles = @($roles + $role) }
        $application = Get-ServiceBusOwnedApplication $InvokeGraph $identity
    }
    if ($identity.identifierUri -notin @($application.identifierUris)) {
        throw 'The executor-specific API audience was not verified after the Graph update.'
    }
    if (-not @($application.appRoles | Where-Object {
        $_.id -ceq $identity.appRoleId -and $_.value -ceq $script:roleValue -and $_.isEnabled -eq $true
    }).Count) {
        throw 'The exact ServiceBus.QueueRestore application role was not verified.'
    }

    $identity.phase = 'ServicePrincipalPending'
    Save-ServiceBusIdentityState $SaveState
    $servicePrincipals = Get-ServiceBusGraphResult $InvokeGraph GET `
        "/servicePrincipals?`$filter=appId eq '$($identity.applicationId)'&`$select=id,appId,displayName,servicePrincipalType"
    if (-not (Test-ServiceBusGraphCollection $servicePrincipals) -or
        @($servicePrincipals.value).Count -gt 1) {
        throw 'Executor service-principal lookup is incomplete or ambiguous.'
    }
    if (-not $identity.servicePrincipalObjectId) {
        if (@($servicePrincipals.value).Count -eq 1) {
            $identity.servicePrincipalObjectId = $servicePrincipals.value[0].id
            Save-ServiceBusIdentityState $SaveState
        } else {
            $servicePrincipal = Get-ServiceBusGraphResult $InvokeGraph POST '/servicePrincipals' @{
                appId = $identity.applicationId
            }
            if (-not $servicePrincipal.id -or $servicePrincipal.appId -ine $identity.applicationId) {
                throw 'Microsoft Graph did not create the executor service principal for the owned app.'
            }
            $identity.servicePrincipalObjectId = $servicePrincipal.id
            Save-ServiceBusIdentityState $SaveState
        }
    } elseif (@($servicePrincipals.value).Count -ne 1 -or
        $servicePrincipals.value[0].id -ine $identity.servicePrincipalObjectId) {
        throw 'The executor service principal differs from its exact saved object ID.'
    }

    $assignments = Get-ServiceBusGraphResult $InvokeGraph GET `
        "/servicePrincipals/$($identity.servicePrincipalObjectId)/appRoleAssignedTo?`$select=id,principalId,resourceId,appRoleId"
    if (-not (Test-ServiceBusGraphCollection $assignments)) {
        throw 'Executor app-role assignment lookup is incomplete.'
    }
    $matchingAssignments = @($assignments.value | Where-Object {
        $_.principalId -ieq $SrePrincipalObjectId
    })
    $exactAssignments = @($matchingAssignments | Where-Object {
        $_.resourceId -ieq $identity.servicePrincipalObjectId -and
        $_.appRoleId -ieq $identity.appRoleId
    })
    if (@($matchingAssignments | Where-Object { $_.appRoleId -ine $identity.appRoleId }).Count) {
        throw 'The SRE principal has a conflicting role assignment on the owned executor application.'
    }
    if ($exactAssignments.Count -gt 1) {
        throw 'Duplicate ServiceBus.QueueRestore grants exist for the SRE principal.'
    }
    if (-not $exactAssignments.Count) {
        $identity.phase = 'RoleAssignmentPending'
        Save-ServiceBusIdentityState $SaveState
        $assignment = Get-ServiceBusGraphResult $InvokeGraph POST `
            "/servicePrincipals/$($identity.servicePrincipalObjectId)/appRoleAssignedTo" @{
                principalId = $SrePrincipalObjectId
                resourceId = $identity.servicePrincipalObjectId
                appRoleId = $identity.appRoleId
            }
        if (-not $assignment.id -or
            $assignment.principalId -ine $SrePrincipalObjectId -or
            $assignment.resourceId -ine $identity.servicePrincipalObjectId -or
            $assignment.appRoleId -ine $identity.appRoleId) {
            throw 'Microsoft Graph did not confirm the exact SRE app-role assignment.'
        }
        $identity.appRoleAssignmentId = $assignment.id
        Save-ServiceBusIdentityState $SaveState
        $exactAssignments = @($assignment)
    }
    $identity.appRoleAssignmentId = $exactAssignments[0].id
    $identity.phase = 'Ready'
    $identity.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $ScenarioState.executorAudience = $identity.identifierUri
    $ScenarioState.srePrincipalObjectId = $identity.srePrincipalObjectId
    Save-ServiceBusIdentityState $SaveState
    return $identity
}

function Get-ServiceBusEntraIdentityStatus {
    param(
        [Parameter(Mandatory)][hashtable]$ScenarioState,
        [Parameter(Mandatory)][scriptblock]$InvokeGraph
    )
    $identity = if ($ScenarioState.ContainsKey('executorIdentity')) {
        $ScenarioState.executorIdentity
    } else { $null }
    if (-not $identity) {
        return @{ ready = $false; status = 'NotOwned' }
    }
    Assert-ServiceBusIdentityManifest $ScenarioState $identity
    $application = Get-ServiceBusOwnedApplication $InvokeGraph $identity
    if (-not $application) { return @{ ready = $false; status = 'ApplicationMissing' } }
    $audienceReady = $application.ContainsKey('identifierUris') -and
        $identity.identifierUri -in @($application.identifierUris)
    $roleReady = @($application.appRoles | Where-Object {
        $_.id -ceq $identity.appRoleId -and
        $_.value -ceq $script:roleValue -and
        $_.isEnabled -eq $true -and
        @($_.allowedMemberTypes) -contains 'Application'
    }).Count -eq 1
    if (-not $audienceReady -or -not $roleReady) {
        return @{ ready = $false; status = 'ApplicationAudienceOrRoleMissing' }
    }
    $assignmentPath = if ($identity.servicePrincipalObjectId) {
        "/servicePrincipals/$($identity.servicePrincipalObjectId)/appRoleAssignedTo?`$select=id,principalId,resourceId,appRoleId"
    } else { $null }
    if (-not $assignmentPath) { return @{ ready = $false; status = 'ServicePrincipalMissing' } }
    $assignments = Get-ServiceBusGraphResult $InvokeGraph GET $assignmentPath
    if (-not (Test-ServiceBusGraphCollection $assignments)) {
        throw 'Executor role-assignment lookup is incomplete; refusing readiness.'
    }
    $ready = @($assignments.value | Where-Object {
        $_.principalId -ieq $identity.srePrincipalObjectId -and
        $_.resourceId -ieq $identity.servicePrincipalObjectId -and
        $_.appRoleId -ieq $identity.appRoleId
    }).Count -eq 1
    return @{
        ready = $ready
        status = if ($ready) { 'RoleAssignmentPresentTokenRefreshUnverified' } else { 'RoleAssignmentMissing' }
        audience = $identity.identifierUri
        executorApplicationId = $identity.applicationId
        srePrincipalObjectId = $identity.srePrincipalObjectId
        appRoleId = $identity.appRoleId
        appRoleAssignmentId = $identity.appRoleAssignmentId
    }
}

function Remove-ServiceBusEntraIdentity {
    param(
        [Parameter(Mandatory)][hashtable]$ScenarioState,
        [Parameter(Mandatory)][scriptblock]$InvokeGraph,
        [Parameter(Mandatory)][scriptblock]$SaveState
    )
    $identity = if ($ScenarioState.ContainsKey('executorIdentity')) {
        $ScenarioState.executorIdentity
    } else { $null }
    if (-not $identity) { return }
    Assert-ServiceBusIdentityManifest $ScenarioState $identity
    if ($identity.phase -ceq 'Removed') {
        foreach ($collection in @('applications', 'servicePrincipals')) {
            $remaining = Get-ServiceBusGraphResult $InvokeGraph GET `
                "/$collection`?`$filter=appId eq '$($identity.applicationId)'&`$select=id,appId"
            if (-not (Test-ServiceBusGraphCollection $remaining) -or
                @($remaining.value).Count) {
                throw 'Previously removed executor identity is present or its absence cannot be verified.'
            }
        }
        return
    }
    if (-not $identity.applicationObjectId) {
        $filter = [uri]::EscapeDataString("displayName eq '$($identity.displayName)'")
        $applications = Get-ServiceBusGraphResult $InvokeGraph GET `
            "/applications?`$filter=$filter&`$select=id,appId,displayName,description,tags,signInAudience"
        if (-not (Test-ServiceBusGraphCollection $applications) -or
            @($applications.value).Count -gt 1) {
            throw 'Cannot safely reconcile an unrecorded executor application during teardown.'
        }
        if (@($applications.value).Count -eq 1) {
            $candidate = $applications.value[0]
            if ($candidate.displayName -cne $identity.displayName -or
                "retailtx-owner-$($identity.ownerToken)" -cnotin @($candidate.tags) -or
                $candidate.description -cnotmatch [regex]::Escape("ownerToken=$($identity.ownerToken)")) {
                throw 'A foreign app registration occupies the reserved executor name; refusing teardown adoption.'
            }
            $identity.applicationObjectId = $candidate.id
            $identity.applicationId = $candidate.appId
            Save-ServiceBusIdentityState $SaveState
        }
    }
    $application = Get-ServiceBusOwnedApplication $InvokeGraph $identity
    if (-not $identity.servicePrincipalObjectId -and $identity.applicationId) {
        $servicePrincipals = Get-ServiceBusGraphResult $InvokeGraph GET `
            "/servicePrincipals?`$filter=appId eq '$($identity.applicationId)'&`$select=id,appId"
        if (-not (Test-ServiceBusGraphCollection $servicePrincipals) -or
            @($servicePrincipals.value).Count -gt 1) {
            throw 'Cannot safely reconcile an unrecorded executor service principal during teardown.'
        }
        if (@($servicePrincipals.value).Count -eq 1) {
            $identity.servicePrincipalObjectId = $servicePrincipals.value[0].id
            Save-ServiceBusIdentityState $SaveState
        }
    }
    if ($identity.servicePrincipalObjectId) {
        $servicePrincipals = Get-ServiceBusGraphResult $InvokeGraph GET `
            "/servicePrincipals?`$filter=appId eq '$($identity.applicationId)'&`$select=id,appId"
        if (-not (Test-ServiceBusGraphCollection $servicePrincipals) -or
            @($servicePrincipals.value).Count -gt 1) {
            throw 'Cannot safely verify the executor service principal before teardown.'
        }
        if (@($servicePrincipals.value).Count -eq 1 -and
            ($servicePrincipals.value[0].id -ine $identity.servicePrincipalObjectId -or
             $servicePrincipals.value[0].appId -ine $identity.applicationId)) {
            throw 'Executor service principal differs from the exact saved application binding.'
        }
        if (@($servicePrincipals.value).Count -eq 1) {
        $assignments = Get-ServiceBusGraphResult $InvokeGraph GET `
            "/servicePrincipals/$($identity.servicePrincipalObjectId)/appRoleAssignedTo?`$select=id,principalId,resourceId,appRoleId"
        if (-not (Test-ServiceBusGraphCollection $assignments)) {
            throw 'Cannot safely remove executor app while app-role assignment discovery is incomplete.'
        }
        $ownedAssignments = @($assignments.value | Where-Object {
            $_.principalId -ieq $identity.srePrincipalObjectId -and
            $_.resourceId -ieq $identity.servicePrincipalObjectId -and
            $_.appRoleId -ieq $identity.appRoleId -and
            (-not $identity.appRoleAssignmentId -or $_.id -ceq $identity.appRoleAssignmentId)
        })
        $foreignAssignments = @($assignments.value | Where-Object {
            $_.principalId -ine $identity.srePrincipalObjectId -or
            $_.resourceId -ine $identity.servicePrincipalObjectId -or
            $_.appRoleId -ine $identity.appRoleId -or
            ($identity.appRoleAssignmentId -and $_.id -cne $identity.appRoleAssignmentId)
        })
        if ($foreignAssignments.Count) {
            throw 'Other principals use the owned executor app; refusing app or service-principal deletion.'
        }
        if ($ownedAssignments.Count -gt 1) {
            throw 'Duplicate exact executor app-role assignments exist; refusing ambiguous teardown.'
        }
        foreach ($assignment in $ownedAssignments) {
            $identity.phase = 'RoleAssignmentRemovalPending'
            Save-ServiceBusIdentityState $SaveState
            $null = Get-ServiceBusGraphResult $InvokeGraph DELETE `
                "/servicePrincipals/$($identity.servicePrincipalObjectId)/appRoleAssignedTo/$([uri]::EscapeDataString($assignment.id))"
        }
        $remaining = Get-ServiceBusGraphResult $InvokeGraph GET `
            "/servicePrincipals/$($identity.servicePrincipalObjectId)/appRoleAssignedTo?`$select=id,principalId,resourceId,appRoleId"
        if (-not (Test-ServiceBusGraphCollection $remaining) -or
            @($remaining.value).Count) {
            throw 'Executor role assignments remain; refusing service-principal deletion.'
        }
        $identity.phase = 'ServicePrincipalRemovalPending'
        Save-ServiceBusIdentityState $SaveState
        $null = Get-ServiceBusGraphResult $InvokeGraph DELETE `
            "/servicePrincipals/$($identity.servicePrincipalObjectId)"
        }
    }
    if ($application) {
        $identity.phase = 'ApplicationRemovalPending'
        Save-ServiceBusIdentityState $SaveState
        $null = Get-ServiceBusGraphResult $InvokeGraph DELETE `
            "/applications/$($identity.applicationObjectId)"
    }
    $identity.phase = 'Removed'
    $identity.removedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Save-ServiceBusIdentityState $SaveState
}

Export-ModuleMember -Function Set-ServiceBusEntraIdentity, Get-ServiceBusEntraIdentityStatus,
    Remove-ServiceBusEntraIdentity, New-ServiceBusIdentitySnapshot
