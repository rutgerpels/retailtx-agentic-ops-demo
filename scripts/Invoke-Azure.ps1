#Requires -Version 7.2
<#
.SYNOPSIS
Operate an isolated private RetailTx Azure application environment.
.DESCRIPTION
Uses explicit subscription selection, Bicep what-if, an ownership manifest and
an exclusive environment lock. Existing proof resources are never adopted.
Guest operations run as the authorized operator, not as SRE remediation.
.PARAMETER Operation
Preflight, Up, Status, Doctor, Verify, Scenario, Reset, or Down.
.PARAMETER SubscriptionId
Explicit authorized subscription identifier.
.PARAMETER EnvironmentName
Neutral 3-12 character environment identifier.
.PARAMETER DurationSeconds
Bounded backlog pause duration. The guest independently resumes consumption.
.EXAMPLE
.\scripts\Invoke-Azure.ps1 Up -SubscriptionId <guid> -EnvironmentName demo01
.EXAMPLE
.\scripts\Invoke-Azure.ps1 Down -SubscriptionId <guid> -EnvironmentName demo01 -WhatIf
.OUTPUTS
Non-secret deployment, readiness, recovery, and residual evidence.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Preflight', 'Up', 'Status', 'Doctor', 'Verify', 'Scenario', 'Reset', 'Down')]
    [string]$Operation,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [string]$EnvironmentName = 'demo01',
    [ValidateRange(5, 300)][int]$DurationSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Azure.Common.psm1') -Force
Assert-RetailEnvironmentName $EnvironmentName
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root ".azure\$EnvironmentName"
$statePath = Join-Path $directory 'application-state.json'
$subscription = $SubscriptionId.ToString()
$location = 'swedencentral'
$groups = @{}
foreach ($role in @('cloud', 'dc', 'ops')) { $groups[$role] = "rg-retailtx-$role-$EnvironmentName-$location" }
$script:state = $null
$arcApi = '2026-07-15'
$computeApi = '2024-11-01'
$azCommand = Get-Command az -ErrorAction Stop
$azExecutable = $azCommand.Source
$azPrefix = @()
if ($IsWindows -and [IO.Path]::GetExtension($azExecutable) -eq '.cmd') {
    # Avoid cmd.exe interpreting REST query ampersands and JMESPath parentheses.
    $azExecutable = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $azExecutable) '..\python.exe'))
    if (-not (Test-Path -LiteralPath $azExecutable)) { throw 'The Windows Azure CLI Python launcher could not be resolved.' }
    $azPrefix = @('-IBm', 'azure.cli')
}

function Invoke-Azure {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = & $azExecutable @azPrefix @Arguments --subscription $subscription --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..([Math]::Min(1, $Arguments.Count - 1))] -join ' ')." }
    if ($result) { return (($result -join "`n") | ConvertFrom-Json -AsHashtable) }
}

function Save-State { Save-RetailState -State $script:state -Path $statePath }

function Read-State {
    $script:state = $null
    if (Test-Path -LiteralPath $statePath) {
        $script:state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -AsHashtable
        Assert-RetailManifest $script:state $subscription $account.tenantId $EnvironmentName
        $outputs = @{}
        foreach ($key in $script:state.outputs.Keys) { $outputs[$key] = $script:state.outputs[$key] }
        $script:state.outputs = $outputs
    }
}

function Get-OwnedGroups {
    $found = @{}
    foreach ($role in @('cloud', 'dc', 'ops')) {
        if (Invoke-Azure @('group', 'exists', '--name', $groups[$role])) {
            if (-not $script:state) { throw "Group $($groups[$role]) exists without the matching local ownership manifest." }
            $group = Invoke-Azure @('group', 'show', '--name', $groups[$role])
            Assert-RetailOwnedGroup -State $script:state -Role $role -Group $group
            $found[$role] = $group
        }
    }
    return $found
}

function Get-Resource {
    param([string]$Id, [string]$Api)
    Invoke-Azure @('rest', '--method', 'get', '--url', "https://management.azure.com${Id}?api-version=$Api")
}

function Update-Inventory {
    $inventory = @()
    $owned = Get-OwnedGroups
    foreach ($role in $owned.Keys) {
        $inventory += @(Invoke-Azure @('resource', 'list', '--resource-group', $groups[$role])) |
            ForEach-Object { @{ id = $_.id; type = $_.type } }
    }
    $script:state.resources = $inventory
    Save-State
}

