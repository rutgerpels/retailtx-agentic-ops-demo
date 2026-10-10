#Requires -Version 7.2
<#
.SYNOPSIS
Provision, fault, observe, and safely tear down a private Service Bus recovery fixture.
.DESCRIPTION
Up creates an isolated Premium Service Bus namespace, dedicated queue, private
endpoint/DNS zone and queue-scoped probe roles, plus a private fixed-action
executor and independent queue-recovery watchdog. Fault writes a durable
run marker before setting only the owned queue to SendDisabled. Recover observes
the fixed-tool result; it never performs the recovery itself. Doctor and Arm
check live integration gates. Connect snapshots the shared SRE configuration
before adding the owned connector, incident platform, and disabled Review
response plan. Arm changes only that owned plan to Autonomous and preserves
global Review. Down removes only the owned connector and plan and restores the
exact saved shared configuration, then removes the exact owned executor app
role and deployment resources.
.PARAMETER Operation
Lifecycle operation to run.
.PARAMETER SubscriptionId
Explicit Azure subscription for every CLI request.
.PARAMETER EnvironmentName
Generic ID for the isolated scenario and local ownership manifest.
.PARAMETER FoundationEnvironment
Existing Stage 0 environment whose private VNet/endpoint subnet are linked.
.PARAMETER ExecutorAudience
Custom API audience URI registered for the private fixed-action executor.
.PARAMETER SreClientAppId
Client application ID of the exact SRE stdio-connector managed identity.
.PARAMETER SrePrincipalObjectId
Object ID of the exact SRE stdio-connector managed identity.
.PARAMETER FaultDurationMinutes
Independent watchdog deadline for the bounded SendDisabled fault.
.PARAMETER TimeoutSeconds
Maximum time to wait for an externally initiated fixed-tool recovery.
.EXAMPLE
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Up -SubscriptionId <guid> -EnvironmentName demo01
.EXAMPLE
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Doctor -SubscriptionId <guid> -EnvironmentName demo01
.EXAMPLE
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Down -SubscriptionId <guid> -EnvironmentName demo01
.OUTPUTS
Structured fixture lifecycle and readiness results.
.NOTES
The fixed executor and independent watchdog are provisioned as separate
identities. The executor receives queue-scoped Contributor, which permits
broader queue-property operations; its code permits only the exact Active
transition. The SRE identity receives no queue-management role. A separate
executor-specific Entra audience and app-role assignment are created and
removed by the lifecycle helper. No live acceptance is claimed by this script.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Up', 'Connect', 'Doctor', 'Arm', 'Fault', 'Incident', 'Recover', 'Reset', 'Down')]
    [string]$Operation,
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9]{2,11}$')]
    [string]$EnvironmentName,
    [ValidatePattern('^[a-z][a-z0-9]{2,11}$')]
    [string]$FoundationEnvironment = 'stage0',
    [ValidatePattern('^api://[0-9a-fA-F-]{36}$')]
    [string]$ExecutorAudience,
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SreClientAppId,
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SrePrincipalObjectId,
    [ValidateRange(1, 15)]
    [int]$FaultDurationMinutes = 5,
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'servicebus\EntraExecutorIdentity.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
Assert-RetailEnvironmentName $FoundationEnvironment

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $repositoryRoot ".azure\$EnvironmentName"
$statePath = Join-Path $directory 'servicebus-scenario-state.json'
$lockPath = Join-Path $directory 'servicebus-scenario.lock'
$groupName = "rg-retailtx-servicebus-$EnvironmentName-swedencentral"
$foundationGroupName = "rg-retailtx-$FoundationEnvironment-swedencentral"
$subscription = $SubscriptionId.ToString()
$scenarioState = $null
$sharedDnsLock = $null

function Invoke-Azure {
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 0)
    Invoke-RetailAzure -SubscriptionId $SubscriptionId -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Get-ServiceBusSourceDigest {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$FileNames
    )
    $records = foreach ($name in @($FileNames | Sort-Object -CaseSensitive)) {
        $path = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Attested Service Bus source file is missing: $name"
        }
        $contentHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($path))
        ).ToLowerInvariant()
        "$name`0$contentHash`n"
    }
    $canonical = [Text.Encoding]::UTF8.GetBytes(($records -join ''))
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($canonical)
    ).ToLowerInvariant()
}

function New-ServiceBusRunnerSshPublicKey {
    param([Parameter(Mandatory)][guid]$OwnerToken)

    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $stream = [IO.MemoryStream]::new()
    try {
        $parameters = $rsa.ExportParameters($false)
        $fields = [Collections.Generic.List[byte[]]]::new()
        $fields.Add([Text.Encoding]::ASCII.GetBytes('ssh-rsa'))
        foreach ($integer in @($parameters.Exponent, $parameters.Modulus)) {
            $first = 0
            while ($first -lt $integer.Length - 1 -and $integer[$first] -eq 0) {
                $first++
            }
            $normalized = [byte[]]::new($integer.Length - $first)
            [Array]::Copy($integer, $first, $normalized, 0, $normalized.Length)
            if (($normalized[0] -band 0x80) -ne 0) {
                $positive = [byte[]]::new($normalized.Length + 1)
                [Array]::Copy($normalized, 0, $positive, 1, $normalized.Length)
                $normalized = $positive
            }
            $fields.Add($normalized)
        }
        foreach ($field in $fields) {
            $stream.WriteByte([byte](($field.Length -shr 24) -band 0xff))
            $stream.WriteByte([byte](($field.Length -shr 16) -band 0xff))
            $stream.WriteByte([byte](($field.Length -shr 8) -band 0xff))
            $stream.WriteByte([byte]($field.Length -band 0xff))
            $stream.Write($field, 0, $field.Length)
        }
        $encodedKey = [Convert]::ToBase64String($stream.ToArray())
        return "ssh-rsa $encodedKey retailtx-servicebus-$OwnerToken"
    } finally {
        $stream.Dispose()
        $rsa.Dispose()
    }
}

function Test-ServiceBusRunnerSshPublicKey {
    param([Parameter(Mandatory)][string]$PublicKey)
    if ($PublicKey -notmatch '^ssh-rsa ([A-Za-z0-9+/]+={0,2}) retailtx-servicebus-[0-9a-fA-F-]{36}$') {
        return $false
    }
    try {
        $payload = [Convert]::FromBase64String($Matches[1])
        $offset = 0
        $fieldIndex = 0
        foreach ($expectedField in @('ssh-rsa', $null, $null)) {
            if ($offset + 4 -gt $payload.Length) { return $false }
            $length = [uint32](
                ([uint32]$payload[$offset] -shl 24) -bor
                ([uint32]$payload[$offset + 1] -shl 16) -bor
                ([uint32]$payload[$offset + 2] -shl 8) -bor
                [uint32]$payload[$offset + 3]
            )
            $offset += 4
            if ($length -eq 0 -or $offset + $length -gt $payload.Length) { return $false }
            if ($null -ne $expectedField) {
                $fieldText = [Text.Encoding]::ASCII.GetString($payload, $offset, $length)
                if ($fieldText -cne $expectedField) { return $false }
            } elseif ($fieldIndex -eq 2 -and $length -lt 256) {
                return $false
            }
            $offset += $length
            $fieldIndex++
        }
        return $offset -eq $payload.Length
    } catch {
        return $false
    }
}

function Get-ServiceBusRunnerSshPublicKey {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $ownerToken = [guid]::Parse([string]$State.ownerToken)
    # Bracket notation avoids a Set-StrictMode -Version Latest exception when
    # the key is not yet present on $State (dot notation throws in that case).
    $existingPublicKey = $State['runnerSshPublicKey']
    if ($existingPublicKey) {
        if (-not (Test-ServiceBusRunnerSshPublicKey -PublicKey $existingPublicKey) -or
            $existingPublicKey -notmatch (
                '^ssh-rsa [A-Za-z0-9+/]+={0,2} retailtx-servicebus-' +
                [regex]::Escape($ownerToken.ToString()) + '$'
            )) {
            throw 'The runner public key is malformed or bound to another scenario owner.'
        }
        return [string]$existingPublicKey
    }

    $State['runnerSshPublicKey'] = New-ServiceBusRunnerSshPublicKey -OwnerToken $ownerToken
    return [string]$State['runnerSshPublicKey']
}

function New-ServiceBusRunnerBundle {
    $runnerRoot = Join-Path $repositoryRoot 'scripts\servicebus'
    $functionRoot = Join-Path $runnerRoot 'executor'
    $runnerFiles = @('probe.py', 'runner.py')
    $functionFiles = @(
        'host.json',
        'function_app.py',
        'executor_core.py',
        'coordination.py',
        'mcp_stdio.py',
        'requirements.txt'
    )
    $functionDigest = Get-ServiceBusSourceDigest -Root $functionRoot -FileNames $functionFiles
    $runnerDigest = Get-ServiceBusSourceDigest -Root $runnerRoot -FileNames $runnerFiles
    $memory = [IO.MemoryStream]::new()
    $archive = [IO.Compression.ZipArchive]::new(
        $memory,
        [IO.Compression.ZipArchiveMode]::Create,
        $true
    )
    try {
        foreach ($name in $runnerFiles) {
            $entryName = $name
            $sourcePath = Join-Path $runnerRoot $name
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $entryStream = $entry.Open()
            try {
                $bytes = [IO.File]::ReadAllBytes($sourcePath)
                $entryStream.Write($bytes, 0, $bytes.Length)
            } finally {
                $entryStream.Dispose()
            }
        }
        foreach ($name in $functionFiles) {
            $entryName = "function-app/$name"
            $sourcePath = Join-Path $functionRoot $name
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $entryStream = $entry.Open()
            try {
                $bytes = [IO.File]::ReadAllBytes($sourcePath)
                $entryStream.Write($bytes, 0, $bytes.Length)
            } finally {
                $entryStream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
    $bundleBytes = $memory.ToArray()
    $memory.Dispose()
    if ($bundleBytes.Length -gt 180000) {
        throw 'The private runner source bundle exceeds the 180 KB bounded delivery limit.'
    }
    return [pscustomobject]@{
        Bytes = $bundleBytes
        BundleSha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bundleBytes)
        ).ToLowerInvariant()
        BundleSourceSha256 = $runnerDigest
        FunctionSourceSha256 = $functionDigest
    }
}

function New-ServiceBusRunnerBootstrapScript {
    param([Parameter(Mandatory)][pscustomobject]$Bundle)
    $templatePath = Join-Path $repositoryRoot 'scripts\servicebus\runner-bootstrap.sh'
    $script = Get-Content -LiteralPath $templatePath -Raw
    $replacements = @{
        '@@OWNER_TOKEN@@' = $scenarioState.ownerToken
        '@@BUNDLE_SHA256@@' = $Bundle.BundleSha256
        '@@BUNDLE_SOURCE_SHA256@@' = $Bundle.BundleSourceSha256
        '@@FUNCTION_SOURCE_SHA256@@' = $Bundle.FunctionSourceSha256
        '@@BUNDLE_BASE64@@' = [Convert]::ToBase64String($Bundle.Bytes)
    }
    foreach ($marker in $replacements.Keys) {
        $script = $script.Replace($marker, [string]$replacements[$marker])
    }
    if ($script.Contains('@@') -or $script.Length -gt 48000) {
        throw 'Runner bootstrap source is incomplete or exceeds the VM custom-data bound.'
    }
    return $script
}

function Invoke-ServiceBusRunnerCommand {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('configure', 'initialize', 'state', 'fault', 'health', 'probe', 'publish')]
        [string]$Action,
        [Parameter()][hashtable]$Arguments = @{},
        [ValidateRange(30, 1800)][int]$CommandTimeoutSeconds = 180
    )
    if (-not $scenarioState -or -not $scenarioState.outputs.RUNNERVMNAME) {
        throw 'The owned private Service Bus runner is not recorded in the manifest.'
    }
    $vmName = [string]$scenarioState.outputs.RUNNERVMNAME
    if ($vmName -cne "vm-sb-runner-$EnvironmentName") {
        throw 'Runner VM name differs from the exact owned environment resource.'
    }
    $request = @{
        schemaVersion = 1
        ownerToken = $scenarioState.ownerToken
        bundleSha256 = $scenarioState.runnerBundleSha256
        action = $Action
        arguments = $Arguments
    } | ConvertTo-Json -Depth 8 -Compress
    $encodedRequest = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))
    $script = @"
set -euo pipefail
cloud-init status --wait >/dev/null
printf '%s' '$encodedRequest' | /opt/retailtx-servicebus/venv/bin/python /opt/retailtx-servicebus/runner.py
"@
    $response = Invoke-Azure @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $groupName,
        '--name', $vmName,
        '--command-id', 'RunShellScript',
        '--scripts', $script
    ) -TimeoutSeconds $CommandTimeoutSeconds
    $message = [string]$response.value[0].message
    $match = [regex]::Match($message, 'SB_RESULT:(\{[^\r\n]*\})')
    if (-not $match.Success) {
        throw 'The private runner returned no bounded structured result; mutation outcome may be unknown.'
    }
    $result = $match.Groups[1].Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($result.ContainsKey('error')) {
        throw "Private runner operation '$Action' failed: $($result.error)"
    }
    return $result
}

function Assert-ServiceBusRunnerHealth {
    $health = Invoke-ServiceBusRunnerCommand -Action health -CommandTimeoutSeconds 300
    if (-not $health.ready -or
        -not $health.stateDatabaseReady -or
        $health.ownerToken -cne $scenarioState.ownerToken -or
        $health.bundleSha256 -cne $scenarioState.runnerBundleSha256 -or
        $health.functionSourceSha256 -cne $scenarioState.functionSourceSha256 -or
        @($health.queuePrivateAddresses).Count -eq 0 -or
        @($health.scmPrivateAddresses.Keys).Count -ne 2 -or
        @($health.coordinationStoragePrivateAddresses).Count -eq 0 -or
        -not $health.coordinationStoreReady) {
        throw 'Private runner source, queue/storage/SCM DNS, owner, blob lease/ETag, or durable state evidence failed.'
    }
    return $health
}

