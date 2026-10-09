#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\scripts\Azure.Common.psm1') -Force
$state = @{
    schemaVersion = 2
    profile = 'azure-lite'
    subscriptionId = '11111111-1111-1111-1111-111111111111'
    tenantId = '22222222-2222-2222-2222-222222222222'
    environmentName = 'demo01'
    location = 'swedencentral'
    ownerToken = '33333333-3333-3333-3333-333333333333'
    groups = @{
        cloud = 'rg-retailtx-cloud-demo01-swedencentral'
        dc = 'rg-retailtx-dc-demo01-swedencentral'
        ops = 'rg-retailtx-ops-demo01-swedencentral'
    }
}
$script:count = 0
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe input was accepted.' }
    $script:count++
}
Assert-RetailManifest $state $state.subscriptionId $state.tenantId demo01
Assert-RetailEnvironmentName demo01
foreach ($name in @('../demo01', 'demo/01', 'Demo01', 'x', 'demo01;exit', 'demo01-test')) {
    Assert-Rejected { Assert-RetailEnvironmentName $name }
}
Assert-Rejected { Assert-RetailManifest $state $state.subscriptionId $state.tenantId demo02 }
Assert-Rejected { Assert-RetailManifest $state $state.tenantId $state.tenantId demo01 }
$group = @{
    id = "/subscriptions/$($state.subscriptionId)/resourceGroups/$($state.groups.cloud)"
    location = 'swedencentral'
    tags = @{ demo = 'retailtx'; environmentId = 'demo01'; profile = 'azure-lite'; managedBy = 'retailtx'; ownerToken = $state.ownerToken }
}
Assert-RetailOwnedGroup $state cloud $group
Assert-Rejected { Assert-RetailOwnedGroup $state dc $group }
foreach ($key in @('demo', 'environmentId', 'profile', 'managedBy', 'ownerToken')) {
    $old = $group.tags[$key]
    $group.tags[$key] = 'foreign'
    Assert-Rejected { Assert-RetailOwnedGroup $state cloud $group }
    $group.tags[$key] = $old
}
$payload = ConvertTo-RetailGuestPayload @{ value = "a'b`"`$literal" }
$decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
if ($decoded.value -cne "a'b`"`$literal") { throw 'Guest payload failed data-only round trip.' }
$mixedCase = '{"arC_PROVISIONING_READER_ROLE_ASSIGNMENT_ID":{"value":"owned-role"}}' | ConvertFrom-Json -AsHashtable
$outputs = ConvertFrom-RetailDeploymentOutputs $mixedCase
$outputs = $outputs | ConvertTo-Json | ConvertFrom-Json -AsHashtable
if ($outputs.ARC_PROVISIONING_READER_ROLE_ASSIGNMENT_ID -cne 'owned-role') {
    throw 'Azure CLI output casing was not normalized.'
}
$script:count++
$syntaxErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '..\scripts\Invoke-Azure.ps1'), [ref]$null, [ref]$syntaxErrors)
if ($syntaxErrors) { throw ($syntaxErrors -join "`n") }
foreach ($name in @('Wait-BacklogClear', 'Wait-BacklogAlert', 'Invoke-Guest', 'Set-ApplicationServices',
    'Start-SetupMaintenance', 'Remove-SetupAccess', 'Remove-MonitorAssociations')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Start-Sleep { param([int]$Seconds) }
function Get-BacklogAlerts { @{ id = 'previous-fired-incident' } }
Assert-Rejected { Wait-BacklogClear -TimeoutSeconds 0 }
$script:alertChecks = 0
function Get-BacklogAlerts {
    $script:alertChecks++
    if ($script:alertChecks -lt 3) { @{ id = 'previous-fired-incident' } }
}
Wait-BacklogClear
if ($script:alertChecks -ne 3) { throw 'Reinjection did not wait for prior alert resolution.' }
$script:count++

$script:firedSince = [DateTimeOffset]::UtcNow.AddSeconds(-5)
function Get-BacklogAlerts {
    $timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    "{`"id`":`"new-alert`",`"properties`":{`"essentials`":{`"startDateTime`":`"$timestamp`"}}}" |
        ConvertFrom-Json -AsHashtable
}
$originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo('nl-NL')
    if ((Wait-BacklogAlert $script:firedSince) -ne 'new-alert') {
        throw 'UTC alert timestamp was not preserved across localized JSON conversion.'
    }
    $script:count++
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }

