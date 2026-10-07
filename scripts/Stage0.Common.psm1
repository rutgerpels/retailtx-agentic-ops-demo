#Requires -Version 7.2
Set-StrictMode -Version Latest

function Assert-Stage0Name {
    <#
    .SYNOPSIS
    Validate a generic environment identifier before using it in paths or Azure names.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -cnotmatch '^[a-z][a-z0-9-]{2,15}$' -or $Name.EndsWith('-')) {
        throw 'EnvironmentName must be 3-16 lowercase letters, digits or hyphens, starting with a letter and not ending with a hyphen.'
    }
}

function Assert-Stage0Ownership {
    <#
    .SYNOPSIS
    Reject adoption or deletion unless the live group matches the recorded identity.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][object]$ResourceGroup
    )
    $expectedId = "/subscriptions/$($State.subscriptionId)/resourceGroups/$($State.resourceGroupName)"
    if ($ResourceGroup.id -ine $expectedId -or
        $ResourceGroup.location -ine $State.location -or
        $ResourceGroup.tags.demo -cne 'retailtx' -or
        $ResourceGroup.tags.environmentId -cne $State.environmentName -or
        $ResourceGroup.tags.ownerToken -cne $State.ownerToken -or
        $ResourceGroup.tags.managedBy -cne 'retailtx-stage0') {
        throw 'Ownership check failed. Refusing to modify a resource group not owned by this environment manifest.'
    }
}

function ConvertFrom-Stage0Environment {
    <#
    .SYNOPSIS
    Parse azd output values as data, without evaluating shell expressions.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    $values = @{}
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^([A-Z][A-Z0-9_]*)="([^"\r\n]*)"$') {
            throw 'Unsupported azd environment line. Values must be single-line quoted strings.'
        }
        $values[$Matches[1]] = $Matches[2]
    }
    return $values
}

function Save-Stage0State {
    <#
    .SYNOPSIS
    Persist non-secret environment state atomically.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Path
    )
    $temporaryPath = "$Path.tmp"
    $State | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $temporaryPath -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Assert-Stage0Evidence {
    <#
    .SYNOPSIS
    Reject incomplete or mismatched fixed host verification output.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Evidence,
        [Parameter(Mandatory)][string]$MachineId
    )
    if ($Evidence.worker -cne 'active' -or $Evidence.azureImds -cne 'blocked' -or
        $Evidence.arcIdentity -cne 'authenticated' -or $Evidence.privateWorkspaceQuery -cne 'succeeded' -or
        $Evidence.recentHeartbeat -isnot [bool] -or -not $Evidence.recentHeartbeat -or
        $Evidence.machineId -ine $MachineId -or
        @($Evidence.workspaceIngestionAddresses).Count -eq 0 -or @($Evidence.workspaceQueryAddresses).Count -eq 0) {
        throw 'Incomplete or mismatched host verification evidence.'
    }
}

function Assert-Stage0Knowledge {
    <#
    .SYNOPSIS
    Validate stored knowledge metadata; the SRE GET API does not return file bytes.
    #>
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][int]$ExpectedSize
    )
    $metadata = $Item.properties.extendedProperties
    if ($Item.name -cne 'retailtx-stage0' -or $Item.type -cne 'KnowledgeItem' -or
        $Item.properties.dataConnectorType -cne 'KnowledgeFile' -or
        $metadata.'metadata.filename' -cne 'stage0.md' -or
        $metadata.contentType -cne 'text/markdown' -or $metadata.fileSize -ne $ExpectedSize) {
        throw 'SRE knowledge metadata does not match the uploaded document.'
    }
}

Export-ModuleMember -Function Assert-Stage0Name, Assert-Stage0Ownership, ConvertFrom-Stage0Environment, Save-Stage0State, Assert-Stage0Evidence, Assert-Stage0Knowledge