function Invoke-ServiceBusGraph {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][hashtable]$Body
    )
    $arguments = @(
        'rest', '--method', $Method,
        '--url', "https://graph.microsoft.com/v1.0$Path"
    )
    if ($Body) {
        $arguments += @('--headers', 'Content-Type=application/json')
        $arguments += @('--body', ($Body | ConvertTo-Json -Depth 20 -Compress))
    }
    return Invoke-Azure $arguments -TimeoutSeconds 180
}

function Save-State {
    $scenarioState | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath "$statePath.tmp" -Encoding utf8NoBOM
    Move-Item -LiteralPath "$statePath.tmp" -Destination $statePath -Force
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'No Service Bus ownership manifest exists. Refusing to adopt a resource group.'
    }
    $script:scenarioState = Get-Content -LiteralPath $statePath -Raw |
        ConvertFrom-Json -AsHashtable
    if ($scenarioState.schemaVersion -ne 1 -or $scenarioState.profile -cne 'servicebus-scenario' -or
        $scenarioState.subscriptionId -ine $subscription -or
        $scenarioState.environmentName -cne $EnvironmentName -or
        $scenarioState.foundationEnvironment -cne $FoundationEnvironment -or
        $scenarioState.groupName -cne $groupName -or
        $scenarioState.groupId -ine "/subscriptions/$subscription/resourceGroups/$groupName") {
        throw 'The Service Bus manifest does not match the requested subscription or environment.'
    }
    $null = [guid]::Parse($scenarioState.ownerToken)
    $null = [guid]::Parse($scenarioState.tenantId)
}

function Get-VerifiedFoundation {
    $foundationPath = Join-Path $repositoryRoot ".azure\$FoundationEnvironment\retailtx-state.json"
    if (-not (Test-Path -LiteralPath $foundationPath -PathType Leaf)) {
        throw 'The retained Stage 0 manifest is missing.'
    }
    $foundation = Get-Content -LiteralPath $foundationPath -Raw | ConvertFrom-Json -AsHashtable
    $account = Invoke-Azure @('account', 'show')
    if ($account.id -ine $subscription -or $account.tenantId -ine $foundation.tenantId -or
        $foundation.subscriptionId -ine $subscription -or
        $foundation.environmentName -cne $FoundationEnvironment -or
        $foundation.outputs.SRE_AGENT_ID -notmatch (
            '^/subscriptions/' + [regex]::Escape($subscription) +
            '/resourceGroups/' + [regex]::Escape($foundationGroupName) +
            '/providers/Microsoft\.App/agents/[^/]+$'
        ) -or
        -not $foundation.outputs.WORKSPACE_ID -or -not $foundation.outputs.DCE_ID) {
        throw 'The retained Stage 0 subscription, tenant, SRE Agent resource ID, or required outputs do not match.'
    }
    $group = Invoke-Azure @('group', 'show', '--name', $foundationGroupName)
    if ($group.id -ine "/subscriptions/$subscription/resourceGroups/$foundationGroupName" -or
        $group.location -ine 'swedencentral' -or $group.tags.demo -cne 'retailtx' -or
        $group.tags.environmentId -cne $FoundationEnvironment -or
        $group.tags.ownerToken -cne $foundation.ownerToken -or
        $group.tags.managedBy -cne 'retailtx-stage0') {
        throw 'The retained Stage 0 resource group failed its ownership check.'
    }
    $vnetName = "vnet-retailtx-$FoundationEnvironment"
    $vnet = Invoke-Azure @('network', 'vnet', 'show', '--resource-group', $foundationGroupName, '--name', $vnetName)
    $expectedVnet = "$($group.id)/providers/Microsoft.Network/virtualNetworks/$vnetName"
    if ($vnet.id -ine $expectedVnet -or $vnet.tags.ownerToken -cne $foundation.ownerToken) {
        throw 'The retained Stage 0 VNet failed its ownership check.'
    }
    $endpointSubnet = @($vnet.subnets | Where-Object { $_.name -ceq 'private-endpoints' })
    if ($endpointSubnet.Count -ne 1 -or $endpointSubnet[0].addressPrefix -cne '10.84.1.0/24') {
        throw 'The expected private endpoint subnet is missing or has drifted.'
    }
    return @{
        state = $foundation
        group = $group
        virtualNetworkId = $vnet.id
        privateEndpointSubnetId = $endpointSubnet[0].id
        tenantId = $foundation.tenantId
    }
}

function Get-OwnedScenarioGroup {
    $exists = Invoke-Azure @('group', 'exists', '--name', $groupName)
    if (-not $exists) { return $null }
    $group = Invoke-Azure @('group', 'show', '--name', $groupName)
    if (-not $scenarioState -or
        $group.id -ine $scenarioState.groupId -or
        $group.location -ine 'swedencentral' -or
        $group.tags.demo -cne 'retailtx' -or
        $group.tags.environmentId -cne $EnvironmentName -or
        $group.tags.ownerToken -cne $scenarioState.ownerToken -or
        $group.tags.profile -cne 'servicebus' -or
        $group.tags.managedBy -cne 'retailtx') {
        throw 'Service Bus resource group ownership validation failed; no adoption or mutation is permitted.'
    }
    return $group
}

function Assert-ServiceBusPrivateDnsOwnership {
    $zones = @(Invoke-Azure @(
        'network', 'private-dns', 'zone', 'list', '--query',
        "[?name=='privatelink.servicebus.windows.net']"
    ))
    if ($zones.Count -gt 1) {
        throw 'Multiple Service Bus private DNS zones exist. Refusing to choose or mutate one.'
    }
    if ($zones.Count -eq 1) {
        $zone = $zones[0]
        $expectedZoneId = "$($scenarioState.groupId)/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net"
        if ($zone.id -ine $expectedZoneId -or
            $zone.resourceGroup -ine $groupName -or
            $zone.tags.demo -cne 'retailtx' -or
            $zone.tags.environmentId -cne $EnvironmentName -or
            $zone.tags.profile -cne 'servicebus' -or
            $zone.tags.ownerToken -cne $scenarioState.ownerToken -or
            $zone.tags.managedBy -cne 'retailtx') {
            throw 'The Service Bus private DNS zone ID or ownership tags do not match this manifest. Refusing to adopt or mutate it.'
        }
    }
}

function Get-ServiceBusExecutorVirtualNetworkId {
    return "$($scenarioState.groupId)/providers/Microsoft.Network/virtualNetworks/vnet-sb-exec-$EnvironmentName"
}

function Assert-ServiceBusFoundationPeeringOwnership {
    param([switch]$RequireExisting)
    $expectedRemoteId = Get-ServiceBusExecutorVirtualNetworkId
    $peeringName = "peer-retailtx-sb-$EnvironmentName"
    $peerings = @(Invoke-Azure @(
        'network', 'vnet', 'peering', 'list',
        '--resource-group', $foundationGroupName,
        '--vnet-name', "vnet-retailtx-$FoundationEnvironment"
    ))
    $matches = @($peerings | Where-Object { $_.name -ceq $peeringName })
    if ($matches.Count -gt 1) {
        throw 'Multiple Stage 0 executor peerings match this environment. Refusing mutation.'
    }
    if ($matches.Count -eq 0) {
        if ($RequireExisting) { throw 'The exact Stage 0 executor peering is missing.' }
        return $false
    }
    if ($matches[0].remoteVirtualNetwork.id -ine $expectedRemoteId) {
        throw 'The Stage 0 executor peering points to a different VNet. Refusing mutation.'
    }
    return $true
}

function Invoke-ServiceBusExecutorPublish {
    param([Parameter(Mandatory)][string]$FunctionAppName)
    if ($FunctionAppName -notmatch '^func-sb-(exec|watch)-[a-z0-9]{3,12}-[a-z0-9]+$') {
        throw 'Executor Function App name failed its deterministic ownership check.'
    }
    $expectedName = if ($FunctionAppName -ceq $scenarioState.outputs.EXECUTORAPPNAME) {
        $scenarioState.outputs.EXECUTORAPPNAME
    } elseif ($FunctionAppName -ceq $scenarioState.outputs.WATCHDOGAPPNAME) {
        $scenarioState.outputs.WATCHDOGAPPNAME
    } else {
        throw 'Function publish target is not one of the exact owned apps.'
    }
    $result = Invoke-ServiceBusRunnerCommand -Action publish -Arguments @{ appName = $expectedName } `
        -CommandTimeoutSeconds 1500
    if (-not $result.published -or $result.appName -cne $expectedName) {
        throw "Private Function package publishing was not confirmed for '$expectedName'."
    }
}

function Get-ServiceBusFoundationDnsLockPath {
    param([Parameter(Mandatory)][string]$VirtualNetworkId)
    if ($VirtualNetworkId -cnotmatch (
        '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+$'
    )) {
        throw 'Cannot derive the shared DNS lock from an invalid foundation VNet resource ID.'
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($VirtualNetworkId.ToLowerInvariant())
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $lockDirectory = Join-Path $repositoryRoot '.azure\shared-locks'
    $null = New-Item -ItemType Directory -Path $lockDirectory -Force
    return Join-Path $lockDirectory "servicebus-dns-$hash.lock"
}

function Enter-ServiceBusFoundationDnsLock {
    param([Parameter(Mandatory)][string]$VirtualNetworkId)
    $path = Get-ServiceBusFoundationDnsLockPath -VirtualNetworkId $VirtualNetworkId
    try {
        return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        throw 'Another Service Bus lifecycle operation holds the shared foundation-VNet DNS lock. Retry after it finishes.'
    }
}

function ConvertTo-ServiceBusCanonicalJson {
    param([Parameter()][object]$Value)
    function ConvertTo-OrderedServiceBusValue {
        param([Parameter()][object]$Item)
        if ($Item -is [Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in @($Item.Keys | Sort-Object)) {
                $ordered[$key] = ConvertTo-OrderedServiceBusValue $Item[$key]
            }
            return $ordered
        }
        if ($Item -is [array]) {
            return ,@($Item | ForEach-Object { ConvertTo-OrderedServiceBusValue $_ })
        }
        return $Item
    }
    return ConvertTo-OrderedServiceBusValue $Value | ConvertTo-Json -Depth 40 -Compress
}

function Get-ServiceBusSreConnectorIdentity {
    param(
        [Parameter(Mandatory)][hashtable]$Resource,
        [Parameter(Mandatory)][scriptblock]$InvokeGraph
    )
    $identity = $Resource.identity
    if (-not $identity -or $identity.type -notmatch '(^|,\s*)SystemAssigned($|,)' -or
        -not $identity.principalId) {
        throw 'The retained SRE Agent system identity required by its stdio connector is missing.'
    }
    try {
        $principalId = [guid]::Parse($identity.principalId).ToString()
    } catch {
        throw 'The retained SRE Agent system identity principal ID is invalid.'
    }
    $servicePrincipal = & $InvokeGraph GET `
        "/servicePrincipals/$([uri]::EscapeDataString($principalId))?`$select=id,appId,servicePrincipalType,accountEnabled" $null
    if ($servicePrincipal.id -ine $principalId -or
        $servicePrincipal.servicePrincipalType -cne 'ManagedIdentity' -or
        -not $servicePrincipal.accountEnabled -or
        -not $servicePrincipal.appId) {
        throw 'The SRE connector system principal did not resolve to an enabled managed identity.'
    }
    $null = [guid]::Parse($servicePrincipal.appId)
    return @{
        id = $principalId
        principalId = $principalId
        clientId = [guid]::Parse($servicePrincipal.appId).ToString()
        servicePrincipalType = $servicePrincipal.servicePrincipalType
    }
}

function Get-ServiceBusSreConnection {
    $foundation = Get-VerifiedFoundation
    if (-not $scenarioState -or
        ($scenarioState.sreIntegration -and
         $scenarioState.sreIntegration.agentId -ine $foundation.state.outputs.SRE_AGENT_ID)) {
        throw 'The retained SRE Agent identity is not bound to the scenario manifest.'
    }
    $resource = Invoke-Azure @(
        'resource', 'show', '--ids', $foundation.state.outputs.SRE_AGENT_ID,
        '--api-version', '2026-01-01'
    )
    if ($resource.id -ine $foundation.state.outputs.SRE_AGENT_ID -or
        $resource.type -ine 'Microsoft.App/agents') {
        throw 'The SRE Agent resource identity or type does not match Stage 0.'
    }
    if ($resource.properties.actionConfiguration.mode -cne 'Review') {
        throw 'The shared SRE global action mode is not Review; refusing to connect or arm.'
    }
    $actionIdentityId = $resource.properties.actionConfiguration.identity
    if (-not $actionIdentityId) { throw 'The SRE action identity is missing.' }
    $connectorIdentity = Get-ServiceBusSreConnectorIdentity -Resource $resource -InvokeGraph {
        param($Method, $Path, $Body)
        Invoke-ServiceBusGraph -Method $Method -Path $Path -Body $Body
    }
    $expectedPrincipalId = if ($SrePrincipalObjectId) {
        $SrePrincipalObjectId
    } elseif ($scenarioState.srePrincipalObjectId) {
        $scenarioState.srePrincipalObjectId
    } else { $null }
    $expectedClientId = if ($SreClientAppId) {
        $SreClientAppId
    } elseif ($scenarioState.sreClientAppId) {
        $scenarioState.sreClientAppId
    } else { $null }
    if (($expectedPrincipalId -and $connectorIdentity.principalId -ine $expectedPrincipalId) -or
        ($expectedClientId -and $connectorIdentity.clientId -ine $expectedClientId)) {
        throw 'The SRE connector system identity differs from the explicit executor identity binding.'
    }
    $endpoint = [uri]$resource.properties.agentEndpoint
    if ($endpoint.Scheme -cne 'https' -or
        -not $endpoint.Host.EndsWith('.azuresre.ai', [StringComparison]::OrdinalIgnoreCase) -or
        $endpoint.Port -ne 443 -or $endpoint.UserInfo -or $endpoint.Query -or
        $endpoint.Fragment -or $endpoint.AbsolutePath -ne '/') {
        throw 'Unexpected SRE data-plane endpoint; refusing to send authentication.'
    }
    return @{
        endpoint = $endpoint.AbsoluteUri.TrimEnd('/')
        clientId = $connectorIdentity.clientId
        principalId = $connectorIdentity.principalId
        actionIdentityId = $actionIdentityId
        resource = $resource
        agentId = $resource.id
    }
}

