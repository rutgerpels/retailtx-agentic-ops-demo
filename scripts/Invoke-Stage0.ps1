#Requires -Version 7.2
<#
.SYNOPSIS
Provision and inspect an isolated, private, Entra-only Stage 0 environment.
.DESCRIPTION
Up runs Azure Developer CLI preview/provision and configures Arc monitoring.
Verify runs a fixed, harmless host/identity/telemetry check as the deploying operator,
not as SRE Agent. Down requires the matching local manifest and live ownership tags.
No subscription defaults, policies, shared resources, or budgets are modified.
.PARAMETER Operation
Preflight, Up, Status, Verify, or Down.
.PARAMETER SubscriptionId
Explicit Azure subscription; never inferred from the global CLI default.
.PARAMETER EnvironmentName
Generic environment ID used for resource names and the ignored .azure state folder.
.PARAMETER Location
Azure region. The initial proof is restricted to Sweden Central.
.EXAMPLE
.\scripts\Invoke-Stage0.ps1 -Operation Up -SubscriptionId <guid> -EnvironmentName stage0
.EXAMPLE
.\scripts\Invoke-Stage0.ps1 -Operation Down -SubscriptionId <guid> -EnvironmentName stage0 -WhatIf
.OUTPUTS
Objects describing preflight, live state, or verification evidence.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Preflight', 'Up', 'Status', 'Verify', 'Down')]
    [string]$Operation,
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentName = 'stage0',
    [ValidateSet('swedencentral')]
    [string]$Location = 'swedencentral'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Stage0.Common.psm1') -Force
Assert-Stage0Name -Name $EnvironmentName
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$environmentDirectory = Join-Path $repositoryRoot ".azure\$EnvironmentName"
$statePath = Join-Path $environmentDirectory 'retailtx-state.json'
$groupName = "rg-retailtx-$EnvironmentName-$Location"
$subscription = $SubscriptionId.ToString()
$script:state = $null
$arcApi = '2026-07-15'
$agentApi = '2026-01-01'

function Invoke-AzureJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $response = & az @Arguments --subscription $subscription --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..([Math]::Min(1, $Arguments.Count - 1))] -join ' ')." }
    if ($response) { return (($response -join "`n") | ConvertFrom-Json) }
}

function Invoke-Azd {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $previousConfigDirectory = $env:AZD_CONFIG_DIR
    try {
        $env:AZD_CONFIG_DIR = Join-Path $environmentDirectory 'azd-config'
        & azd @Arguments --cwd $repositoryRoot --no-prompt
        if ($LASTEXITCODE -ne 0) { throw "Azure Developer CLI failed: $($Arguments[0])." }
    } finally {
        $env:AZD_CONFIG_DIR = $previousConfigDirectory
    }
}

