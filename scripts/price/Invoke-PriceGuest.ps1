#Requires -Version 5.1
<#
.SYNOPSIS
Operate the owned IIS price-dependency fixture on the Arc guest.
.DESCRIPTION
Creates a loopback-only IIS site with static JSON price responses, stops only
its owned application pool for a bounded fault, and restores it using an
independent SYSTEM watchdog. The fixture is not customer checkout traffic.
.PARAMETER Operation
Install, Reconcile, Status, SafetyTest, Fault, Recover or Watchdog.
.PARAMETER OwnerToken
Ownership GUID recorded by the Azure lifecycle.
.PARAMETER EnvironmentName
Environment suffix used by the owned IIS site, pool and event source.
.PARAMETER RunId
Exact fault or safety-test identifier. Required for Fault and Recover.
.PARAMETER DurationSeconds
Bounded fault duration between 60 and 1800 seconds.
.EXAMPLE
.\Invoke-PriceGuest.ps1 -Operation Recover -OwnerToken <guid> -EnvironmentName demo03 -RunId <guid>
.OUTPUTS
JSON containing an actual loopback HTTP result and owned guest observations.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Install', 'Reconcile', 'Status', 'SafetyTest', 'Fault', 'Recover', 'Watchdog')]
    [string]$Operation = 'Status',
    [Parameter(Mandatory)][guid]$OwnerToken,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{1,10}$')][string]$EnvironmentName,
    [guid]$RunId = [guid]::Empty,
    [ValidateRange(60, 1800)][int]$DurationSeconds = 1200
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$directory = 'C:\ProgramData\RetailTxDisk\PriceService'
$owner = $OwnerToken.ToString()
$poolName = "RetailTxPrice-$EnvironmentName"
$siteName = "RetailTxPrice-$EnvironmentName"
$eventSource = "RetailTxPrice-$EnvironmentName"
$port = 18081
$endpoint = "http://127.0.0.1:$port/price/basket-a/"
$statePath = Join-Path $directory 'price-state.json'
$metadataPath = Join-Path $directory 'fixture.json'
$taskName = "RetailTxPriceWatchdog-$EnvironmentName"

function Assert-PlainPath {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Reparse points are not allowed in the price fixture: $Path"
    }
}

function New-PriceContentAcl {
    param(
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier]$PoolSid,
        [switch]$Container
    )
    $acl = if ($Container) { [Security.AccessControl.DirectorySecurity]::new() } else {
        [Security.AccessControl.FileSecurity]::new()
    }
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = if ($Container) {
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($identity in @(
        @{sid=[Security.Principal.SecurityIdentifier]::new('S-1-5-18');rights=[Security.AccessControl.FileSystemRights]::FullControl},
        @{sid=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544');rights=[Security.AccessControl.FileSystemRights]::FullControl},
        @{sid=$PoolSid;rights=[Security.AccessControl.FileSystemRights]::ReadAndExecute}
    )) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity.sid, $identity.rights, $inheritance,
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    }
    return $acl
}

function Set-PriceContentAcl {
    param(
        [Parameter(Mandatory)][string]$WebRoot,
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier]$PoolSid
    )
    Assert-PlainPath $WebRoot
    $items = @((Get-Item -LiteralPath $WebRoot -Force)) + @(Get-ChildItem -LiteralPath $WebRoot -Recurse -Force)
    foreach ($item in $items) {
        Assert-PlainPath $item.FullName
        $acl = New-PriceContentAcl -PoolSid $PoolSid -Container:($item.PSIsContainer)
        Set-Acl -LiteralPath $item.FullName -AclObject $acl -ErrorAction Stop
    }
}

function Get-PriceHttpFailure {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $detail = if ($ErrorRecord.ErrorDetails) { [string]$ErrorRecord.ErrorDetails.Message } else { '' }
    $substatus = $null
    $hresult = $null
    if ($detail -match 'HTTP Error\s+(\d{3}\.\d+)') { $substatus = $Matches[1] }
    if ($detail -match '0x[0-9a-fA-F]{8}') { $hresult = $Matches[0] }
    return @{
        message=$ErrorRecord.Exception.Message; httpError=$substatus; hresult=$hresult
        detail=$detail.Substring(0, [Math]::Min($detail.Length, 4096))
    }
}

