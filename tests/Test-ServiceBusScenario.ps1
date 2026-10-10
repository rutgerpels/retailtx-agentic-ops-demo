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
    'Get-ServiceBusAlertRuleName', 'Test-ServiceBusAlertEssentials',
    'Assert-ServiceBusEasyAuthBinding',
    'Enter-ServiceBusScenarioLock',
    'Get-ServiceBusSreConnectorIdentity',
    'Get-ServiceBusDoctorResult', 'Invoke-ServiceBusFault',
    'Invoke-ServiceBusIncidentObservation', 'Invoke-ServiceBusRecover',
    'Invoke-ServiceBusReset', 'Invoke-ServiceBusUp', 'Invoke-ServiceBusDown',
    'Assert-ServiceBusExecutorRuntime', 'Assert-ServiceBusFoundationPeeringOwnership'
)) {
    if ($required -notin $functionNames) { throw "Missing fail-closed gate function $required." }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scenarioState = @{ ownerToken = '12345678-1234-1234-1234-123456789abc' }
foreach ($helperName in @(
    'Get-ServiceBusSourceDigest',
    'New-ServiceBusRunnerSshPublicKey',
    'Test-ServiceBusRunnerSshPublicKey',
    'Get-ServiceBusRunnerSshPublicKey',
    'New-ServiceBusRunnerBundle',
    'New-ServiceBusRunnerBootstrapScript'
)) {
    $helper = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $helperName
    }, $true)
    . ([scriptblock]::Create($helper.Extent.Text))
}
$runnerOwnerToken = [guid]::NewGuid()
$runnerPublicKey = New-ServiceBusRunnerSshPublicKey -OwnerToken $runnerOwnerToken
if (-not (Test-ServiceBusRunnerSshPublicKey -PublicKey $runnerPublicKey) -or
    $runnerPublicKey -match 'PRIVATE KEY|BEGIN RSA' -or
    $runnerPublicKey -notmatch ([regex]::Escape($runnerOwnerToken.ToString()))) {
    throw 'Runner provisioning must generate an owner-bound OpenSSH public key without persisting private material.'
}
$existingRunnerState = [ordered]@{ ownerToken = $runnerOwnerToken.ToString() }
$firstPersistedPublicKey = Get-ServiceBusRunnerSshPublicKey -State $existingRunnerState
$secondPersistedPublicKey = Get-ServiceBusRunnerSshPublicKey -State $existingRunnerState
if ($firstPersistedPublicKey -cne $secondPersistedPublicKey -or
    $existingRunnerState.runnerSshPublicKey -cne $firstPersistedPublicKey) {
    throw 'An existing owner manifest must persist and reuse its one provisioning-only public key.'
}
$existingRunnerState.runnerSshPublicKey = $runnerPublicKey
$existingRunnerState.ownerToken = [guid]::NewGuid().ToString()
Assert-Rejected { Get-ServiceBusRunnerSshPublicKey -State $existingRunnerState }
$sshParts = $runnerPublicKey.Split(' ')
$sshBytes = [Convert]::FromBase64String($sshParts[1])
$sshOffset = 0
$sshFieldLengths = @()
for ($fieldIndex = 0; $fieldIndex -lt 3; $fieldIndex++) {
    $fieldLength = ([int]$sshBytes[$sshOffset] * 16777216) +
        ([int]$sshBytes[$sshOffset + 1] * 65536) +
        ([int]$sshBytes[$sshOffset + 2] * 256) +
        [int]$sshBytes[$sshOffset + 3]
    $sshOffset += 4
    $sshFieldLengths += $fieldLength
    $sshOffset += $fieldLength
}
if ($sshOffset -ne $sshBytes.Length -or $sshFieldLengths[0] -ne 7 -or
    $sshFieldLengths[1] -lt 3 -or $sshFieldLengths[2] -lt 256) {
    throw 'Runner key must be a structurally valid 2048-bit-or-larger OpenSSH RSA public key.'
}
$runnerBundle = New-ServiceBusRunnerBundle
$bootstrapScript = New-ServiceBusRunnerBootstrapScript -Bundle $runnerBundle
if ($runnerBundle.Bytes.Length -gt 180000 -or $bootstrapScript.Length -gt 48000 -or
    $bootstrapScript.Contains('@@') -or
    $runnerBundle.BundleSha256 -notmatch '^[0-9a-f]{64}$' -or
    $runnerBundle.FunctionSourceSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'Runner source package or bootstrap exceeds its bounded attestation envelope.'
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
function Get-ServiceBusSreRuntimeState { return $null }
$gate = Get-ServiceBusActionGate
if ($gate.readiness -cne 'Blocked' -or -not $gate.preInvocationEnforcement -or
    $gate.autonomousResponsePlan -cne 'NotArmed' -or
    $gate.executor -cne 'FixedActionExecutor' -or
    $gate.executorIdentity -cne 'SeparateExecutorAndWatchdogSystemIdentities' -or
    $gate.sreConnector -cne 'NotVerified' -or
    $gate.privateEndpointCallPath -cne 'ConfiguredNotRuntimeProbed' -or
    $gate.automaticAlertTrigger -cne 'NotConnected' -or
    $gate.blockers.Count -lt 7 -or
    -not $gate.nextVerification.Contains('response plan') -or
    -not $gate.blockers.Contains('The owned executor audience or exact SRE application-role assignment is not verified.')) {
    throw 'Doctor must distinguish implemented offline executor code from unverified live integration gates.'
}
Assert-Rejected { Assert-ServiceBusActionGate }
$blockedOperationNames = @('Arm', 'Incident')
foreach ($operationName in $blockedOperationNames) {
    $Operation = $operationName
    try {
        Assert-ServiceBusActionGate
        throw "Blocked operation '$operationName' unexpectedly passed."
    } catch {
        if ($_.Exception.Message -notmatch 'Blocked at|owned SRE MCP connector') {
            throw
        }
    }
}
$faultDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-ServiceBusFault'
}, $true)
if (-not $faultDefinition -or
    -not $faultDefinition.Extent.Text.Contains('Assert-ServiceBusActionGate')) {
    throw 'Fault must require verified alert routing and the Autonomous response plan before setting SendDisabled.'
}
$incidentDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-ServiceBusIncidentObservation'
}, $true)
if (-not $incidentDefinition.Extent.Text.Contains('Assert-ServiceBusActionGate')) {
    throw 'Incident observation must remain blocked until automatic SRE routing is verified.'
}

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
$alertNameDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Get-ServiceBusAlertRuleName'
}, $true)
$alertEssentialsDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Test-ServiceBusAlertEssentials'
}, $true)
$scenarioLockDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Enter-ServiceBusScenarioLock'
}, $true)
$easyAuthDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Assert-ServiceBusEasyAuthBinding'
}, $true)
. ([scriptblock]::Create($alertNameDefinition.Extent.Text))
. ([scriptblock]::Create($alertEssentialsDefinition.Extent.Text))
. ([scriptblock]::Create($scenarioLockDefinition.Extent.Text))
. ([scriptblock]::Create($easyAuthDefinition.Extent.Text))
$connectorIdentityDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Get-ServiceBusSreConnectorIdentity'
}, $true)
. ([scriptblock]::Create($connectorIdentityDefinition.Extent.Text))
$EnvironmentName = 'demo01'
$namespaceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/sb'
$alertRuleId = "$namespaceId/providers/Microsoft.Insights/metricAlerts/alert-servicebus-demo01"
$faultAt = [DateTimeOffset]::UtcNow.AddMinutes(-5)
$alertsManagementResponse = @{
    value = @(
        @{
            id = "$namespaceId/providers/Microsoft.AlertsManagement/alerts/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            properties = @{
                essentials = @{
                    alertRule = 'alert-servicebus-demo01'
                    alertRuleId = $alertRuleId
                    targetResource = $namespaceId
                    monitoringService = 'Platform'
                    signalType = 'Metric'
                    monitorCondition = 'Fired'
                    startDateTime = $faultAt.AddMinutes(1).ToString('o')
                }
            }
        }
    )
}
$alertEssentials = $alertsManagementResponse.value[0].properties.essentials
if (-not (Test-ServiceBusAlertEssentials -Essentials $alertEssentials `
    -ExpectedTargetId $namespaceId -ExpectedRuleId $alertRuleId -FaultAt $faultAt)) {
    throw 'AlertsManagement-shaped metric alert should match exact rule name, ID, target, source, and fault window.'
}
$alertEssentials.alertRule = $alertRuleId
if (Test-ServiceBusAlertEssentials -Essentials $alertEssentials `
    -ExpectedTargetId $namespaceId -ExpectedRuleId $alertRuleId -FaultAt $faultAt) {
    throw 'Incident correlation must compare essentials.alertRule with the metric alert NAME, not its resource ID.'
}
$alertEssentials.alertRule = 'alert-servicebus-demo01'
$alertEssentials.alertRuleId = "$alertRuleId-foreign"
Assert-Rejected {
    Test-ServiceBusAlertEssentials -Essentials $alertEssentials `
        -ExpectedTargetId $namespaceId -ExpectedRuleId $alertRuleId -FaultAt $faultAt
}
$alertEssentials.alertRuleId = $alertRuleId
$alertEssentials.monitoringService = 'ActivityLog'
Assert-Rejected {
    Test-ServiceBusAlertEssentials -Essentials $alertEssentials `
        -ExpectedTargetId $namespaceId -ExpectedRuleId $alertRuleId -FaultAt $faultAt
}
$alertEssentials.monitoringService = 'Platform'
$alertEssentials.targetResource = "$namespaceId-foreign"
Assert-Rejected {
    Test-ServiceBusAlertEssentials -Essentials $alertEssentials `
        -ExpectedTargetId $namespaceId -ExpectedRuleId $alertRuleId -FaultAt $faultAt
}

$connectorSystemPrincipalId = '6983a5f9-e38b-4fc3-a3c6-4676a1853b52'
$connectorSystemAppId = '07490000-0000-4000-8000-000000000001'
$actionUserPrincipalId = '1f2b0000-0000-4000-8000-000000000001'
$actionUserAppId = '07490000-0000-4000-8000-000000000002'
$connectorIdentity = Get-ServiceBusSreConnectorIdentity -Resource @{
    identity = @{
        type = 'SystemAssigned'
        principalId = $connectorSystemPrincipalId
    }
    properties = @{
        actionConfiguration = @{
            identity = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/action-uami"
        }
    }
} -InvokeGraph {
    param($Method, $Path, $Body)
    if ($Method -cne 'GET' -or
        $Path -cne "/servicePrincipals/$($connectorSystemPrincipalId)?`$select=id,appId,servicePrincipalType,accountEnabled" -or
        $Body) {
        throw 'Connector identity lookup must read the exact system principal, not the native action UAMI.'
    }
    return @{
        id = $connectorSystemPrincipalId
        appId = $connectorSystemAppId
        servicePrincipalType = 'ManagedIdentity'
        accountEnabled = $true
    }
}
if ($connectorIdentity.principalId -ine $connectorSystemPrincipalId -or
    $connectorIdentity.clientId -ine $connectorSystemAppId -or
    $connectorIdentity.principalId -ceq $actionUserPrincipalId) {
    throw 'The fixed executor identity must bind to the connector system identity, not the native action UAMI.'
}
$easyAuthFixture = @{
    properties = @{
        globalValidation = @{
            requireAuthentication = $true
            unauthenticatedClientAction = 'Return401'
        }
        identityProviders = @{
            azureActiveDirectory = @{
                enabled = $true
                validation = @{
                    allowedAudiences = @('api://77777777-7777-4777-8777-777777777777')
                    defaultAuthorizationPolicy = @{
                        allowedApplications = @($connectorSystemAppId)
                    }
                }
            }
        }
    }
}
Assert-ServiceBusEasyAuthBinding -Configuration $easyAuthFixture `
    -ExpectedAudience 'api://77777777-7777-4777-8777-777777777777' `
    -ExpectedApplicationId $connectorSystemAppId
