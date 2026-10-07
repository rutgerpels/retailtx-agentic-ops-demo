#Requires -Version 7.2
Set-StrictMode -Version Latest

function Assert-RetailEnvironmentName {
    <#
    .SYNOPSIS
    Reject unsafe environment identifiers before resolving local or Azure paths.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -cnotmatch '^[a-z][a-z0-9]{2,11}$') {
        throw 'EnvironmentName must be 3-12 lowercase letters and digits, starting with a letter.'
    }
}

function Assert-RetailManifest {
    <#
    .SYNOPSIS
    Bind the saved deployment to the explicit subscription, tenant, and environment.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$EnvironmentName
    )
    if ($State.schemaVersion -ne 2 -or $State.profile -cne 'azure-lite' -or
        $State.subscriptionId -ine $SubscriptionId -or $State.tenantId -ine $TenantId -or
        $State.environmentName -cne $EnvironmentName -or $State.location -cne 'swedencentral') {
        throw 'The manifest does not match this Azure application environment.'
    }
    $null = [guid]::Parse($State.ownerToken)
    foreach ($role in @('cloud', 'dc', 'ops')) {
        if ($State.groups[$role] -cne "rg-retailtx-$role-$EnvironmentName-swedencentral") {
            throw 'Manifest resource group identity is invalid.'
        }
    }
}

function Assert-RetailOwnedGroup {
    <#
    .SYNOPSIS
    Refuse adoption or mutation of a group outside the exact owned manifest.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][object]$Group
    )
    if ($Role -notin @('cloud', 'dc', 'ops')) { throw 'Unknown resource group role.' }
    $expectedId = "/subscriptions/$($State.subscriptionId)/resourceGroups/$($State.groups[$Role])"
    if ($Group.id -ine $expectedId -or $Group.location -ine $State.location -or
        $Group.tags.demo -cne 'retailtx' -or $Group.tags.environmentId -cne $State.environmentName -or
        $Group.tags.ownerToken -cne $State.ownerToken -or $Group.tags.managedBy -cne 'retailtx' -or
        $Group.tags.profile -cne 'azure-lite') {
        throw 'Owned resource group verification failed. No adoption or mutation is permitted.'
    }
}

function Save-RetailState {
    <#
    .SYNOPSIS
    Atomically persist only non-secret deployment state.
    #>
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path)
    $State | ConvertTo-Json -Depth 40 |
        Set-Content -LiteralPath "$Path.tmp" -Encoding utf8NoBOM
    Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
}

function ConvertTo-RetailGuestPayload {
    <#
    .SYNOPSIS
    Encode non-secret JSON for a shell-independent, bounded guest command.
    #>
    param([Parameter(Mandatory)][hashtable]$Value)
    $json = $Value | ConvertTo-Json -Depth 30 -Compress
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

function ConvertFrom-RetailDeploymentOutputs {
    <#
    .SYNOPSIS
    Normalize CLI output-key casing without changing nested application values.
    #>
    param([Parameter(Mandatory)][hashtable]$Outputs)
    $values = @{}
    foreach ($key in $Outputs.Keys) { $values[$key.ToUpperInvariant()] = $Outputs[$key].value }
    return $values
}

function Test-RetailApplicationInstall {
    <#
    .SYNOPSIS
    Require installation and cleanup whenever a previous setup is incomplete.
    .DESCRIPTION
    An unchanged release can skip setup only when cleanup previously succeeded
    and all three owned resource groups still exist.
    .PARAMETER State
    Validated application ownership manifest.
    .PARAMETER ReleaseSha
    Digest of the requested source release.
    .PARAMETER OwnedGroupCount
    Number of resource groups that passed ownership validation.
    .EXAMPLE
    Test-RetailApplicationInstall -State $state -ReleaseSha $digest -OwnedGroupCount 3
    .OUTPUTS
    Boolean indicating whether installation and setup cleanup are required.
    .NOTES
    Cleanup state takes precedence over release equality during rollback.
    #>
    param([hashtable]$State, [string]$ReleaseSha, [int]$OwnedGroupCount)
    return (-not $State.ContainsKey('setupAccessRemoved') -or
        -not $State.setupAccessRemoved -or $State.releaseSha -cne $ReleaseSha -or
        $OwnedGroupCount -ne 3)
}

Export-ModuleMember -Function Assert-RetailEnvironmentName, Assert-RetailManifest,
    Assert-RetailOwnedGroup, Save-RetailState, ConvertTo-RetailGuestPayload,
    ConvertFrom-RetailDeploymentOutputs, Test-RetailApplicationInstall