function Assert-PriceSiteIdentity {
    param([Parameter(Mandatory)][string]$SiteName, [Parameter(Mandatory)][string]$PoolName)
    $filter = 'system.webServer/security/authentication/anonymousAuthentication'
    $enabled = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $SiteName `
        -Filter $filter -Name enabled -ErrorAction Stop
    $userName = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $SiteName `
        -Filter $filter -Name userName -ErrorAction Stop
    $pool = Get-Item -LiteralPath "IIS:\AppPools\$PoolName" -ErrorAction Stop
    $enabledValue = if ($enabled.PSObject.Properties['Value']) { $enabled.Value } else { $enabled }
    $userNameValue = if ($userName.PSObject.Properties['Value']) { $userName.Value } else { $userName }
    $isEnabled = $enabledValue -is [bool] -and $enabledValue
    if ($enabledValue -is [string]) {
        $parsedEnabled = $false
        $isEnabled = [bool]::TryParse($enabledValue, [ref]$parsedEnabled) -and $parsedEnabled
    }
    $identity = $pool.processModel.identityType
    $isPoolIdentity = ($identity -is [string] -or $identity -is [enum]) -and
        $identity.ToString() -ceq 'ApplicationPoolIdentity'
    if ($identity -is [byte] -or $identity -is [int16] -or $identity -is [int32] -or
        $identity -is [int64] -or $identity -is [uint16] -or $identity -is [uint32] -or
        $identity -is [uint64]) {
        $isPoolIdentity = $identity -eq 4
    } elseif ($identity -is [string] -and $identity -ceq '4') {
        $isPoolIdentity = $true
    }
    if (-not $isEnabled -or $userNameValue -isnot [string] -or $userNameValue -cne '' -or
        -not $isPoolIdentity) {
        throw 'Owned price site must use enabled anonymous authentication with the application-pool identity.'
    }
}

