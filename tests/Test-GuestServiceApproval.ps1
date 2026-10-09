#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\scripts\Invoke-GuestServiceApproval.ps1'
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
$text = $ast.Extent.Text
foreach ($name in @('Assert-ApprovalPolicy', 'New-ApprovedRepairCommand', 'Assert-ApprovedExecution', 'Assert-ApprovalStatus', 'Assert-ApprovedRecovery')) {
    $helper = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($helper.Extent.Text))
}
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid approval proof input accepted.' }
}
$policy = @{ permissions = @{ allow = @()
    ask = @('RunAzCliWriteCommands', 'RunAzCliReadCommands(*run-command*)')
    deny = @('RunInTerminal', 'RunShellCommand', 'ExecutePythonCode') } }
Assert-ApprovalPolicy $policy
Assert-Rejected { Assert-ApprovalPolicy @{ permissions = @{ allow = @(); ask = @(); deny = @() } } }
Assert-Rejected { Assert-ApprovalPolicy @{ permissions = @{ allow = @('RunAzCliWriteCommands') } } }
Assert-Rejected { Assert-ApprovalPolicy @{ permissions = @{ ask = $policy.permissions.ask; deny = $policy.permissions.deny } } }
$fixture = @{ ownerToken = [guid]::NewGuid().ToString(); sourceHashes = @{ 'controller.py' = 'a' * 64 }
    agentPrincipalId = [guid]::NewGuid().ToString(); subscriptionId = [guid]::NewGuid().ToString()
    vmId = '/subscriptions/test/resourceGroups/fixture/providers/Microsoft.Compute/virtualMachines/test' }
$initial = @{ runId = [guid]::NewGuid().ToString(); actor = [guid]::NewGuid().ToString()
    phase = 'fault-active'; canary = $false; deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(8).ToString('o') }
$guest = @{ marker = $initial.Clone(); active = $false; healthy = $false
    observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
$command = New-ApprovedRepairCommand $fixture $guest
if ($command -notmatch "echo ([A-Za-z0-9+/=]+) \| base64 --decode \| python3'") { throw 'Expected short repair wrapper.' }
$code = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
if ($code -notmatch '(?m)^r=(.+)$') { throw 'Expected explicit current-run request.' }
$request = $Matches[1] | ConvertFrom-Json -AsHashtable
if (-not $code.Contains("r['sourceHashes']=json.load(open('/opt/retailtx-guest/config.json'))['sourceHashes']") -or
    -not $code.Contains("'/opt/retailtx-guest/controller.py'")) { throw 'Wrapper must invoke existing attested controller.' }
if ($request.actor -cne $fixture.agentPrincipalId -or $request.runId -cne $initial.runId -or
    [DateTimeOffset]$request.expectedDeadlineUtc -ne [DateTimeOffset]$initial.deadlineUtc) {
    throw 'Repair request does not bind action identity, run and deadline.'
}
$guest.marker.canary = $true
Assert-Rejected { New-ApprovedRepairCommand $fixture $guest }
$guest.marker.canary = $false
$guest.observedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
Assert-Rejected { New-ApprovedRepairCommand $fixture $guest }
$guest.observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
$execution = @{ id = [guid]::NewGuid().ToString(); command = $command; requiredScopes = $null
    originalFunctionCall = (@{ Name = 'RunAzCliWriteCommands'; Arguments = @{ command = $command } } | ConvertTo-Json) }
Assert-ApprovedExecution $execution $command
$execution.status = 'Pending'
$status = @{ id = $execution.id; command = $command; status = 'Pending'; requiredScopes = $null
    startedTimestamp = $null; completedTimestamp = $null }
Assert-ApprovalStatus $status $execution $command
$status.startedTimestamp = [DateTimeOffset]::UtcNow.ToString('o')
Assert-Rejected { Assert-ApprovalStatus $status $execution $command }
$status.startedTimestamp = $null
$status.requiredScopes = @('OBO')
Assert-Rejected { Assert-ApprovalStatus $status $execution $command }
$execution.requiredScopes = @('elevation')
Assert-Rejected { Assert-ApprovedExecution $execution $command }
$execution.requiredScopes = $null
$execution.command = "$command; echo unsafe"
Assert-Rejected { Assert-ApprovedExecution $execution $command }
$guest.active = $true
$guest.healthy = $true
$guest.marker.phase = 'recovered'
$guest.marker.recoveryReason = 'repair'
$guest.marker.recoveredBy = $fixture.agentPrincipalId
$guest.marker.recoveredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
Assert-ApprovedRecovery $guest $initial $fixture.agentPrincipalId
$roundTrip = $initial | ConvertTo-Json | ConvertFrom-Json -AsHashtable
Assert-ApprovedRecovery $guest $roundTrip $fixture.agentPrincipalId
foreach ($field in @('recoveredBy', 'runId', 'recoveryReason')) {
    $original = $guest.marker[$field]
    $guest.marker[$field] = 'watchdog'
    Assert-Rejected { Assert-ApprovedRecovery $guest $initial $fixture.agentPrincipalId }
    $guest.marker[$field] = $original
}
if ($text -match "/action`"|AutomatedApproval|ValidateSet\([^)]*'Approve'") {
    throw 'Human-only adapter must not implement execution approval.'
}
$creation = $text.IndexOf("Invoke-ApprovalRequest Post '/api/v1/threads'", [StringComparison]::Ordinal)
$intent = $text.IndexOf('Save-RetailState $intent $requestPath', [StringComparison]::Ordinal)
$followup = $text.IndexOf('Invoke-ApprovalRequest Post "/api/v1/threads/$threadId/messages"', [StringComparison]::Ordinal)
$followupIntent = $text.IndexOf('Save-RetailState $intent $followupPath', [StringComparison]::Ordinal)
if ($intent -lt 0 -or $intent -ge $creation -or $followupIntent -lt 0 -or $followupIntent -ge $followup) {
    throw 'Durable intent must precede non-replayable POST.'
}
$environment = 'dry' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$directory = Join-Path $PSScriptRoot "..\.azure\$environment"
foreach ($operation in @('Configure', 'Propose', 'Read', 'Verify')) {
    & $path $operation -SubscriptionId ([guid]::NewGuid()) -EnvironmentName $environment -WhatIf
}
if (Test-Path -LiteralPath $directory) { throw 'WhatIf created approval state.' }
'Guest-service human approval contracts passed.'