function Get-DeployerObjectId {
    # Use the target-tenant ARM identity, not the CLI's potentially different default Graph tenant.
    if ($account.user.type -ne 'user') { throw 'Stage 0 requires an interactive Entra operator identity.' }
    $rawToken = & az account get-access-token --subscription $subscription `
        --resource https://management.azure.com/ --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $rawToken) { throw 'Could not resolve the target-tenant deploying identity.' }
    try {
        $payload = (($rawToken -join '') -split '\.')[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if ($claims.tid -ine $account.tenantId) { throw 'ARM token tenant does not match the target subscription.' }
        return [guid]::Parse($claims.oid).ToString()
    } finally {
        $rawToken = $null
        $payload = $null
    }
}

function Get-OwnedGroup {
    $exists = Invoke-AzureJson -Arguments @('group', 'exists', '--name', $groupName)
    if (-not $exists) { return $null }
    $group = Invoke-AzureJson -Arguments @('group', 'show', '--name', $groupName)
    if (-not $script:state) {
        throw 'The target group already exists without this local manifest. Refusing to adopt it.'
    }
    Assert-Stage0Ownership -State $script:state -ResourceGroup $group
    return $group
}

function Save-CurrentState {
    Save-Stage0State -State $script:state -Path $statePath
}

function Read-CurrentState {
    $script:state = $null
    if (Test-Path -LiteralPath $statePath) {
        $script:state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -AsHashtable
        if ($script:state.schemaVersion -ne 1 -or $script:state.subscriptionId -ine $subscription -or
            $script:state.tenantId -ine $account.tenantId -or $script:state.environmentName -cne $EnvironmentName -or
            $script:state.resourceGroupName -cne $groupName -or $script:state.location -cne $Location) {
            throw 'Manifest does not match the requested environment, tenant, subscription, or schema.'
        }
    }
}

function Get-ArmResource {
    param([string]$Id, [string]$ApiVersion)
    Invoke-AzureJson -Arguments @('rest', '--method', 'get', '--url', "https://management.azure.com${Id}?api-version=$ApiVersion")
}

function Update-Inventory {
    $resources = @(Invoke-AzureJson -Arguments @('resource', 'list', '--resource-group', $groupName))
    $script:state.resources = @($resources | ForEach-Object { @{ id = $_.id; type = $_.type } })
    Save-CurrentState
}

function Set-AgentKnowledge {
    $agent = Get-ArmResource -Id $script:state.outputs.SRE_AGENT_ID -ApiVersion $agentApi
    $endpoint = [uri]$agent.properties.agentEndpoint
    if ($endpoint.Scheme -ne 'https' -or -not $endpoint.Host.EndsWith('.azuresre.ai')) {
        throw 'Unexpected SRE data-plane endpoint. Refusing to send an Entra token.'
    }
    $rawToken = & az account get-access-token --subscription $subscription --resource https://azuresre.dev --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $rawToken) { throw 'SRE data-plane authentication is unavailable; knowledge configuration is not complete.' }
    $token = ConvertTo-SecureString ($rawToken -join '') -AsPlainText -Force
    $rawToken = $null
    $content = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'docs\agent-context\stage0.md')
    $content += "`nEnvironment resource group: $groupName`nWorkspace resource: $($script:state.outputs.WORKSPACE_ID)`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
    $body = @{
        name = 'retailtx-stage0'
        type = 'KnowledgeItem'
        tags = @()
        properties = @{
            dataConnectorType = 'KnowledgeFile'
            dataSource = 'retailtx-stage0'
            extendedProperties = @{
                displayName = 'RetailTx Stage 0'
                fileName = 'stage0.md'
                fileContent = $encoded
                contentType = 'text/markdown'
            }
        }
    } | ConvertTo-Json -Depth 10
    $uri = "$($endpoint.AbsoluteUri.TrimEnd('/'))/api/v2/extendedAgent/connectors/retailtx-stage0"
    try {
        $null = Invoke-RestMethod -Uri $uri -Method Put -Authentication Bearer -Token $token `
            -ContentType 'application/json' -Body $body -TimeoutSec 60
        $stored = Invoke-RestMethod -Uri $uri -Method Get -Authentication Bearer -Token $token -TimeoutSec 60
        Assert-Stage0Knowledge -Item $stored -ExpectedSize ([Text.Encoding]::UTF8.GetByteCount($content))
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        throw "SRE knowledge configuration HTTP failure ($([int]$_.Exception.Response.StatusCode)); no successful readiness state was recorded."
    } finally {
        $token.Dispose()
    }
    $script:state.knowledgeConfigured = $true
    $script:state.knowledgeVerification = 'stored-metadata-verified; retrieval/indexing is a separate check'
    $script:state.outputs.SRE_ENDPOINT = $endpoint.AbsoluteUri.TrimEnd('/')
    Save-CurrentState
}

function Invoke-FixedArcCommand {
    param([string]$Name, [string]$Script)
    $machineId = "/subscriptions/$subscription/resourceGroups/$groupName/providers/Microsoft.HybridCompute/machines/erp-core-01"
    $commandId = "$machineId/runCommands/$Name"
    $body = @{
        location = $Location
        properties = @{
            source = @{ script = $Script.Replace("`r`n", "`n") }
            timeoutInSeconds = 180
            asyncExecution = $false
        }
    }
    $bodyPath = Join-Path $environmentDirectory 'run-command.json'
    try {
        $body | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bodyPath -Encoding utf8NoBOM
        $null = Invoke-AzureJson -Arguments @('rest', '--method', 'put', '--url',
            "https://management.azure.com${commandId}?api-version=$arcApi", '--body', "@$bodyPath")
    } finally {
        Remove-Item -LiteralPath $bodyPath -ErrorAction Stop
    }
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(6)
    do {
        $commands = Get-ArmResource -Id "$machineId/runCommands" -ApiVersion $arcApi
        if (-not ($commands.value | Where-Object name -CEQ $Name)) {
            Start-Sleep -Seconds 10
            continue
        }
        $command = Get-ArmResource -Id $commandId -ApiVersion $arcApi
        $properties = $command.properties
        if ($properties.PSObject.Properties.Name -contains 'instanceView') {
            $view = $properties.instanceView
            if ($view.executionState -eq 'Succeeded') {
                if ($view.exitCode -ne 0) { throw "Arc command exited with $($view.exitCode): $($view.error)" }
                return $view.output
            }
            if ($view.executionState -in @('Failed', 'Canceled', 'TimedOut')) {
                throw "Arc command $Name failed: $($view.error) $($view.output)"
            }
        }
        if ($properties.provisioningState -eq 'Failed') { throw "Arc command $Name provisioning failed." }
        Start-Sleep -Seconds 10
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Arc command $Name did not finish within six minutes."
}