$directory = Join-Path ([IO.Path]::GetTempPath()) "retailtx-lifecycle-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
try {
    $location = 'swedencentral'
    $computeApi = 'synthetic'
    $groups = @{ cloud = 'cloud'; dc = 'dc' }
    $script:state = @{ outputs = @{ cloudVmId = '/owned/cloud'; arcMachineId = '/owned/arc' }; setupAccessRemoved = $false }
    function Get-OwnedGroups { @{ cloud = @{}; dc = @{} } }
    function Save-State {}
    function Get-Resource {
        param([string]$Id, [string]$Api)
        @{ value = @(@{ id = '/older-command' }); nextLink = 'https://management.azure.com/next-test-page' }
    }
    $script:guestExitCode = 0
    function Invoke-Azure {
        param([string[]]$Arguments)
        if ($Arguments -contains 'delete') {
            $script:deletedCommandUrl = $Arguments[[array]::IndexOf($Arguments, '--url') + 1]
            return
        }
        if ($Arguments -contains 'put') {
            $url = $Arguments[[array]::IndexOf($Arguments, '--url') + 1]
            $script:testCommandId = ([uri]$url).AbsolutePath
            return @{}
        }
        if ($Arguments -contains 'https://management.azure.com/next-test-page') {
            return @{ value = @(@{ id = $script:testCommandId }) }
        }
        return @{ properties = @{ instanceView = @{
            executionState = 'Succeeded'; exitCode = $script:guestExitCode
            output = 'completed'; error = 'synthetic failure'
        } } }
    }
    if ((Invoke-Guest cloud 'true' -TimeoutSeconds 1) -ne 'completed') {
        throw 'Guest result on a later command-list page was lost.'
    }
    if ($script:deletedCommandUrl -notlike "*$script:testCommandId`?api-version=*") {
        throw 'The completed guest command was not deleted after capturing its result.'
    }
    $script:count++
    $script:deletedCommandUrl = $null
    $script:guestExitCode = 1
    Assert-Rejected { Invoke-Guest cloud 'false' -TimeoutSeconds 1 }
    if ($null -ne $script:deletedCommandUrl) { throw 'A failed guest command was deleted before diagnosis.' }
    $script:count++
    $script:guestScripts = @()
    function Invoke-Guest {
        param([string]$Role, [string]$Script)
        $script:guestScripts += $Script
    }
    function Invoke-Azure {
        param([string[]]$Arguments)
        @(@{ id = '/owned/cloud' }, @{ id = '/owned/arc' })
    }
    Set-ApplicationServices stop
    if ($script:guestScripts.Count -ne 2 -or
        @($script:guestScripts | Where-Object {
            $_ -notmatch 'rm -f /etc/retailtx/runtime-enabled' -or $_ -notmatch 'disable --now'
        }).Count -ne 0) {
        throw 'Interrupted-setup retry did not persistently disable both runtime hosts.'
    }
    $script:count++
    $script:state.releaseSha = 'installed-a'
    $script:state.setupAccessRemoved = $true
    function Save-State { $script:savedCleanupFlag = $script:state.setupAccessRemoved }
    if (Test-RetailApplicationInstall $script:state 'installed-a' 3) {
        throw 'An unchanged clean release should not need setup.'
    }
    Start-SetupMaintenance
    if ($script:savedCleanupFlag -ne $false -or
        -not (Test-RetailApplicationInstall $script:state 'installed-a' 3)) {
        throw 'Source rollback after interrupted setup bypassed mandatory cleanup.'
    }
    $script:count++
    $script:state.outputs.dcVmId = '/owned/dc'
    $script:state.setupCleanup = @{
        roleAssignments = @(); databaseAdministrator = '/owned/admin'; identities = @('/owned/setup')
    }
    function Get-InstallConfiguration { @{ role = 'cloud' } }
    function Deploy-Base {}
    function Assert-OwnedResourceId { param([string]$Id) }
    function Get-Resource { param([string]$Id, [string]$Api) @{ identity = $script:backingIdentity } }
    $script:nativeRoleAssignments = @()
    function Invoke-Azure {
        param([string[]]$Arguments)
        if ($Arguments -contains 'patch') {
            $body = Get-Content (Join-Path $directory 'detach-identity.json') -Raw | ConvertFrom-Json -AsHashtable
            if ($body.identity.ContainsKey('userAssignedIdentities')) {
                throw 'A system-only identity PATCH must omit the user-assigned map.'
            }
        }
        if ($Arguments[0] -eq 'role' -and $Arguments[2] -eq 'list') {
            return $script:nativeRoleAssignments
        }
    }
    $script:backingIdentity = @{
        type = 'SystemAssigned'; userAssignedIdentities = @{}
        principalId = '44444444-4444-4444-4444-444444444444'
    }
    Remove-SetupAccess
    if ($script:state.setupAccessRemoved -ne $true) { throw 'Verified cleanup was not persisted.' }
    $script:count++
    $script:backingIdentity.userAssignedIdentities = @{ '/owned/leaked-setup' = @{} }
    Assert-Rejected { Remove-SetupAccess }
    $script:backingIdentity.userAssignedIdentities = @{}
    $script:backingIdentity.type = 'SystemAssigned, UserAssigned'
    Assert-Rejected { Remove-SetupAccess }
    $script:backingIdentity.type = 'SystemAssigned'
    $script:nativeRoleAssignments = @(@{ id = '/unexpected/native-role' })
    Assert-Rejected { Remove-SetupAccess }
    $script:state.outputs.DCR_ID = '/owned/dcr'
    $script:state.outputs.DCE_ID = '/owned/dce'
    $script:associationTarget = '/owned/dcr'
    $script:monitorDeletes = @()
    $script:associationsPresent = $true
    $script:lateAssociationMismatch = $false
    function Get-Resource {
        param([string]$Id, [string]$Api)
        if ($script:lateAssociationMismatch -and $Id -like '/owned/arc/*') {
            return @{
                value = @(@{ name = 'retailtx-host'; id = "$Id/retailtx-host"
                    properties = @{ dataCollectionRuleId = '/owned/dcr' } })
                nextLink = 'https://management.azure.com/association-next-test-page'
            }
        }
        $items = @()
        if ($script:associationsPresent) {
            $items = @(
                @{ name = 'retailtx-host'; id = "$Id/retailtx-host"
                    properties = @{ dataCollectionRuleId = $script:associationTarget } }
                @{ name = 'configurationAccessEndpoint'; id = "$Id/configurationAccessEndpoint"
                    properties = @{ dataCollectionEndpointId = '/owned/dce' } }
                @{ name = 'unrelated'; id = "$Id/unrelated"
                    properties = @{ dataCollectionRuleId = '/shared/dcr' } }
            )
        }
        @{ value = $items }
    }
    function Invoke-Azure {
        param([string[]]$Arguments)
        if ($Arguments -contains 'https://management.azure.com/association-next-test-page') {
            return @{ value = @(@{
                name = 'configurationAccessEndpoint'
                id = '/owned/arc/providers/Microsoft.Insights/dataCollectionRuleAssociations/configurationAccessEndpoint'
                properties = @{ dataCollectionEndpointId = '/shared/dce' }
            }) }
        }
        if ($Arguments -contains 'delete') {
            $script:monitorDeletes += $Arguments[[array]::IndexOf($Arguments, '--url') + 1]
            return
        }
        @(@{ id = '/owned/cloud' }, @{ id = '/owned/arc' })
    }
    Remove-MonitorAssociations
    if ($script:monitorDeletes.Count -ne 4 -or
        @($script:monitorDeletes | Where-Object { $_ -match 'unrelated' }).Count -ne 0) {
        throw 'Monitor cleanup did not remove only the four exact owned associations.'
    }
    $script:count++
    $script:monitorDeletes = @()
    $script:associationTarget = '/shared/dcr'
    Assert-Rejected { Remove-MonitorAssociations }
    if ($script:monitorDeletes.Count -ne 0) { throw 'A changed association target allowed partial deletion.' }
    $script:count++
    $script:associationTarget = '/owned/dcr'
    $script:lateAssociationMismatch = $true
    Assert-Rejected { Remove-MonitorAssociations }
    if ($script:monitorDeletes.Count -ne 0) {
        throw 'A mismatched association on a later DC page allowed earlier cloud deletions.'
    }
    $script:count++
    $script:lateAssociationMismatch = $false
    $script:associationsPresent = $false
    Remove-MonitorAssociations
    if ($script:monitorDeletes.Count -ne 0) { throw 'Repeated monitor cleanup was not a no-op.' }
    $script:count++
} finally {
    Remove-Item -LiteralPath $directory
}
"Passed $($script:count + 4) manifest, ownership, encoding and lifecycle checks."
