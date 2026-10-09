#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:checks = 0

function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe Service Bus scenario operation was accepted.' }
}

$scriptPath = Join-Path $PSScriptRoot '..\scripts\Invoke-ServiceBusScenario.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors -join "`n") }
$functionNames = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object Name)
foreach ($required in @(
    'Get-ServiceBusActionGate', 'Assert-ServiceBusActionGate',
    'Get-OwnedScenarioGroup', 'Assert-ServiceBusPrivateDnsOwnership',
    'Get-ServiceBusFoundationDnsLockPath', 'Enter-ServiceBusFoundationDnsLock',
    'Get-ServiceBusDoctorResult'
)) {
    if ($required -notin $functionNames) { throw "Missing fail-closed gate function $required." }
}

$EnvironmentName = 'demo01'
foreach ($name in @('Get-ServiceBusActionGate', 'Assert-ServiceBusActionGate')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$gate = Get-ServiceBusActionGate
if ($gate.readiness -cne 'Blocked' -or $gate.preInvocationEnforcement -or
    $gate.autonomousResponsePlan -cne 'NotConfiguredByThisScript' -or
    $gate.queueStatusMutation -cne 'NotAuthorized' -or $gate.blockers.Count -lt 3) {
    throw 'The Service Bus tool boundary must remain explicitly blocked until verified.'
}
Assert-Rejected { Assert-ServiceBusActionGate }

$doctorDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Get-ServiceBusDoctorResult'
}, $true)
$lockPathDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Get-ServiceBusFoundationDnsLockPath'
}, $true)
$enterLockDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Enter-ServiceBusFoundationDnsLock'
}, $true)
. ([scriptblock]::Create($doctorDefinition.Extent.Text))
. ([scriptblock]::Create($lockPathDefinition.Extent.Text))
. ([scriptblock]::Create($enterLockDefinition.Extent.Text))
$savedReadyState = @{
    status = 'Ready'
    outputs = @{ QUEUEID = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/sb/queues/recovery-demo01' }
}
$verifiedGroup = @{ id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg' }
$doctorResult = Get-ServiceBusDoctorResult -State $savedReadyState -Group $verifiedGroup -ActionGate $gate
if ($doctorResult.fixture -cne 'ManifestAndGroupVerified' -or
    $doctorResult.savedManifestStatus -cne 'Ready' -or
    $doctorResult.deploymentHealth -cne 'NotChecked' -or
    $doctorResult.queueHealth -cne 'NotChecked' -or
    $doctorResult.ready -or -not $doctorResult.queueId) {
    throw 'Doctor must not treat saved Ready plus resource-group ownership as live scenario readiness.'
}
$notDeployedDoctor = Get-ServiceBusDoctorResult -State $null -Group $null -ActionGate $gate
if ($notDeployedDoctor.ready -or $notDeployedDoctor.fixture -cne 'NotDeployed') {
    throw 'Doctor must not report an absent queue or fixture as ready.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$foundationVnetId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-retailtx-stage0-swedencentral/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-stage0'
$sharedLockPath = Get-ServiceBusFoundationDnsLockPath -VirtualNetworkId $foundationVnetId
$sameVnetLockPath = Get-ServiceBusFoundationDnsLockPath -VirtualNetworkId $foundationVnetId
$differentVnetLockPath = Get-ServiceBusFoundationDnsLockPath -VirtualNetworkId ($foundationVnetId -replace 'vnet-retailtx-stage0$', 'vnet-retailtx-other')
if ($sharedLockPath -cne $sameVnetLockPath -or $sharedLockPath -ceq $differentVnetLockPath) {
    throw 'The shared DNS lock must be stable per foundation VNet and distinct across VNets.'
}
$heldDnsLock = [IO.File]::Open($sharedLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    Assert-Rejected { Enter-ServiceBusFoundationDnsLock -VirtualNetworkId $foundationVnetId }
} finally {
    $heldDnsLock.Dispose()
}

$foundationFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Get-VerifiedFoundation'
}, $true)
if (-not $foundationFunction.Extent.Text.Contains('Microsoft\.App/agents/[^/]+$')) {
    throw 'Foundation SRE identity validation must match the deployed Microsoft.App/agents resource type.'
}
& {
    $subscription = '11111111-1111-1111-1111-111111111111'
    $FoundationEnvironment = 'stage0'
    $foundationGroupName = 'rg-retailtx-stage0-swedencentral'
    $repositoryRoot = 'C:\retailtx-tests'
    $expectedTenant = '22222222-2222-2222-2222-222222222222'
    $foundationFixture = @{
        subscriptionId = $subscription
        tenantId = $expectedTenant
        environmentName = $FoundationEnvironment
        ownerToken = '33333333-3333-3333-3333-333333333333'
        outputs = @{
            SRE_AGENT_ID = "/subscriptions/$subscription/resourceGroups/$foundationGroupName/providers/Microsoft.App/agents/retailtx-stage0"
            WORKSPACE_ID = "/subscriptions/$subscription/resourceGroups/$foundationGroupName/providers/Microsoft.OperationalInsights/workspaces/law-retailtx-stage0"
            DCE_ID = "/subscriptions/$subscription/resourceGroups/$foundationGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/dce-retailtx-stage0"
        }
    }
    $foundationGroup = @{
        id = "/subscriptions/$subscription/resourceGroups/$foundationGroupName"
        location = 'swedencentral'
        tags = @{
            demo = 'retailtx'
            environmentId = $FoundationEnvironment
            ownerToken = $foundationFixture.ownerToken
            managedBy = 'retailtx-stage0'
        }
    }
    $foundationVnet = @{
        id = "$($foundationGroup.id)/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-stage0"
        tags = @{ ownerToken = $foundationFixture.ownerToken }
        subnets = @(
            @{
                name = 'private-endpoints'
                addressPrefix = '10.84.1.0/24'
                id = "$($foundationGroup.id)/providers/Microsoft.Network/virtualNetworks/vnet-retailtx-stage0/subnets/private-endpoints"
            }
        )
    }
    function Test-Path {
        param([string]$LiteralPath, [string]$PathType)
        return $true
    }
    function Get-Content {
        param([string]$LiteralPath, [switch]$Raw)
        return ($foundationFixture | ConvertTo-Json -Depth 10 -Compress)
    }
    function Invoke-Azure {
        param([string[]]$Arguments)
        if ($Arguments[0] -ceq 'account' -and $Arguments[1] -ceq 'show') {
            return @{ id = $subscription; tenantId = $expectedTenant }
        }
        if ($Arguments[0] -ceq 'group' -and $Arguments[1] -ceq 'show') {
            return $foundationGroup
        }
        if ($Arguments[0] -ceq 'network' -and $Arguments[1] -ceq 'vnet') {
            return $foundationVnet
        }
        throw 'Unexpected foundation read in offline regression.'
    }
    . ([scriptblock]::Create($foundationFunction.Extent.Text))
    $foundationResult = Get-VerifiedFoundation
    if ($foundationResult.state.outputs.SRE_AGENT_ID -notmatch
        '/providers/Microsoft\.App/agents/retailtx-stage0$') {
        throw 'The retained Microsoft.App SRE Agent resource was not accepted.'
    }
    $script:checks++
    $foundationFixture.outputs.SRE_AGENT_ID =
        "/subscriptions/$subscription/resourceGroups/$foundationGroupName/providers/Microsoft.SRE/agents/retailtx-stage0"
    Assert-Rejected { Get-VerifiedFoundation }
}

$script:subscription = '11111111-1111-1111-1111-111111111111'
$script:groupName = 'rg-retailtx-servicebus-demo01-swedencentral'
$script:scenarioState = @{
    groupId = "/subscriptions/$subscription/resourceGroups/$groupName"
    ownerToken = '22222222-2222-2222-2222-222222222222'
}
$script:fakeGroup = @{
    id = $scenarioState.groupId
    location = 'swedencentral'
    tags = @{
        demo = 'retailtx'
        environmentId = 'demo01'
        ownerToken = $scenarioState.ownerToken
        profile = 'servicebus'
        managedBy = 'retailtx'
    }
}
function Invoke-Azure {
    param([string[]]$Arguments)
    if ($Arguments[0] -ceq 'group' -and $Arguments[1] -ceq 'exists') { return $true }
    if ($Arguments[0] -ceq 'group' -and $Arguments[1] -ceq 'show') { return $script:fakeGroup }
    if ($Arguments[0] -ceq 'network') { return @($script:fakeZones) }
    throw 'Unexpected Azure read in offline ownership test.'
}
$helperNames = @('Get-OwnedScenarioGroup', 'Assert-ServiceBusPrivateDnsOwnership')
foreach ($name in $helperNames) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
if (-not (Get-OwnedScenarioGroup)) { throw 'Exact owned resource group was not accepted.' }
$originalOwner = $fakeGroup.tags.ownerToken
$fakeGroup.tags.ownerToken = 'foreign'
Assert-Rejected { Get-OwnedScenarioGroup }
$fakeGroup.tags.ownerToken = $originalOwner
$script:fakeZones = @(@{
    id = "$($scenarioState.groupId)/providers/Microsoft.Network/privateDnsZones/privatelink.servicebus.windows.net"
    name = 'privatelink.servicebus.windows.net'
    resourceGroup = $groupName
    tags = @{
        demo = 'retailtx'
        environmentId = 'demo01'
        profile = 'servicebus'
        ownerToken = $scenarioState.ownerToken
        managedBy = 'retailtx'
    }
})
Assert-ServiceBusPrivateDnsOwnership
$script:fakeZones[0].tags.ownerToken = 'foreign'
Assert-Rejected { Assert-ServiceBusPrivateDnsOwnership }
$script:fakeZones[0].tags.ownerToken = $scenarioState.ownerToken
$script:fakeZones[0].id = "$($scenarioState.groupId)/providers/Microsoft.Network/privateDnsZones/foreign.example"
Assert-Rejected { Assert-ServiceBusPrivateDnsOwnership }
$script:fakeZones = @(@{ name = 'privatelink.servicebus.windows.net'; resourceGroup = 'shared' })
Assert-Rejected { Assert-ServiceBusPrivateDnsOwnership }

$armBranch = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.SwitchStatementAst]
}, $true)
if (-not $armBranch.Extent.Text.Contains("'Arm'") -or
    -not $armBranch.Extent.Text.Contains('Assert-ServiceBusActionGate')) {
    throw 'Arm must invoke the fail-closed enforcement gate.'
}
if ($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -match '^(az|Invoke-RestMethod|Invoke-WebRequest)$'
}, $true).Count) {
    throw 'The orchestrator must not issue direct Azure or external requests outside its bounded helper.'
}
$upFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-ServiceBusUp'
}, $true)
$upCommands = @($upFunction.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
$manifestWrite = @($upCommands | Where-Object { $_.GetCommandName() -eq 'Save-State' })[0]
$groupCreate = @($upCommands | Where-Object { $_.Extent.Text -match "'group', 'create" })[0]
$deploymentCreate = @($upCommands | Where-Object { $_.Extent.Text -match "'deployment', 'group', 'create" })[0]
if (-not $groupCreate -or -not $deploymentCreate -or -not $manifestWrite -or
    $manifestWrite.Extent.StartOffset -ge $groupCreate.Extent.StartOffset -or
    $manifestWrite.Extent.StartOffset -ge $deploymentCreate.Extent.StartOffset) {
    throw 'Up must persist the ownership manifest before any Azure write.'
}
$downFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-ServiceBusDown'
}, $true)
$downCommands = @($downFunction.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
$downDnsGuard = @($downCommands | Where-Object { $_.GetCommandName() -eq 'Assert-ServiceBusPrivateDnsOwnership' })[0]
$downDelete = @($downCommands | Where-Object { $_.Extent.Text -match "'group', 'delete" })[0]
if (-not $downDnsGuard -or -not $downDelete -or
    $downDnsGuard.Extent.StartOffset -ge $downDelete.Extent.StartOffset) {
    throw 'Down must verify exact DNS zone ownership before deleting the owned group.'
}

$templatePath = Join-Path $PSScriptRoot '..\infra\servicebus-scenario.bicep'
$template = Get-Content -LiteralPath $templatePath -Raw
foreach ($requirement in @(
    "br/public:avm/res/service-bus/namespace:0.17.1",
    "br/public:avm/res/network/private-endpoint:0.12.1",
    "disableLocalAuth: true",
    "publicNetworkAccess: 'Disabled'",
    "status: 'Active'",
    "metricName: 'UserErrors'",
    "name: 'EntityName'",
    "scope: scenarioQueue",
    'param probeSystemIdentityPrincipalId string',
    '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39',
    '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0',
    "actions: []"
)) {
    if (-not $template.Contains($requirement)) {
        throw "Service Bus Bicep contract is missing: $requirement"
    }
}
if ($template -notmatch 'name:\s+''\$\{namespaceName\}/\$\{queueName\}''') {
    throw 'The probe queue must be nested under the dedicated owned namespace.'
}
if ($template -match "Azure Service Bus Data Owner|SRE_AGENT_ID|scope:\s*broker") {
    throw 'Scenario must not assign namespace-wide or SRE data-plane privileges.'
}
if ($template -notmatch "roleDefinitionId:\s*senderRoleId" -or
    $template -notmatch "roleDefinitionId:\s*receiverRoleId") {
    throw 'Probe sender and receiver grants must remain at the exact queue scope.'
}

Write-Output 'Service Bus scenario offline contract checks passed.'
