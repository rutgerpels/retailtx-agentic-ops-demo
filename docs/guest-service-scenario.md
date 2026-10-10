# Native Azure VM guest-service feasibility

**Scope:** a stopped application service inside a running native Azure VM,
not VM start and not the Arc-managed host. Service Bus work remains parked.
This first gate proves a small guest fixture and the Azure VM Agent command
transport before adding a human-approved SRE repair. Alert intake and autonomy
are later gates.

The fixture represents a posting worker, not the actual RetailTx ERP ledger,
Service Bus pipeline or business recovery. Do not infer customer impact from
its localhost health or worker progress.

## Acceptance gates

1. Deploy an isolated, owned VM with no public VM IP or inbound SSH/RDP.
   Explicit outbound connectivity is required by the Azure VM Agent.
2. Verify that the application service and its independent watchdog are
   healthy, with current guest evidence and source identity.
3. Inject a bounded service stop while the VM remains running. Persist the
   exact fault run and deadline before stopping anything.
4. Verify independent deadline recovery before relying on the repair path.
5. Collect fresh fault evidence, let SRE explain the narrow diagnosis and
   recommend the fixed repair, then execute that repair through the controlled
   operator harness. Verify the named systemd service and localhost health
   independently through the operator harness.
6. Reset and tear down the fixture; preserve receipts and independently check
   absence of owned resources.

Alert-driven investigation, direct SRE guest execution and approval-free
autonomy are separate gates, not implied by operator Run Command success.
The retained SRE action identity receives Reader only on the isolated fixture
group so it can inspect Azure resource evidence. That grant is removed with
the fixture group. No guest-command grant or shared global-mode change is
required for this initial proof.

## Operator lifecycle

Use the authorized subscription explicitly. The fixture defaults to `demo16`;
it must not reuse the retained foundation's environment ID.

```powershell
$subscription = '<subscription-guid>'
.\scripts\Invoke-GuestService.ps1 Up -SubscriptionId $subscription -EnvironmentName demo16
.\scripts\Invoke-GuestService.ps1 Status -SubscriptionId $subscription -EnvironmentName demo16
.\scripts\Invoke-GuestService.ps1 Fault -SubscriptionId $subscription -EnvironmentName demo16 -Canary
# Wait for independent watchdog recovery; obtain a fresh Status receipt.
.\scripts\Invoke-GuestService.ps1 Status -SubscriptionId $subscription -EnvironmentName demo16
```

Only after the safety canary is proven, create a separate bounded fault.
Keep the exact returned run ID; never substitute a prior run.

```powershell
.\scripts\Invoke-GuestService.ps1 Fault -SubscriptionId $subscription -EnvironmentName demo16 -FaultDurationSeconds 600
.\scripts\Invoke-GuestServiceSre.ps1 Investigate -SubscriptionId $subscription -EnvironmentName demo16
.\scripts\Invoke-GuestServiceSre.ps1 Read -SubscriptionId $subscription -EnvironmentName demo16
.\scripts\Invoke-GuestService.ps1 Repair -SubscriptionId $subscription -EnvironmentName demo16 -RunId '<current-run-guid>'
.\scripts\Invoke-GuestServiceSre.ps1 Verify -SubscriptionId $subscription -EnvironmentName demo16
.\scripts\Invoke-GuestService.ps1 Down -SubscriptionId $subscription -EnvironmentName demo16
```

SRE request intents are durable and deliberately non-replayable after an
uncertain POST. Read/reconcile the saved thread rather than create a substitute.
Recovery follow-up accepts only fresh healthy evidence from the initial run;
it requires repair attribution to the currently authenticated operator.
Watchdog recovery is not operator-repair acceptance. `Up -WhatIf` describes
the operation without preflight, local files or Azure writes.

If thread creation returns no reliable ID, preserve its saved intent and use
the SRE UI to locate the exact owner marker and fault run. Decline any pending
actions there, tear down the owned fixture and start with a fresh environment
rather than replaying creation or hand-editing an uncertain intent into success.

## Authority boundary

