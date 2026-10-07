#Requires -Version 7.2
<#
.SYNOPSIS
Dependency-free regression checks for Stage 0 lifecycle safety and syntax.
.EXAMPLE
pwsh -File .\tests\Test-Stage0.ps1
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\Stage0.Common.psm1') -Force
$checks = 0

function Assert-Throws {
    param([scriptblock]$Action)
    $caught = $false
    try { & $Action } catch { $caught = $true }
    if (-not $caught) { throw 'Expected the operation to be rejected.' }
}

foreach ($name in @('stage0', 'proof-02', 'abc')) {
    Assert-Stage0Name -Name $name
    $checks++
}
foreach ($name in @('../other', 'a/b', 'a\b', 'Upper', '-stage0', 'stage0-', 'x', 'x;echo', ('a' * 17))) {
    Assert-Throws { Assert-Stage0Name -Name $name }
    $checks++
}
$state = @{
    subscriptionId = '11111111-1111-1111-1111-111111111111'
    resourceGroupName = 'rg-retailtx-test-swedencentral'
    environmentName = 'test'
    location = 'swedencentral'
    ownerToken = '22222222-2222-2222-2222-222222222222'
}
$group = @{
    id = "/subscriptions/$($state.subscriptionId)/resourceGroups/$($state.resourceGroupName)"
    location = 'swedencentral'
    tags = @{
        demo = 'retailtx'
        environmentId = 'test'
        ownerToken = $state.ownerToken
        managedBy = 'retailtx-stage0'
    }
}
Assert-Stage0Ownership -State $state -ResourceGroup $group
$checks++
foreach ($field in @('demo', 'environmentId', 'ownerToken', 'managedBy')) {
    $changed = $group.Clone()
    $changed.tags = $group.tags.Clone()
    $changed.tags[$field] = 'different'
    Assert-Throws { Assert-Stage0Ownership -State $state -ResourceGroup $changed }
    $checks++
}
$changed = $group.Clone()
$changed.id = '/subscriptions/another/resourceGroups/another'
Assert-Throws { Assert-Stage0Ownership -State $state -ResourceGroup $changed }
$checks++
$changed = $group.Clone()
$changed.location = 'eastus2'
Assert-Throws { Assert-Stage0Ownership -State $state -ResourceGroup $changed }
$checks++
$values = ConvertFrom-Stage0Environment -Lines @(
    'WORKSPACE_ID="/subscriptions/id/resourceGroups/demo/workspaces/one"',
    'DATA="$(throw no-evaluation)"',
    '# comment',
    ''
)
if ($values.DATA -cne '$(throw no-evaluation)') { throw 'Environment data was changed or evaluated.' }
$checks++
Assert-Throws { ConvertFrom-Stage0Environment -Lines @('export KEY=value') }
$checks++

$machineId = "$($group.id)/providers/Microsoft.HybridCompute/machines/erp-core-01"
$evidence = @{
    worker = 'active'
    azureImds = 'blocked'
    arcIdentity = 'authenticated'
    privateWorkspaceQuery = 'succeeded'
    recentHeartbeat = $true
    machineId = $machineId
    workspaceIngestionAddresses = @('10.84.1.4')
    workspaceQueryAddresses = @('10.84.1.5')
}
Assert-Stage0Evidence -Evidence $evidence -MachineId $machineId
$checks++
foreach ($field in $evidence.Keys) {
    $incomplete = $evidence.Clone()
    $incomplete.Remove($field)
    Assert-Throws { Assert-Stage0Evidence -Evidence $incomplete -MachineId $machineId }
    $checks++
}
$invalid = $evidence.Clone()
$invalid.recentHeartbeat = 'false'
Assert-Throws { Assert-Stage0Evidence -Evidence $invalid -MachineId $machineId }
$checks++
Assert-Throws { Assert-Stage0Evidence -Evidence $evidence -MachineId "$machineId-other" }
$checks++

foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Include '*.ps1', '*.psm1' -Recurse) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$($file.Name): $($errors -join '; ')" }
    $checks++
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) "retailtx-test-$([guid]::NewGuid()).json"
try {
    Save-Stage0State -State $state -Path $temporary
    $restored = Get-Content -Raw -LiteralPath $temporary | ConvertFrom-Json -AsHashtable
    if ($restored.ownerToken -cne $state.ownerToken) { throw 'State round trip failed.' }
    if (Test-Path -LiteralPath "$temporary.tmp") { throw 'Atomic state write left a temporary file.' }
    $checks++
} finally {
    foreach ($path in @($temporary, "$temporary.tmp")) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
}
"Passed $checks Stage 0 safety and syntax checks."
$item = @{
    name = 'retailtx-stage0'; type = 'KnowledgeItem'
    properties = @{
        dataConnectorType = 'KnowledgeFile'
        extendedProperties = @{ 'metadata.filename' = 'stage0.md'; contentType = 'text/markdown'; fileSize = 100 }
    }
}
Assert-Stage0Knowledge -Item $item -ExpectedSize 100
Assert-Throws { Assert-Stage0Knowledge -Item $item -ExpectedSize 200 }
$item.properties.extendedProperties.Remove('metadata.filename')
Assert-Throws { Assert-Stage0Knowledge -Item $item -ExpectedSize 100 }
'Passed 3 SRE knowledge metadata checks.'
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-Stage0.Lifecycle.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Lifecycle orchestration checks failed.' }