function Set-PriceSiteIdentity {
    param([Parameter(Mandatory)][string]$SiteName, [Parameter(Mandatory)][string]$PoolName)
    Set-ItemProperty -LiteralPath "IIS:\AppPools\$PoolName" -Name processModel.identityType `
        -Value 4 -ErrorAction Stop
    $filter = 'system.webServer/security/authentication/anonymousAuthentication'
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $SiteName `
        -Filter $filter -Name enabled -Value $true -ErrorAction Stop
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $SiteName `
        -Filter $filter -Name userName -Value '' -ErrorAction Stop
    Assert-PriceSiteIdentity -SiteName $SiteName -PoolName $PoolName
}

function Assert-PriceInstallStage {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$ControllerPath,
        [Parameter(Mandatory)][string]$OwnerToken,
        [Parameter(Mandatory)][string]$EnvironmentName
    )
    Assert-PlainPath $Directory
    $parent = Split-Path -Parent $Directory
    Assert-PlainPath $parent
    if ((Get-Content -LiteralPath (Join-Path $parent 'owner.txt') -Raw).Trim() -cne $OwnerToken -or
        [IO.Path]::GetFullPath($ControllerPath) -ine (Join-Path $Directory 'Invoke-PriceGuest.ps1')) {
        throw 'Price installation staging is not the exact owned controller location.'
    }
    $files = @(Get-ChildItem -LiteralPath $Directory -Force)
    $expectedFiles = @('Invoke-PriceGuest.ps1','controller.sha256','install-stage.json')
    if ($files.Count -ne $expectedFiles.Count) {
        throw 'Price installation directory is not a fresh controller-only stage; destroy and recreate.'
    }
    foreach ($file in $files) {
        Assert-PlainPath $file.FullName
        if ($file.PSIsContainer -or $file.Name -cnotin $expectedFiles) {
            throw 'Price installation staging contains unexpected content; refusing overwrite.'
        }
    }
    $receipt = Get-Content -LiteralPath (Join-Path $Directory 'install-stage.json') -Raw | ConvertFrom-Json
    $hash = (Get-FileHash -LiteralPath $ControllerPath -Algorithm SHA256).Hash
    if ($receipt.schemaVersion -ne 1 -or $receipt.ownerToken -cne $OwnerToken -or
        $receipt.environmentName -cne $EnvironmentName -or $receipt.controllerSha256 -cne $hash -or
        (Get-Content -LiteralPath (Join-Path $Directory 'controller.sha256') -Raw).Trim() -cne $hash) {
        throw 'Price installation stage ownership or controller digest mismatch.'
    }
}

function Assert-PriceSiteBinding {
    param(
        [Parameter(Mandatory)][object[]]$Bindings,
        [Parameter(Mandatory)][string]$BindingInformation
    )
    if ($Bindings.Count -ne 1 -or $Bindings[0].protocol -cne 'http' -or
        $Bindings[0].bindingInformation -cne $BindingInformation) {
        throw 'Price IIS site must have exactly one HTTP binding on the owned loopback address and port.'
    }
}

function Assert-HealthyPriceObservation {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Observation)
    if ($Observation.phase -cne 'healthy' -or $Observation.endpoint -cne $endpoint -or
        $Observation.serviceStatus -ne 200 -or $Observation.baselineHttpStatus -ne 200 -or
        $Observation.contractValid -ne $true -or $Observation.poolState -cne 'Started') {
        throw 'Owned price-pool recovery did not verify healthy endpoint, baseline and response contract.'
    }
    return $Observation
}

function Invoke-PriceWatchdogCycle {
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$State,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        [Parameter(Mandatory)][scriptblock]$GetPoolState,
        [Parameter(Mandatory)][scriptblock]$CompleteRecovery,
        [Parameter(Mandatory)][scriptblock]$AssertHealthy
    )
    if ($State -isnot [System.Collections.IDictionary] -and $State -isnot [pscustomobject]) {
        throw 'Price watchdog requires an owned persisted state object.'
    }
    if ($State.phase -in @('fault-active', 'safety-test')) {
        $deadline = [DateTimeOffset]::MinValue
        if (-not $State.deadline -or
            -not [DateTimeOffset]::TryParse([string]$State.deadline, [ref]$deadline)) {
            throw 'Active price fault has no valid durable recovery deadline.'
        }
        if ($Now -lt $deadline) { return 'active-fault-preserved' }
        $observation = & $CompleteRecovery
        Assert-HealthyPriceObservation -Observation $observation | Out-Null
        return 'expired-fault-recovered'
    }
    if ($State.phase -eq 'recovering') {
        $observation = & $CompleteRecovery
        Assert-HealthyPriceObservation -Observation $observation | Out-Null
        return 'recovery-resumed'
    }
    if ($State.phase -ne 'healthy') {
        throw "Price watchdog refuses unknown durable phase '$($State.phase)'."
    }
    if ((& $GetPoolState) -cne 'Started') {
        $observation = & $CompleteRecovery
        Assert-HealthyPriceObservation -Observation $observation | Out-Null
        return 'healthy-pool-restored'
    }
    $observation = & $AssertHealthy
    Assert-HealthyPriceObservation -Observation $observation | Out-Null
    return 'healthy-pool-verified'
}

function Get-PriceMetadata {
    Assert-PlainPath $directory
    Assert-PlainPath $metadataPath
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if ($metadata.ownerToken -cne $owner -or $metadata.environmentName -cne $EnvironmentName -or
        $metadata.poolName -cne $poolName -or $metadata.siteName -cne $siteName -or
        $metadata.endpoint -cne $endpoint -or $metadata.port -ne $port -or
        $metadata.eventSource -cne $eventSource -or $metadata.schemaVersion -ne 1) {
        throw 'Price fixture metadata ownership or endpoint mismatch.'
    }
    $site = Get-Website -Name $siteName -ErrorAction Stop
    if ($site.PhysicalPath -ine (Join-Path $directory 'www') -or
        $site.ApplicationPool -cne $poolName) {
        throw 'Price IIS site differs from the exact owned path, pool or loopback binding.'
    }
    Assert-PriceSiteBinding -Bindings @($site.Bindings.Collection) `
        -BindingInformation "127.0.0.1:$($port):"
    Assert-PriceSiteIdentity -SiteName $siteName -PoolName $poolName
    $pool = Get-Item -LiteralPath "IIS:\AppPools\$poolName" -ErrorAction Stop
    if ($pool.autoStart -ne $false) {
        throw 'Price app pool must not auto-start; the independent watchdog owns recovery.'
    }
    return $metadata
}

function Get-PriceState {
    Get-PriceMetadata | Out-Null
    Assert-PlainPath $statePath
    $current = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($current.ownerToken -cne $owner -or $current.environmentName -cne $EnvironmentName -or
        $current.endpoint -cne $endpoint -or $current.poolName -cne $poolName -or
        $current.eventSource -cne $eventSource) {
        throw 'Price state ownership or endpoint mismatch.'
    }
    return $current
}

function Save-PriceState {
    $script:priceState.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $tempPath = "$statePath.tmp"
    $script:priceState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $statePath -Force
}

function Get-PricePoolState {
    (Get-WebAppPoolState -Name $poolName -ErrorAction Stop).Value
}