$easyAuthFixture.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications =
    @($actionUserAppId)
Assert-Rejected {
    Assert-ServiceBusEasyAuthBinding -Configuration $easyAuthFixture `
        -ExpectedAudience 'api://77777777-7777-4777-8777-777777777777' `
        -ExpectedApplicationId $connectorSystemAppId
}

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
$scenarioLockDirectory = Join-Path $repositoryRoot ('.azure\servicebus-offline-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scenarioLockDirectory -Force
$scenarioLockPath = Join-Path $scenarioLockDirectory 'scenario.lock'
try {
    $heldScenarioLock = Enter-ServiceBusScenarioLock -Path $scenarioLockPath
    try {
        Assert-Rejected { Enter-ServiceBusScenarioLock -Path $scenarioLockPath }
    } finally {
        $heldScenarioLock.Dispose()
    }
    $releasedScenarioLock = Enter-ServiceBusScenarioLock -Path $scenarioLockPath
    $releasedScenarioLock.Dispose()
} finally {
    Remove-Item -LiteralPath $scenarioLockDirectory -Recurse -Force
}
$scenarioLockGuard = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.Contains('Enter-ServiceBusScenarioLock')
}, $true))
if (-not $scenarioLockGuard -or
    $scenarioLockGuard[0].Extent.Text -notmatch "'Up', 'Connect'.*'Down'") {
    throw 'Connect must acquire the same exclusive scenario lock as Up and Down.'
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
$script:foundationGroupName = 'rg-retailtx-stage0-swedencentral'
$script:FoundationEnvironment = 'stage0'
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
    if ($Arguments[0] -ceq 'network' -and $Arguments[1] -ceq 'private-dns') { return @($script:fakeZones) }
    if ($Arguments[0] -ceq 'network' -and $Arguments[1] -ceq 'vnet' -and $Arguments[2] -ceq 'peering') {
        return @($script:fakePeerings)
    }
    throw 'Unexpected Azure read in offline ownership test.'
}
$helperNames = @(
    'Get-OwnedScenarioGroup', 'Assert-ServiceBusPrivateDnsOwnership',
    'Get-ServiceBusExecutorVirtualNetworkId', 'Assert-ServiceBusFoundationPeeringOwnership'
)
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
$script:fakePeerings = @(@{
    name = 'peer-retailtx-sb-demo01'
    remoteVirtualNetwork = @{ id = Get-ServiceBusExecutorVirtualNetworkId }
})
if (-not (Assert-ServiceBusFoundationPeeringOwnership -RequireExisting)) {
    throw 'The exact owned executor peering was not accepted.'
}
$script:fakePeerings[0].remoteVirtualNetwork.id = "$($scenarioState.groupId)/providers/Microsoft.Network/virtualNetworks/foreign"
Assert-Rejected { Assert-ServiceBusFoundationPeeringOwnership -RequireExisting }
$script:fakePeerings = @()
if (Assert-ServiceBusFoundationPeeringOwnership) {
    throw 'Missing exact executor peering must not be reported as present.'
}
Assert-Rejected { Assert-ServiceBusFoundationPeeringOwnership -RequireExisting }