function Invoke-Guest {
    param([ValidateSet('cloud', 'dc')][string]$Role, [string]$Script, [int]$TimeoutSeconds = 1800)
    $null = Get-OwnedGroups
    $id = if ($Role -eq 'cloud') { $script:state.outputs.cloudVmId } else { $script:state.outputs.arcMachineId }
    if (-not $id) { throw "Missing $Role guest identity." }
    $api = if ($Role -eq 'cloud') { $computeApi } else { $arcApi }
    $commandId = "$id/runCommands/rtx-$([guid]::NewGuid().ToString('N'))"
    $path = Join-Path $directory 'guest-command.json'
    $body = @{
        location = $location
        properties = @{
            source = @{ script = $Script.Replace("`r`n", "`n") }
            timeoutInSeconds = $TimeoutSeconds
            asyncExecution = $false
        }
    }
    try {
        $body | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        $null = Invoke-Azure @('rest', '--method', 'put', '--url',
            "https://management.azure.com${commandId}?api-version=$api", '--body', "@$path")
    } finally {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    $script:state.lastCommandId = $commandId
    Save-State
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds + 180)
    do {
        $listing = Get-Resource "$id/runCommands" $api
        $commands = @($listing.value)
        while ($listing.ContainsKey('nextLink') -and $listing.nextLink) {
            $listing = Invoke-Azure @('rest', '--method', 'get', '--url', $listing.nextLink)
            $commands += @($listing.value)
        }
        if (@($commands | Where-Object { $_.id -ieq $commandId }).Count -gt 0) {
            $command = Invoke-Azure @('rest', '--method', 'get', '--url',
                "https://management.azure.com${commandId}?api-version=$api&`$expand=instanceView")
            $view = if ($command.properties.ContainsKey('instanceView')) { $command.properties.instanceView } else { $null }
            if ($view -and $view.executionState -eq 'Succeeded') {
                if ($view.exitCode -ne 0) { throw "$Role guest exited $($view.exitCode): $($view.error) $($view.output)" }
                $null = Invoke-Azure @('rest', '--method', 'delete', '--url',
                    "https://management.azure.com${commandId}?api-version=$api")
                return $view.output
            }
            if (($view -and $view.executionState -in @('Failed', 'Canceled', 'TimedOut')) -or
                ($command.properties.ContainsKey('provisioningState') -and $command.properties.provisioningState -eq 'Failed')) {
                throw "$Role guest command failed: $($view | ConvertTo-Json -Compress)"
            }
        }
        Start-Sleep -Seconds 10
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "$Role guest command did not complete within the bounded execution window."
}

function Invoke-AppCommand {
    param([ValidateSet('cloud', 'dc')][string]$Role, [string]$Command)
    Invoke-Guest -Role $Role -Script @"
set -euo pipefail
runuser -u retailtx -- bash -c 'set -a; source /etc/retailtx/runtime.env; set +a; cd /opt/retailtx/current; .venv/bin/python $Command'
"@
}

function Write-Parameters {
    param([string]$Path, [hashtable]$Values)
    $parameters = @{}
    foreach ($key in $Values.Keys) { $parameters[$key] = @{ value = $Values[$key] } }
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Deploy-Base {
    param([switch]$Bootstrap, [switch]$Foundation, [switch]$Alerts)
    $path = Join-Path $directory 'parameters.json'
    Write-Parameters $path @{
        environmentName = $EnvironmentName
        location = $location
        ownerToken = $script:state.ownerToken
        expiresAt = $script:state.expiresAt
        adminSshPublicKey = $script:state.sshPublicKey
        enableBootstrapIdentities = $Bootstrap.IsPresent
        enableArtifactBridge = $Bootstrap.IsPresent
        allowPackageHttpEgress = $Bootstrap.IsPresent
        deployHosts = -not $Foundation.IsPresent
        enableAlerts = -not $Foundation.IsPresent -and (
            $Alerts.IsPresent -or ($script:state.ContainsKey('alertsActivated') -and $script:state.alertsActivated))
        cloudBootstrapScript = if ($Foundation) { '' } else { $script:state.cloudBootstrapScript }
        dcBootstrapScript = if ($Foundation) { '' } else { $script:state.dcBootstrapScript }
    }
    $arguments = @('--location', $location, '--name', "retailtx-$EnvironmentName",
        '--template-file', (Join-Path $root 'infra\azure-main.bicep'), '--parameters', "@$path")
    $null = Invoke-Azure (@('deployment', 'sub', 'what-if', '--no-pretty-print') + $arguments)
    $null = Get-OwnedGroups
    $deployment = Invoke-Azure (@('deployment', 'sub', 'create') + $arguments)
    $script:state.outputs = ConvertFrom-RetailDeploymentOutputs $deployment.properties.outputs
    $mapping = @{
        cloudVmId = 'CLOUD_VM_ID'; dcVmId = 'DC_VM_ID'; arcMachineId = 'ARC_MACHINE_RESOURCE_ID'
        cloudPrincipalId = 'CLOUD_PRINCIPAL_ID'; postgresHost = 'POSTGRES_FQDN'
        storageAccountName = 'STORAGE_ACCOUNT_NAME'; databaseAdminName = 'DATABASE_BOOTSTRAP_NAME'
        databaseAdminClientId = 'DATABASE_BOOTSTRAP_CLIENT_ID'; workspaceCustomerId = 'WORKSPACE_CUSTOMER_ID'
    }
    foreach ($key in $mapping.Keys) { $script:state.outputs[$key] = $script:state.outputs[$mapping[$key]] }
    $script:state.outputs.capHost = ([uri]$script:state.outputs.RUNTIME_CONFIG.CAP_URL).Host
    $script:state.outputs.erpHost = ([uri]$script:state.outputs.RUNTIME_CONFIG.ERP_URL).Host
    Save-State
}

function Get-BootstrapScript {
    param([ValidateSet('cloud', 'dc')][string]$Role)
    $source = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'azure\bootstrap-host.sh')
    $values = @{
        SUBSCRIPTION_ID = $subscription; TENANT_ID = $account.tenantId; LOCATION = $location
        ARC_MACHINE_NAME = $script:state.outputs.ARC_MACHINE_NAME
        ARC_SCOPE_ID = $script:state.outputs.ARC_PRIVATE_LINK_SCOPE_ID
        BOOTSTRAP_CLIENT_ID = $script:state.outputs.DC_BOOTSTRAP_CLIENT_ID
        OWNER_TOKEN = $script:state.ownerToken; ENVIRONMENT_NAME = $EnvironmentName
    }
    $rendered = $source.Replace('__HOST_ROLE__', $Role).Replace('__RESOURCE_GROUP__', $groups[$Role])
    foreach ($key in $values.Keys) {
        $value = [string]$values[$key]
        if ($value.Contains("'") -or $value.Contains("`n")) { throw 'Invalid bootstrap identifier.' }
        $rendered = $rendered.Replace("__$($key)__", $value)
    }
    if ($rendered -match '__[A-Z_]+__' -or [Text.Encoding]::UTF8.GetByteCount($rendered) -ge 64000) {
        throw 'Bootstrap template has unresolved placeholders or exceeds customData size.'
    }
    return $rendered.Replace("`r`n", "`n")
}

function Set-BootstrapScripts {
    foreach ($role in @('cloud', 'dc')) {
        $script:state["$($role)BootstrapScript"] = Get-BootstrapScript $role
    }
    Save-State
}

function Complete-CloudBootstrap {
    $bootstrap = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-BootstrapScript cloud)))
    $result = Invoke-Guest cloud @"