function Invoke-ServiceBusSreRequest {
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][hashtable]$Body,
        [Parameter()][switch]$AllowMissing
    )
    if ($Path -notmatch '^/api/v2/(agent/settings/global|incidentManagement/(incidentFilters(?:/[^/?]+)?|incidents(?:\?.*)?|checkConnectivityDetailed))$' -or
        $Path.Contains('..')) {
        throw 'Unexpected SRE data-plane API path.'
    }
    $credentials = Invoke-Azure @(
        'account', 'get-access-token', '--resource', 'https://azuresre.dev'
    )
    if (-not $credentials.accessToken) { throw 'Azure CLI did not return an SRE data-plane token.' }
    $token = ConvertTo-SecureString $credentials.accessToken -AsPlainText -Force
    $credentials = $null
    $arguments = @{
        Uri = "$($Connection.endpoint)$Path"
        Method = $Method
        Authentication = 'Bearer'
        Token = $token
        MaximumRedirection = 0
        TimeoutSec = 90
        SkipHttpErrorCheck = $true
    }
    if ($Body) {
        $arguments.ContentType = 'application/json'
        $arguments.Body = $Body | ConvertTo-Json -Depth 40 -Compress
    }
    try {
        $response = Invoke-WebRequest @arguments
    } finally {
        $token = $null
        $arguments.Token = $null
    }
    if ($AllowMissing -and $Method -ceq 'GET' -and $response.StatusCode -eq 404) { return $null }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        $error = [InvalidOperationException]::new(
            "SRE $Method $Path failed with HTTP $($response.StatusCode)."
        )
        $error.Data['HttpStatusCode'] = [int]$response.StatusCode
        throw $error
    }
    if ($response.Content) { return $response.Content | ConvertFrom-Json -AsHashtable }
}

function Get-ServiceBusMcpConnectorName {
    return "retailtx-servicebus-$EnvironmentName"
}

function Get-ServiceBusResponsePlanName {
    return "retailtx-servicebus-$EnvironmentName"
}

function Get-ServiceBusAlertRuleName {
    return "alert-servicebus-$EnvironmentName"
}

function Test-ServiceBusAlertEssentials {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Essentials,
        [Parameter(Mandatory)][string]$ExpectedTargetId,
        [Parameter(Mandatory)][string]$ExpectedRuleId,
        [Parameter(Mandatory)][DateTimeOffset]$FaultAt
    )
    if ($Essentials.alertRule -cne (Get-ServiceBusAlertRuleName)) { return $false }
    foreach ($identifierField in @('alertRuleId', 'alertRuleResourceId')) {
        if ($Essentials.Keys -contains $identifierField -and
            $Essentials[$identifierField] -ine $ExpectedRuleId) {
            throw "Azure alert $identifierField does not match the exact deployed metric alert."
        }
    }
    if ($Essentials.targetResource -ine $ExpectedTargetId -or
        $Essentials.monitoringService -cne 'Platform' -or
        $Essentials.signalType -cne 'Metric') {
        throw 'Azure alert target or source does not match the exact Service Bus platform metric.'
    }
    if (-not $Essentials.startDateTime) {
        throw 'Service Bus alert start timestamp is missing.'
    }
    $started = [DateTimeOffset]::Parse($Essentials.startDateTime).ToUniversalTime()
    if ($started -gt [DateTimeOffset]::UtcNow.AddSeconds(30)) {
        throw 'Service Bus alert start timestamp is future-dated.'
    }
    return $started -ge $FaultAt
}

function Assert-ServiceBusEasyAuthBinding {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Configuration,
        [Parameter(Mandatory)][string]$ExpectedAudience,
        [Parameter(Mandatory)][string]$ExpectedApplicationId
    )
    $properties = $Configuration.properties
    $authentication = $properties.identityProviders.azureActiveDirectory
    $allowedApplications = @($authentication.validation.defaultAuthorizationPolicy.allowedApplications)
    $allowedAudiences = @($authentication.validation.allowedAudiences)
    if ($properties.globalValidation.requireAuthentication -ne $true -or
        $properties.globalValidation.unauthenticatedClientAction -cne 'Return401' -or
        $authentication.enabled -ne $true -or
        $allowedApplications.Count -ne 1 -or
        $allowedApplications[0] -ine $ExpectedApplicationId -or
        $allowedAudiences.Count -ne 1 -or
        $allowedAudiences[0] -cne $ExpectedAudience) {
        throw 'Function App Easy Auth does not allow only the exact SRE connector application and executor audience.'
    }
}

function Enter-ServiceBusScenarioLock {
    param([Parameter(Mandatory)][string]$Path)
    try {
        return [IO.File]::Open(
            $Path,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    } catch [IO.IOException] {
        throw 'Another Service Bus lifecycle operation is in progress; refusing concurrent mutation.'
    }
}

function Get-ServiceBusMcpConnectorDefinition {
    if (-not $scenarioState.outputs.EXECUTORAPPNAME) {
        throw 'The private fixed executor has not been provisioned.'
    }
    $bridgePath = Join-Path $repositoryRoot 'scripts\servicebus\executor\mcp_stdio.py'
    if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) {
        throw 'The fixed stdio MCP bridge source is missing.'
    }
    $source = [IO.File]::ReadAllText($bridgePath, [Text.Encoding]::UTF8)
    $encodedSource = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $bootstrap = "import base64;exec(compile(base64.b64decode('$encodedSource'),'<retailtx-servicebus-mcp>','exec'),{'__name__':'__main__'})"
    $args = @('-u', '-c', $bootstrap)
    $envs = @{
        EXECUTOR_PRIVATE_URL = "https://$($scenarioState.outputs.EXECUTORAPPNAME).azurewebsites.net/api/restore"
        EXECUTOR_PRIVATE_ENDPOINT_CIDR = '10.85.0.64/26'
        EXECUTOR_AUDIENCE = $scenarioState.executorAudience
        RETAILTX_SCENARIO_OWNER_TOKEN = $scenarioState.ownerToken
    }
    return @{
        name = Get-ServiceBusMcpConnectorName
        properties = @{
            name = Get-ServiceBusMcpConnectorName
            dataConnectorType = 'Mcp'
            dataSource = 'python3'
            identity = 'system'
            extendedProperties = @{
                type = 'stdio'
                command = 'python3'
                args = $args
                envs = $envs
            }
        }
    }
}

function Get-ServiceBusSreConnector {
    $url = "https://management.azure.com$($scenarioState.sreIntegration.agentId)/connectors?api-version=2025-05-01-preview"
    $result = Invoke-Azure @('rest', '--method', 'get', '--url', $url)
    if (-not $result.ContainsKey('value') -or
        ($result.ContainsKey('nextLink') -and $result.nextLink)) {
        throw 'SRE connector list is incomplete; refusing to infer connector absence.'
    }
    $matches = @($result.value | Where-Object { $_.name -ceq (Get-ServiceBusMcpConnectorName) })
    if ($matches.Count -gt 1) { throw 'Multiple connectors match the exact Service Bus connector name.' }
    if ($matches.Count -eq 0) { return $null }
    $expectedId = "$($scenarioState.sreIntegration.agentId)/connectors/$(Get-ServiceBusMcpConnectorName)"
    if ($matches[0].id -ine $expectedId) { throw 'SRE returned a connector outside the exact owned resource path.' }
    return $matches[0]
}

function Test-ServiceBusSreConnector {
    param([Parameter()][object]$Connector)
    if (-not $Connector) { return $false }
    $expected = (Get-ServiceBusMcpConnectorDefinition).properties
    foreach ($property in @('dataConnectorType', 'dataSource', 'identity')) {
        if ($Connector.properties[$property] -cne $expected[$property]) { return $false }
    }
    $actualExtended = $Connector.properties.extendedProperties
    $expectedExtended = $expected.extendedProperties
    foreach ($property in @('type', 'command')) {
        if ($actualExtended[$property] -cne $expectedExtended[$property]) { return $false }
    }
    if ((ConvertTo-ServiceBusCanonicalJson $actualExtended.args) -cne
        (ConvertTo-ServiceBusCanonicalJson $expectedExtended.args) -or
        (ConvertTo-ServiceBusCanonicalJson $actualExtended.envs) -cne
        (ConvertTo-ServiceBusCanonicalJson $expectedExtended.envs)) {
        return $false
    }
    return $true
}

function Get-ServiceBusSreState {
    if (-not $scenarioState.ContainsKey('sreIntegration') -or -not $scenarioState.sreIntegration) {
        return $null
    }
    $configuration = $scenarioState.sreIntegration
    if ($configuration.ownerToken -cne $scenarioState.ownerToken -or
        $configuration.agentId -ine $scenarioState.foundationAgentId -or
        $configuration.connectorName -cne (Get-ServiceBusMcpConnectorName) -or
        $configuration.responsePlanName -cne (Get-ServiceBusResponsePlanName)) {
        throw 'Service Bus SRE integration manifest ownership or resource identity drifted.'
    }
    return $configuration
}

function Get-ServiceBusResponsePlan {
    param([Parameter(Mandatory)][hashtable]$Connection)
    $name = [uri]::EscapeDataString((Get-ServiceBusResponsePlanName))
    return Invoke-ServiceBusSreRequest $Connection GET "/api/v2/incidentManagement/incidentFilters/$name" -AllowMissing
}

function Get-ServiceBusExpectedResponsePlan {
    param(
        [Parameter(Mandatory)][ValidateSet('review', 'autonomous')][string]$AgentMode,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $targetId = $scenarioState.outputs.NAMESPACEID
    $alertId = $scenarioState.outputs.SENDFAILUREALERTID
    if (-not $targetId -or -not $alertId) {
        throw 'The Service Bus namespace and exact alert resource IDs are required for response routing.'
    }
    return @{
        name = Get-ServiceBusResponsePlanName
        type = 'IncidentFilter'
        tags = @("retailtxServiceBusOwner:$($scenarioState.ownerToken)")
        properties = @{
            incidentPlatform = 'AzMonitor'
            priorities = @('Sev0', 'Sev1', 'Sev2', 'Sev3', 'Sev4')
            impactedService = ''
            incidentType = ''
            alertId = ''
            titleContains = ($alertId -split '/')[-1]
            titleContainsAll = @()
            titleContainsAny = @()
            titleNotContains = @()
            agentMode = $AgentMode
            handlingAgent = 'meta_agent'
            handlingAgents = $null
            owningTeamId = ''
            owningTeamIds = @()
            maxAutomatedInvestigationAttempts = 1
            mergeEnabled = $false
            isEnabled = $Enabled
            azMonitorFilterSettings = @{
                targetResourceType = 'Microsoft.ServiceBus/namespaces'
                targetResource = $targetId
            }
        }
    }
}

function Assert-ServiceBusResponsePlan {
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)][ValidateSet('review', 'autonomous')][string]$AgentMode,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $expected = Get-ServiceBusExpectedResponsePlan -AgentMode $AgentMode -Enabled $Enabled
    if ($Plan.name -cne $expected.name -or $Plan.type -cne 'IncidentFilter' -or
        @($Plan.tags | Where-Object { $_ -ceq $expected.tags[0] }).Count -ne 1) {
        throw 'SRE response plan is not owned by this exact Service Bus manifest.'
    }
    foreach ($key in @(
        'incidentPlatform', 'titleContains', 'agentMode', 'handlingAgent',
        'isEnabled', 'mergeEnabled'
    )) {
        if ($Plan.properties[$key] -cne $expected.properties[$key]) {
            throw "SRE response plan property '$key' differs from the owned expected value."
        }
    }
    if ((ConvertTo-ServiceBusCanonicalJson $Plan.properties.azMonitorFilterSettings) -cne
        (ConvertTo-ServiceBusCanonicalJson $expected.properties.azMonitorFilterSettings)) {
        throw 'SRE response plan does not target the exact Service Bus namespace.'
    }
}

function Get-ServiceBusExpectedSharedConfiguration {
    param([Parameter(Mandatory)][hashtable]$Configuration)
    $graph = ConvertFrom-Json -AsHashtable (
        ConvertTo-Json -InputObject $Configuration.baselineKnowledgeGraph -Depth 40 -Compress
    )
    $graph.managedResources = @(@($graph.managedResources) + $scenarioState.groupId | Select-Object -Unique)
    $platform = $Configuration.baselineIncidentConfiguration
    if (-not $platform) {
        $platform = @{
            type = 'AzMonitor'
            connectionName = 'azmonitor'
            oboUser = ''
            apiConnectionName = $null
            connectionKey = ''
            connectionUrl = $null
        }
    }
    return @{ knowledgeGraph = $graph; incidentConfiguration = $platform }
}

function Assert-ServiceBusSreSharedConfiguration {
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][hashtable]$Configuration
    )
    if ($Connection.resource.properties.actionConfiguration.mode -cne 'Review') {
        throw 'The shared SRE global mode changed from Review; refusing to proceed.'
    }
    $global = Invoke-ServiceBusSreRequest $Connection GET '/api/v2/agent/settings/global'
    if ((ConvertTo-ServiceBusCanonicalJson $global.permissions) -cne
        (ConvertTo-ServiceBusCanonicalJson $Configuration.baselineGlobalPermissions)) {
        throw 'Shared SRE global tool permissions changed outside this scenario.'
    }
    $expected = Get-ServiceBusExpectedSharedConfiguration $Configuration
    if ((ConvertTo-ServiceBusCanonicalJson $Connection.resource.properties.knowledgeGraphConfiguration) -cne
        (ConvertTo-ServiceBusCanonicalJson $expected.knowledgeGraph) -or
        (ConvertTo-ServiceBusCanonicalJson $Connection.resource.properties.incidentManagementConfiguration) -cne
        (ConvertTo-ServiceBusCanonicalJson $expected.incidentConfiguration)) {
        throw 'Shared SRE scope or incident platform drifted outside the Service Bus-owned update.'
    }
}