$armBranch = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.SwitchStatementAst]
}, $true)
if (-not $armBranch.Extent.Text.Contains("'Arm'") -or
    -not $armBranch.Extent.Text.Contains('Assert-ServiceBusActionGate')) {
    throw 'Arm must invoke the fail-closed enforcement gate.'
}
foreach ($networkCommand in @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -match '^(az|Invoke-RestMethod|Invoke-WebRequest)$'
}, $true))) {
    $parent = $networkCommand.Parent
    while ($parent -and
        $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
        $parent = $parent.Parent
    }
    if ($networkCommand.GetCommandName() -ceq 'Invoke-WebRequest' -and
        $parent.Name -ceq 'Invoke-ServiceBusSreRequest') {
        continue
    }
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
$downPeeringGuard = @($downCommands | Where-Object { $_.GetCommandName() -eq 'Assert-ServiceBusFoundationPeeringOwnership' })[0]
$downDelete = @($downCommands | Where-Object { $_.Extent.Text -match "'group', 'delete" })[0]
if (-not $downDnsGuard -or -not $downPeeringGuard -or -not $downDelete -or
    $downDnsGuard.Extent.StartOffset -ge $downDelete.Extent.StartOffset) {
    throw 'Down must verify exact DNS zone ownership before deleting the owned group.'
}
if ($downPeeringGuard.Extent.StartOffset -ge $downDelete.Extent.StartOffset) {
    throw 'Down must verify exact Stage 0 peering ownership before deleting resources.'
}

$faultFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-ServiceBusFault'
}, $true)
$faultCommands = @($faultFunction.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
$faultStateWrite = @($faultCommands | Where-Object { $_.GetCommandName() -eq 'Save-State' })[0]
$faultQueueWrite = @($faultCommands | Where-Object {
    $_.Extent.Text -match 'Invoke-ServiceBusRunnerCommand -Action fault'
})[0]
$faultSeed = @($faultCommands | Where-Object {
    $_.Extent.Text -match 'Invoke-ServiceBusProbe -ProbeOperation seed'
})[0]
$faultSend = @($faultCommands | Where-Object {
    $_.Extent.Text -match 'Invoke-ServiceBusProbe -ProbeOperation send'
})[0]
if (-not $faultSeed -or -not $faultStateWrite -or -not $faultQueueWrite -or -not $faultSend -or
    $faultSeed.Extent.StartOffset -ge $faultQueueWrite.Extent.StartOffset -or
    $faultStateWrite.Extent.StartOffset -ge $faultQueueWrite.Extent.StartOffset -or
    $faultSend.Extent.StartOffset -le $faultQueueWrite.Extent.StartOffset) {
    throw 'Fault must seed and persist its deadline before one fixed private-runner action, then verify an actual sender rejection.'
}
$recoverFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-ServiceBusRecover'
}, $true)
if ($recoverFunction.Extent.Text -match "'rest', '--method', 'put" -or
    -not $recoverFunction.Extent.Text.Contains('initiatingPrincipalObjectId') -or
    -not $recoverFunction.Extent.Text.Contains('postedCount') -or
    -not $recoverFunction.Extent.Text.Contains('payloadHash')) {
    throw 'Recover must observe, not perform, SRE recovery and verify caller identity plus exactly-once ledger evidence.'
}
$executorRuntimeFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Assert-ServiceBusExecutorRuntime'
}, $true)
if (-not $executorRuntimeFunction.Extent.Text.Contains('Assert-ServiceBusEasyAuthBinding') -or
    -not $executorRuntimeFunction.Extent.Text.Contains('$scenarioState.sreClientAppId') -or
    -not $executorRuntimeFunction.Extent.Text.Contains('$scenarioState.executorAudience')) {
    throw 'Executor runtime readback must bind both Easy Auth configurations to the exact connector identity and audience.'
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
    "actions: []"
)) {
    if (-not $template.Contains($requirement)) {
        throw "Service Bus Bicep contract is missing: $requirement"
    }
}
if ($template -notmatch 'name:\s+''\$\{namespaceName\}/\$\{queueName\}''[\r\n\s]+dependsOn:\s*\[broker\]') {
    throw 'The probe queue must depend on the AVM namespace deployment before creation.'
}
if ($template -match "Azure Service Bus Data Owner|SRE_AGENT_ID|scope:\s*broker") {
    throw 'Scenario must not assign namespace-wide or SRE data-plane privileges.'
}
if ($template -match 'probeSystemIdentityPrincipalId|senderRoleId|receiverRoleId') {
    throw 'The queue template must not depend on an external probe principal.'
}