Azure documents Run Command as a guest diagnosis/remediation channel through
the VM Agent. It does not require inbound SSH/RDP, but requires outbound
connectivity. Linux Action Run Command normally executes elevated scripts,
supports only one active command, returns at most the last 4,096 bytes, cannot
be cancelled and has an approximately 20-second minimum execution time.
These are command-channel constraints, not an incident-duration guarantee.
See [Linux Action Run Command](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command)
and the [Run Command comparison](https://learn.microsoft.com/en-us/azure/virtual-machines/run-command-overview).

A VM-scoped Run Command grant restricts the target VM, **not the script**.
The operator harness can constrain its own fixed operations; it does not turn
the operator's Azure permissions into a service-only RBAC boundary. SRE receives
no guest-command grant in the first gate. A hard fixed-action boundary must be
demonstrated before describing direct autonomous repair as constrained.

Run Command itself is a write operation even when its script only reads guest
state. A read-only SRE investigation therefore uses Azure resource evidence
and explicitly attributed, fresh operator-collected guest receipts. Do not
claim that SRE independently read the guest when it received that evidence.

## Stop condition

If the native guest channel or independent recovery cannot be proven reliably,
record the failure and remove the fixture rather than adding another custom
execution platform. If the channel works but authority confinement remains
unresolved, retain the recommendation/operator proof and report autonomous
guest repair as blocked by that specific boundary.

## Native SRE execution gate

**2026-10-09 decision: no-go for granting guest-write authority to the retained
shared agent.** This is an authority-boundary finding, not evidence that native
SRE execution is unsupported. No new fixture was deployed, fault injected,
write permission granted or shared setting changed during this gate.

[Execute mitigations in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/execute-mitigations)
documents native Azure CLI write actions. Combined with Linux Run Command,
this establishes a documented candidate transport, not verified SRE guest
execution in this environment. Linux `RunShellScript` accepts arbitrary
elevated scripts; limiting the role to one VM does not restrict script content.

[Tool access policies](https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies)
now document argument matching, but deny rules exist only at global scope.
Custom-agent and thread policies only add allows, and an allow skips default
approval even in Review mode. An exact-command allow alone is therefore
neither a deny-by-default boundary nor an approval-gated test.
A read-only live GET of `/api/v2/agent/settings/global` returned empty
allow, ask and deny lists; the retained agent's ARM action mode remained Review.
Those settings were left unchanged.

[Agent hooks](https://learn.microsoft.com/en-us/azure/sre-agent/agent-hooks)
document Stop and **PostToolUse**, not a pre-execution argument veto.
PostToolUse runs after successful execution and cannot prevent an arbitrary
guest script from already having run. A hook returning allow can also override
global policy denies. Do not use prompt instructions or a post-execution hook
as the privileged repair boundary.

An isolated SRE agent alone does **not** resolve this boundary. Further review
of the documented precedence found that a blanket global deny also rejects
the intended repair, even when an exact allow exists. An exact allow without
that deny leaves unmatched commands subject to default behavior, not hard
rejection. No exception/default-deny mechanism is documented that meets the
proposed exact-repair-only acceptance gate. This is a documentation-based
no-go, not a live negative-policy test or proof about undocumented controls.

The user explicitly resolved
[the owner decision](https://github.com/rutgerpels/retailtx-agentic-ops-demo/issues/10):
demonstrate **human approval before any SRE guest command**, with Review mode
and privileged Run Command authority limited to one disposable native VM.
This accepts supervised execution, not a hard service-only permission boundary.
The retained shared agent must not gain guest-write permissions. Arc remains
recommendation/operator repair; alert plumbing and autonomous mode remain deferred.

## Human-approved native repair

**2026-10-09: the `demo23` fixture passed this gate.** SRE proposed the exact
repair command; a human approver independently verified it byte-for-byte
against the portal's pending card before clicking Approve, and execution ran
only after that click. See
[the `demo23` evidence](#human-approved-repair-evidence-demo23) below for the
full reconciliation. The optional execution fixture uses its own SRE agent,
action managed identity and delegated network. Its custom VM-scoped role grants
Action Run Command, not general Contributor, managed Run Command resource writes,
SSH or OBO elevation. Do not add tool Allow rules that bypass Review.

After the independent canary, inject a non-canary bounded fault and create the
proposal. Inspect the exact command and pending approval in SRE; **a human**
clicks Approve. The adapter has no programmatic approval operation.

```powershell
.\scripts\Invoke-GuestService.ps1 Up -SubscriptionId $subscription -EnvironmentName demo20 -WithSreExecution
.\scripts\Invoke-GuestServiceApproval.ps1 Configure -SubscriptionId $subscription -EnvironmentName demo20
.\scripts\Invoke-GuestService.ps1 Fault -SubscriptionId $subscription -EnvironmentName demo20 -Canary
# Wait for watchdog recovery and collect Status before the normal fault.
.\scripts\Invoke-GuestService.ps1 Status -SubscriptionId $subscription -EnvironmentName demo20
.\scripts\Invoke-GuestService.ps1 Fault -SubscriptionId $subscription -EnvironmentName demo20 -FaultDurationSeconds 600
.\scripts\Invoke-GuestServiceApproval.ps1 Propose -SubscriptionId $subscription -EnvironmentName demo20
.\scripts\Invoke-GuestServiceApproval.ps1 Read -SubscriptionId $subscription -EnvironmentName demo20
# Human reviews/approves the exact native RunAzCliWriteCommands card in SRE.
.\scripts\Invoke-GuestServiceApproval.ps1 Verify -SubscriptionId $subscription -EnvironmentName demo20
.\scripts\Invoke-GuestService.ps1 Down -SubscriptionId $subscription -EnvironmentName demo20
```

Read saves the native execution records without running a guest command. Propose
uses the operator-collected fault receipt and refuses stale, canary or near-expiry
evidence. The encoded repair binds owner, source hashes, exact run, action principal
and deadline; the locked guest controller rejects late, recovered or rebooted
faults before touching the service. This protects the supplied repair from stale
approval; it does not constrain arbitrary privileged scripts.

Configure requires Ask for native writes and guest invocations routed through
the CLI read tool, denies terminal, shell and Python alternatives, and installs
no Allow rules. These are documented
[tool access policies](https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies),
not a service-only OS boundary. User-defined hooks and thread/custom-agent
Allow overrides must remain absent; verify those in the SRE UI as part of the
supervised gate.

Verify requires an exact completed native execution with no OBO scopes, an
independent successful Azure Activity Log action by the isolated action principal,
and fresh operator-collected health with that principal's exact-run repair
attribution. Watchdog recovery is never accepted as SRE repair. The final supplied
receipt is explicitly operator-collected, not independent SRE guest verification.
Guest diagnostic/status commands by SRE would also require human approval and
are deliberately excluded from this first demo.

Keep the supervised window short. Decline outstanding cards and remove the
fixture/grant if approval cannot happen before recovery expiry. Do not leave an
authorized pending command unattended or silently replace human approval with
an automated test decision. Teardown must report agent retention/residuals rather
than claim a fully removed environment without checking them.

## Current evidence

The isolated `demo19` fixture verified a stopped application service inside a
running native Azure VM on 2026-10-09. SRE independently read Azure resource and
Activity Log evidence, distinguished the running VM from the stopped worker,
recommended the exact current-run operator repair and recorded recovery.
Guest service evidence was explicitly operator-collected throughout.

| Measurement | Observed outcome |
| --- | --- |
| Independent safety canary | Service stopped at 16:36:20 UTC and watchdog recovered it at 16:37:22 UTC: 62.15 seconds, without operator repair |
| Application fault | Real worker stop at 16:41:09 UTC; VM remained running; localhost health failed |
| Operator repair | Same-run repair recovered the service at 16:46:35 UTC: 5m26s after the actual service stop, before the ten-minute watchdog deadline |
| Repair command channel | Durable repair intent at 16:46:28 UTC; verified command result at 16:47:03 UTC: approximately 35 seconds, not a five-minute restart |
| SRE recovery conclusion | Fresh healthy receipt supplied at 16:50:13 UTC; SRE concluded recovered/no repair needed at 16:51:07 UTC: approximately ten minutes after the actual stop |
| Reset | Exact-run reset returned active/healthy service with a separate reset attribution |
| Teardown | Hardened inventory validation passed; Down and repeated Down returned absent; independent reads confirmed group, owner-tagged resources and fixture Reader grant absent |

The recovery conclusion included a verification-code correction: persisted JSON
timestamps can become PowerShell `DateTime` values, so deadline matching now
compares instants rather than string representations. This was not an
uninterrupted demo rehearsal. The timings exclude deployment and start at the
actual guest stop, not the fault request. Native Run Command added observable
command latency; the service failure itself was immediate. Fault-command intent
to SRE's final recovery note was approximately 10m05s. Operator orchestration and
the verification correction account for part of this interval; it is not a
measured autonomous or presentation time.

This is a promising replacement for VM-start-only demonstrations, **not yet an
autonomous scenario**. No alert-triggered investigation, direct SRE guest
repair, cross-reboot watchdog acceptance, three-cycle repeatability or retail
transaction recovery is claimed. The health gate checks the named systemd process and expected localhost JSON;
it does not verify worker progress, ERP ledger writes or Service Bus recovery.

**Planned reuse — GitHub-issue intake scenario.** This fixture's stopped
posting-worker fault is the designated fixture for the separate
"GitHub-reported incident to SRE recommendation" scenario (see
`docs/implementation-plan.md`): a user-filed GitHub issue describing the
stopped service, relayed to SRE through an HTTP trigger, rather than Azure
Monitor. That reuse is design-only and not yet built. It is a deliberate
contrast/fallback intake path, not a replacement for the standing goal that
every incident should eventually be triggered by Azure Monitor; this fixture
still has zero monitoring by design, and no Monitor-based trigger work is
implied or required for this gap.

Teardown rejects unexpected child resources before deleting the owned group.
The sole untagged exception is the exact VM-child `AzurePolicyforLinux`
extension with its ARM publisher/type verified. Pending repair/reset readback
requires the matching recovery actor and reason; watchdog recovery cannot
confirm an operator command with an unknown outcome.

The retained shared foundation remains intentionally present and billable.
Its SRE action mode stayed Review; no guest-write permission was granted.

Initial deployment exposed an invalid Allow rule using the deny-only
`AzurePlatformDNS` platform opt-out tag. The rule now targets the Azure resolver
address `168.63.129.16` on port 53 while preserving deny-all gates and explicit
NAT. The failed partial `demo16` fixture was removed and absence verified.
A fresh `demo17` VM provisioned and its exact fixture-scoped SRE Reader grant
was independently observed; post-deployment verification then exposed an
unsupported combination of scoped role-assignment listing with `--all`.
No guest fault was attempted during either provisioning failure. These are
deployment findings, not guest transport or autonomous-repair acceptance.
A fresh `demo18` installation verified the real guest command channel and
healthy service, but operator lookup failed before fault injection because
`az ad signed-in-user show` rejects the shared helper's subscription argument.
The harness now uses the authenticated Graph `/me` endpoint. The unused fixture
was removed rather than rebinding its source attestation; `demo19` supplied the
live fault/recovery evidence above.

## Repeatability and reboot test wrapper

`scripts\Invoke-GuestServiceCycleTest.ps1` is a code-only orchestration wrapper
that closes the "three-cycle repeatability" and "cross-reboot watchdog
acceptance" gaps flagged above. It does not add a new operation: it drives the
existing `Invoke-GuestService.ps1 Fault`/`Repair`/`Status` operations in a loop,
and triggers a VM restart (`az vm restart`, the same pattern used by
`Invoke-DiskScenario.ps1`) to additionally prove watchdog recovery survives a
guest reboot.

```powershell
.\scripts\Invoke-GuestServiceCycleTest.ps1 -SubscriptionId $subscription `
    -EnvironmentName demo16 -Cycles 3 -IncludeRebootCycle -Bootstrap
```

Each cycle injects a bounded fault, waits for a fresh fault run, collects the
SRE-equivalent repair attribution via `Repair -RunId`, and verifies healthy
Status evidence before starting the next cycle; it aborts on the first failed
cycle rather than masking a partial result. The optional final reboot cycle
restarts the VM, waits for the watchdog to bring the service back without any
operator repair call, and verifies `recoveryReason: "reboot"` /
`recoveredBy: "watchdog"` in the resulting Status evidence. The wrapper emits a
single structured summary object (`EnvironmentName`, `TotalCycles`, `Success`,
and a `Cycles` array with per-cycle timings and evidence) rather than narrating
progress, consistent with the repo's `Write-Verbose`-only console convention.

**2026-10-10: executed live against a fresh `demo25` fixture.** The wrapper
ran bootstrap + three fault/repair cycles + one reboot cycle end to end and
returned `TotalCycles=5, Success=True`. Every one of the 33 entries in the
fixture's persisted journal (`guest-service-state.json`) recorded
`outcome: "verified"` (or `"deployment-succeeded"` for the initial deploy) —
zero failures anywhere in the run.

| Cycle | Run ID | Fault injected (UTC) | Recovery (UTC) | Recovered by |
| --- | --- | --- | --- | --- |
| Bootstrap canary | `659a2dab-6f54-4b2d-a426-561feb6786f5` | 13:06:50 (60 s, canary) | 13:07:58 | `watchdog` (self-heal, proves the watchdog is live before real cycles start) |
| Cycle 1 | `4e65332d-f760-41cf-9b0d-e9b2d2704daf` | 13:10:56 (300 s) | 13:14:32 (repair started 13:13:58) | operator-equivalent `Repair` call |
| Cycle 2 | `15aca3dc-ea45-45e7-badd-5b7212914fd0` | 13:18:10 (300 s) | 13:21:47 (repair started 13:21:13) | operator-equivalent `Repair` call |
| Cycle 3 | `b705f5c6-5d2e-49bb-a269-0c8dae7e2234` | 13:25:22 (300 s) | 13:28:59 (repair started 13:28:25) | operator-equivalent `Repair` call |
| Reboot cycle | `36882af3-5694-41be-a05b-37bc53bdd2d1` | 13:32:34 (300 s, non-canary) | 13:33:45 | `watchdog`, `recoveryReason: "reboot"` |

The reboot cycle is the key new proof: the VM actually restarted (a distinct
`bootId`, `e90e6c24-...`, confirms a real reboot rather than a service
restart) and the watchdog detected and recovered the stopped service on its
own, with **no operator or SRE repair call**, well inside the ten-minute
recovery deadline (`13:37:43`). A final `Status` check at `13:35:25` confirmed
`active=true, healthy=true`. All five cycles share one consistent actor/owner
identity throughout, with no unexpected identity changes between cycles.

Total live test execution ran from the fixture's `deploy` entry (`12:56:49`)
to its final `status` entry (`13:35:25`) — about 38.5 minutes, in line with
the original estimate. This closes both previously open gaps: three-cycle
repeatability and cross-reboot watchdog acceptance are now verified, not just
tooled. The `demo25` fixture was torn down after evidence was captured.

## Human-approved repair evidence (`demo23`)

The isolated `demo23` fixture repeated the `demo19` proof with the
human-approved gate from "Human-approved native repair" live. SRE proposed the
exact native repair command; the human approver fetched the same pending
command from the SRE portal, verified it byte-for-byte against the harness's
expected output, and only then clicked Approve.

| Measurement | Observed outcome |
| --- | --- |
| Fault injected | 2026-10-09 19:49:11.957860 UTC |
| Recovery deadline | 2026-10-09 19:59:11.957860 UTC (ten-minute watchdog window) |
| Command verification | Portal pending command matched the harness's encoded repair byte-for-byte (965/965 characters), confirmed before approval |
| Human approval | Approver clicked Approve in the SRE portal only after verification; the adapter exposes no programmatic approval operation |
| Repair completed | 2026-10-09 19:52:53.185469 UTC, approximately six minutes before the watchdog deadline |
| Guest-side evidence | `recoveredBy` matched the isolated action principal (`d0c24ad7-...2b59`); `recoveryReason: "repair"`, distinct from `"watchdog"` |
| Independent Activity Log evidence | A single `correlationId` recorded `Started` -> `Accepted` -> `Succeeded` for the Run Command action, with caller equal to the same action principal; no duplicate or earlier invocation existed in the window |

Three independent lines of evidence (guest-reported attribution, the Azure
control-plane Activity Log, and the approver's own byte-for-byte verification
immediately before clicking Approve) agree on exactly one gated invocation.
This confirms the human-approval gate worked as intended: SRE proposed and
waited; only the human's own portal click released the command.

### Known tooling limitation, not a gate failure

The adapter's `Read` operation (`Invoke-GuestServiceApproval.ps1 Read`) never
populated the `approval`, `nativePending` or `nativeCompleted` fields during
this rehearsal, even while a command was genuinely pending and later executed.
This reflects a gap in the adapter's structured visibility into the SRE
portal's native-action approval state, not a bypass of the gate itself; the
Activity Log and guest evidence independently confirm the single approved
execution. Operators should treat the SRE portal/chat UI itself, not scripted
polling against this field, as authoritative for observing and acting on
pending native-action approvals until that visibility gap is closed.
