# Independent single-agent demo lifecycle

This lifecycle creates a fresh native Linux service fixture and one SRE Agent.
It does not load a retained foundation manifest or migrate an existing agent.
Bicep owns Azure infrastructure; PowerShell coordinates guest bootstrap,
monitoring and native SRE configuration. Bash invokes the same PowerShell engine.

## Prerequisites

Use PowerShell 7.5+, Azure CLI with Bicep, Python, GitHub CLI and `ssh-keygen`.
Authenticate to the explicit Azure subscription and the trusted GitHub repository.
Deployment requires resource provisioning, role-definition/assignment privileges
and access to the SRE data plane. No private runner is required for the selected
public authenticated Monitor profile; private application probing is not included.

Use an unused neutral environment name. Generated ownership/configuration files
are under `.azure/<environment>/` and must be preserved for safe cleanup.
They contain resource bindings, not an alternative source of infrastructure.

## Step 1 - Create the environment

Choose one shell and replace the subscription placeholder:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-Demo.ps1 Up -SubscriptionId '<subscription-guid>' -EnvironmentName demo01
```

```bash
bash scripts/demo.sh Up -SubscriptionId '<subscription-guid>' -EnvironmentName demo01
```

Up provisions the VM/network and SRE resources through Bicep, bootstraps the
protected service, configures monitoring, uploads the recovery skill and
investigator, establishes Review routing and enables the owned alert.
It never injects a fault or approves a repair.

An existing successful deployment is inspected rather than recreated.
Telemetry warm-up can stop Up before configuration admission. Repeat only after
fresh telemetry is available; never relax the three-minute freshness gate.
Unknown guest or provisioning outcomes remain journaled and block replay:
inspect/reconcile the recorded operation, or use owned teardown where permitted.
This is not automatic recovery from every partial Azure deployment.

Before enabling or testing intake, settle existing investigations and stop other
SRE Agents in the subscription. The scripts do not stop them automatically.
This deliberately conservative operating gate is not a claim of isolated
subscription-level Monitor scanners.

## Step 2 - Verify readiness

```powershell
pwsh -NoProfile -File .\scripts\Invoke-Demo.ps1 Ready -SubscriptionId '<subscription-guid>' -EnvironmentName demo01
```

```bash
bash scripts/demo.sh Ready -SubscriptionId '<subscription-guid>' -EnvironmentName demo01
```

Ready requires fresh healthy service telemetry, settled local command intent,
the expected identity/grants/skill, one running agent, Azure Monitor intake,
and an enabled exact-target Review plan and alert. It performs no repair or
alert enablement. A previous incident must naturally resolve before reuse.
`githubRuntime: SeparateAcceptanceRequired` is intentionally not GitHub readiness.

## Step 3 - Configure the optional GitHub investigator

```powershell
pwsh -NoProfile -File .\scripts\Invoke-Demo.ps1 ConfigureGitHub -SubscriptionId '<subscription-guid>' -EnvironmentName demo01
```

```bash
bash scripts/demo.sh ConfigureGitHub -SubscriptionId '<subscription-guid>' -EnvironmentName demo01
```

The trusted repository and its actual OIDC subject mode are read from GitHub.
Bicep creates an exact-agent caller identity, FIC, custom role and assignment;
the existing Python lifecycle journals and validates the deployment.
Native knowledge, an investigation-only custom agent and a disabled HTTP
trigger are configured separately. No repository gates or secrets are changed.
See [caller Bicep lifecycle](github-intake-identity.md).

Configuration metadata is not proof of knowledge retrieval, workflow
authentication or successful issue investigation. The narrow caller's known
runtime permission gap remains an acceptance gate; the lifecycle never
silently grants Standard User. See [GitHub investigation](github-investigation.md).

## Step 4 - Rehearse and reset

After Ready, use the existing exact-environment guest-service Fault command.
The presenter personally triggers live faults; authorized development tests are
recorded separately. SRE repair always waits for a genuine human approval.
The old retained-fixture presenter profile does not target this environment.

```powershell
pwsh -NoProfile -File .\scripts\Invoke-GuestService.ps1 Fault -SubscriptionId '<subscription-guid>' -EnvironmentName demo01
```

Record the new current run ID before approving its matching repair. Verify
same-run guest recovery separately from Azure terminal audit and natural
Monitor clearance. No repair replay is permitted.

After the investigation and approval/execution are settled:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-Demo.ps1 Reset -SubscriptionId '<subscription-guid>' -EnvironmentName demo01 -RunId '<exact-run-guid>'
```

```bash
bash scripts/demo.sh Reset -SubscriptionId '<subscription-guid>' -EnvironmentName demo01 -RunId '<exact-run-guid>'
```

Reset is an explicit operator operation, not SRE approval. It can perform an
exact-run controller reset; use the recovered-run evidence when describing it.

## Step 5 - Remove and verify absence

Disable repository GitHub intake first if it was separately enabled.

```powershell
pwsh -NoProfile -File .\scripts\Invoke-Demo.ps1 Down -SubscriptionId '<subscription-guid>' -EnvironmentName demo01
```

```bash
bash scripts/demo.sh Down -SubscriptionId '<subscription-guid>' -EnvironmentName demo01
```

Down validates exact ownership and removes configured GitHub assets before their
agent, removes external grants/custom roles, deletes the resource group and
checks absence again. Never delete local ownership journals to bypass a failure.
The optional `-CleanupFailedGitHub` authorizes only proven non-submitted or
terminal-failed Bicep cleanup; unknown/in-flight creation still blocks.
An uncertain caller deployment can therefore block full teardown pending
reconciliation. No success or complete rebuild claim is made for that state.

## Live evidence and open gates (2026-10-15)

Fresh `demo01` VM, SRE Agent, owned workspace, collection and alert resources
were deployed through existing Bicep modules without a foundation manifest.
The protected service reported healthy, recovery skill and Review routing
were installed, and the wrapper reached Ready. The earlier `demo36` run was
archived with zero guest writes; its agent was stopped and its resources retained.

One development-test fault produced a real Monitor alert and an automatically
created incident in the new agent. The native card remained pending until a
human approved that single action. Execution began at 12:13:58 UTC, guest
recovery was recorded at 12:14:12 UTC, and the matching action-principal Azure
operation reached Succeeded at 12:14:24 UTC. Fresh independent telemetry
confirmed same-run health. No repair was replayed.

The approval waited approximately 71 minutes. SRE's resumed first answer did
not verify recovery because approval metadata was not exposed. One neutral
follow-up independently queried fresh health and correctly reported
"Service observed healthy; repair verification pending." Its pre-approval fixed
audit discovery window excluded the later action; operator audit verification
used the actual execution time. This is not automatic full SRE verification,
and the human wait is not counted as platform recovery latency.

GitHub knowledge/investigator and the disabled native trigger were configured.
The caller's first Bicep submission returned failure without a deployment
receipt. A separate no-write ARM validation identified a subscription-scope
`resourceId` overload defect. The module is corrected and regression-tested,
but the original uncertain journal remains frozen: it is not replayed,
rehash-adopted or represented as a successful caller deployment.

Full GitHub workflow acceptance, teardown/rebuild acceptance and customer
repeatability are not established by infrastructure deployment or Ready.