$executorTemplatePath = Join-Path $PSScriptRoot '..\infra\servicebus-executor.bicep'
$executorTemplate = Get-Content -LiteralPath $executorTemplatePath -Raw
foreach ($requirement in @(
    'Microsoft.Web/sites/config@2022-09-01',
    "name: 'authsettingsV2'",
    'requireAuthentication: true',
    "unauthenticatedClientAction: 'Return401'",
    'allowedApplications: [sreClientAppId]',
    'allowedAudiences: [executorAudience]',
    "publicNetworkAccess: 'Disabled'",
    "type: 'SystemAssigned'",
    'resource executorAuthentication',
    'resource watchdogAuthentication',
    'resource executorQueueRoleAssignment',
    'resource watchdogQueueRoleAssignment',
    "name: 'scenario-coordination'",
    'resource coordinationContainer',
    'resource runnerCoordinationBlobRoleAssignment',
    'scope: coordinationContainer',
    'COORDINATION_STORAGE_ACCOUNT',
    'COORDINATION_CONTAINER',
    'COORDINATION_BLOB_NAME',
    'scope: queue',
    "br/public:avm/res/compute/virtual-machine:0.22.3",
    "name: 'runner'",
    "addressPrefix: '10.85.0.128/26'",
    'module privateRunner',
    'runnerSshPublicKey string',
    'keyData: runnerSshPublicKey',
    "path: '/home/retailtxadmin/.ssh/authorized_keys'",
    "Microsoft.Network/networkSecurityGroups@2023-09-01",
    "name: 'deny-runner-inbound'",
    "direction: 'Inbound'",
    "access: 'Deny'",
    'resource runnerQueueRoleAssignments',
    'resource runnerExecutorPublishRole',
    'resource runnerWatchdogPublishRole',
    'runnerBootstrapScript string',
    "Microsoft.Network/publicIPAddresses@2023-09-01",
    "Microsoft.Network/natGateways@2023-09-01",
    "Microsoft.Network/networkSecurityGroups@2023-09-01",
    "publicIPAllocationMethod: 'Static'",
    'defaultOutboundAccess: false',
    'id: runnerNetworkSecurityGroup.id',
    'id: runnerNatGateway.id',
    'output runnerVmName string',
    'output runnerIdentityPrincipalId string'
)) {
    if (-not $executorTemplate.Contains($requirement)) {
        throw "Fixed executor infrastructure contract is missing: $requirement"
    }
}
if ($executorTemplate -match 'principalId:\s*srePrincipalObjectId') {
    throw 'The SRE Agent must not receive queue management RBAC.'
}
if ($executorTemplate -notmatch 'queueContributorRoleId' -or
    $executorTemplate -notmatch 'executorApp\.identity\.principalId' -or
    $executorTemplate -notmatch 'watchdogApp\.identity\.principalId') {
    throw 'Only the separate executor/watchdog identities may receive queue-scoped management RBAC.'
}
if ($executorTemplate -notmatch 'principalId:\s*privateRunner\.outputs\.systemAssignedMIPrincipalId!' -or
    $executorTemplate -notmatch 'for roleId in \[senderRoleId, receiverRoleId\]' -or
    $executorTemplate -notmatch 'roleDefinitionId:\s*roleId' -or
    $executorTemplate -notmatch 'scope:\s*executorApp' -or
    $executorTemplate -notmatch 'scope:\s*watchdogApp' -or
    $executorTemplate -notmatch 'publicNetworkAccess:\s*''Disabled''') {
    throw 'The private runner must receive only queue-scoped sender/receiver and app-scoped publish roles.'
}
if ($executorTemplate -notmatch "(?s)resource runnerCoordinationBlobRoleAssignment .*?scope:\s*coordinationContainer\s+properties:\s*\{\s+principalId:\s*privateRunner\.outputs\.systemAssignedMIPrincipalId!" -or
    $executorTemplate -match "(?s)resource runnerCoordinationBlobRoleAssignment .*?scope:\s*hostStorage") {
    throw 'Only the runner identity may receive the container-scoped coordination Blob data role.'
}
    if ($executorTemplate -notmatch "(?s)\{\s+name: 'runner'\s+properties: \{\s+addressPrefix: '10\.85\.0\.128/26'\s+defaultOutboundAccess: false\s+networkSecurityGroup: \{\s+id: runnerNetworkSecurityGroup\.id\s+\}\s+natGateway: \{\s+id: runnerNatGateway\.id\s+\}\s+\}\s+\}") {
        throw 'The private runner subnet must associate the owned NAT gateway and disable default outbound access.'
    }
    if ($executorTemplate -notmatch "(?s)\{\s+name: 'function-integration'\s+properties: \{\s+addressPrefix: '10\.85\.0\.0/26'\s+defaultOutboundAccess: false\s+natGateway: \{\s+id: runnerNatGateway\.id\s+\}\s+delegations:") {
        throw 'The Flex integration subnet must use the same owned NAT gateway for explicit ARM/control-plane egress.'
    }
    if ([regex]::Matches($executorTemplate, 'resource runnerNatGateway ').Count -ne 1 -or
        [regex]::Matches($executorTemplate, 'id: runnerNatGateway\.id').Count -ne 2) {
        throw 'Runner and Flex integration subnets must share exactly one owned NAT gateway.'
    }
    if ($executorTemplate -match 'publicKeys:\s*\[\s*\]') {
        throw 'Runner provisioning must configure one owner-bound public key and deny inbound network traffic.'
    }
    $functionSettingsMatch = [regex]::Match(
        $executorTemplate,
        '(?s)var identityBasedStorageSettings\s*=\s*\[(.*?)\]\s*\r?\n\r?\nresource executorApp'
    )
    if (-not $functionSettingsMatch.Success -or
        $functionSettingsMatch.Groups[1].Value -match 'FUNCTIONS_WORKER_RUNTIME|FUNCTIONS_EXTENSION_VERSION|WEBSITE_CONTENTAZUREFILECONNECTIONSTRING|WEBSITE_CONTENTSHARE|WEBSITE_RUN_FROM_PACKAGE|DefaultEndpointsProtocol|AccountKey=') {
        throw 'Flex Consumption must not use legacy runtime, Azure Files, package, or storage-key app settings.'
    }
    foreach ($requiredFlexSetting in @(
        'AzureWebJobsStorage__accountName',
        'AzureWebJobsStorage__credential',
        "value: 'managedidentity'",
        "name: 'python'",
        "version: '3.11'",
        "type: 'SystemAssignedIdentity'"
    )) {
        if (-not $executorTemplate.Contains($requiredFlexSetting)) {
            throw "Flex runtime/deployment identity configuration is missing: $requiredFlexSetting"
        }
    }
    if ($executorTemplate -notmatch 'vnetRouteAllEnabled:\s*true' -or
        $executorTemplate -notmatch 'virtualNetworkSubnetId:\s*integrationSubnet\.id') {
        throw 'Flex control-plane egress must route through its NAT-associated integration subnet.'
    }

