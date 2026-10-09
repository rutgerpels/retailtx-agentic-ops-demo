#Requires -Version 5.1
<#
.SYNOPSIS
Prepare a disposable Windows/IIS host before switching exclusively to Arc.
.DESCRIPTION
Executed once through native Azure VM Run Command during provisioning only.
The delayed local task removes Azure guest management and blocks Azure IMDS
before connecting to Arc with an in-memory bootstrap managed-identity token.
It never injects pressure and does not initialize or format a disk.
.PARAMETER Configuration
Base64 non-secret JSON containing exact deployment and ownership identifiers.
.EXAMPLE
.\Initialize-ArcDiskHost.ps1 -Configuration <base64-json>
.OUTPUTS
Preparation marker. Final connection is checked independently through ARM.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Configuration)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-VerifiedArcInstaller {
    param([string]$Destination)
    # Windows PowerShell returned truncated downloads without an error in live provisioning.
    & curl.exe --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' `
        --retry 2 --retry-all-errors --connect-timeout 15 --max-time 180 --remove-on-error `
        --output $Destination 'https://aka.ms/AzureConnectedMachineAgent'
    if ($LASTEXITCODE -ne 0) { throw "Connected Machine installer download failed: curl exit $LASTEXITCODE." }
    $signature = Get-AuthenticodeSignature -LiteralPath $Destination
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation,') {
        throw "Connected Machine installer signature rejected: $($signature.Status)."
    }
    Write-Output "RETAILTX_INSTALLER_SHA256:$((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash)"
}
$config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Configuration)) | ConvertFrom-Json
$owner = [guid]::Parse($config.ownerToken).ToString()
$directory = 'C:\ProgramData\RetailTxDisk'
if (Test-Path -LiteralPath $directory) { throw 'Bootstrap directory already exists; do not overwrite an uncertain installation.' }
$null = New-Item -ItemType Directory -Path $directory
& icacls.exe $directory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict bootstrap directory permissions.' }
$Configuration | Set-Content -LiteralPath "$directory\configuration.txt" -Encoding ASCII
$owner | Set-Content -LiteralPath "$directory\owner.txt" -Encoding ASCII
$result = Install-WindowsFeature -Name Web-Server
if (-not $result.Success -or $result.RestartNeeded -ne 'No') { throw 'IIS installation failed or requires a reboot.' }
Set-Content -LiteralPath 'C:\inetpub\wwwroot\health.txt' -Value 'RetailTx disk scenario: IIS healthy' -Encoding ASCII
if ((Invoke-WebRequest -Uri 'http://localhost/health.txt' -UseBasicParsing -TimeoutSec 10).StatusCode -ne 200) {
    throw 'IIS baseline is not healthy.'
}
[Environment]::SetEnvironmentVariable('MSFT_ARC_TEST', 'true', 'Machine')
$env:MSFT_ARC_TEST = 'true'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$installer = "$directory\AzureConnectedMachineAgent.msi"
Get-VerifiedArcInstaller $installer
$install = Start-Process -FilePath msiexec.exe -ArgumentList @('/i', $installer, '/qn', '/norestart') -Wait -PassThru
if ($install.ExitCode -ne 0) { throw "Arc agent installation exited $($install.ExitCode)." }
Remove-Item -LiteralPath $installer

$finalizer = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$directory = 'C:\ProgramData\RetailTxDisk'
try {
    $config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
        (Get-Content -LiteralPath "$directory\configuration.txt" -Raw).Trim())) | ConvertFrom-Json
    $credential = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F' -Headers @{Metadata='true'} -TimeoutSec 30
    Set-Service -Name WindowsAzureGuestAgent -StartupType Disabled
    Stop-Service -Name WindowsAzureGuestAgent -Force
    $null = New-NetFirewallRule -Name 'RetailTxBlockAzureIMDS' -DisplayName 'RetailTx: block Azure and Azure Local IMDS' -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress @('169.254.169.254','169.254.169.253')
    $env:MSFT_ARC_TEST = 'true'
    $arguments = @('connect', '--subscription-id', $config.subscriptionId, '--tenant-id', $config.tenantId,
        '--resource-group', $config.groupName, '--location', 'swedencentral', '--resource-name', $config.machineName,
        '--private-link-scope', $config.privateLinkScopeId, '--access-token', $credential.access_token,
        '--tags', "demo=retailtx,environmentId=$($config.environmentName),profile=disk-scenario,managedBy=retailtx,ownerToken=$($config.ownerToken),expiresAt=$($config.expiresAt)")
    & "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" @arguments *> $null
    $exit = $LASTEXITCODE
    $credential = $null
    $arguments = $null
    if ($exit -ne 0) { throw "Arc connection exited $exit; inspect the guest agent log without exposing credentials." }
    @{ phase='connected'; at=[DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json |
        Set-Content -LiteralPath "$directory\bootstrap-result.json" -Encoding UTF8
} catch {
    @{ phase='failed'; at=[DateTimeOffset]::UtcNow.ToString('o'); error=$_.Exception.Message } | ConvertTo-Json |
        Set-Content -LiteralPath "$directory\bootstrap-result.json" -Encoding UTF8
    throw
}
'@
$finalizer | Set-Content -LiteralPath "$directory\Connect-Arc.ps1" -Encoding UTF8
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ProgramData\RetailTxDisk\Connect-Arc.ps1'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$null = Register-ScheduledTask -TaskName 'RetailTxDiskArcBootstrap' -Action $action -Trigger $trigger -Principal $principal -Settings $settings
Write-Output "RETAILTX_PREPARED:$owner"