set -euo pipefail
install -d -m 0700 /var/lib/retailtx
cloud_init_exit=0
timeout 900 cloud-init status --wait > /var/lib/retailtx/cloud-init-status 2>&1 || cloud_init_exit=`$?
if [ "`$cloud_init_exit" -gt 2 ]; then
    cat /var/lib/retailtx/cloud-init-status
    exit 1
fi
repaired=false
if ! test -f /var/lib/retailtx/bootstrap-complete; then
    printf '%s' '$bootstrap' | base64 --decode > /var/lib/retailtx/bootstrap-repair.sh
    if ! bash /var/lib/retailtx/bootstrap-repair.sh > /var/lib/retailtx/bootstrap-repair.log 2>&1; then
        tail -n 30 /var/lib/retailtx/bootstrap-repair.log
        exit 1
    fi
    repaired=true
fi
test -f /var/lib/retailtx/bootstrap-complete
printf '{"complete":true,"repaired":%s,"initialCloudInitExitCode":%s}\n' "`$repaired" "`$cloud_init_exit"
"@
    $script:state.cloudBootstrapEvidence = $result | ConvertFrom-Json -AsHashtable
    Save-State
}

function Get-InstallConfiguration {
    param([string]$Role)
    $outputs = $script:state.outputs
    $runtime = $outputs.RUNTIME_CONFIG.Clone()
    $runtime.RETAILTX_IDENTITY = if ($Role -eq 'cloud') { 'vm' } else { 'arc' }
    if ($Role -eq 'dc') {
        $runtime.IDENTITY_ENDPOINT = 'http://localhost:40342/metadata/identity/oauth2/token'
        $runtime.IMDS_ENDPOINT = 'http://localhost:40342'
        foreach ($key in @('CAP_DB_HOST', 'CAP_DB_USER', 'CAP_DB_NAME', 'CAP_DB_SSLROOTCERT')) { $runtime.Remove($key) }
    } else {
        foreach ($key in @('ERP_DB_HOST', 'ERP_DB_USER', 'ERP_DB_NAME')) { $runtime.Remove($key) }
    }
    return @{
        role = $Role; environment = $EnvironmentName; releaseSha = $script:state.releaseSha
        storageAccount = $outputs.storageAccountName; capHost = $outputs.capHost; erpHost = $outputs.erpHost
        postgresHost = $outputs.postgresHost; databaseAdminName = $outputs.databaseAdminName
        databaseAdminClientId = $outputs.databaseAdminClientId; cloudPrincipalId = $outputs.cloudPrincipalId
        workspaceId = $outputs.workspaceCustomerId; arcMachineId = $outputs.arcMachineId
        runtimeEnv = $runtime; installedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Install-Application {
    $releasePath = Join-Path $directory 'release.zip'
    $result = & python (Join-Path $PSScriptRoot 'azure\package_release.py') --output $releasePath
    if ($LASTEXITCODE -ne 0) { throw 'Deterministic release packaging failed.' }
    $release = $result | ConvertFrom-Json
    $script:state.releaseSha = $release.sha256
    Save-State
    $archive = [Convert]::ToBase64String([IO.File]::ReadAllBytes($releasePath))
    $transport = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'azure\guest_transport.py')))
    $installer = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'azure\install_guest.py')))
    foreach ($role in @('cloud', 'dc')) {
        $config = ConvertTo-RetailGuestPayload (Get-InstallConfiguration $role)
        $upload = if ($role -eq 'cloud') { "printf '%s' '$archive' | base64 --decode > /var/lib/retailtx/release.zip" } else { '' }
        $null = Invoke-Guest -Role $role -Script @"
set -euo pipefail
test -f /var/lib/retailtx/bootstrap-complete
$upload
printf '%s' '$transport' | base64 --decode > /var/lib/retailtx/guest_transport.py
printf '%s' '$installer' | base64 --decode > /var/lib/retailtx/install_guest.py
python3 /var/lib/retailtx/install_guest.py --config '$config'
"@
    }
}

