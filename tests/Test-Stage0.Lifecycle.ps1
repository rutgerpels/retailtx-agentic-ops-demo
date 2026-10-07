#Requires -Version 7.2
<#
.SYNOPSIS
Exercise lifecycle orchestration with a fake Azure CLI and isolated manifests.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) "retailtx-lifecycle-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path (Join-Path $fixture '.azure\test') -Force
Copy-Item -LiteralPath (Join-Path $root 'scripts') -Destination $fixture -Recurse
$subscription = '11111111-1111-1111-1111-111111111111'
$groupId = "/subscriptions/$subscription/resourceGroups/rg-retailtx-test-swedencentral"
$machineId = "$groupId/providers/Microsoft.HybridCompute/machines/erp-core-01"
$mock = @{}
$mock.stateFile = Join-Path $fixture '.azure\test\retailtx-state.json'
$mock.seed = @{
    schemaVersion = 1
    subscriptionId = $subscription
    tenantId = $subscription
    environmentName = 'test'
    resourceGroupName = 'rg-retailtx-test-swedencentral'
    location = 'swedencentral'
    ownerToken = 'owner'
    phase = 'infrastructure-ready'
    outputs = @{ WORKSPACE_CUSTOMER_ID = $subscription }
    resources = @()
}
$mock.group = @{
    id = $groupId
    location = 'swedencentral'
    tags = @{ demo = 'retailtx'; environmentId = 'test'; ownerToken = 'owner'; managedBy = 'retailtx-stage0' }
}
$mock.evidence = @{
    worker = 'active'; azureImds = 'blocked'; arcIdentity = 'authenticated'
    privateWorkspaceQuery = 'succeeded'; recentHeartbeat = $true; machineId = $machineId
    workspaceIngestionAddresses = @('10.84.1.4'); workspaceQueryAddresses = @('10.84.1.5')
}
$mock.putUrls = [Collections.Generic.List[string]]::new()
$mock.failExecution = $false
$mock.invalidateManifest = $false
$mock.groupReads = 0
$mock.verificationWasInvalidated = $false
$mock.listReads = 0

function az {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    if ($command.StartsWith('account show ')) {
        return (@{ id = $mock.seed.subscriptionId; tenantId = $mock.seed.tenantId; state = 'Enabled' } | ConvertTo-Json)
    }
    if ($command.StartsWith('group exists ')) { return 'true' }
    if ($command.StartsWith('group show ')) {
        $mock.groupReads++
        if ($mock.invalidateManifest -and $mock.groupReads -eq 1) {
            $changed = $mock.seed.Clone()
            $changed.ownerToken = 'foreign'
            $changed | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mock.stateFile
        }
        return ($mock.group | ConvertTo-Json -Depth 10)
    }
    if ($command.StartsWith('resource list ')) { return '[]' }
    if ($command.StartsWith('rest --method put ')) {
        $url = $args[([array]::IndexOf($args, '--url') + 1)]
        if (([uri]$url).Segments[-1].Length -gt 36) { throw 'Arc command name exceeds the RP limit.' }
        $mock.putUrls.Add($url)
        $current = Get-Content -Raw -LiteralPath $mock.stateFile | ConvertFrom-Json -AsHashtable
        $mock.verificationWasInvalidated = $current.phase -eq 'verifying' -and
            -not $current.ContainsKey('verification') -and -not $current.ContainsKey('verifiedAt')
        return '{}'
    }
    if ($command.StartsWith('rest --method get ') -and $command.Contains('/runCommands?')) {
        $mock.listReads++
        if ($mock.listReads -eq 1) { return '{"value":[]}' }
        return (@{ value = @(@{ name = ([uri]$mock.putUrls[-1]).Segments[-1] }) } | ConvertTo-Json -Depth 10)
    }
    if ($command.StartsWith('rest --method get ') -and $command.Contains('/runCommands/')) {
        $view = if ($mock.failExecution) {
            @{ executionState = 'Failed'; exitCode = 1; error = 'fixture failure'; output = '' }
        } else {
            @{ executionState = 'Succeeded'; exitCode = 0; output = ($mock.evidence | ConvertTo-Json -Compress) }
        }
        Set-Item -Path Function:az -Value (${function:az}.GetNewClosure())
        return (@{ properties = @{ provisioningState = 'Succeeded'; instanceView = $view } } | ConvertTo-Json -Depth 10)
    }
    throw "Unexpected fake Azure CLI call: $command"
}

function azd { throw 'azd must not run during these tests.' }
function Start-Sleep { param([int]$Seconds) }

try {
    $mock.seed | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mock.stateFile
    $entry = Join-Path $fixture 'scripts\Invoke-Stage0.ps1'
    $null = & $entry -Operation Verify -SubscriptionId $subscription -EnvironmentName test
    $null = & $entry -Operation Verify -SubscriptionId $subscription -EnvironmentName test
    if ($mock.putUrls.Count -ne 2 -or $mock.putUrls[0] -eq $mock.putUrls[1]) {
        throw 'Repeated Verify did not create distinct executions.'
    }
    if (-not $mock.verificationWasInvalidated) { throw 'Previous verification was not invalidated before execution.' }
    if ($mock.listReads -lt 3) { throw 'Run Command resource visibility was not awaited.' }
    $mock.failExecution = $true
    $rejected = $false
    try { $null = & $entry -Operation Verify -SubscriptionId $subscription -EnvironmentName test } catch { $rejected = $true }
    $current = Get-Content -Raw -LiteralPath $mock.stateFile | ConvertFrom-Json -AsHashtable
    if (-not $rejected -or $current.phase -ne 'verification-failed' -or
        $current.ContainsKey('verification') -or $current.ContainsKey('verifiedAt')) {
        throw 'A failed verification retained successful readiness.'
    }
    $mock.seed | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mock.stateFile
    $mock.invalidateManifest = $true
    $mock.groupReads = 0
    $before = $mock.putUrls.Count
    $rejected = $false
    try { $null = & $entry -Operation Verify -SubscriptionId $subscription -EnvironmentName test } catch { $rejected = $true }
    if (-not $rejected -or $mock.putUrls.Count -ne $before) {
        throw 'A stale manifest allowed mutation after the lifecycle lock.'
    }
    'Passed 4 Stage 0 lifecycle orchestration checks.'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