function Get-ServiceBusSreRuntimeState {
    $configuration = Get-ServiceBusSreState
    if (-not $configuration) { throw 'Service Bus SRE connector and response plan have not been connected.' }
    $connection = Get-ServiceBusSreConnection
    if ($connection.agentId -ine $configuration.agentId) { throw 'SRE Agent resource ID changed.' }
    Assert-ServiceBusSreSharedConfiguration $connection $configuration
    $connector = Get-ServiceBusSreConnector
    if (-not (Test-ServiceBusSreConnector $connector)) {
        throw 'The exact fixed-action stdio MCP connector is missing or has drifted.'
    }
    $plan = Get-ServiceBusResponsePlan $connection
    if (-not $plan) { throw 'The owned Service Bus SRE response plan is missing.' }
    $connectivity = Invoke-ServiceBusSreRequest $connection GET '/api/v2/incidentManagement/checkConnectivityDetailed'
    $executorRuntime = Assert-ServiceBusExecutorRuntime
    $queue = $executorRuntime.queue
    $watchdogHeartbeat = $executorRuntime.watchdogHeartbeat
    $executorIdentity = Get-ServiceBusEntraIdentityStatus `
        -ScenarioState $scenarioState `
        -InvokeGraph {
            param($Method, $Path, $Body)
            Invoke-ServiceBusGraph -Method $Method -Path $Path -Body $Body
        }
    return @{
        configuration = $configuration
        connection = $connection
        connector = $connector
        plan = $plan
        connectivity = $connectivity
        globalActionMode = $connection.resource.properties.actionConfiguration.mode
        watchdogHeartbeat = $watchdogHeartbeat
        executorRuntime = $executorRuntime
        executorIdentity = $executorIdentity
        queue = $queue
    }
}

function Get-ServiceBusActionGate {
    param([Parameter()][object]$RuntimeState)
    $connectorReady = $false
    $planReady = $false
    $connectivityReady = $false
    $globalReview = $false
    $watchdogReady = $false
    $executorReady = $false
    $executorIdentityReady = $false
    $blockers = [Collections.Generic.List[string]]::new()
    if ($RuntimeState) {
        $connectorReady = Test-ServiceBusSreConnector $RuntimeState.connector
        $globalReview = $RuntimeState.globalActionMode -ceq 'Review'
        $planReady = $RuntimeState.plan.properties.agentMode -ceq 'autonomous' -and
            $RuntimeState.plan.properties.isEnabled -eq $true
        $connectivityReady = $RuntimeState.connectivity.success -eq $true -and
            $RuntimeState.connectivity.incidentType -ceq 'AzMonitor'
        $watchdogReady = [bool]($RuntimeState.watchdogHeartbeat -and
            $RuntimeState.watchdogHeartbeat.fresh)
        $executorReady = [bool]$RuntimeState.executorRuntime.ready
        $executorIdentityReady = [bool]$RuntimeState.executorIdentity.ready
    } else {
        $blockers.Add('Connect the owned fixed-action MCP connector and Azure Monitor response plan.')
    }
    if (-not $connectorReady) { $blockers.Add('The exact owned SRE MCP connector is not verified.') }
    if (-not $planReady) { $blockers.Add('The exact owned Autonomous response plan is not enabled.') }
    if (-not $connectivityReady) { $blockers.Add('SRE Azure Monitor incident-platform connectivity is not healthy.') }
    if (-not $globalReview) { $blockers.Add('The shared SRE global action mode is not Review.') }
    if (-not $watchdogReady) { $blockers.Add('The independent watchdog lacks a fresh durable success heartbeat.') }
    if (-not $executorReady) { $blockers.Add('The fixed executor and watchdog runtime are not running and indexed.') }
    if (-not $executorIdentityReady) { $blockers.Add('The owned executor audience or exact SRE application-role assignment is not verified.') }
    [pscustomobject]@{
        scenario = 'private-servicebus-send-recovery'
        environmentId = $EnvironmentName
        readiness = if ($blockers.Count -eq 0) { 'Ready' } else { 'Blocked' }
        autonomousResponsePlan = if ($planReady) { 'EnabledAndVerified' } else { 'NotArmed' }
        executor = 'FixedActionExecutor'
        executorIdentity = 'SeparateExecutorAndWatchdogSystemIdentities'
        executorRuntime = if ($executorReady) { 'RunningAndIndexed' } else { 'NotVerified' }
        executorAppRole = if ($executorIdentityReady) {
            'ExactRoleAssignmentPresentTokenRefreshUnverified'
        } else { 'NotVerified' }
        sreConnector = if ($connectorReady) { 'OwnedFixedToolVerified' } else { 'NotVerified' }
        privateEndpointCallPath = 'ConfiguredNotRuntimeProbed'
        automaticAlertTrigger = if ($connectivityReady) { 'AzureMonitorConnected' } else { 'NotConnected' }
        globalActionMode = if ($globalReview) { 'Review' } else { 'Drifted' }
        watchdog = if ($watchdogReady) { 'FreshDurableHeartbeat' } else { 'NotReady' }
        preInvocationEnforcement = $true
        blockers = @($blockers)
        nextVerification = if ($blockers.Count -eq 0) {
            'Run a bounded Service Bus fault and confirm an Azure Monitor alert routes to the exact SRE incident and fixed MCP action before its watchdog deadline.'
        } else {
            'Run Connect to provision the owned connector and disabled response plan, then Arm after private executor and Azure Monitor incident connectivity pass.'
        }
    }
}

function Get-ServiceBusDoctorResult {
    param(
        [Parameter()][hashtable]$State,
        [Parameter()][object]$Group,
        [Parameter(Mandatory)][object]$ActionGate,
        [Parameter()][object]$SreRuntime,
        [Parameter()][object]$Queue,
        [Parameter()][object]$RunnerHealth
    )
    $isReady = $false
    if ($Group -and $State -and $SreRuntime -and $Queue) {
        $isReady = $ActionGate.readiness -ceq 'Ready' -and
            $Queue.properties.status -ceq 'Active' -and
        $RunnerHealth -and $RunnerHealth.ready -eq $true -and
            $State.status -in @('Armed', 'Faulted', 'Recovered') -and
            (-not $State.currentFault -or $State.currentFault.status -notin @('Faulting', 'Faulted', 'FaultedWithRejectedSend'))
    }
    [pscustomobject]@{
        scenario = 'private-servicebus-send-recovery'
        foundation = 'Verified'
        fixture = if ($Group) { 'ManifestAndGroupVerified' } else { 'NotDeployed' }
        savedManifestStatus = if ($State) { $State.status } else { $null }
        deploymentHealth = if ($SreRuntime -and $SreRuntime.executorRuntime.ready) {
            'ExecutorRuntimeVerified'
        } else { 'NotChecked' }
        privateRunner = if ($RunnerHealth -and $RunnerHealth.ready) {
            'PrivateNetworkAndDurableStateVerified'
        } else { 'NotChecked' }
        runnerSourceSha256 = if ($RunnerHealth) { $RunnerHealth.bundleSha256 } else { $null }
        functionSourceSha256 = if ($RunnerHealth) { $RunnerHealth.functionSourceSha256 } else { $null }
        durableState = if ($RunnerHealth -and $RunnerHealth.stateDatabaseReady) {
            $RunnerHealth.database
        } else { $null }
        queueHealth = if ($Queue) { $Queue.properties.status } else { 'NotChecked' }
        ready = $isReady
        queueId = if ($State -and $State.outputs) { $State.outputs.QUEUEID } else { $null }
        sre = if ($SreRuntime) {
            @{
                globalActionMode = $SreRuntime.globalActionMode
                connector = $ActionGate.sreConnector
                responsePlan = $ActionGate.autonomousResponsePlan
                incidentPlatform = $SreRuntime.connectivity.incidentType
                incidentConnectivity = $SreRuntime.connectivity.success
                watchdogHeartbeatUtc = if ($SreRuntime.watchdogHeartbeat) {
                    $SreRuntime.watchdogHeartbeat.recordedAtUtc.ToString('o')
                } else { $null }
            }
        } else { $null }
        actionGate = $ActionGate
    }
}

function Assert-ServiceBusActionGate {
    $runtime = Get-ServiceBusSreRuntimeState
    $gate = Get-ServiceBusActionGate -RuntimeState $runtime
    if ($gate.readiness -cne 'Ready') {
        throw "Blocked at ${Operation}: the owned SRE MCP connector, enabled Autonomous response plan, Azure Monitor incident connectivity, and global Review mode must all be verified. Use Doctor for current state."
    }
}

function Get-ServiceBusSrePlanList {
    param([Parameter(Mandatory)][hashtable]$Connection)
    $plans = Invoke-ServiceBusSreRequest $Connection GET '/api/v2/incidentManagement/incidentFilters'
    if (-not $plans.ContainsKey('value') -or
        ($plans.ContainsKey('nextLink') -and $plans.nextLink)) {
        throw 'SRE response-plan list is incomplete; refusing to infer absence.'
    }
    return @($plans.value)
}

