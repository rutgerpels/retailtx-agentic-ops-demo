#Requires -Version 5.1
<#
.SYNOPSIS
Read the exact owned price-probe event from private Log Analytics.
.DESCRIPTION
Uses the Arc host's existing HIMDS challenge and system identity. This fixed,
read-only query has no Perf dependency and does not query customer traffic.
.PARAMETER WorkspaceId
Log Analytics workspace customer GUID.
.PARAMETER ArcResourceId
Exact Arc machine resource ID.
.PARAMETER OwnerToken
Fixture ownership GUID used to filter event evidence.
.PARAMETER EnvironmentName
Exact environment name used to filter event evidence.
.EXAMPLE
.\Get-PriceTelemetry.ps1 -WorkspaceId <guid> -ArcResourceId <resource-id> -OwnerToken <guid> -EnvironmentName demo03
.OUTPUTS
JSON with private DNS addresses and the latest exact owned event, if present.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[a-zA-Z0-9-]+/providers/Microsoft\.HybridCompute/machines/disk-[a-z0-9]+$')][string]$ArcResourceId,
    [Parameter(Mandatory)][guid]$OwnerToken,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{1,10}$')][string]$EnvironmentName
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$addresses = @(Resolve-DnsName -Name api.loganalytics.io -Type A -DnsOnly |
    Where-Object Type -EQ A | ForEach-Object IPAddress)
if (-not $addresses.Count -or @($addresses | Where-Object { $_ -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' }).Count) {
    throw 'Log Analytics query DNS is not exclusively private IPv4.'
}
$endpoint = 'http://localhost:40342/metadata/identity/oauth2/token?resource=https%3A%2F%2Fapi.loganalytics.io&api-version=2020-06-01'
$challenge = $null
try {
    $null = Invoke-WebRequest -Uri $endpoint -Headers @{ Metadata = 'true' } -UseBasicParsing `
        -MaximumRedirection 0 -TimeoutSec 30
} catch [Net.WebException] {
    if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 401) { throw }
    $challenge = $_.Exception.Response.Headers['WWW-Authenticate']
}
if (-not $challenge -or $challenge -notmatch '^Basic realm=(.+)$') {
    throw 'Expected HIMDS authentication challenge was not returned.'
}
$path = [IO.Path]::GetFullPath($Matches[1].Trim('"'))
$tokenDirectory = Join-Path $env:ProgramData 'AzureConnectedMachineAgent\Tokens'
if (-not $path.StartsWith("$tokenDirectory\", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HIMDS challenge file is outside the expected agent token directory.'
}
foreach ($item in @($tokenDirectory, $path)) {
    if ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'HIMDS challenge path must not be a reparse point.'
    }
}
$headers = @{}
try {
    $secret = (Get-Content -LiteralPath $path -Raw).Trim()
    $credential = Invoke-RestMethod -Uri $endpoint -Headers @{ Metadata = 'true'; Authorization = "Basic $secret" } `
        -MaximumRedirection 0 -TimeoutSec 30
    $secret = $null
    $headers.Authorization = "******"
    $credential = $null
    $kql = @"
let target = '$ArcResourceId';
let owner = '$($OwnerToken.ToString())';
let environmentName = '$EnvironmentName';
Event
| where TimeGenerated >= ago(15m) and _ResourceId =~ target
| where Source == 'RetailTxPrice-$EnvironmentName' and EventID == 2200
| extend data = parse_json(RenderedDescription)
| where tostring(data.ownerToken) == owner and tostring(data.environmentName) == environmentName
| summarize arg_max(TimeGenerated, data)
| project observedAt = TimeGenerated, details = data
"@
    $query = Invoke-RestMethod -Uri "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query" `
        -Method Post -ContentType 'application/json' -Body (@{ query = $kql } | ConvertTo-Json) `
        -Headers $headers -MaximumRedirection 0 -TimeoutSec 60
    if ($query.PSObject.Properties.Name -contains 'error') { throw 'Log Analytics returned a partial query error.' }
    $rows = @()
    foreach ($table in $query.tables) {
        foreach ($row in $table.rows) {
            $record = [ordered]@{}
            for ($i = 0; $i -lt $table.columns.Count; $i++) {
                $record[$table.columns[$i].name] = $row[$i]
            }
            $rows += $record
        }
    }
    @{
        workspaceId = $WorkspaceId.ToString(); arcResourceId = $ArcResourceId
        privateAddresses = $addresses; rows = $rows
    } | ConvertTo-Json -Depth 8 -Compress
} finally {
    $secret = $null
    $credential = $null
    $headers.Clear()
}