$runnerPath = Join-Path $PSScriptRoot '..\scripts\servicebus\runner.py'
$runnerSource = Get-Content -LiteralPath $runnerPath -Raw
$scenarioScriptSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Invoke-ServiceBusScenario.ps1') -Raw
$bootstrapPath = Join-Path $PSScriptRoot '..\scripts\servicebus\runner-bootstrap.sh'
$bootstrapSource = Get-Content -LiteralPath $bootstrapPath -Raw
foreach ($requirement in @(
    'ALLOWED_ACTIONS = {"configure", "initialize", "state", "fault", "health", "probe", "publish"}',
    '"func",',
    '"azure",',
    '"functionapp",',
    '"publish",',
    '"--build",',
    '"remote"',
    'Run Command.',
    'automatic replay is disabled',
    'MANIFEST_PATH',
    'DATABASE_PATH',
    'flock',
    'PRIVATE_NETWORKS',
    'coordination.py'
)) {
    if (-not $runnerSource.Contains($requirement)) {
        throw "Private runner contract is missing: $requirement"
    }
    $probeSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\servicebus\probe.py') -Raw
    if (-not $probeSource.Contains('ManagedIdentityCredential')) {
        throw 'The private runner probe must use managed identity, not SAS or connection strings.'
    }
}
if ($scenarioScriptSource -match 'userMetadata|\.etag\b|If-Match=' -or
    -not $scenarioScriptSource.Contains("Invoke-ServiceBusRunnerCommand -Action state") -or
    -not $faultFunction.Extent.Text.Contains('Invoke-ServiceBusRunnerCommand -Action fault')) {
    throw 'Queue coordination must use the private runner and Blob lease/ETag state, never Queue GET ETag or userMetadata.'
}
if ($runnerSource -match 'shell=True|os\.system\(|eval\(' -or
    $bootstrapSource -match 'ssh-rsa|authorized_keys|publicIpAddress') {
    throw 'Private runner must not expose arbitrary shell or public SSH access.'
}