function Connect-ServiceBusSre {
    if (-not $scenarioState.outputs.QUEUEID -or
        -not $scenarioState.outputs.NAMESPACEID -or
        -not $scenarioState.outputs.SENDFAILUREALERTID -or
        -not $scenarioState.outputs.EXECUTORAPPNAME) {
        throw 'Connect requires the isolated queue, alert, and private fixed executor to be provisioned.'
    }
    $connection = Get-ServiceBusSreConnection
    if (-not $PSCmdlet.ShouldProcess(
        $connection.agentId,
        'Create the owned MCP connector and disabled Review response plan'
    )) {
        return
    }
    if (-not $scenarioState.ContainsKey('sreIntegration') -or -not $scenarioState.sreIntegration) {
        if ($connection.resource.properties.incidentManagementConfiguration -and
            $connection.resource.properties.incidentManagementConfiguration.type -cne 'AzMonitor') {
            throw 'A different SRE incident platform is already configured; refusing replacement.'
        }
        if ($scenarioState.groupId -in
            @($connection.resource.properties.knowledgeGraphConfiguration.managedResources)) {
            throw 'The scenario group already exists in SRE scope without this integration manifest.'
        }
        $global = Invoke-ServiceBusSreRequest $connection GET '/api/v2/agent/settings/global'
        $plans = Get-ServiceBusSrePlanList $connection
        if ($plans.Count) {
            throw 'Existing SRE response plans prevent safe ownership and restoration of the shared incident platform.'
        }
        $configuration = @{
            schemaVersion = 1
            ownerToken = $scenarioState.ownerToken
            agentId = $connection.agentId
            connectorName = Get-ServiceBusMcpConnectorName
            responsePlanName = Get-ServiceBusResponsePlanName
            baselineActionMode = $connection.resource.properties.actionConfiguration.mode
            baselineKnowledgeGraph = $connection.resource.properties.knowledgeGraphConfiguration
            baselineIncidentConfiguration = $connection.resource.properties.incidentManagementConfiguration
            baselineGlobalPermissions = $global.permissions
            baselineResponsePlanNames = @()
            baselineConnector = $null
            phase = 'SnapshotSaved'
            createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $scenarioState.foundationAgentId = $connection.agentId
        $scenarioState.sreIntegration = $configuration
        Save-State
    }
    $configuration = Get-ServiceBusSreState
    if ($configuration.agentId -ine $connection.agentId -or
        $configuration.baselineActionMode -cne 'Review') {
        throw 'SRE Agent identity or original Review mode does not match the saved snapshot.'
    }
    $expectedShared = Get-ServiceBusExpectedSharedConfiguration $configuration
    $currentGraph = $connection.resource.properties.knowledgeGraphConfiguration
    $currentPlatform = $connection.resource.properties.incidentManagementConfiguration
    $baselineGraph = $configuration.baselineKnowledgeGraph
    $baselinePlatform = $configuration.baselineIncidentConfiguration
    $isBaseline = (ConvertTo-ServiceBusCanonicalJson $currentGraph) -ceq
        (ConvertTo-ServiceBusCanonicalJson $baselineGraph) -and
        (ConvertTo-ServiceBusCanonicalJson $currentPlatform) -ceq
        (ConvertTo-ServiceBusCanonicalJson $baselinePlatform)
    $isConnected = (ConvertTo-ServiceBusCanonicalJson $currentGraph) -ceq
        (ConvertTo-ServiceBusCanonicalJson $expectedShared.knowledgeGraph) -and
        (ConvertTo-ServiceBusCanonicalJson $currentPlatform) -ceq
        (ConvertTo-ServiceBusCanonicalJson $expectedShared.incidentConfiguration)
    if (-not $isBaseline -and -not $isConnected) {
        throw 'SRE shared scope or incident platform changed after the baseline snapshot; refusing overwrite.'
    }
    $connector = Get-ServiceBusSreConnector
    if ($connector) {
        if (-not (Test-ServiceBusSreConnector $connector)) {
            throw 'A connector with the reserved Service Bus name exists but does not match the saved fixed-tool payload.'
        }
    } else {
        $scenarioState.sreIntegration.phase = 'ConnectorWritePending'
        Save-State
        $connectorBody = Get-ServiceBusMcpConnectorDefinition
        $connectorUrl = "https://management.azure.com$($connection.agentId)/connectors/$([uri]::EscapeDataString((Get-ServiceBusMcpConnectorName)) )?api-version=2025-05-01-preview"
        $body = $connectorBody | ConvertTo-Json -Depth 30 -Compress
        $null = Invoke-Azure @('rest', '--method', 'put', '--url', $connectorUrl, '--body', $body) -TimeoutSeconds 180
        $connector = Get-ServiceBusSreConnector
        if (-not (Test-ServiceBusSreConnector $connector)) {
            throw 'Azure did not read back the exact fixed-action stdio connector after creation.'
        }
        $scenarioState.sreIntegration.phase = 'ConnectorVerified'
        Save-State
    }
    if ($isBaseline) {
        $body = @{
            properties = @{
                knowledgeGraphConfiguration = $expectedShared.knowledgeGraph
                incidentManagementConfiguration = $expectedShared.incidentConfiguration
            }
        } | ConvertTo-Json -Depth 40 -Compress
        $null = Invoke-Azure @(
            'rest', '--method', 'patch', '--url',
            "https://management.azure.com$($connection.agentId)?api-version=2026-01-01",
            '--body', $body
        ) -TimeoutSeconds 180
    }
    $connection = Get-ServiceBusSreConnection
    Assert-ServiceBusSreSharedConfiguration $connection $configuration
    $scenarioState.sreIntegration.phase = 'PlatformConnected'
    Save-State

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $connectivity = Invoke-ServiceBusSreRequest $connection GET '/api/v2/incidentManagement/checkConnectivityDetailed'
        if ($connectivity.success -eq $true -and $connectivity.incidentType -ceq 'AzMonitor') { break }
        if ($connectivity.incidentType -cnotin @('None', 'AzMonitor')) {
            throw 'SRE incident connectivity reports a different incident platform.'
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw 'SRE Azure Monitor incident platform did not become ready before timeout; snapshot and connector remain for safe reconciliation.'
        }
        Start-Sleep -Seconds ([Math]::Min(15, [Math]::Max(1, $TimeoutSeconds)))
        $connection = Get-ServiceBusSreConnection
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $plans = Get-ServiceBusSrePlanList $connection
    $planName = Get-ServiceBusResponsePlanName
    $otherPlans = @($plans | Where-Object { $_.name -cne $planName })
    if ($otherPlans.Count) {
        throw 'Another SRE response plan appeared after the snapshot; refusing to add or restore shared configuration.'
    }
    $plan = Get-ServiceBusResponsePlan $connection
    if ($plan) {
        Assert-ServiceBusResponsePlan -Plan $plan -AgentMode review -Enabled $false
    } else {
        $scenarioState.sreIntegration.phase = 'ResponsePlanWritePending'
        Save-State
        $planBody = Get-ServiceBusExpectedResponsePlan -AgentMode review -Enabled $false
        $null = Invoke-ServiceBusSreRequest $connection PUT `
            "/api/v2/incidentManagement/incidentFilters/$([uri]::EscapeDataString($planName))" $planBody
        $plan = Get-ServiceBusResponsePlan $connection
        if (-not $plan) { throw 'The disabled Review response plan was not returned after creation.' }
        Assert-ServiceBusResponsePlan -Plan $plan -AgentMode review -Enabled $false
    }
    $scenarioState.sreIntegration.phase = 'Connected'
    $scenarioState.status = 'Connected'
    Save-State
    return [pscustomobject]@{
        status = 'Connected'
        connector = $scenarioState.sreIntegration.connectorName
        responsePlan = $scenarioState.sreIntegration.responsePlanName
        responsePlanMode = $plan.properties.agentMode
        responsePlanEnabled = $plan.properties.isEnabled
        globalActionMode = $connection.resource.properties.actionConfiguration.mode
        incidentPlatform = $connectivity.incidentType
        incidentConnectivity = $connectivity.success
    }
}

function Arm-ServiceBusSre {
    $connection = Get-ServiceBusSreConnection
    $null = Assert-ServiceBusExecutorRuntime
    if (-not $PSCmdlet.ShouldProcess(
        (Get-ServiceBusResponsePlanName),
        'Enable the owned Autonomous Service Bus response plan while preserving global Review'
    )) {
        return
    }
    $configuration = Get-ServiceBusSreState
    if (-not $configuration -or $configuration.phase -notin @('Connected', 'ArmPending', 'Armed')) {
        throw 'Connect the owned SRE connector and disabled Review response plan before arming.'
    }
    Assert-ServiceBusSreSharedConfiguration $connection $configuration
    $connector = Get-ServiceBusSreConnector
    if (-not (Test-ServiceBusSreConnector $connector)) {
        throw 'Arm requires the exact fixed-action MCP connector readback.'
    }
    $connectivity = Invoke-ServiceBusSreRequest $connection GET '/api/v2/incidentManagement/checkConnectivityDetailed'
    if ($connectivity.success -ne $true -or $connectivity.incidentType -cne 'AzMonitor') {
        throw 'Arm requires a healthy Azure Monitor SRE incident connection.'
    }
    $plan = Get-ServiceBusResponsePlan $connection
    if (-not $plan) { throw 'The owned Service Bus response plan is missing.' }
    if ($plan.properties.agentMode -ceq 'autonomous' -and $plan.properties.isEnabled -eq $true) {
        Assert-ServiceBusResponsePlan -Plan $plan -AgentMode autonomous -Enabled $true
        $scenarioState.sreIntegration.phase = 'Armed'
        $scenarioState.status = 'Armed'
        Save-State
        return [pscustomobject]@{ status = 'Armed'; globalActionMode = 'Review'; responsePlan = $plan.name }
    }
    Assert-ServiceBusResponsePlan -Plan $plan -AgentMode review -Enabled $false
    $scenarioState.sreIntegration.phase = 'ArmPending'
    $scenarioState.status = 'ArmPending'
    Save-State
    $planPath = "/api/v2/incidentManagement/incidentFilters/$([uri]::EscapeDataString((Get-ServiceBusResponsePlanName)))"
    $null = Invoke-ServiceBusSreRequest $connection PATCH $planPath @{
        name = Get-ServiceBusResponsePlanName
        type = 'IncidentFilter'
        properties = @{ agentMode = 'autonomous'; isEnabled = $true }
    }
    $plan = Get-ServiceBusResponsePlan $connection
    Assert-ServiceBusResponsePlan -Plan $plan -AgentMode autonomous -Enabled $true
    $connection = Get-ServiceBusSreConnection
    Assert-ServiceBusSreSharedConfiguration $connection $configuration
    $scenarioState.sreIntegration.phase = 'Armed'
    $scenarioState.status = 'Armed'
    Save-State
    return [pscustomobject]@{
        status = 'Armed'
        globalActionMode = $connection.resource.properties.actionConfiguration.mode
        responsePlan = $plan.name
        responsePlanMode = $plan.properties.agentMode
        enabled = $plan.properties.isEnabled
    }
}

function Disconnect-ServiceBusSre {
    $configuration = Get-ServiceBusSreState
    if (-not $configuration) { return }
    $connection = Get-ServiceBusSreConnection
    $expectedShared = Get-ServiceBusExpectedSharedConfiguration $configuration
    $isBaseline = (ConvertTo-ServiceBusCanonicalJson $connection.resource.properties.knowledgeGraphConfiguration) -ceq
        (ConvertTo-ServiceBusCanonicalJson $configuration.baselineKnowledgeGraph) -and
        (ConvertTo-ServiceBusCanonicalJson $connection.resource.properties.incidentManagementConfiguration) -ceq
        (ConvertTo-ServiceBusCanonicalJson $configuration.baselineIncidentConfiguration)
    $isConnected = (ConvertTo-ServiceBusCanonicalJson $connection.resource.properties.knowledgeGraphConfiguration) -ceq
        (ConvertTo-ServiceBusCanonicalJson $expectedShared.knowledgeGraph) -and
        (ConvertTo-ServiceBusCanonicalJson $connection.resource.properties.incidentManagementConfiguration) -ceq
        (ConvertTo-ServiceBusCanonicalJson $expectedShared.incidentConfiguration)
    if ($connection.resource.properties.actionConfiguration.mode -cne 'Review' -or
        (-not $isBaseline -and -not $isConnected)) {
        throw 'Shared SRE configuration changed outside the baseline or owned Service Bus update; refusing restoration.'
    }
    $global = Invoke-ServiceBusSreRequest $connection GET '/api/v2/agent/settings/global'
    if ((ConvertTo-ServiceBusCanonicalJson $global.permissions) -cne
        (ConvertTo-ServiceBusCanonicalJson $configuration.baselineGlobalPermissions)) {
        throw 'Shared SRE permissions changed; refusing Service Bus teardown.'
    }
    $plans = Get-ServiceBusSrePlanList $connection
    $foreignPlans = @($plans | Where-Object { $_.name -cne $configuration.responsePlanName })
    if ($foreignPlans.Count) {
        throw 'A different response plan now uses shared SRE incident settings; refusing teardown or restoration.'
    }
    $plan = Get-ServiceBusResponsePlan $connection
    if ($plan) {
        if ($plan.properties.agentMode -ceq 'autonomous') {
            Assert-ServiceBusResponsePlan -Plan $plan -AgentMode autonomous -Enabled ($plan.properties.isEnabled -eq $true)
        } else {
            Assert-ServiceBusResponsePlan -Plan $plan -AgentMode review -Enabled ($plan.properties.isEnabled -eq $true)
        }
    }
    $connector = Get-ServiceBusSreConnector
    if ($connector -and -not (Test-ServiceBusSreConnector $connector)) {
        throw 'The SRE MCP connector changed outside this scenario; refusing to delete it.'
    }
    if ($plan) {
        $null = Invoke-ServiceBusSreRequest $connection DELETE `
            "/api/v2/incidentManagement/incidentFilters/$([uri]::EscapeDataString($configuration.responsePlanName))"
        if (Get-ServiceBusResponsePlan $connection) { throw 'Owned SRE response plan remains after deletion.' }
    }
    if ($connector) {
        $connectorPath = "https://management.azure.com$($configuration.agentId)/connectors/$([uri]::EscapeDataString($configuration.connectorName))?api-version=2025-05-01-preview"
        $null = Invoke-Azure @('rest', '--method', 'delete', '--url', $connectorPath) -TimeoutSeconds 180
        if (Get-ServiceBusSreConnector) { throw 'Owned SRE MCP connector remains after deletion.' }
    }
    if ($isConnected) {
        $connection = Get-ServiceBusSreConnection
        Assert-ServiceBusSreSharedConfiguration $connection $configuration
        $body = @{
            properties = @{
                knowledgeGraphConfiguration = $configuration.baselineKnowledgeGraph
                incidentManagementConfiguration = $configuration.baselineIncidentConfiguration
            }
        } | ConvertTo-Json -Depth 40 -Compress
        $null = Invoke-Azure @(
            'rest', '--method', 'patch', '--url',
            "https://management.azure.com$($configuration.agentId)?api-version=2026-01-01",
            '--body', $body
        ) -TimeoutSeconds 180
    }
    $restored = Get-ServiceBusSreConnection
    if ((ConvertTo-ServiceBusCanonicalJson $restored.resource.properties.knowledgeGraphConfiguration) -cne
        (ConvertTo-ServiceBusCanonicalJson $configuration.baselineKnowledgeGraph) -or
        (ConvertTo-ServiceBusCanonicalJson $restored.resource.properties.incidentManagementConfiguration) -cne
        (ConvertTo-ServiceBusCanonicalJson $configuration.baselineIncidentConfiguration) -or
        $restored.resource.properties.actionConfiguration.mode -cne 'Review') {
        throw 'SRE shared configuration did not restore to its exact snapshot.'
    }
    $scenarioState.sreIntegration.phase = 'Removed'
    $scenarioState.status = 'SreDisconnected'
    Save-State
}

function Get-ServiceBusQueueSnapshot {
    if (-not $scenarioState.outputs.QUEUEID -or -not $scenarioState.outputs.RUNNERVMNAME) {
        throw 'The ownership manifest has no exact queue resource ID.'
    }
    if ($Operation -ceq 'Down' -and
        (-not $scenarioState.ContainsKey('currentFault') -or -not $scenarioState.currentFault)) {
        $url = "https://management.azure.com$($scenarioState.outputs.QUEUEID)?api-version=2024-01-01"
        $queue = Invoke-Azure @('rest', '--method', 'get', '--url', $url)
        if ($queue.id -ine $scenarioState.outputs.QUEUEID) {
            throw 'ARM returned a queue outside the exact partial-teardown manifest.'
        }
        return $queue
    }
    $snapshot = Invoke-ServiceBusRunnerCommand -Action state -CommandTimeoutSeconds 180
    $queue = $snapshot.queue
    if ($queue.id -ine $scenarioState.outputs.QUEUEID) {
        throw 'The private runner returned a queue outside the exact ownership manifest.'
    }
    $queue.coordination = $snapshot.coordination
    $queue.coordinationEtag = $snapshot.coordinationEtag
    return $queue
}

function ConvertFrom-ServiceBusFaultMarker {
    param([Parameter(Mandatory)][object]$Queue)
    $coordination = $Queue.coordination
    if (-not $coordination -or
        $coordination.contract -cne 'retailtx-servicebus-coordination-v1' -or
        $coordination.ownerToken -ine $scenarioState.ownerToken -or
        $coordination.environmentName -cne $EnvironmentName -or
        $coordination.queueResourceId -ine $scenarioState.outputs.QUEUEID) {
        throw 'Private coordination state does not match the exact scenario owner, environment, and queue.'
    }
    $run = $coordination.currentRun
    if (-not $run) { return $null }
    if ($run.contract -cne 'retailtx-servicebus-fault-v1' -or
        $run.ownerToken -ine $scenarioState.ownerToken -or
        $run.environmentName -cne $EnvironmentName -or
        $run.queueResourceId -ine $scenarioState.outputs.QUEUEID -or
        -not $run.runId -or -not $run.deadlineUtc -or
        $run.state -notin @('FaultIntent', 'Faulted', 'RecoveryIntent', 'Recovered', 'FaultNotApplied')) {
        throw 'Private coordination state contains a foreign or malformed fault run.'
    }
    return $run
}

function Get-ServiceBusWatchdogHeartbeat {
    param([Parameter(Mandatory)][object]$Queue)
    $coordination = $Queue.coordination
    if (-not $coordination -or
        $coordination.ownerToken -ine $scenarioState.ownerToken -or
        $coordination.environmentName -cne $EnvironmentName -or
        $coordination.queueResourceId -ine $scenarioState.outputs.QUEUEID -or
        -not $coordination.watchdogHeartbeatSuccess -or
        -not $coordination.watchdogHeartbeatUtc -or
        $coordination.watchdogQueueStatus -cne $Queue.properties.status) {
        return $null
    }
    try {
        $recorded = [DateTimeOffset]::Parse($coordination.watchdogHeartbeatUtc).ToUniversalTime()
    } catch {
        throw 'Watchdog heartbeat timestamp is invalid.'
    }
    $now = [DateTimeOffset]::UtcNow
    if ($recorded -gt $now.AddSeconds(30)) { throw 'Watchdog heartbeat is future-dated.' }
    return [pscustomobject]@{
        recordedAtUtc = $recorded
        ageSeconds = [Math]::Max(0, ($now - $recorded).TotalSeconds)
        fresh = ($now - $recorded) -le [TimeSpan]::FromMinutes(3)
        markerContract = $coordination.contract
        markerState = if ($coordination.currentRun) { $coordination.currentRun.state } else { 'Healthy' }
        coordinationEtag = $Queue.coordinationEtag
    }
}

function Assert-ServiceBusWatchdogHeartbeat {
    param([Parameter(Mandatory)][object]$Queue)
    $heartbeat = Get-ServiceBusWatchdogHeartbeat $Queue
    if (-not $heartbeat -or -not $heartbeat.fresh) {
        throw 'The independent watchdog has no fresh durable success heartbeat; refusing a fault or autonomous arm.'
    }
    if ($Queue.properties.status -cnotin @('Active', 'SendDisabled')) {
        throw 'The independent watchdog queue preflight found an unexpected queue status.'
    }
    return $heartbeat
}

function Assert-ServiceBusExecutorRuntime {
    if (-not $scenarioState.outputs.EXECUTORAPPNAME -or
        -not $scenarioState.outputs.WATCHDOGAPPNAME -or
        -not $scenarioState.outputs.EXECUTORVNETID) {
        throw 'The private executor and independent watchdog have not been provisioned.'
    }
    $identityStatus = Get-ServiceBusEntraIdentityStatus `
        -ScenarioState $scenarioState `
        -InvokeGraph {
            param($Method, $Path, $Body)
            Invoke-ServiceBusGraph -Method $Method -Path $Path -Body $Body
        }
    if (-not $identityStatus.ready) {
        throw "The executor app role is not ready ($($identityStatus.status)); refusing autonomous arm or queue fault."
    }
    foreach ($functionAppId in @(
        $scenarioState.outputs.EXECUTORAPPID,
        $scenarioState.outputs.WATCHDOGAPPID
    )) {
        $authSettingsId = "$functionAppId/config/authsettingsV2"
        $authSettings = Invoke-Azure @(
            'resource', 'show', '--ids', $authSettingsId, '--api-version', '2022-09-01'
        )
        if ($authSettings.id -ine $authSettingsId) {
            throw 'Function App Easy Auth readback returned a different resource.'
        }
        Assert-ServiceBusEasyAuthBinding -Configuration $authSettings `
            -ExpectedAudience $scenarioState.executorAudience `
            -ExpectedApplicationId $scenarioState.sreClientAppId
    }
    $group = Get-OwnedScenarioGroup
    if (-not $group) { throw 'The exact Service Bus resource group is absent.' }
    $executor = Invoke-Azure @(
        'functionapp', 'show', '--resource-group', $groupName,
        '--name', $scenarioState.outputs.EXECUTORAPPNAME
    )
    $watchdog = Invoke-Azure @(
        'functionapp', 'show', '--resource-group', $groupName,
        '--name', $scenarioState.outputs.WATCHDOGAPPNAME
    )
    if ($executor.state -cne 'Running' -or $watchdog.state -cne 'Running') {
        throw 'Both fixed executor and watchdog Function Apps must be Running before a fault.'
    }
    $executorFunctions = @(Invoke-Azure @(
        'functionapp', 'function', 'list', '--resource-group', $groupName,
        '--name', $scenarioState.outputs.EXECUTORAPPNAME
    ))
    $watchdogFunctions = @(Invoke-Azure @(
        'functionapp', 'function', 'list', '--resource-group', $groupName,
        '--name', $scenarioState.outputs.WATCHDOGAPPNAME
    ))
    if (@($executorFunctions | Where-Object { $_.name -match '/restore$' }).Count -eq 0 -or
        @($watchdogFunctions | Where-Object { $_.name -match '/watchdog$' }).Count -eq 0) {
        throw 'The deployed fixed restore tool or independent watchdog function is not indexed.'
    }
    $queue = Get-ServiceBusQueueSnapshot
    $heartbeat = Assert-ServiceBusWatchdogHeartbeat -Queue $queue
    return @{
        ready = $true
        executorState = $executor.state
        watchdogState = $watchdog.state
        executorFunctionCount = $executorFunctions.Count
        watchdogFunctionCount = $watchdogFunctions.Count
        watchdogHeartbeat = $heartbeat
        queue = $queue
    }
}

function Invoke-ServiceBusProbe {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('health', 'seed', 'send', 'receive', 'verify')]
        [string]$ProbeOperation,
        [Parameter()][string]$TransactionId,
        [Parameter()][ValidateRange(1, 10)][int]$MaxMessages = 10
    )
    $arguments = @{ operation = $ProbeOperation }
    if ($ProbeOperation -in @('send', 'verify')) {
        if ($TransactionId -notmatch '^[0-9a-fA-F-]{36}$') {
            throw "Probe operation '$ProbeOperation' requires the durable transaction UUID."
        }
        $arguments.transactionId = [guid]::Parse($TransactionId).ToString()
    }
    if ($ProbeOperation -eq 'receive') {
        $arguments.maxMessages = $MaxMessages
    }
    return Invoke-ServiceBusRunnerCommand -Action probe -Arguments $arguments `
        -CommandTimeoutSeconds 180
}

function Invoke-ServiceBusFault {
    Assert-ServiceBusActionGate
    $null = Assert-ServiceBusRunnerHealth
    $queue = Get-ServiceBusQueueSnapshot
    $null = Assert-ServiceBusExecutorRuntime
    $heartbeat = Assert-ServiceBusWatchdogHeartbeat -Queue $queue
    $oldMarker = ConvertFrom-ServiceBusFaultMarker -Queue $queue
    if ($queue.properties.status -cne 'Active' -or
        ($oldMarker -and $oldMarker.state -cne 'Recovered')) {
        throw 'Fault requires the exact owned queue to be Active with no prior live fault.'
    }
    $transaction = Invoke-ServiceBusProbe -ProbeOperation seed
    if ($transaction.exitCode -ne 0 -or -not $transaction.result.transactionId) {
        throw 'Could not durably seed the retry-safe transaction before the fault; no queue mutation was attempted.'
    }
    $runId = [guid]::NewGuid().ToString()
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes($FaultDurationMinutes)
    $scenarioState.currentFault = @{
        runId = $runId
        transactionId = $transaction.result.transactionId
        deadlineUtc = $deadline.ToString('o')
        status = 'Faulting'
        sendFailureObserved = $false
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if (-not $PSCmdlet.ShouldProcess($scenarioState.outputs.QUEUEID, 'Disable sends until the independent watchdog deadline')) {
        return
    }
    Save-State
    $fault = Invoke-ServiceBusRunnerCommand -Action fault -Arguments @{
        transactionId = $transaction.result.transactionId
        faultRunId = $runId
        deadlineUtc = $deadline.ToString('o')
    } -CommandTimeoutSeconds 180
    if ($fault.status -cne 'Faulted' -or
        $fault.faultRunId -cne $runId -or
        $fault.transactionId -cne $transaction.result.transactionId -or
        $fault.queueId -ine $scenarioState.outputs.QUEUEID) {
        throw 'Private runner did not confirm the exact single fault attempt; durable deadline cleanup remains responsible.'
    }
    $faulted = Get-ServiceBusQueueSnapshot
    $faultMarker = ConvertFrom-ServiceBusFaultMarker -Queue $faulted
    if ($faulted.properties.status -cne 'SendDisabled' -or
        $faultMarker.runId -cne $runId -or
        $faultMarker.state -cne 'Faulted' -or
        $faultMarker.deadlineUtc -cne $deadline.ToString('o') -or
        $faultMarker.transactionId -cne $transaction.result.transactionId) {
        throw 'ARM status readback or leased coordination state did not confirm the exact SendDisabled run; the independent watchdog remains responsible for cleanup.'
    }
    $scenarioState.currentFault.status = 'Faulted'
    Save-State

    $send = Invoke-ServiceBusProbe -ProbeOperation send `
        -TransactionId $transaction.result.transactionId
    $queueAfterSend = Get-ServiceBusQueueSnapshot
    $markerAfterSend = ConvertFrom-ServiceBusFaultMarker -Queue $queueAfterSend
    if ($send.exitCode -ne 3 -or $send.result.state -cne 'pending' -or
        $send.result.accepted -or $queueAfterSend.properties.status -cne 'SendDisabled' -or
        $markerAfterSend.runId -cne $runId) {
        $scenarioState.currentFault.status = 'SendFailureNotVerified'
        Save-State
        throw 'The private sender did not provide an expected rejected-send result against the verified SendDisabled queue. The watchdog remains active.'
    }
    $scenarioState.currentFault.sendFailureObserved = $true
    $scenarioState.currentFault.status = 'FaultedWithRejectedSend'
    $scenarioState.currentFault.sendErrorType = $send.result.errorType
    Save-State
    return [pscustomobject]@{
        status = $scenarioState.currentFault.status
        faultRunId = $runId
        transactionId = $transaction.result.transactionId
        deadlineUtc = $deadline.ToString('o')
        queueStatus = $queueAfterSend.properties.status
        sendFailureObserved = $true
        alertId = $scenarioState.outputs.SENDFAILUREALERTID
        sreIncident = 'NotVerified'
    }
}

