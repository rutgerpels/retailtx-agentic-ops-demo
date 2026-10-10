#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\Azure.Common.psm1') -Force
. (Join-Path $root 'scripts\guest\GuestMonitor.ps1')
$subscription = [guid]::NewGuid().ToString()
$EnvironmentName = 'demo01'
$FoundationEnvironment = 'stage0'
$location = 'swedencentral'
$groupName = "rg-retailtx-guest-$EnvironmentName-$location"
$groupId = "/subscriptions/$subscription/resourceGroups/$groupName"
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/vm-retailtx-guest-$EnvironmentName"
$directory = Join-Path $root ".azure\guest-isolation-tests-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
$statePath = Join-Path $directory 'state.json'
$script:state = @{
    withMonitoring = $true; withSreExecution = $true; withIsolatedMonitoring = $true
    workspaceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/law-retailtx-guest-$EnvironmentName"
    dceId = "$groupId/providers/Microsoft.Insights/dataCollectionEndpoints/dce-retailtx-guest-$EnvironmentName"
    privateLinkScopeId = "$groupId/providers/Microsoft.Insights/privateLinkScopes/ampls-retailtx-guest-$EnvironmentName"
    workspaceCustomerId = $null; ownerToken = [guid]::NewGuid().ToString(); monitorAccess = @{}; journal = @()
}
$script:checks = 0
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe isolated monitoring input accepted.' }
    $script:checks++
}
$script:resources = @()
$script:links = @{ value = @() }
$script:connections = @{ value = @() }
$script:backlinks = @()
$endpointId = "$groupId/providers/Microsoft.Network/privateEndpoints/pe-retailtx-guest-$EnvironmentName-monitor"
$script:endpoint = @{ id = $endpointId; tags = @{ ownerToken = $script:state.ownerToken }
    privateLinkServiceConnections = @(@{ privateLinkServiceId = $script:state.privateLinkScopeId }) }