$identityModulePath = Join-Path $PSScriptRoot '..\scripts\servicebus\EntraExecutorIdentity.psm1'
$identityModule = Get-Content -LiteralPath $identityModulePath -Raw
foreach ($requirement in @(
    'function Set-ServiceBusEntraIdentity',
    'function Get-ServiceBusEntraIdentityStatus',
    'function Remove-ServiceBusEntraIdentity',
    'ApplicationCreatePending',
    'ServicePrincipalPending',
    'RoleAssignmentPending',
    'api://',
    'ServiceBus.QueueRestore'
)) {
    if (-not $identityModule.Contains($requirement)) {
        throw "Owned executor Entra lifecycle contract is missing: $requirement"
    }
}
if ($identityModule -match 'clientSecret|password|privateKey|certificate') {
    throw 'The executor app identity must not create or persist a client credential.'
}
$upDefinition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-ServiceBusUp'
}, $true)
$identitySetup = @($upDefinition.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -ceq 'Set-ServiceBusEntraIdentity'
}, $true))[0]
$executorDeploy = @($upDefinition.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.Extent.Text -match "'deployment', 'group', 'create"
}, $true))[1]
if (-not $identitySetup -or -not $executorDeploy -or
    $identitySetup.Extent.StartOffset -ge $executorDeploy.Extent.StartOffset) {
    throw 'Up must create and persist the executor audience/role before deploying Easy Auth.'
}
if (-not $upDefinition.Extent.Text.Contains('Get-ServiceBusSreConnectorIdentity') -or
    -not $upDefinition.Extent.Text.Contains('$sreIdentity.clientId') -or
    -not $upDefinition.Extent.Text.Contains('$sreIdentity.principalId') -or
    -not $upDefinition.Extent.Text.Contains('$sreObjectId')) {
    throw 'Up must bind the app-role grant and Easy Auth allow-list to the connector system principal and app ID.'
}
if ($upDefinition.Extent.Text.Contains('ProbePrincipalId') -or
    -not $upDefinition.Extent.Text.Contains('runnerBootstrapScript=@$bootstrapPath') -or
    -not $upDefinition.Extent.Text.Contains('runnerSshPublicKey=$($scenarioState.runnerSshPublicKey)') -or
    -not $upDefinition.Extent.Text.Contains('Get-ServiceBusRunnerSshPublicKey -State $scenarioState') -or
    -not $upDefinition.Extent.Text.Contains('RUNNERIDENTITYPRINCIPALID') -or
    -not $upDefinition.Extent.Text.Contains('Invoke-ServiceBusRunnerCommand')) {
    throw 'Up must persist and pass the exact owned public runner key, and invoke the private runner without an external probe principal.'
}
$removeIdentity = @($downCommands | Where-Object {
    $_.GetCommandName() -eq 'Remove-ServiceBusEntraIdentity'
})[0]
if (-not $removeIdentity -or $removeIdentity.Extent.StartOffset -ge $downDelete.Extent.StartOffset) {
    throw 'Down must revoke the exact owned Entra grant before deleting its supporting resources.'
}

Write-Output 'Service Bus scenario offline contract checks passed.'