function Invoke-ServiceBusIncidentObservation {
    Assert-ServiceBusActionGate
    if (-not $scenarioState.currentFault -or
        $scenarioState.currentFault.status -notin @(
            'FaultedWithRejectedSend', 'SreRecoveredAndPosted'
        ) -or -not $scenarioState.currentFault.createdAt) {
        throw 'Incident requires the durable current fault run and verified rejected sender result.'
    }
    $faultAt = [DateTimeOffset]::Parse($scenarioState.currentFault.createdAt).ToUniversalTime()
    $now = [DateTimeOffset]::UtcNow
    if ($faultAt -gt $now -or $faultAt -lt $now.AddDays(-1)) {
        throw 'Incident discovery requires a fault created within the last 24 hours.'
    }
    $connection = Get-ServiceBusSreConnection
    $alertListUrl = 'https://management.azure.com/subscriptions/{0}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01&targetResource={1}&timeRange=1d&pageCount=100' -f `
        $subscription, [uri]::EscapeDataString($scenarioState.outputs.NAMESPACEID)
    $alertList = Invoke-Azure @('rest', '--method', 'get', '--url', $alertListUrl)
    if (-not $alertList.ContainsKey('value') -or
        ($alertList.ContainsKey('nextLink') -and $alertList.nextLink) -or
        @($alertList.value).Count -gt 100) {
        throw 'Azure Monitor alert discovery is incomplete; refusing to infer an incident is absent.'
    }
    $matches = @(
        foreach ($candidate in $alertList.value) {
            $essentials = $candidate.properties.essentials
            if (Test-ServiceBusAlertEssentials -Essentials $essentials `
                -ExpectedTargetId $scenarioState.outputs.NAMESPACEID `
                -ExpectedRuleId $scenarioState.outputs.SENDFAILUREALERTID `
                -FaultAt $faultAt) {
                $candidate
            }
        }
    )
    if ($matches.Count -gt 1) {
        throw 'Multiple Azure alerts match the exact current Service Bus fault; refusing to choose one.'
    }
    if (-not $matches.Count) {
        return [pscustomobject]@{
            status = 'AwaitingAzureMonitorAlert'
            faultRunId = $scenarioState.currentFault.runId
            alertId = $null
            incidentId = $null
            threadId = $null
        }
    }
    $candidate = $matches[0]
    $alertGuid = [guid]::Parse(($candidate.id -split '/')[-1]).ToString()
    $expectedAlertId = "$($scenarioState.outputs.NAMESPACEID)/providers/Microsoft.AlertsManagement/alerts/$alertGuid"
    if ($candidate.id -ine $expectedAlertId) {
        throw 'Alert list returned an ID outside the exact Service Bus namespace.'
    }
    $alert = Invoke-Azure @(
        'rest', '--method', 'get', '--url',
        "https://management.azure.com${expectedAlertId}?api-version=2019-05-05-preview"
    )
    $essentials = $alert.properties.essentials
    if ($alert.id -ine $expectedAlertId -or
        -not (Test-ServiceBusAlertEssentials -Essentials $essentials `
            -ExpectedTargetId $scenarioState.outputs.NAMESPACEID `
            -ExpectedRuleId $scenarioState.outputs.SENDFAILUREALERTID `
            -FaultAt $faultAt) -or
        $essentials.monitorCondition -cnotin @('Fired', 'Resolved')) {
        throw 'The individual Azure alert does not match the exact fault or a known monitor condition.'
    }
    $incident = Invoke-ServiceBusSreRequest $connection GET `
        "/api/v2/incidentManagement/incidents?incidentId=$alertGuid" -AllowMissing
    if ($incident -and (
        $incident.id -ine $alertGuid -or
        $incident.alertId -ine $expectedAlertId -or
        $incident.targetResourceId -ine $scenarioState.outputs.NAMESPACEID -or
        $incident.alertRuleResourceId -ine $scenarioState.outputs.SENDFAILUREALERTID -or
        -not $incident.createdAt -or
        [DateTimeOffset]::Parse($incident.createdAt).ToUniversalTime() -lt $faultAt
    )) {
        throw 'SRE incident does not link to the exact Azure alert, namespace, and fault window.'
    }
    if ($incident -and $incident.threadId) { $null = [guid]::Parse($incident.threadId) }
    return [pscustomobject]@{
        status = if ($incident) { 'IncidentFound' } else { 'AwaitingSreIncident' }
        faultRunId = $scenarioState.currentFault.runId
        alertId = $alert.id
        monitorCondition = $essentials.monitorCondition
        resolvedAt = $essentials.monitorConditionResolvedDateTime
        incidentId = if ($incident) { $incident.id } else { $null }
        incidentStatus = if ($incident) { $incident.status } else { $null }
        acknowledgementState = if ($incident) { $incident.acknowledgementState } else { $null }
        threadId = if ($incident) { $incident.threadId } else { $null }
    }
}

function Invoke-ServiceBusRecover {
    Assert-ServiceBusExecutorRuntime
    if (-not $scenarioState.currentFault -or
        -not $scenarioState.currentFault.sendFailureObserved) {
        throw 'Recover requires a durable fault run with a verified real sender rejection.'
    }
    $deadline = [DateTimeOffset]::Parse($scenarioState.currentFault.deadlineUtc).ToUniversalTime()
    $watchUntil = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $watchUntil) {
        $queue = Get-ServiceBusQueueSnapshot
        $marker = ConvertFrom-ServiceBusFaultMarker -Queue $queue
        if ($marker.runId -cne $scenarioState.currentFault.runId) {
            throw 'Queue fault run changed while observing recovery.'
        }
        if ($marker.state -ceq 'Recovered') {
            if ($marker.recoveryMechanism -cne 'sre-fixed-tool' -or
                $marker.initiatingPrincipalObjectId -ine $scenarioState.srePrincipalObjectId) {
                throw 'The independent watchdog or another actor recovered the queue; this is not SRE recovery evidence.'
            }
            if ([DateTimeOffset]::Parse($marker.recoveredAtUtc).ToUniversalTime() -ge $deadline) {
                throw 'The queue was recovered at or after the watchdog deadline; autonomous SRE recovery is not proven.'
            }
            if ($queue.properties.status -cne 'Active') {
                throw 'The executor recorded recovery but the exact queue is not Active.'
            }
            $send = Invoke-ServiceBusProbe -ProbeOperation send `
                -TransactionId $scenarioState.currentFault.transactionId
            if ($send.exitCode -ne 0 -or
                $send.result.transactionId -cne $scenarioState.currentFault.transactionId -or
                $send.result.state -cne 'accepted') {
                throw 'The stable outbox retry was not accepted after SRE fixed-tool recovery.'
            }
            $received = Invoke-ServiceBusProbe -ProbeOperation receive -MaxMessages 10
            if ($received.exitCode -ne 0 -or
                $received.result.completed -lt 1 -or
                $received.result.duplicateDeliveries -ne 0) {
                throw 'The receiver did not confirm one non-duplicate delivery after recovery.'
            }
            $posted = Invoke-ServiceBusProbe -ProbeOperation verify `
                -TransactionId $scenarioState.currentFault.transactionId
            if ($posted.exitCode -ne 0 -or
                $posted.result.state -cne 'posted' -or
                $posted.result.postedCount -ne 1) {
                throw 'The durable ledger did not prove exactly one posting for the stable transaction.'
            }
            $scenarioState.currentFault.status = 'SreRecoveredAndPosted'
            $scenarioState.currentFault.recoveryMechanism = $marker.recoveryMechanism
            $scenarioState.currentFault.initiatingPrincipalObjectId = $marker.initiatingPrincipalObjectId
            $scenarioState.currentFault.postedCount = $posted.result.postedCount
            $scenarioState.currentFault.recoveredAtUtc = $marker.recoveredAtUtc
            Save-State
            return [pscustomobject]@{
                status = $scenarioState.currentFault.status
                faultRunId = $marker.runId
                transactionId = $posted.result.transactionId
                queueStatus = $queue.properties.status
                recoveryMechanism = $marker.recoveryMechanism
                initiatingPrincipalObjectId = $marker.initiatingPrincipalObjectId
                postedCount = $posted.result.postedCount
                payloadHash = $posted.result.payloadHash
            }
        }
        if ($marker.state -cne 'Faulted' -or $queue.properties.status -cne 'SendDisabled') {
            throw 'Queue status and durable run marker no longer match the active fault.'
        }
        Start-Sleep -Seconds 5
    }
    throw "No SRE fixed-tool recovery was observed within $TimeoutSeconds seconds. The independent deadline watchdog remains active; use Doctor and do not call the incident autonomous."
}