function Get-PriceProbe {
    $baselineStatus = 0
    try {
        $baselineStatus = [int](Invoke-WebRequest -Uri 'http://localhost/health.txt' -UseBasicParsing -TimeoutSec 5).StatusCode
    } catch {
        if ($_.Exception.Response) { $baselineStatus = [int]$_.Exception.Response.StatusCode }
    }
    $status = 0
    $body = $null
    $contentType = $null
    $contractValid = $false
    $httpFailure = $null
    try {
        $response = Invoke-WebRequest -Uri $endpoint -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 5
        $status = [int]$response.StatusCode
        $contentType = ([string]$response.Headers['Content-Type']).Split(';')[0].Trim()
        $body = $response.Content | ConvertFrom-Json
        $contractValid = $status -eq 200 -and $body.sku -ceq 'basket-a' -and
            $body.currency -ceq 'EUR' -and $body.unit_price_cents -eq 199 -and
            $contentType -ceq 'application/json'
    } catch {
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $httpFailure = Get-PriceHttpFailure -ErrorRecord $_
    }
    return @{
        endpoint = $endpoint; serviceStatus = $status; baselineHttpStatus = $baselineStatus
        contentType = $contentType; contractValid = $contractValid; response = $body; httpFailure=$httpFailure
    }
}

function Write-PriceObservation {
    param([string]$EventName)
    $probe = Get-PriceProbe
    $poolState = Get-PricePoolState
    $isHealthy = $probe.serviceStatus -eq 200 -and $probe.contractValid -and $poolState -ceq 'Started'
    $phase = if ($isHealthy) { 'healthy' } else { 'price-unavailable' }
    if ($script:priceState.phase -in @('safety-test', 'fault-active') -and -not $isHealthy) {
        $phase = $script:priceState.phase
    }
    $record = [ordered]@{
        schemaVersion = 1; event = $EventName; kind = 'price-probe'; ownerToken = $owner
        environmentName = $EnvironmentName; runId = $script:priceState.runId
        phase = $phase; observedAt = [DateTimeOffset]::UtcNow.ToString('o')
        endpoint = $endpoint; serviceStatus = $probe.serviceStatus
        contentType = $probe.contentType
        baselineHttpStatus = $probe.baselineHttpStatus; contractValid = $probe.contractValid
        poolState = $poolState; deadline = $script:priceState.deadline
        watchdogAt = $script:priceState.watchdogAt
        recoveryActor = $script:priceState.recoveryActor; recoveredAt = $script:priceState.recoveredAt
        bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        response = $probe.response
        httpFailure = $probe.httpFailure
    }
    $message = $record | ConvertTo-Json -Depth 8 -Compress
    Write-EventLog -LogName Application -Source $eventSource -EventId 2200 `
        -EntryType Information -Message $message
    return $record
}

function Assert-HealthyPriceService {
    $observation = Write-PriceObservation 'health-check'
    if ($observation.phase -cne 'healthy' -or $observation.baselineHttpStatus -ne 200) {
        throw ("The owned price endpoint or baseline is unhealthy: HTTP {0}, baseline {1}, pool {2}; failure {3}" -f
            $observation.serviceStatus, $observation.baselineHttpStatus, $observation.poolState,
            ($observation.httpFailure | ConvertTo-Json -Depth 4 -Compress))
    }
    return $observation
}

function Start-OwnedPricePool {
    $null = Get-PriceMetadata
    if ((Get-PricePoolState) -cne 'Started') {
        Start-WebAppPool -Name $poolName -ErrorAction Stop
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    do {
        if ((Get-PricePoolState) -ceq 'Started') {
            $observation = Write-PriceObservation 'recovery-check'
            if ($observation.phase -ceq 'healthy' -and $observation.baselineHttpStatus -eq 200) {
                return Assert-HealthyPriceObservation $observation
            }
        }
        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw ("The owned price pool did not restore real HTTP evidence: {0}" -f
        ((Write-PriceObservation 'recovery-failed') | ConvertTo-Json -Depth 8 -Compress))
}

function Complete-PriceRecovery {
    param([ValidateSet('operator-script', 'independent-watchdog', 'injection-error-cleanup')][string]$Actor)
    $script:priceState.phase = 'recovering'
    Save-PriceState
    $null = Start-OwnedPricePool
    $script:priceState.phase = 'healthy'
    $script:priceState.recoveryActor = $Actor
    $script:priceState.recoveredAt = [DateTimeOffset]::UtcNow.ToString('o')
    Save-PriceState
    return Write-PriceObservation 'recovered'
}

if ($RunId -eq [guid]::Empty -and $Operation -in @('Fault', 'SafetyTest', 'Recover')) {
    throw 'Fault, SafetyTest and Recover require an explicit RunId.'
}
if (-not $PSCmdlet.ShouldProcess($siteName, "$Operation owned loopback-only IIS price fixture")) {
    return
}
Import-Module WebAdministration -ErrorAction Stop
if ($Operation -eq 'Install') {
    Assert-PriceInstallStage -Directory $directory -ControllerPath $PSCommandPath `
        -OwnerToken $owner -EnvironmentName $EnvironmentName
    if ([Diagnostics.EventLog]::SourceExists($eventSource)) {
        throw 'Price event source already exists outside this fresh owned guest fixture.'
    }
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        throw 'Price watchdog task already exists; refusing to adopt or overwrite it.'
    }
    foreach ($item in @(Get-Website | Where-Object Name -CEQ $siteName) +
        @(Get-ChildItem IIS:\AppPools | Where-Object Name -CEQ $poolName)) {
        if ($item) { throw 'An IIS price site or pool already exists; refusing adoption or overwrite.' }
    }
    & icacls.exe $directory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot protect the owned price fixture directory.' }
    $null = New-Item -ItemType Directory -Path (Join-Path $directory 'www')
    $webRoot = Join-Path $directory 'www'
    $priceRoot = Join-Path $webRoot 'price'
    $null = New-Item -ItemType Directory -Path $priceRoot
    foreach ($sku in @(@{name='basket-a';price=199}, @{name='basket-b';price=349}, @{name='basket-c';price=105})) {
        $folder = Join-Path $priceRoot $sku.name
        $null = New-Item -ItemType Directory -Path $folder
        $priceJson = @{sku=$sku.name;currency='EUR';unit_price_cents=$sku.price} | ConvertTo-Json -Compress
        [IO.File]::WriteAllText((Join-Path $folder 'default.json'), $priceJson, [Text.UTF8Encoding]::new($false))
    }
    Set-Content -LiteralPath (Join-Path $webRoot 'web.config') -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <defaultDocument enabled="true">
      <files>
        <clear />
        <add value="default.json" />
      </files>
    </defaultDocument>
    <staticContent>
      <remove fileExtension=".json" />
      <mimeMap fileExtension=".json" mimeType="application/json" />
    </staticContent>
  </system.webServer>