function Remove-SetupAccess {
    $cleanup = $script:state.setupCleanup
    $config = ConvertTo-RetailGuestPayload (Get-InstallConfiguration cloud)
    $null = Invoke-Guest cloud @"
set -euo pipefail
cd /opt/retailtx/current
.venv/bin/python scripts/azure/install_guest.py --config '$config' --phase cleanup
"@
    Deploy-Base
    $identityPath = Join-Path $directory 'detach-identity.json'
    try {
        '{"identity":{"type":"SystemAssigned"}}' |
            Set-Content -LiteralPath $identityPath -Encoding utf8NoBOM
        $null = Invoke-Azure @('rest', '--method', 'patch', '--url',
            "https://management.azure.com$($script:state.outputs.dcVmId)?api-version=$computeApi",
            '--body', "@$identityPath")
    } finally {
        if (Test-Path -LiteralPath $identityPath) { Remove-Item -LiteralPath $identityPath }
    }
    $null = Get-OwnedGroups
    foreach ($id in $cleanup.roleAssignments) {
        Assert-OwnedResourceId $id
        $null = Invoke-Azure @('role', 'assignment', 'delete', '--ids', $id)
    }
    foreach ($id in @($cleanup.databaseAdministrator) + @($cleanup.identities)) {
        Assert-OwnedResourceId $id
        $null = Invoke-Azure @('resource', 'delete', '--ids', $id)
    }
    $cloud = Get-Resource $script:state.outputs.cloudVmId $computeApi
    $dc = Get-Resource $script:state.outputs.dcVmId $computeApi
    foreach ($hostResource in @($cloud, $dc)) {
        if ($hostResource.identity.type -cne 'SystemAssigned' -or
            ($hostResource.identity.ContainsKey('userAssignedIdentities') -and
            $hostResource.identity.userAssignedIdentities -and
            $hostResource.identity.userAssignedIdentities.Count -ne 0)) {
            throw 'Bootstrap identity attachments were not fully removed.'
        }
    }
    $nativeDcRoles = @(Invoke-Azure @('role', 'assignment', 'list',
        '--assignee-object-id', $dc.identity.principalId, '--all'))
    if ($nativeDcRoles.Count -ne 0) {
        throw 'The policy-required DC backing identity has unexpected role assignments.'
    }
    $script:state.setupAccessRemoved = $true
    Save-State
}