function Invoke-ServiceBusReset {
    Assert-ServiceBusExecutorRuntime
    $queue = Get-ServiceBusQueueSnapshot
    $marker = ConvertFrom-ServiceBusFaultMarker -Queue $queue
    if ($queue.properties.status -cne 'Active' -or
        -not $marker -or $marker.state -cne 'Recovered') {
        throw 'Reset is read-only and requires the exact owned queue to be Active with a completed durable run marker.'
    }
    $scenarioState.status = 'ResetVerified'
    $scenarioState.currentFault.status = 'ResetVerified'
    $scenarioState.resetAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Save-State
    return [pscustomobject]@{
        status = 'ResetVerified'
        queueId = $scenarioState.outputs.QUEUEID
        queueStatus = $queue.properties.status
        recoveryMechanism = $marker.recoveryMechanism
        faultRunId = $marker.runId
    }
}

function Invoke-ServiceBusUp {
    $bundle = New-ServiceBusRunnerBundle
    $initialFoundation = Get-VerifiedFoundation
    $script:sharedDnsLock = Enter-ServiceBusFoundationDnsLock -VirtualNetworkId $initialFoundation.virtualNetworkId
    $foundation = Get-VerifiedFoundation
    if ($foundation.virtualNetworkId -ine $initialFoundation.virtualNetworkId) {
        throw 'The retained Stage 0 VNet changed while acquiring its shared DNS lock.'
    }
    $agent = Invoke-Azure @(
        'resource', 'show', '--ids', $initialFoundation.state.outputs.SRE_AGENT_ID,
        '--api-version', '2026-01-01'
    )
    if ($agent.id -ine $initialFoundation.state.outputs.SRE_AGENT_ID -or
        $agent.type -ine 'Microsoft.App/agents' -or
        $agent.properties.actionConfiguration.mode -cne 'Review') {
        throw 'The retained SRE Agent identity, type, or global Review mode is invalid.'
    }
    $sreIdentity = Get-ServiceBusSreConnectorIdentity -Resource $agent -InvokeGraph {
        param($Method, $Path, $Body)
        Invoke-ServiceBusGraph -Method $Method -Path $Path -Body $Body
    }
    $sreClientId = [guid]::Parse($sreIdentity.clientId).ToString()
    $sreObjectId = [guid]::Parse($sreIdentity.principalId).ToString()
    if (($SreClientAppId -and $SreClientAppId -ine $sreClientId) -or
        ($SrePrincipalObjectId -and $SrePrincipalObjectId -ine $sreObjectId)) {
        throw 'Explicit SRE managed-identity IDs differ from the retained Agent identity.'
    }
    if ($ExecutorAudience -and $ExecutorAudience -notmatch '^api://[0-9a-fA-F-]{36}$') {
        throw 'An explicit executor audience must be an executor-specific api:// GUID, never an Azure management audience.'
    }
    Assert-ServiceBusPrivateDnsOwnership
    if ($scenarioState) {
        if ($scenarioState.tenantId -ine $foundation.tenantId -or
            $scenarioState.runnerBundleSha256 -cne $bundle.BundleSha256 -or
            $scenarioState.runnerBundleSourceSha256 -cne $bundle.BundleSourceSha256 -or
            $scenarioState.functionSourceSha256 -cne $bundle.FunctionSourceSha256 -or
            ($ExecutorAudience -and $scenarioState.executorAudience -cne $ExecutorAudience) -or
            ($scenarioState.sreClientAppId -and $scenarioState.sreClientAppId -ine $sreClientId) -or
            ($scenarioState.srePrincipalObjectId -and $scenarioState.srePrincipalObjectId -ine $sreObjectId) -or
            ($scenarioState.foundationVirtualNetworkId -and
             $scenarioState.foundationVirtualNetworkId -ine $foundation.virtualNetworkId)) {
            throw 'Existing Service Bus manifest tenant, source attestation, runner key, executor identity, or foundation VNet changed. Do not overwrite the attestation; reconcile or Down the exact owned fixture before creating a fresh manifest.'
        }
        $null = Get-ServiceBusRunnerSshPublicKey -State $scenarioState
        $scenarioState.foundationVirtualNetworkId = $foundation.virtualNetworkId
        $scenarioState.sreClientAppId = $sreClientId
        $scenarioState.srePrincipalObjectId = $sreObjectId
    } else {
        if (Invoke-Azure @('group', 'exists', '--name', $groupName)) {
            throw 'A resource group exists without this local manifest. Refusing to adopt it.'
        }
        $ownerToken = [guid]::NewGuid()
        $script:scenarioState = @{
            schemaVersion = 1
            profile = 'servicebus-scenario'
            subscriptionId = $subscription
            tenantId = $foundation.tenantId
            environmentName = $EnvironmentName
            foundationEnvironment = $FoundationEnvironment
            foundationVirtualNetworkId = $foundation.virtualNetworkId
            executorAudience = $null
            sreClientAppId = $sreClientId
            srePrincipalObjectId = $sreObjectId
            groupName = $groupName
            groupId = "/subscriptions/$subscription/resourceGroups/$groupName"
            ownerToken = $ownerToken.ToString()
            runnerBundleSha256 = $bundle.BundleSha256
            runnerBundleSourceSha256 = $bundle.BundleSourceSha256
            functionSourceSha256 = $bundle.FunctionSourceSha256
            createdAt = [DateTimeOffset]::UtcNow.ToString('o')
            expiresAt = [DateTimeOffset]::UtcNow.AddHours(24).ToString('o')
            status = 'Provisioning'
        }
        $null = Get-ServiceBusRunnerSshPublicKey -State $scenarioState
    }
    $null = Assert-ServiceBusFoundationPeeringOwnership

    if (-not $PSCmdlet.ShouldProcess($scenarioState.groupId, 'Create private Service Bus probe runner and recovery fixture')) {
        return
    }
    Save-State
    $graphInvoker = {
        param($Method, $Path, $Body)
        Invoke-ServiceBusGraph -Method $Method -Path $Path -Body $Body
    }
    $saveIdentityState = { Save-State }
    $identity = Set-ServiceBusEntraIdentity `
        -ScenarioState $scenarioState `
        -EnvironmentName $EnvironmentName `
        -SrePrincipalObjectId $sreObjectId `
        -InvokeGraph $graphInvoker `
        -SaveState $saveIdentityState
    if ($ExecutorAudience -and $identity.identifierUri -cne $ExecutorAudience) {
        throw 'The caller-supplied executor audience differs from the exact owned Entra app registration.'
    }
    $scenarioState.executorAudience = $identity.identifierUri
    $scenarioState.sreClientAppId = $sreClientId
    $scenarioState.srePrincipalObjectId = $sreObjectId
    Save-State

    $group = Get-OwnedScenarioGroup
    if (-not $group) {
        $null = Invoke-Azure @(
            'group', 'create', '--name', $groupName, '--location', 'swedencentral', '--tags',
            'demo=retailtx', "environmentId=$EnvironmentName", 'profile=servicebus',
            "ownerToken=$($scenarioState.ownerToken)", 'managedBy=retailtx',
            "expiresAt=$($scenarioState.expiresAt)"
        ) -TimeoutSeconds 120
        $group = Get-OwnedScenarioGroup
    }
    if (-not $group) { throw 'The owned scenario group was not created.' }

    $template = Join-Path $repositoryRoot 'infra\servicebus-scenario.bicep'
    $deployment = Invoke-Azure @(
        'deployment', 'group', 'create', '--resource-group', $groupName,
        '--name', 'servicebus-scenario', '--template-file', $template, '--parameters',
        "environmentName=$EnvironmentName", "ownerToken=$($scenarioState.ownerToken)",
        "expiresAt=$($scenarioState.expiresAt)",
        "privateEndpointSubnetId=$($foundation.privateEndpointSubnetId)",
        "virtualNetworkId=$($foundation.virtualNetworkId)",
        'location=swedencentral'
    ) -TimeoutSeconds 1800
    if ($deployment.properties.provisioningState -cne 'Succeeded') {
        throw 'Service Bus deployment did not complete successfully; retained manifest is required for safe reconciliation or Down.'
    }
    $outputs = ConvertFrom-RetailDeploymentOutputs $deployment.properties.outputs
    $expectedQueueId = "$($scenarioState.groupId)/providers/Microsoft.ServiceBus/namespaces/$($outputs.NAMESPACENAME)/queues/$($outputs.QUEUENAME)"
    if ($outputs.QUEUEID -ine $expectedQueueId) {
        throw 'Deployment outputs do not match the expected isolated namespace and queue.'
    }
    $scenarioState.outputs = $outputs
    $scenarioState.status = 'ServiceBusProvisioned'
    $scenarioState.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Save-State

    $bootstrapScript = New-ServiceBusRunnerBootstrapScript -Bundle $bundle
    $bootstrapPath = Join-Path $directory 'servicebus-runner-bootstrap.sh'
    if (Test-Path -LiteralPath $bootstrapPath -PathType Leaf) {
        $priorBootstrap = Get-Content -LiteralPath $bootstrapPath -Raw
        if (-not $priorBootstrap.Contains($scenarioState.ownerToken)) {
            throw 'A bootstrap parameter file exists with a different owner token; refusing to replace it.'
        }
    }
    Set-Content -LiteralPath $bootstrapPath -Value $bootstrapScript -Encoding utf8NoBOM -NoNewline
    $executorTemplate = Join-Path $repositoryRoot 'infra\servicebus-executor.bicep'
    $executorDeployment = Invoke-Azure @(
        'deployment', 'group', 'create', '--resource-group', $groupName,
        '--name', 'servicebus-executor', '--template-file', $executorTemplate, '--parameters',
        "environmentName=$EnvironmentName", "ownerToken=$($scenarioState.ownerToken)",
        "expiresAt=$($scenarioState.expiresAt)", "queueResourceId=$($outputs.QUEUEID)",
        "queueResourceName=$($outputs.NAMESPACENAME)/$($outputs.QUEUENAME)",
        "foundationVirtualNetworkId=$($foundation.virtualNetworkId)",
        "foundationResourceGroupName=$foundationGroupName",
        "foundationVirtualNetworkName=vnet-retailtx-$FoundationEnvironment",
        "tenantId=$($foundation.tenantId)", "executorAudience=$($scenarioState.executorAudience)",
        "sreClientAppId=$($scenarioState.sreClientAppId)",
        "srePrincipalObjectId=$($scenarioState.srePrincipalObjectId)",
        "runnerSshPublicKey=$($scenarioState.runnerSshPublicKey)",
        "runnerBootstrapScript=@$bootstrapPath",
        'location=swedencentral'
    ) -TimeoutSeconds 1800
    if ($executorDeployment.properties.provisioningState -cne 'Succeeded') {
        throw 'Executor infrastructure deployment did not succeed; the manifest is retained for reconciliation or Down.'
    }
    $executorOutputs = ConvertFrom-RetailDeploymentOutputs $executorDeployment.properties.outputs
    $runnerQueueRoleIds = @($executorOutputs.RUNNERQUEUEROLEASSIGNMENTIDS)
    if ($executorOutputs.EXECUTORAPPID -notlike "$($scenarioState.groupId)/providers/Microsoft.Web/sites/func-sb-exec-$EnvironmentName-*" -or
        $executorOutputs.WATCHDOGAPPID -notlike "$($scenarioState.groupId)/providers/Microsoft.Web/sites/func-sb-watch-$EnvironmentName-*" -or
        $executorOutputs.EXECUTORVNETID -cne (Get-ServiceBusExecutorVirtualNetworkId) -or
        $executorOutputs.RUNNERVMID -cne "$($scenarioState.groupId)/providers/Microsoft.Compute/virtualMachines/vm-sb-runner-$EnvironmentName" -or
        $executorOutputs.RUNNERVMNAME -cne "vm-sb-runner-$EnvironmentName" -or
        $executorOutputs.RUNNERIDENTITYPRINCIPALID -notmatch '^[0-9a-fA-F-]{36}$' -or
        $executorOutputs.RUNNERIDENTITYPRINCIPALID -ieq $scenarioState.srePrincipalObjectId -or
        $executorOutputs.COORDINATIONCONTAINERNAME -cne 'scenario-coordination' -or
        $executorOutputs.COORDINATIONBLOBNAME -cne 'scenario-state.json' -or
        $executorOutputs.COORDINATIONCONTAINERID -notlike (
            "$($scenarioState.groupId)/providers/Microsoft.Storage/storageAccounts/" +
            "$($executorOutputs.HOSTSTORAGENAME)/blobServices/default/containers/scenario-coordination"
        ) -or
        $runnerQueueRoleIds.Count -ne 2 -or
        @($runnerQueueRoleIds | Where-Object {
            $_ -notlike "$expectedQueueId/providers/Microsoft.Authorization/roleAssignments/*"
        }).Count -gt 0 -or
        $executorOutputs.RUNNEREXECUTERPUBLISHROLEASSIGNMENTID -notlike "$($executorOutputs.EXECUTORAPPID)/providers/Microsoft.Authorization/roleAssignments/*" -or
        $executorOutputs.RUNNERWATCHDOGPUBLISHROLEASSIGNMENTID -notlike "$($executorOutputs.WATCHDOGAPPID)/providers/Microsoft.Authorization/roleAssignments/*" -or
        $executorOutputs.RUNNERCOORDINATIONBLOBROLEASSIGNMENTID -notlike "$($executorOutputs.COORDINATIONCONTAINERID)/providers/Microsoft.Authorization/roleAssignments/*" -or
        $executorOutputs.EXECUTORQUEUEROLEASSIGNMENTID -notlike "$expectedQueueId/providers/Microsoft.Authorization/roleAssignments/*" -or
        $executorOutputs.WATCHDOGQUEUEROLEASSIGNMENTID -notlike "$expectedQueueId/providers/Microsoft.Authorization/roleAssignments/*") {
        throw 'Executor deployment outputs failed exact resource and queue-scope checks.'
    }
    foreach ($key in $executorOutputs.Keys) {
        $outputs[$key] = $executorOutputs[$key]
    }
    $scenarioState.outputs = $outputs
    $scenarioState.status = 'ExecutorInfrastructureProvisioned'
    Save-State

    $null = Invoke-ServiceBusRunnerCommand -Action configure -Arguments @{
        namespace = "$($outputs.NAMESPACENAME).servicebus.windows.net"
        queueName = $outputs.QUEUENAME
        queueResourceId = $outputs.QUEUEID
        functionApps = @($outputs.EXECUTORAPPNAME, $outputs.WATCHDOGAPPNAME)
        environmentName = $EnvironmentName
        coordinationStorageAccount = $outputs.HOSTSTORAGENAME
        coordinationContainer = $outputs.COORDINATIONCONTAINERNAME
        coordinationBlobName = $outputs.COORDINATIONBLOBNAME
    } -CommandTimeoutSeconds 1200
    $null = Invoke-ServiceBusRunnerCommand -Action initialize -CommandTimeoutSeconds 180
    $health = Assert-ServiceBusRunnerHealth
    Invoke-ServiceBusExecutorPublish -FunctionAppName $outputs.EXECUTORAPPNAME
    Invoke-ServiceBusExecutorPublish -FunctionAppName $outputs.WATCHDOGAPPNAME
    Remove-Item -LiteralPath $bootstrapPath -Force -ErrorAction Stop

    $scenarioState.outputs = $outputs
    $scenarioState.status = 'ProvisionedUnverified'
    $scenarioState.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Save-State
    return [pscustomobject]@{
        status = $scenarioState.status
        resourceGroupId = $scenarioState.groupId
        namespaceName = $outputs.NAMESPACENAME
        queueName = $outputs.QUEUENAME
        queueId = $outputs.QUEUEID
        alertId = $outputs.SENDFAILUREALERTID
        executorApp = $outputs.EXECUTORAPPNAME
        watchdogApp = $outputs.WATCHDOGAPPNAME
        runnerVm = $outputs.RUNNERVMNAME
        runnerIdentityPrincipalId = $outputs.RUNNERIDENTITYPRINCIPALID
        runnerBundleSha256 = $scenarioState.runnerBundleSha256
        functionSourceSha256 = $scenarioState.functionSourceSha256
        runnerHealth = $health
        readiness = (Get-ServiceBusActionGate).readiness
    }
}

function Invoke-ServiceBusDown {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        if (Invoke-Azure @('group', 'exists', '--name', $groupName)) {
            throw 'The scenario group exists without its ownership manifest. Refusing deletion.'
        }
        $peerings = @(Invoke-Azure @(
            'network', 'vnet', 'peering', 'list',
            '--resource-group', $foundationGroupName,
            '--vnet-name', "vnet-retailtx-$FoundationEnvironment"
        ))
        if (@($peerings | Where-Object {
            $_.name -ceq "peer-retailtx-sb-$EnvironmentName"
        }).Count) {
            throw 'The exact Stage 0 executor peering exists without its ownership manifest. Refusing deletion and reporting a residual.'
        }
        return [pscustomobject]@{ status = 'Absent'; residuals = @() }
    }
    Read-State
    $account = Invoke-Azure @('account', 'show')
    if ($account.id -ine $subscription -or $account.tenantId -ine $scenarioState.tenantId) {
        throw 'Down target subscription or tenant does not match the ownership manifest.'
    }
    $expectedFoundationVnetId = "/subscriptions/$subscription/resourceGroups/$foundationGroupName/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-$FoundationEnvironment"
    if ($scenarioState.foundationVirtualNetworkId -and
        $scenarioState.foundationVirtualNetworkId -ine $expectedFoundationVnetId) {
        throw 'The manifest foundation VNet ID does not match the selected retained environment.'
    }
    $script:sharedDnsLock = Enter-ServiceBusFoundationDnsLock -VirtualNetworkId $expectedFoundationVnetId
    Assert-ServiceBusPrivateDnsOwnership
    $hasFoundationPeering = Assert-ServiceBusFoundationPeeringOwnership
    $group = Get-OwnedScenarioGroup
    $target = "$($scenarioState.groupId) and exact Stage 0 VNet peering"
    if (-not $PSCmdlet.ShouldProcess($target, 'Delete owned Service Bus executor and its exact VNet peering')) {
        return
    }
    if ($group -and $scenarioState.outputs.QUEUEID) {
        $queue = Get-ServiceBusQueueSnapshot
        $marker = if ($scenarioState.ContainsKey('currentFault') -and $scenarioState.currentFault) {
            ConvertFrom-ServiceBusFaultMarker -Queue $queue
        } else { $null }
        if ($queue.properties.status -cne 'Active' -or
            ($marker -and $marker.state -cne 'Recovered')) {
            throw 'Down requires a healthy Active queue with no outstanding durable fault before SRE disconnection.'
        }
    }
    Disconnect-ServiceBusSre
    if ($scenarioState.ContainsKey('executorIdentity') -and $scenarioState.executorIdentity) {
        $graphInvoker = {
            param($Method, $Path, $Body)
            Invoke-ServiceBusGraph -Method $Method -Path $Path -Body $Body
        }
        $saveIdentityState = { Save-State }
        Remove-ServiceBusEntraIdentity `
            -ScenarioState $scenarioState `
            -InvokeGraph $graphInvoker `
            -SaveState $saveIdentityState
    }
    if ($group) {
        $null = Invoke-Azure @('group', 'delete', '--name', $groupName, '--yes') -TimeoutSeconds 1800
        if (Invoke-Azure @('group', 'exists', '--name', $groupName)) {
            throw 'Owned resource group deletion has not completed; keep the manifest and retry Down.'
        }
    }
    if ($hasFoundationPeering) {
        $null = Invoke-Azure @(
            'network', 'vnet', 'peering', 'delete',
            '--resource-group', $foundationGroupName,
            '--vnet-name', "vnet-retailtx-$FoundationEnvironment",
            '--name', "peer-retailtx-sb-$EnvironmentName"
        ) -TimeoutSeconds 120
        if (Assert-ServiceBusFoundationPeeringOwnership) {
            throw 'The exact Stage 0 executor peering still exists; keep the manifest and retry Down.'
        }
    }
    $archiveDirectory = Join-Path $repositoryRoot '.azure\archive'
    New-Item -ItemType Directory -Path $archiveDirectory -Force | Out-Null
    $archivePath = Join-Path $archiveDirectory "servicebus-$EnvironmentName-$($scenarioState.ownerToken).json"
    Move-Item -LiteralPath $statePath -Destination $archivePath -ErrorAction Stop
    return [pscustomobject]@{ status = 'Deleted'; residuals = @(); archive = $archivePath }
}