foreach ($tool in @('az', 'azd')) { $null = Get-Command $tool -ErrorAction Stop }
$account = Invoke-AzureJson -Arguments @('account', 'show')
if ($account.id -ine $subscription -or $account.state -ne 'Enabled') {
    throw "Target subscription $subscription is unavailable or disabled (returned $($account.id), state $($account.state))."
}

Read-CurrentState

if ($Operation -eq 'Preflight') {
    $provider = Invoke-AzureJson -Arguments @('provider', 'show', '--namespace', 'Microsoft.App')
    $agentType = $provider.resourceTypes | Where-Object resourceType -CEQ 'agents'
    if (-not $agentType -or 'Sweden Central' -notin $agentType.locations) {
        throw 'SRE Agent is not advertised in Sweden Central for this subscription.'
    }
    $policies = @(Invoke-AzureJson -Arguments @('policy', 'assignment', 'list',
        '--scope', "/subscriptions/$subscription", '--disable-scope-strict-match'))
    $permissions = Invoke-AzureJson -Arguments @('rest', '--method', 'get', '--url',
        "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Authorization/permissions?api-version=2022-04-01")
    [pscustomobject]@{
        subscriptionId = $subscription
        tenantId = $account.tenantId
        location = $Location
        sreAgentAvailable = $true
        policyAssignments = $policies.Count
        permissions = @($permissions.value | Select-Object actions, notActions)
        note = 'Read-only inventory. Deployment preview/validation is still required; this does not override policy.'
    }
    return
}

$null = Get-OwnedGroup
if ($Operation -ne 'Up' -and -not $script:state) { throw 'No environment manifest exists. Run Up first.' }
if ($Operation -in @('Up', 'Verify', 'Down') -and
    -not $PSCmdlet.ShouldProcess("/subscriptions/$subscription/resourceGroups/$groupName", $Operation)) {
    return
}