function Assert-OwnedResourceId {
    param([Parameter(Mandatory)][string]$Id)
    foreach ($group in $groups.Values) {
        if ($Id.StartsWith("/subscriptions/$subscription/resourceGroups/$group/", [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }
    throw 'Setup cleanup ID is outside the owned resource groups.'
}

function Set-ApplicationServices {
    param([ValidateSet('start', 'stop')][string]$Action)
    $owned = Get-OwnedGroups
    foreach ($role in @('cloud', 'dc')) {
        if ($Action -eq 'stop') {
            if (-not $owned.ContainsKey($role)) { continue }
            $key = if ($role -eq 'cloud') { 'cloudVmId' } else { 'arcMachineId' }
            if (-not $script:state.outputs.ContainsKey($key) -or -not $script:state.outputs[$key]) { continue }
            $resources = @(Invoke-Azure @('resource', 'list', '--resource-group', $groups[$role]))
            if (@($resources | Where-Object { $_.id -ieq $script:state.outputs[$key] }).Count -eq 0) { continue }
        }
        $services = if ($role -eq 'cloud') {
            'retailtx-cap-api retailtx-outbox-publisher retailtx-recon-job'
        } else { 'retailtx-erp-core retailtx-erp-poster' }
        $command = if ($Action -eq 'start') {
            "install -m 0600 /dev/null /etc/retailtx/runtime-enabled; systemctl enable --now $services"
        } else {
            @"
rm -f /etc/retailtx/runtime-enabled
for unit in $services; do
    if test -f "/etc/systemd/system/`$unit.service"; then
        systemctl disable --now "`$unit"
    fi
done
"@
        }
        $null = Invoke-Guest -Role $role -Script "set -euo pipefail`n$command"
    }
}

function Get-QueueEvidence {
    $queue = Invoke-Azure @('servicebus', 'queue', 'show', '--resource-group', $groups.cloud,
        '--namespace-name', $script:state.outputs.SERVICE_BUS_NAMESPACE_NAME, '--name', 'IDOC_POSTING')
    if ($queue.id -ine $script:state.outputs.SERVICE_BUS_QUEUE_ID -or
        $queue.status -ne 'Active' -or -not $queue.ContainsKey('countDetails') -or
        $queue.countDetails.deadLetterMessageCount -ne 0) {
        throw 'Queue identity/status or dead-letter readiness check failed.'
    }
    return $queue.countDetails
}

function Start-SetupMaintenance {
    Set-ApplicationServices stop
    $script:state.setupAccessRemoved = $false
    Save-State
}

function Remove-MonitorAssociations {
    $owned = Get-OwnedGroups
    $expected = @{
        'retailtx-host' = @{ property = 'dataCollectionRuleId'; output = 'DCR_ID' }
        'configurationAccessEndpoint' = @{ property = 'dataCollectionEndpointId'; output = 'DCE_ID' }
    }
    $deleteIds = @()
    foreach ($role in @('cloud', 'dc')) {
        $key = if ($role -eq 'cloud') { 'cloudVmId' } else { 'arcMachineId' }
        if (-not $owned.ContainsKey($role) -or -not $script:state.outputs.ContainsKey($key)) { continue }
        $hostId = $script:state.outputs[$key]
        Assert-OwnedResourceId $hostId
        $resources = @(Invoke-Azure @('resource', 'list', '--resource-group', $groups[$role]))
        if (@($resources | Where-Object { $_.id -ieq $hostId }).Count -eq 0) { continue }
        $prefix = "$hostId/providers/Microsoft.Insights/dataCollectionRuleAssociations"
        $page = Get-Resource $prefix '2023-03-11'
        do {
            foreach ($association in $page.value) {
                if (-not $expected.ContainsKey($association.name)) { continue }
                $target = $expected[$association.name]
                if ($association.id -ine "$prefix/$($association.name)" -or
                    -not $script:state.outputs.ContainsKey($target.output) -or
                    -not $association.properties.ContainsKey($target.property) -or
                    $association.properties[$target.property] -ine $script:state.outputs[$target.output]) {
                    throw 'Monitor association cleanup target does not match the owned manifest.'
                }
                Assert-OwnedResourceId $association.properties[$target.property]
                $deleteIds += $association.id
            }
            if (-not $page.ContainsKey('nextLink') -or -not $page.nextLink) { break }
            $page = Invoke-Azure @('rest', '--method', 'get', '--url', $page.nextLink)
        } while ($true)
    }
    foreach ($id in $deleteIds) {
        $null = Invoke-Azure @('rest', '--method', 'delete', '--url',
            "https://management.azure.com${id}?api-version=2023-03-11")
    }
}

function Get-BacklogAlerts {
    $ruleId = $script:state.outputs.ALERT_IDS[0]
    $ruleName = ($ruleId -split '/')[-1]
    $target = [uri]::EscapeDataString($script:state.outputs.WORKSPACE_ID)
    $page = Invoke-Azure @('rest', '--method', 'get', '--url',
        "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01&targetResource=$target&timeRange=30d&monitorCondition=Fired&pageCount=100")
    $alerts = @($page.value)
    while ($page.ContainsKey('nextLink') -and $page.nextLink) {
        $page = Invoke-Azure @('rest', '--method', 'get', '--url', $page.nextLink)
        $alerts += @($page.value)
    }
    @($alerts | Where-Object {
        $_.properties.essentials.alertRule -in @($ruleId, $ruleName) -and
        $_.properties.essentials.monitorCondition -eq 'Fired'
    })
}

function Wait-BacklogClear {
    param([int]$TimeoutSeconds = 1200)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (@(Get-BacklogAlerts).Count -eq 0) { return }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 20
    } while ($true)
    throw 'Previous backlog alert has not resolved; no new fault was injected.'
}

function Wait-BacklogAlert {
    param([DateTimeOffset]$Since)
    $deadline = $Since.AddSeconds(295)
    do {
        $fired = @(Get-BacklogAlerts | Where-Object {
            $essentials = $_.properties.essentials
            [DateTimeOffset]$essentials.startDateTime -ge $Since
        })
        if ($fired.Count -gt 0) { return $fired[0].id }
        Start-Sleep -Seconds 15
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'The bounded backlog fault did not produce a verified fired alert before independent recovery.'
}

$account = Invoke-Azure @('account', 'show')
if ($account.id -ine $subscription -or $account.state -ne 'Enabled') { throw 'Target subscription is not enabled for this login.' }
Read-State
$null = Get-OwnedGroups
if ($Operation -eq 'Preflight') {
    $providers = @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.ServiceBus',
        'Microsoft.DBforPostgreSQL', 'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.HybridCompute')
    foreach ($namespace in $providers) {
        $provider = Invoke-Azure @('provider', 'show', '--namespace', $namespace)
        if ($provider.registrationState -ne 'Registered') { throw "Provider $namespace is not registered." }
    }
    [pscustomobject]@{
        subscription = $subscription; tenant = $account.tenantId; location = $location
        groups = $groups; profile = 'azure-lite'
        computeQuota = Invoke-Azure @('vm', 'list-usage', '--location', $location, '--query',
            "[?name.value=='standardBSFamily' || name.value=='cores'].{name:name.value,used:currentValue,limit:limit}")
        note = 'Private Azure services and quota require successful deployment what-if; no policy exemptions or budgets are created.'
    }
    return
}
if ($Operation -ne 'Up' -and -not $script:state) { throw 'No application manifest exists. Run Up first.' }
if ($Operation -eq 'Status') {
    [pscustomobject]@{ phase = $script:state.phase; groups = (Get-OwnedGroups).Keys; release = $script:state.releaseSha; outputs = $script:state.outputs }
    return
}
if (-not $PSCmdlet.ShouldProcess("$subscription / $EnvironmentName", $Operation)) { return }
$null = New-Item -ItemType Directory -Path $directory -Force
$lock = [IO.File]::Open((Join-Path $directory 'application.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    Read-State
    $null = Get-OwnedGroups
    if ($Operation -ne 'Up' -and -not $script:state) { throw 'Application manifest disappeared before lock acquisition.' }
    if ($Operation -eq 'Up') {
        if (-not $script:state) {
            $script:state = @{
                schemaVersion = 2; profile = 'azure-lite'; subscriptionId = $subscription
                tenantId = $account.tenantId; location = $location; environmentName = $EnvironmentName
                ownerToken = [guid]::NewGuid().ToString(); groups = $groups
                expiresAt = [DateTimeOffset]::UtcNow.AddDays(3).ToString('o')
                phase = 'initialized'; outputs = @{}; resources = @(); releaseSha = ''
            }
            Save-State
        }
        if (-not $script:state.ContainsKey('sshPublicKey')) {
            $key = Join-Path $directory 'disabled-ssh-key'
            try {
                & ssh-keygen -q -t rsa -b 3072 -N '""' -C 'retailtx-disabled-ssh' -f $key
                if ($LASTEXITCODE -ne 0) { throw 'Provisioning public-key generation failed.' }
                $script:state.sshPublicKey = (Get-Content -Raw -LiteralPath "$key.pub").Trim()
                Save-State
            } finally {
                foreach ($path in @($key, "$key.pub")) {
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
                }
            }
        }
        $releasePath = Join-Path $directory 'release.zip'
        $package = & python (Join-Path $PSScriptRoot 'azure\package_release.py') --output $releasePath
        if ($LASTEXITCODE -ne 0) { throw 'Source release packaging failed.' }
        $candidate = $package | ConvertFrom-Json
        $requiresInstall = Test-RetailApplicationInstall $script:state $candidate.sha256 (Get-OwnedGroups).Count
        if ($requiresInstall) {
            Start-SetupMaintenance
        }
        $script:state.phase = 'provisioning'
        $script:state.Remove('verification')
        Save-State
        if (-not $script:state.ContainsKey('cloudBootstrapScript') -or (Get-OwnedGroups).Count -eq 0) {
            $script:state.alertsActivated = $false
            Save-State
            Deploy-Base -Bootstrap -Foundation
            Set-BootstrapScripts
        }
        Deploy-Base -Bootstrap:$requiresInstall
        Update-Inventory
        Complete-CloudBootstrap
        $deadline = [DateTimeOffset]::UtcNow.AddMinutes(25)
        do {
            $machines = @(Invoke-Azure @('resource', 'list', '--resource-group', $groups.dc,
                '--resource-type', 'Microsoft.HybridCompute/machines'))
            $match = $machines | Where-Object { $_.id -ieq $script:state.outputs.arcMachineId }
            if ($match) {
                $machine = Get-Resource $match.id $arcApi
                if ($machine.properties.status -eq 'Connected') { break }
            }
            if ([DateTimeOffset]::UtcNow -gt $deadline) { throw 'Arc bootstrap did not become Connected within 25 minutes.' }
            Start-Sleep -Seconds 20
        } while ($true)
        $bindingsPath = Join-Path $directory 'bindings.json'
        if ($machine.id -ine $script:state.outputs.arcMachineId -or
            $machine.tags.ownerToken -cne $script:state.ownerToken -or
            $machine.tags.environmentId -cne $EnvironmentName) { throw 'Arc identity ownership mismatch.' }
        $bindingValues = $script:state.outputs.BINDINGS_CONFIG.Clone()
        $bindingValues.arcPrincipalId = $machine.identity.principalId
        $bindingValues.arcMachineResourceId = $machine.id
        $bindingValues.enableProvisioningReader = $requiresInstall
        Write-Parameters $bindingsPath $bindingValues
        $bindingArgs = @('--location', $location, '--name', "retailtx-$EnvironmentName-bindings",
            '--template-file', (Join-Path $root 'infra\azure-bindings.bicep'), '--parameters', "@$bindingsPath")
        $null = Invoke-Azure (@('deployment', 'sub', 'what-if', '--no-pretty-print') + $bindingArgs)
        $null = Get-OwnedGroups
        $bindingDeployment = Invoke-Azure (@('deployment', 'sub', 'create') + $bindingArgs)
        $bindingOutputs = ConvertFrom-RetailDeploymentOutputs $bindingDeployment.properties.outputs
        if ($requiresInstall) {
            $script:state.setupCleanup = @{
                roleAssignments = @($script:state.outputs.BOOTSTRAP_ROLE_ASSIGNMENT_IDS) +
                    @($script:state.outputs.ARTIFACT_BRIDGE_ROLE_ASSIGNMENT_IDS) +
                    @($bindingOutputs.ARC_PROVISIONING_READER_ROLE_ASSIGNMENT_ID)
                databaseAdministrator = $script:state.outputs.DATABASE_BOOTSTRAP_ADMINISTRATOR_ID
                identities = @($script:state.outputs.DATABASE_BOOTSTRAP_IDENTITY_ID, $script:state.outputs.DC_BOOTSTRAP_IDENTITY_ID)
            }
            Save-State
            Install-Application
            Remove-SetupAccess
        }
        Set-ApplicationServices start
        $script:state.phase = 'application-installed'
        Save-State
        Update-Inventory
    }
    if ($Operation -eq 'Down') {
        $owned = Get-OwnedGroups
        foreach ($role in $owned.Keys) {
            $locks = @(Invoke-Azure @('lock', 'list', '--resource-group', $groups[$role]))
            if ($locks.Count -gt 0) { throw "Resource locks protect $($groups[$role]); no locks were changed." }
        }
        $script:state.phase = 'deleting'
        Save-State
        $guestStops = @{}
        foreach ($role in @('cloud', 'dc')) {
            $key = if ($role -eq 'cloud') { 'cloudVmId' } else { 'arcMachineId' }
            if ($owned.ContainsKey($role) -and $script:state.outputs.ContainsKey($key) -and $script:state.outputs[$key]) {
                $services = if ($role -eq 'cloud') {
                    'retailtx-cap-api retailtx-outbox-publisher retailtx-recon-job'
                } else { 'retailtx-erp-poster retailtx-erp-core' }
                try {
                    $null = Invoke-Guest -Role $role -Script "set -eu; systemctl stop $services" -TimeoutSeconds 120
                    $guestStops[$role] = 'stopped'
                } catch [System.Management.Automation.RuntimeException] {
                    $guestStops[$role] = 'unreachable-or-not-installed; owned VM destruction is the independent cleanup path'
                    Write-Warning "$role guest quiesce failed: $($_.Exception.Message). Continuing exact owned resource destruction."
                }
            } else {
                $guestStops[$role] = 'no-recorded-guest'
            }
        }
        Remove-MonitorAssociations
        foreach ($role in @('ops', 'cloud', 'dc')) {
            $owned = Get-OwnedGroups
            if ($owned.ContainsKey($role)) {
                $null = Invoke-Azure @('group', 'delete', '--name', $groups[$role], '--yes')
            }
        }
        if ((Get-OwnedGroups).Count -ne 0) { throw 'Owned resource groups remain after deletion.' }
        $residuals = @(Invoke-Azure @('resource', 'list', '--tag', "ownerToken=$($script:state.ownerToken)"))
        $script:state.resources = $residuals
        $script:state.phase = if ($residuals.Count -eq 0) { 'deleted' } else { 'residuals-found' }
        Save-State
        if ($residuals.Count -gt 0) { throw 'Owned live residuals remain; inspect the retained manifest.' }
        [pscustomobject]@{
            deletedGroups = $groups; ownedLiveResiduals = 0
            guestStops = $guestStops
            retention = 'Local manifest and ARM deployment history retained. Log Analytics/managed database soft deletion and backup retention are not purged. Expiry tags are not automated teardown.'
        }
        return
    }
    if ($Operation -eq 'Scenario') {
        Invoke-AppCommand dc "chaos/backlog.py --duration-seconds $DurationSeconds"
        return
    }
    if ($Operation -eq 'Reset') {
        $null = Invoke-AppCommand dc 'chaos/backlog.py --undo'
        $null = Invoke-Guest dc 'set -eu; systemctl start retailtx-erp-poster'
        $null = Invoke-AppCommand cloud 'scripts/azure/verify_guest.py --operation recovery'
    }
    if ($Operation -in @('Up', 'Doctor', 'Verify', 'Reset')) {
        $script:state.phase = 'verifying'
        $script:state.Remove('verification')
        Save-State
        $output = Invoke-AppCommand cloud 'scripts/azure/verify_guest.py --operation ready'
        if (-not $script:state.ContainsKey('alertsActivated') -or -not $script:state.alertsActivated) {
            if ($Operation -ne 'Up') { throw 'Alert activation is incomplete; resume Up before readiness.' }
            Deploy-Base -Alerts
            $script:state.alertsActivated = $true
            Save-State
            $output = Invoke-AppCommand cloud 'scripts/azure/verify_guest.py --operation ready'
        }
        $queueEvidence = Get-QueueEvidence
        $dcExtensions = Get-Resource "$($script:state.outputs.dcVmId)/extensions" $computeApi
        if (@($dcExtensions.value).Count -ne 0) {
            throw 'The Arc evaluation backing VM has native Compute extensions; readiness is blocked.'
        }
        $evidence = @{
            doctor = ($output | ConvertFrom-Json -AsHashtable)
            queue = $queueEvidence
            dcNativeExtensions = 0
            observedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $evidence.hosts = @{}
        foreach ($role in @('cloud', 'dc')) {
            $hostOutput = Invoke-Guest -Role $role -Script @'
set -euo pipefail
cd /opt/retailtx/current
.venv/bin/python scripts/azure/verify_guest.py --operation host
'@
            $evidence.hosts[$role] = $hostOutput | ConvertFrom-Json -AsHashtable
        }
        if ($Operation -eq 'Verify') {
            $baseline = (Invoke-AppCommand cloud 'scripts/azure/verify_guest.py --operation recovery' |
                ConvertFrom-Json -AsHashtable).recovered
            Wait-BacklogClear
            $seed = [guid]::NewGuid().ToString()
            $timer = "retailtx-restore-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
            $started = [DateTimeOffset]::UtcNow
            try {
                $null = Invoke-Guest dc @"
set -euo pipefail
systemd-run --unit=$timer --on-active=300 /bin/systemctl start retailtx-erp-poster
runuser -u retailtx -- bash -c 'set -a; source /etc/retailtx/runtime.env; set +a; cd /opt/retailtx/current; .venv/bin/python chaos/backlog.py --duration-seconds 300'
systemctl stop retailtx-erp-poster
"@
                $null = Invoke-AppCommand dc "sim/pos_sim.py --seed $seed --count 12 --interval 0 && .venv/bin/python sim/pos_sim.py --seed $seed --count 12 --interval 0"
                $stopped = Invoke-AppCommand cloud "scripts/azure/verify_guest.py --operation backlog --seed $seed --baseline-accepted $($baseline.accepted_count) --baseline-posted $($baseline.posted_count)"
                $evidence.backlog = $stopped | ConvertFrom-Json -AsHashtable
                $evidence.firedAlertId = Wait-BacklogAlert $started
            } finally {
                $null = Invoke-AppCommand dc 'chaos/backlog.py --undo'
                $null = Invoke-Guest dc @"
set -euo pipefail
systemctl start retailtx-erp-poster
if systemctl show $timer.timer --property=LoadState --value | grep -qx loaded; then
    systemctl stop $timer.timer
fi
"@
            }
            $recovered = Invoke-AppCommand cloud 'scripts/azure/verify_guest.py --operation recovery'
            $evidence.recovery = $recovered | ConvertFrom-Json -AsHashtable
            $evidence.queueAfterRecovery = Get-QueueEvidence
            $traces = Invoke-AppCommand cloud "scripts/azure/verify_guest.py --operation traces --seed $seed"
            $evidence.distributedTraces = $traces | ConvertFrom-Json -AsHashtable
        }
        $script:state.verification = $evidence
        $script:state.phase = 'application-ready'
        Save-State
        $evidence
    }
} catch {
    if ($script:state) {
        $script:state.phase = 'operation-failed'
        $script:state.Remove('verification')
        Save-State
    }
    throw
} finally {
    $lock.Dispose()
}