if ($Operation -in @('Up', 'Connect', 'Arm', 'Fault', 'Incident', 'Recover', 'Reset', 'Down') -and
    -not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$lockStream = $null
try {
    if ($Operation -in @('Up', 'Connect', 'Arm', 'Fault', 'Incident', 'Recover', 'Reset', 'Down')) {
        $lockStream = Enter-ServiceBusScenarioLock -Path $lockPath
    }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Read-State
    } elseif ($Operation -in @('Doctor', 'Down')) {
        $scenarioState = $null
    } elseif ($Operation -ne 'Up') {
        throw 'No Service Bus ownership manifest exists. Run Up first; refusing to adopt a resource group.'
    }

    switch ($Operation) {
        'Up' {
            Invoke-ServiceBusUp
        }
        'Connect' {
            if (-not $scenarioState) { throw 'Connect requires a provisioned Service Bus manifest. Run Up first.' }
            Connect-ServiceBusSre
        }
        'Doctor' {
            $null = Get-VerifiedFoundation
            $group = if ($scenarioState) { Get-OwnedScenarioGroup } else { $null }
            $queue = $null
            $runtime = $null
            $runtimeError = $null
            $runnerHealth = $null
            $runnerError = $null
            if ($group -and $scenarioState.outputs.QUEUEID) {
                try {
                    $queue = Get-ServiceBusQueueSnapshot
                    $runtime = Get-ServiceBusSreRuntimeState
                } catch {
                    $runtimeError = $_.Exception.Message
                }
                try {
                    $runnerHealth = Assert-ServiceBusRunnerHealth
                } catch {
                    $runnerError = $_.Exception.Message
                }
            }
            $gate = Get-ServiceBusActionGate -RuntimeState $runtime
            $result = Get-ServiceBusDoctorResult -State $scenarioState -Group $group `
                -ActionGate $gate -SreRuntime $runtime -Queue $queue -RunnerHealth $runnerHealth
            if ($runtimeError -or $runnerError) {
                $result.actionGate.readiness = 'Blocked'
                $result.actionGate.blockers = @($result.actionGate.blockers) +
                    @(@($runtimeError, $runnerError) | Where-Object { $_ })
                $result.ready = $false
                if ($runtimeError) {
                    $result | Add-Member -NotePropertyName sreReadError -NotePropertyValue $runtimeError
                }
                if ($runnerError) {
                    $result | Add-Member -NotePropertyName runnerReadError -NotePropertyValue $runnerError
                }
            }
            $result
        }
        'Arm' {
            Arm-ServiceBusSre
        }
        'Fault' {
            Invoke-ServiceBusFault
        }
        'Incident' {
            Invoke-ServiceBusIncidentObservation
        }
        'Recover' {
            Invoke-ServiceBusRecover
        }
        'Reset' {
            Invoke-ServiceBusReset
        }
        default {
            Assert-ServiceBusActionGate
        }
        'Down' {
            Invoke-ServiceBusDown
        }
    }
} finally {
    if ($sharedDnsLock) { $sharedDnsLock.Dispose() }
    if ($lockStream) { $lockStream.Dispose() }
}