$null = New-Item -ItemType Directory -Path $environmentDirectory -Force
$lockPath = Join-Path $environmentDirectory 'retailtx.lock'
$lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    Read-CurrentState
    $null = Get-OwnedGroup
    if ($Operation -ne 'Up' -and -not $script:state) { throw 'Environment manifest disappeared before the lifecycle lock was acquired.' }
    if ($Operation -eq 'Up') {
        if (-not $script:state) {
            $script:state = @{
                schemaVersion = 1
                subscriptionId = $subscription
                tenantId = $account.tenantId
                location = $Location
                environmentName = $EnvironmentName
                resourceGroupName = $groupName
                ownerToken = [guid]::NewGuid().ToString()
                createdAt = [DateTimeOffset]::UtcNow.ToString('o')
                phase = 'initialized'
                outputs = @{}
                resources = @()
            }
            Save-CurrentState
        }
        $deployer = Get-DeployerObjectId
        if (-not $deployer) { throw 'Stage 0 requires an interactive Entra operator identity for the initial proof.' }
        if (-not $script:state.ContainsKey('sshPublicKey')) {
            $keyPath = Join-Path $environmentDirectory 'provisioning-key'
            try {
                & ssh-keygen -q -t rsa -b 3072 -N '""' -C 'retailtx-disabled-ssh' -f $keyPath
                if ($LASTEXITCODE -ne 0) { throw 'Could not generate the provisioning-only SSH public key.' }
                $script:state.sshPublicKey = (Get-Content -Raw -LiteralPath "$keyPath.pub").Trim()
                Save-CurrentState
            } finally {
                foreach ($path in @($keyPath, "$keyPath.pub")) {
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
                }
            }
        }
        Invoke-Azd -Arguments @('config', 'set', 'auth.useAzCliAuth', 'true')
        if (-not (Test-Path -LiteralPath (Join-Path $environmentDirectory '.env'))) {
            # The manifest/lock already reserved this directory, which azd env new refuses to adopt.
            @(
                "AZURE_ENV_NAME=`"$EnvironmentName`""
                "AZURE_SUBSCRIPTION_ID=`"$subscription`""
                "AZURE_LOCATION=`"$Location`""
            ) | Set-Content -LiteralPath (Join-Path $environmentDirectory '.env') -Encoding utf8NoBOM
        }
        $values = @{
            AZURE_ENV_NAME = $EnvironmentName
            AZURE_SUBSCRIPTION_ID = $subscription
            AZURE_TENANT_ID = $account.tenantId
            AZURE_LOCATION = $Location
            OWNER_TOKEN = $script:state.ownerToken
            SSH_PUBLIC_KEY = $script:state.sshPublicKey
            DEPLOYER_OBJECT_ID = $deployer
        }
        foreach ($entry in $values.GetEnumerator()) {
            Invoke-Azd -Arguments @('env', 'set', $entry.Key, $entry.Value, '--environment', $EnvironmentName)
        }
        $script:state.phase = 'provisioning'
        Save-CurrentState
        Invoke-Azd -Arguments @('provision', '--preview', '--environment', $EnvironmentName)
        $null = Get-OwnedGroup
        Invoke-Azd -Arguments @('provision', '--environment', $EnvironmentName)
        $environmentValues = ConvertFrom-Stage0Environment -Lines (Get-Content -LiteralPath (Join-Path $environmentDirectory '.env'))
        $script:state.outputs = @{}
        foreach ($key in @('RESOURCE_GROUP_NAME', 'VM_NAME', 'ARC_MACHINE_NAME',
            'ARC_PRIVATE_LINK_SCOPE_ID', 'WORKSPACE_ID', 'WORKSPACE_CUSTOMER_ID',
            'DCE_ID', 'DCR_ID', 'SRE_AGENT_ID', 'SRE_ENDPOINT',
            'BOOTSTRAP_IDENTITY_ID', 'BOOTSTRAP_ROLE_ASSIGNMENT_ID')) {
            if ($environmentValues.ContainsKey($key)) { $script:state.outputs[$key] = $environmentValues[$key] }
        }
        Save-CurrentState
        $null = Get-OwnedGroup
        Update-Inventory
        $deadline = [DateTimeOffset]::UtcNow.AddMinutes(25)
        do {
            $machines = @(Invoke-AzureJson -Arguments @('resource', 'list', '--resource-group', $groupName,
                '--resource-type', 'Microsoft.HybridCompute/machines'))
            $targetMachine = $machines | Where-Object name -CEQ 'erp-core-01'
            if ($targetMachine) {
                $machine = Get-ArmResource -Id $targetMachine.id -ApiVersion $arcApi
                if ($machine.properties.status -eq 'Connected') { break }
            }
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                throw 'Arc host did not connect within 25 minutes. Inspect VM boot diagnostics; no public-access fallback was enabled.'
            }
            Start-Sleep -Seconds 20
        } while ($true)
        $outputs = $script:state.outputs
        foreach ($key in @('DCR_ID', 'DCE_ID', 'WORKSPACE_ID', 'BOOTSTRAP_ROLE_ASSIGNMENT_ID', 'SRE_AGENT_ID')) {
            if (-not $outputs.ContainsKey($key) -or -not $outputs[$key]) { throw "Missing infrastructure output $key." }
        }
        $parameters = @("machineName=erp-core-01", "dcrId=$($outputs.DCR_ID)",
            "dceId=$($outputs.DCE_ID)", "workspaceName=$(($outputs.WORKSPACE_ID -split '/')[-1])")
        $template = Join-Path $repositoryRoot 'infra\arc-monitor.bicep'
        $null = Invoke-AzureJson -Arguments (@('deployment', 'group', 'what-if', '--no-pretty-print', '--name', 'retailtx-arc-monitor',
            '--resource-group', $groupName, '--template-file', $template, '--parameters') + $parameters)
        $null = Invoke-AzureJson -Arguments (@('deployment', 'group', 'create', '--name', 'retailtx-arc-monitor',
            '--resource-group', $groupName, '--template-file', $template, '--parameters') + $parameters)
        $null = Invoke-AzureJson -Arguments @('role', 'assignment', 'delete', '--ids', $outputs.BOOTSTRAP_ROLE_ASSIGNMENT_ID)
        Set-AgentKnowledge
        $script:state.phase = 'infrastructure-ready'
        $script:state.sreRemediation = 'not-enabled-read-only'
        Update-Inventory
    }

    if ($Operation -eq 'Verify') {
        $null = Get-OwnedGroup
        $script:state.phase = 'verifying'
        $script:state.Remove('verification')
        $script:state.Remove('verifiedAt')
        $script:state.Remove('verificationError')
        Save-CurrentState
        try {
            if (-not $script:state.outputs.ContainsKey('WORKSPACE_CUSTOMER_ID')) { throw 'Workspace output is missing.' }
            $workspace = [guid]::Parse($script:state.outputs.WORKSPACE_CUSTOMER_ID).ToString()
            $machineId = "/subscriptions/$subscription/resourceGroups/$groupName/providers/Microsoft.HybridCompute/machines/erp-core-01"
            $source = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'verify-arc.py')
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
            $check = "set -eu`nprintf '%s' '$encoded' | base64 --decode | python3 - --workspace-id '$workspace' --machine-id '$machineId'"
            $name = "rtx-$([guid]::NewGuid().ToString('N'))"
            $script:state.verificationCommandId = "$machineId/runCommands/$name"
            Save-CurrentState
            $output = Invoke-FixedArcCommand -Name $name -Script $check
            $evidence = $output | ConvertFrom-Json -AsHashtable
            Assert-Stage0Evidence -Evidence $evidence -MachineId $machineId
            $script:state.verification = $evidence
            $script:state.verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
            $script:state.phase = 'host-verified-sre-read-only'
            Update-Inventory
        } catch {
            $script:state.phase = 'verification-failed'
            $script:state.Remove('verification')
            $script:state.Remove('verifiedAt')
            $script:state.verificationError = 'The latest fixed host check failed. Inspect its Arc Run Command and retry after resolving the reported error.'
            Save-CurrentState
            throw
        }
        $script:state.verification
        return
    }

    if ($Operation -eq 'Down') {
        $group = Get-OwnedGroup
        if ($group) {
            $resources = @(Invoke-AzureJson -Arguments @('resource', 'list', '--resource-group', $groupName))
            Write-Information -MessageData (($resources | ForEach-Object { "$($_.type) $($_.name)" }) -join "`n") -InformationAction Continue
            $locks = @(Invoke-AzureJson -Arguments @('lock', 'list', '--resource-group', $groupName))
            if ($locks.Count -gt 0) { throw 'Resource locks exist. No locks were removed; resolve retention policy before teardown.' }
            # The owned VM is disposable: group deletion also removes its Arc registration.
            # No shared host is disconnected and no guest token or Entra application was created.
            $script:state.phase = 'deleting'
            Save-CurrentState
            $null = Invoke-AzureJson -Arguments @('group', 'delete', '--name', $groupName, '--yes')
        }
        if (Invoke-AzureJson -Arguments @('group', 'exists', '--name', $groupName)) {
            throw 'Resource group still exists after deletion.'
        }
        $script:state.phase = 'deleted'
        $script:state.resources = @()
        $script:state.deletedAt = [DateTimeOffset]::UtcNow.ToString('o')
        Save-CurrentState
        [pscustomobject]@{
            resourceGroup = $groupName
            deleted = $true
            retention = 'Local manifest and subscription deployment records remain. Log Analytics soft-deleted data follows Azure retention; no purge is attempted.'
        }
        return
    }

    $group = Get-OwnedGroup
    if (-not $group) {
        [pscustomobject]@{ resourceGroup = $groupName; exists = $false; phase = $script:state.phase }
        return
    }
    $agent = if ($script:state.outputs.ContainsKey('SRE_AGENT_ID')) {
        Get-ArmResource -Id $script:state.outputs.SRE_AGENT_ID -ApiVersion $agentApi
    } else { $null }
    [pscustomobject]@{
        resourceGroup = $groupName
        phase = $script:state.phase
        resourceCount = @(Invoke-AzureJson -Arguments @('resource', 'list', '--resource-group', $groupName)).Count
        agent = if ($agent) {
            @{
                id = $agent.id
                provisioningState = $agent.properties.provisioningState
                actionConfiguration = $agent.properties.actionConfiguration
                endpoint = $agent.properties.agentEndpoint
            }
        } else { $null }
        portal = "https://portal.azure.com/#resource/subscriptions/$subscription/resourceGroups/$groupName/overview"
        note = 'Infrastructure readiness is not proof of SRE approval-gated remediation. Run Verify for host/identity/telemetry evidence.'
    }
} finally {
    $lock.Dispose()
}