</configuration>
'@
    New-EventLog -LogName Application -Source $eventSource
    New-WebAppPool -Name $poolName | Out-Null
    Set-ItemProperty -LiteralPath "IIS:\AppPools\$poolName" -Name autoStart -Value $false
    Set-ItemProperty -LiteralPath "IIS:\AppPools\$poolName" -Name managedRuntimeVersion -Value ''
    & icacls.exe 'C:\ProgramData\RetailTxDisk' /grant "IIS AppPool\$($poolName):(X)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot grant the owned IIS pool traversal access to its protected parent directory.' }
    & icacls.exe $directory /grant "IIS AppPool\$($poolName):(X)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot grant the owned IIS pool traversal access to its protected site directory.' }
    $poolSid = ([Security.Principal.NTAccount]::new("IIS AppPool\$poolName")).Translate(
        [Security.Principal.SecurityIdentifier])
    Set-PriceContentAcl -WebRoot $webRoot -PoolSid $poolSid
    $null = New-Website -Name $siteName -PhysicalPath $webRoot -ApplicationPool $poolName `
        -IPAddress '127.0.0.1' -Port $port
    Set-PriceSiteIdentity -SiteName $siteName -PoolName $poolName
    $script:priceState = [ordered]@{
        schemaVersion=1; ownerToken=$owner; environmentName=$EnvironmentName
        endpoint=$endpoint; poolName=$poolName; eventSource=$eventSource
        phase='healthy'; runId=[guid]::NewGuid().ToString(); deadline=$null
        recoveryActor=$null; recoveredAt=$null; watchdogAt=$null; updatedAt=$null
    }
    $metadata = [ordered]@{
        schemaVersion=1; ownerToken=$owner; environmentName=$EnvironmentName
        siteName=$siteName; poolName=$poolName; endpoint=$endpoint; port=$port; eventSource=$eventSource
    }
    $metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    Save-PriceState
    Remove-Item -LiteralPath (Join-Path $directory 'install-stage.json') -ErrorAction Stop
    Start-WebAppPool -Name $poolName -ErrorAction Stop
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$directory\Invoke-PriceGuest.ps1`" -Operation Watchdog -OwnerToken $owner -EnvironmentName $EnvironmentName"
    $triggers = @(
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(15) -RepetitionInterval (New-TimeSpan -Minutes 1)),
        (New-ScheduledTaskTrigger -AtStartup)
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
        -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers `
        -Principal $principal -Settings $settings -ErrorAction Stop
    $observation = Assert-HealthyPriceService
    if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction Stop)) { throw 'Independent price watchdog was not registered.' }
    $observation | ConvertTo-Json -Depth 8 -Compress
    return
}

if ($Operation -eq 'Reconcile') {
    $null = Get-PriceMetadata
    if (-not (Test-Path -LiteralPath $statePath) -or
        (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash -cne (Get-Content -LiteralPath (Join-Path $directory 'controller.sha256') -Raw).Trim()) {
        throw 'Price reconciliation does not match the installed, owned controller revision.'
    }
}
Get-PriceMetadata | Out-Null
Assert-PlainPath $statePath
$lease = [IO.File]::Open((Join-Path $directory 'price.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $script:priceState = Get-PriceState
    if ($Operation -eq 'Install') { throw 'Price service is already installed; inspect it instead of reinstalling.' }
    if ($Operation -eq 'Reconcile') {
        if ($script:priceState.phase -cne 'healthy') { throw 'Reconciliation requires a healthy price service.' }
        Assert-HealthyPriceService | ConvertTo-Json -Depth 8 -Compress
        return
    }
    if ($Operation -eq 'Watchdog') {
        $null = Invoke-PriceWatchdogCycle -State $script:priceState -Now ([DateTimeOffset]::UtcNow) `
            -GetPoolState { Get-PricePoolState } `
            -CompleteRecovery { Complete-PriceRecovery -Actor independent-watchdog } `
            -AssertHealthy { Assert-HealthyPriceService }
        $script:priceState.watchdogAt = [DateTimeOffset]::UtcNow.ToString('o')
        Save-PriceState
        $observation = Write-PriceObservation 'watchdog'
    } elseif ($Operation -eq 'Recover') {
        if ($script:priceState.runId -cne $RunId.ToString()) {
            throw 'Recovery run does not match the current owned price-service incident.'
        }
        if ($script:priceState.phase -cne 'healthy') {
            $observation = Complete-PriceRecovery -Actor operator-script
        } else {
            $observation = Assert-HealthyPriceService
        }
    } elseif ($Operation -in @('Fault', 'SafetyTest')) {
        if ($script:priceState.phase -cne 'healthy' -or -not $script:priceState.watchdogAt -or
            [DateTimeOffset]::UtcNow.AddSeconds(-90) -gt [DateTimeOffset]$script:priceState.watchdogAt) {
            throw 'Price fault requires a healthy fixture and a fresh independent watchdog observation.'
        }
        $null = Assert-HealthyPriceService
        $receiptPath = Join-Path $directory "run-$RunId.id"
        $receipt = [IO.File]::Open($receiptPath, 'CreateNew', 'Write', 'None')
        $receipt.Dispose()
        $duration = if ($Operation -eq 'SafetyTest' -and $DurationSeconds -eq 1200) { 60 } else { $DurationSeconds }
        $script:priceState.runId = $RunId.ToString()
        $script:priceState.deadline = [DateTimeOffset]::UtcNow.AddSeconds($duration).ToString('o')
        $script:priceState.phase = if ($Operation -eq 'SafetyTest') { 'safety-test' } else { 'fault-active' }
        $script:priceState.recoveryActor = $null
        $script:priceState.recoveredAt = $null
        Save-PriceState
        try {
            Stop-WebAppPool -Name $poolName -ErrorAction Stop
            $observation = Write-PriceObservation 'fault-injected'
            if ($observation.serviceStatus -ne 503 -or $observation.phase -cne $script:priceState.phase -or
                $observation.baselineHttpStatus -ne 200) {
                throw 'Stopping only the owned price pool did not produce a real HTTP failure while baseline IIS remained healthy.'
            }
        } catch {
            $null = Complete-PriceRecovery -Actor injection-error-cleanup
            throw
        }
    } elseif ($Operation -eq 'Status') {
        $observation = Write-PriceObservation 'status'
    } else {
        throw "Unsupported price guest operation: $Operation"
    }
    if ($observation -isnot [System.Collections.IDictionary]) {
        $observation = Write-PriceObservation $Operation
    }
    $observation | ConvertTo-Json -Depth 8 -Compress
} finally {
    $lease.Dispose()
}