$script:retainScopeLinks = $false
$script:zones = @{ value = @() }
$script:dnsLinks = @{ value = @() }
$script:writes = @()
$script:groupExists = $true
function Get-OwnedGroup {
    if ($script:groupExists) { return @{ tags = @{ ownerToken = $script:state.ownerToken } } }
}
function Add-GuestJournal {
    param([hashtable]$Entry)
    $script:writes += $Entry.action
    $script:state.journal += $Entry
}
function Invoke-Azure {
    param([string[]]$Arguments, [int]$TimeoutSeconds)
    switch ($Arguments[0..2] -join ' ') {
        'resource list --resource-group' { return $script:resources }
        'resource show --ids' {
            return @{ id = $script:state.workspaceId; tags = @{ ownerToken = $script:state.ownerToken }
                properties = @{ privateLinkScopedResources = $script:backlinks } }
        }
        'network private-endpoint show' { return $script:endpoint }
        'network private-dns link' {
            $link = @($script:dnsLinks.value | Where-Object id -CEQ $Arguments[6])[0]
            return @{ id = $link.id; tags = $link.tags
                virtualNetwork = $link.properties.virtualNetwork
                registrationEnabled = $link.properties.registrationEnabled }
        }
        'rest --method get' {
            if ($Arguments[4].Contains('/providers/Microsoft.Network/privateDnsZones?')) { return $script:zones }
            if ($Arguments[4] -like '*virtualNetworkLinks?*') {
                $result = $script:dnsLinks.Clone()
                $result.value = @($script:dnsLinks.value | Where-Object {
                    $zoneId = $_.id.Substring(0, $_.id.IndexOf('/virtualNetworkLinks/'))
                    $Arguments[4].StartsWith("https://management.azure.com$zoneId/virtualNetworkLinks?")
                })
                return $result
            }
            if ($Arguments[4] -like '*scopedResources?*') { return $script:links }
            if ($Arguments[4] -like '*privateEndpointConnections?*') { return $script:connections }
            throw 'Unexpected REST read.'
        }
        'rest --method delete' {
            $script:writes += $Arguments[4]
            if (-not $script:retainScopeLinks) {
                $script:links.value = @($script:links.value | Where-Object {
                    "https://management.azure.com$($_.id)?api-version=2021-07-01-preview" -cne $Arguments[4]
                })
            }
            return
        }
        'monitor log-analytics workspace' {
            if ($Arguments[3] -cne 'delete' -or $Arguments[5] -ine $script:state.workspaceId -or
                $Arguments[6..8] -join ' ' -cne '--force true --yes') { throw 'Unexpected purge target.' }
            $script:writes += 'purge'; return
        }
        'deployment group create' {
            $script:writes += 'deploy'
            return @{ properties = @{ provisioningState = 'Succeeded'; outputs = @{
                workspaceId = @{ value = $script:state.workspaceId }
                dceId = @{ value = $script:state.dceId }
                privateLinkScopeId = @{ value = $script:state.privateLinkScopeId }
                workspaceCustomerId = @{ value = [guid]::NewGuid().ToString() }
            } } }
        }
        default { throw 'Unexpected Azure command.' }
    }
}
try {
    Assert-GuestMonitorBinding
    $script:state.isolatedMonitorConfigured = $true
    Assert-Rejected { Assert-GuestMonitorBinding }
    $script:state.Remove('isolatedMonitorConfigured')
    foreach ($field in @('workspaceId', 'dceId', 'privateLinkScopeId')) {
        $old = $script:state[$field]
        $script:state[$field] = "/subscriptions/$subscription/resourceGroups/retained/providers/resource/shared"
        Assert-Rejected { Assert-GuestMonitorBinding }
        $script:state[$field] = $old
    }
    $expected = @{}
    Add-GuestMonitorInventory $expected
    if ($expected.Count -ne 22) { throw 'Missing isolated teardown resources.' }
    $script:zones.value = @(@{ id = "$groupId/providers/Microsoft.Network/privateDnsZones/privatelink.monitor.azure.com"
        name = 'privatelink.monitor.azure.com'; tags = @{ ownerToken = $script:state.ownerToken } })
    $script:dnsLinks.value = @(@{ id = "$($script:zones.value[0].id)/virtualNetworkLinks/guest"
        tags = @{ ownerToken = $script:state.ownerToken }
        properties = @{ registrationEnabled = $false
            virtualNetwork = @{ id = "$groupId/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-guest-$EnvironmentName" } } })
    Assert-GuestMonitorDnsTopology
    Assert-Rejected { Assert-GuestMonitorDnsTopology -RequireComplete }
    $script:zones.value[0].tags.ownerToken = 'foreign'
    Assert-Rejected { Assert-GuestMonitorDnsTopology }
    $script:zones.value[0].tags.ownerToken = $script:state.ownerToken
    $script:dnsLinks.value[0].tags.ownerToken = 'foreign'
    Assert-Rejected { Assert-GuestMonitorDnsTopology }
    $script:dnsLinks.value[0].tags.ownerToken = $script:state.ownerToken
    $oldNetworkId = $script:dnsLinks.value[0].properties.virtualNetwork.id
    $script:dnsLinks.value[0].properties.virtualNetwork.id = '/foreign/network'
    $script:dnsLinks.value[0].tags.ownerToken = 'foreign'
    Assert-Rejected { Assert-GuestMonitorDnsTopology }
    $script:dnsLinks.value[0].tags.ownerToken = $script:state.ownerToken
    Assert-Rejected { Assert-GuestMonitorDnsTopology }
    $script:dnsLinks.value[0].properties.virtualNetwork.id = $oldNetworkId
    $script:dnsLinks.value[0].properties.registrationEnabled = $true
    Assert-Rejected { Assert-GuestMonitorDnsTopology }
    $script:dnsLinks.value[0].properties.registrationEnabled = $false
    $oldLinkId = $script:dnsLinks.value[0].id
    $script:dnsLinks.value[0].id = "$($script:zones.value[0].id)/virtualNetworkLinks/foreign"
    Assert-Rejected { Assert-GuestMonitorDnsTopology }
    $script:dnsLinks.value[0].id = $oldLinkId
    $script:dnsLinks.value += $script:dnsLinks.value[0].Clone()
    Assert-Rejected { Assert-GuestMonitorDnsTopology }
    $script:dnsLinks.value = @($script:dnsLinks.value[0])
    $script:zones.value[0].id = '/subscriptions/foreign/privateDnsZones/privatelink.monitor.azure.com'
    $script:dnsLinks.value[0].id = "$($script:zones.value[0].id)/virtualNetworkLinks/guest"
    Assert-Rejected { Assert-GuestMonitorDnsTopology }
    $script:zones.nextLink = 'more'
    Assert-Rejected { Assert-GuestMonitorDnsTopology }
    $script:zones.Remove('nextLink')
    $script:zones.value = @()
    $script:dnsLinks.value = @()
    foreach ($zoneName in @('privatelink.monitor.azure.com', 'privatelink.oms.opinsights.azure.com',
        'privatelink.ods.opinsights.azure.com', 'privatelink.agentsvc.azure-automation.net', 'privatelink.blob.core.windows.net')) {
        $zoneId = "$groupId/providers/Microsoft.Network/privateDnsZones/$zoneName"
        $script:zones.value += @{ id = $zoneId; name = $zoneName; tags = @{ ownerToken = $script:state.ownerToken } }
        foreach ($name in @('guest', 'agent')) {
            $network = if ($name -ceq 'guest') { "vnet-retailtx-guest-$EnvironmentName" } else { "vnet-retailtx-guest-agent-$EnvironmentName" }
            $script:dnsLinks.value += @{ id = "$zoneId/virtualNetworkLinks/$name"
                tags = @{ ownerToken = $script:state.ownerToken }
                properties = @{ registrationEnabled = $false
                    virtualNetwork = @{ id = "$groupId/providers/Microsoft.Network/virtualNetworks/$network" } } }
        }
    }
    Assert-GuestMonitorDnsTopology -RequireComplete
    $script:resources = @(@{ id = $script:state.workspaceId; tags = @{ ownerToken = $script:state.ownerToken } })
    Assert-Rejected { Initialize-GuestMonitorFoundation }
    if ($script:writes.Count) { throw 'Adopted existing resources.' }
    $script:resources = @()
    Initialize-GuestMonitorFoundation
    Assert-GuestMonitorBinding
    if (-not $script:state.isolatedMonitorConfigured -or -not $script:state.workspaceCustomerId) { throw 'Missing isolated binding receipt.' }
    $script:state.isolatedMonitorConfigured = $false
    Assert-Rejected { Initialize-GuestMonitorFoundation }
    $script:state.isolatedMonitorConfigured = $true
    $script:resources = @(
        @{ id = $script:state.workspaceId; tags = @{ ownerToken = $script:state.ownerToken } }
        @{ id = $script:state.privateLinkScopeId; tags = @{ ownerToken = $script:state.ownerToken } }
    )
    $script:links.value = @(
        @{ name = 'workspace'; id = "$($script:state.privateLinkScopeId)/scopedResources/workspace"
            properties = @{ linkedResourceId = $script:state.workspaceId } }
        @{ name = 'data-collection-endpoint'; id = "$($script:state.privateLinkScopeId)/scopedResources/data-collection-endpoint"
            properties = @{ linkedResourceId = $script:state.dceId } }
    )
    $script:writes = @()
    $script:resources[0].tags.ownerToken = 'foreign'
    Assert-Rejected { Remove-GuestMonitorFoundation }
    if ($script:writes.Count) { throw 'Unlinked before all ownership validation.' }
    $script:resources[0].tags.ownerToken = $script:state.ownerToken
    $script:backlinks = @(@{ resourceId = '/foreign/scope/scopedResources/workspace' })
    Assert-Rejected { Remove-GuestMonitorFoundation }
    if ($script:writes.Count) { throw 'Unlinked workspace used by a foreign scope.' }
    $script:backlinks = @(@{ resourceId = "$($script:state.privateLinkScopeId)/scopedResources/workspace" })
    $script:connections.value = @(@{ name = 'owned'; id = "$($script:state.privateLinkScopeId)/privateEndpointConnections/owned"
        properties = @{ privateEndpoint = @{ id = '/foreign/endpoint' } } })
    Assert-Rejected { Remove-GuestMonitorFoundation }
    if ($script:writes.Count) { throw 'Unlinked scope used by a foreign endpoint.' }
    $script:connections.value[0].properties.privateEndpoint.id = $endpointId
    $script:endpoint.tags.ownerToken = 'foreign'
    Assert-Rejected { Remove-GuestMonitorFoundation }
    if ($script:writes.Count) { throw 'Unlinked scope before endpoint ownership validation.' }
    $script:endpoint.tags.ownerToken = $script:state.ownerToken
    $script:connections.nextLink = 'more'
    Assert-Rejected { Remove-GuestMonitorFoundation }
    if ($script:writes.Count) { throw 'Unlinked before complete endpoint inventory.' }
    $script:connections.Remove('nextLink')
    $script:links.value[1].properties.linkedResourceId = '/shared/dce'
    Assert-Rejected { Remove-GuestMonitorFoundation }
    if ($script:writes.Count) { throw 'Unlinked before all scope validation.' }
    $script:links.value[1].properties.linkedResourceId = $script:state.dceId
    $script:retainScopeLinks = $true
    Assert-Rejected { Remove-GuestMonitorFoundation }
    if ('purge' -cin $script:writes) { throw 'Purged before unlinking completed.' }
    $script:retainScopeLinks = $false
    $script:writes = @()
    Remove-GuestMonitorFoundation
    if ($script:writes.Count -ne 4 -or $script:writes[-1] -cne 'purge') { throw 'Owned unlink/purge incomplete.' }
    $script:resources = @()
    $script:connections.value = @()
    $script:backlinks = @()
    $script:writes = @()
    Remove-GuestMonitorFoundation
    Remove-GuestMonitorAccess
    if ($script:writes.Count) { throw 'Partial empty foundation cleanup wrote resources.' }
    $script:resources = @(@{ id = $script:state.privateLinkScopeId; tags = @{ ownerToken = $script:state.ownerToken } })
    Remove-GuestMonitorFoundation
    if ($script:writes.Count) { throw 'Partial scope-only cleanup purged a workspace.' }
    $script:resources = @(@{ id = $script:state.workspaceId; tags = @{ ownerToken = $script:state.ownerToken } })
    Remove-GuestMonitorFoundation
    if ($script:writes.Count -ne 2 -or $script:writes[-1] -cne 'purge') { throw 'Partial workspace-only cleanup failed.' }
    $script:groupExists = $false
    $script:writes = @()
    Remove-GuestMonitorFoundation
    Remove-GuestMonitorAccess
    Assert-GuestMonitorEndpointAbsent
    if ($script:writes.Count) { throw 'Absent fixture cleanup wrote resources.' }
    $script:state.withIsolatedMonitoring = $false
    Assert-Rejected { Remove-GuestMonitorFoundation }
    foreach ($options in @(@{}, @{ WithMonitoring = $true }, @{ WithSreExecution = $true })) {
        Assert-Rejected {
            & (Join-Path $root 'scripts\Invoke-GuestService.ps1') Up -SubscriptionId $subscription `
                -EnvironmentName dry01 -WithIsolatedMonitoring @options -WhatIf
        }
    }
    & (Join-Path $root 'scripts\Invoke-GuestService.ps1') Up -SubscriptionId $subscription `
        -EnvironmentName dry01 -WithIsolatedMonitoring -WithMonitoring -WithSreExecution -WhatIf
    if (Test-Path -LiteralPath (Join-Path $root '.azure\dry01')) { throw 'WhatIf wrote a manifest.' }
    "Isolated monitoring contracts passed ($script:checks rejection checks)."
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
