#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$path = Join-Path $PSScriptRoot '..\scripts\Invoke-GuestServiceSre.ps1'
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
if ($errors) { throw ($errors -join "`n") }
$text = $ast.Extent.Text
foreach ($required in @(
    'OPERATOR-COLLECTED guest evidence',
    'do not invoke it',
    'You have no guest-repair grant',
    "actionConfiguration.mode -cne 'Review'",
    'MaximumRedirection = 0',
    "'Requested'",
    'reconcile without replay',
    'live SRE thread ownership marker',
    'OperatorGuestReceipt'
)) {
    if ($text.IndexOf($required, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Missing guest SRE evidence/authority constraint: $required"
    }
}
$creation = $text.IndexOf("Invoke-GuestSreRequest Post '/api/v1/threads'", [StringComparison]::Ordinal)
$creationIntent = $text.IndexOf('Save-RetailState $intent $requestPath', [StringComparison]::Ordinal)
$followup = $text.IndexOf('Invoke-GuestSreRequest Post "/api/v1/threads/$threadId/messages"', [StringComparison]::Ordinal)
$followupIntent = $text.IndexOf('Save-RetailState $intent $recoveryPath', [StringComparison]::Ordinal)
if ($creationIntent -lt 0 -or $creation -le $creationIntent -or
    $followupIntent -lt 0 -or $followup -le $followupIntent) {
    throw 'SRE POST must persist durable intent before either mutation.'
}
if ($text -match "ValidateSet\([^)]*'Approve'|/approve|role', 'assignment', 'create") {
    throw 'Recommendation adapter must not approve execution or grant guest authority.'
}
$helper = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Assert-GuestSreRecovery'
}, $true)
. ([scriptblock]::Create($helper.Extent.Text))
$actor = [guid]::NewGuid()
$initial = @{ runId = [guid]::NewGuid().ToString(); actor = [guid]::NewGuid().ToString()
    deadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o') }
$guest = @{ marker = $initial.Clone(); active = $true; healthy = $true
    observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
$guest.marker.phase = 'recovered'
$guest.marker.recoveryReason = 'repair'
$guest.marker.recoveredBy = $actor.ToString()
Assert-GuestSreRecovery $guest $initial $actor
$persistedInitial = $initial | ConvertTo-Json | ConvertFrom-Json -AsHashtable
Assert-GuestSreRecovery $guest $persistedInitial $actor
$deadline = $guest.marker.deadlineUtc
$guest.marker.deadlineUtc = [DateTimeOffset]::Parse($deadline).AddSeconds(1).ToString('o')
$rejected = $false
try { Assert-GuestSreRecovery $guest $persistedInitial $actor } catch { $rejected = $true }
if (-not $rejected) { throw 'Recovery accepted a different deadline instant.' }
$guest.marker.deadlineUtc = $deadline
foreach ($field in @('recoveredBy', 'runId', 'recoveryReason')) {
    $value = $guest.marker[$field]
    $guest.marker[$field] = 'wrong'
    $rejected = $false
    try { Assert-GuestSreRecovery $guest $initial $actor } catch { $rejected = $true }
    if (-not $rejected) { throw "Recovery accepted mismatched $field." }
    $guest.marker[$field] = $value
}
'Guest-service SRE recommendation contracts passed.'
