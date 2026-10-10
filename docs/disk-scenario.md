# Windows Arc disk-capacity scenario

**Status: operator-first incidents verified on three fresh fixtures, not
customer-ready.** Fresh fixtures completed the following flow on 2026-10-08
and 2026-10-09:

1. Introduce bounded pressure on a disposable data volume.
2. Receive a real Azure Monitor alert.
3. Let SRE investigate actual evidence and propose the supplied recovery script.
4. Have the operator run that fixed script for the current fault.
5. Verify fresh capacity, watchdog and IIS observations, alert recovery, and
   SRE's evidence-backed resolution.

Automatic SRE guest remediation is a later, separate integration question.
An operator script or safety watchdog is never recorded as an autonomous
SRE fix. This sequencing supersedes the earlier recommendation to extend the
native VM-start proof first; that proof remains a verified fallback.

The [operator demo runsheet](disk-demo-runsheet.md) separates a proposed live
recovery segment from later monitor clearance and prepares exact-run operator
verification. It changes no alert or safety behavior and has not been rehearsed.

## Scenario and safeguards

The independently implemented Windows/IIS fixture follows the capacity-incident
concept in the [reference workshop](https://github.com/JoranBergfeld/sre-agent-workshop).
It does not copy the workshop's implementation or fill its system disk.
The Windows choice is an implementation assumption, not a user-selected OS.

The fixture has a private NIC and a separate four-GiB managed data disk. Native
Compute Run Command is used only during provisioning. Afterwards, native VM
extensions are removed, WindowsAzureGuestAgent is stopped and disabled, and
both Azure IMDS addresses are blocked using the documented evaluation pattern.
Arc connects through the retained foundation's private-link scope.

The guest controller restricts disk operations to the dedicated nonboot,
nonsystem disk. Installation requires exactly one empty RAW four-GiB SAS/SCSI
disk and an unused `R:` letter; it persists volume and disk identities and
restricts the test directory to SYSTEM/administrators. Recovery rechecks those
identities and removes only the exact current run's pressure file. It does not
delete arbitrary files, resize a volume, or clean an OS disk.
Each run ID has a lifetime reservation: it cannot be reused even after cleanup
or an unsuccessful attempt. A file collision preserves both the existing file
and the previous run state.

The fault targets approximately eight percent free on `R:`, with a
fixed allocation bound and reserve, a two-minute injection limit, and a maximum
20-minute expiry through the public lifecycle (the guest controller caps all
requests at 30 minutes). A SYSTEM scheduled task runs every minute and on startup,
independently of Arc, SRE or the laptop. A one-MiB canary must prove independent
cleanup before real pressure is enabled. Expiry includes the injection period;
watchdog scheduling means cleanup is not guaranteed at the exact deadline.

**IIS deliberately remains healthy.** This is a disk-capacity incident, not
evidence of an unavailable website, failed retail checkout or lost revenue.
The OS volume is not stressed.

## Observed integration evidence, 2026-10-08

The original and replacement `demo03` attempts below preceded the successful
`demo04` incident. Their failures and safety evidence remain separate from the
new fixture's acceptance record.

| Boundary | Evidence and limit |
| --- | --- |
| Private Windows Arc onboarding | Connected Machine agent connected through the expected private-link scope after the native management transition |
| Guest commands | Four complete probes verified owner, disabled native guest agent, enabled IMDS firewall blocks and local IIS HTTP 200 |
| Initial command polling | An accepted PUT can temporarily return HTTP 404/HCRP404 on GET. The client now waits for the same command within a deadline; it does not resubmit the mutation or hide other HTTP failures |
| Disk inventory | The actual four-GiB RAW Azure data disk reports bus type SAS, not SCSI. The first installation correctly stopped before initialization; the corrected guard accepts both |
| Corrected installation | The guest completed installation at 11:15 UTC, but the client initially saw Creating / Unknown and timed out. A later read exposed the successful result. This is delayed result visibility, not proof that the command never executed |
| Normal safety canary | The independent watchdog recovered the one-MiB canary at 11:47:39 UTC, approximately 23 seconds after its deadline; a subsequent observation confirmed healthy capacity and IIS |
| Recovery across reboot | A five-minute canary was active before a real boot at 12:05:37 UTC. The independent watchdog recovered it at 12:09:40 UTC, after its 12:09:19 deadline. A later diagnostic confirmed the exact run, healthy capacity and IIS. The first post-reboot Status request timed out; this proves recovery, not a successful or predictably timed observer workflow |
| Private monitoring | Real `Perf` and `RetailTxDisk` Event 2100 records were verified through private DNS and Arc managed identity. Initial missing Event rows failed readiness rather than being treated as health; later records arrived after collection warm-up |
| SRE read access | A separately labeled readiness thread queried actual private Windows telemetry. It was not an alert-created incident |
| Alert routing setup | Azure Monitor connectivity and an exact-Arc Review response plan were verified; the alert and plan were armed only after private healthy evidence and the independent canary proof |
| First full-allocation attempt | A Windows PowerShell 5.1 `Math.Min` overload selected Int32 for a greater-than-Int32 remaining size. The controller failed before filling the disk, performed its own cleanup, and exact-run recovery inspection confirmed 99.43% free and IIS 200. The arithmetic now uses Int64 and is checked in Windows PowerShell 5.1; the corrected controller was installed on a clean replacement fixture |
| Fresh provisioning downloads | Windows PowerShell twice returned a short MSI without a download exception; signature checks rejected it as NotSigned or UnknownError before installation. Bootstrap now uses bounded HTTPS-only curl downloads, checks its exit code and still requires a valid Microsoft signature. A subsequent clean deployment completed successfully with the verified package; it never installs an unverified package |
| Replacement fixture safety | Three consecutive fresh Arc probes completed, followed by installation, Doctor and independent canary recovery at 19:25:59 UTC, about 69 seconds after the deadline. The replacement reported 99.43% free and IIS 200. The earlier reboot proof belongs to the original fixture, not this replacement |
| Policy-installed monitoring agent | Policy started AMA installation before the monitoring template reached its extension resource, causing HCRP409. A manual retry after installation unnecessarily updated AMA and exceeded the 15-minute deployment observer, although it later succeeded. The lifecycle now verifies and preserves an existing agent; for this exact conflict only, it waits up to ten minutes and retries the declarative deployment once without rewriting AMA. The preservation path subsequently completed in about 74 seconds |
| Replacement incident preparation | Fresh private Perf/Event queries, SRE connectivity and the exact-target Review plan passed. An initial Fault call stopped before submission because the latest guest event was older than the three-minute limit. A second attempt's read-only telemetry command exceeded the four-minute observer and was still Creating / Unknown at 20:06 UTC, more than twelve minutes after submission. No full fault was submitted on this replacement |
| Cleanup and recreation | Teardown removed the original fixture, external grants and owned SRE configuration, restored the original shared settings, and succeeded again on repetition. Failed-provisioning generations and the final unready replacement were also removed. Final repeat teardown and an independent read at 20:13 UTC confirmed no fixture or owned workspace grants, removed SRE configuration, and the original foundation-only scope with no incident platform. The foundation remains intentionally retained and billable |
| Complete incident | Subsequently verified once on fresh `demo04`, as recorded below; this does not erase the earlier command-delivery failures |

**Reliability assessment:** do not use this guest-command path as the primary
live customer demo yet. The earlier failure was before fault injection, not
evidence that SRE failed to diagnose an alert. The fresh successful incident
proves the operator-first integration can work, but not predictable delivery
across repeated runs or fresh deployments. Neither the root cause of the earlier
stalls nor a general limitation of Arc-managed VMs has been established. Retain
the verified native-action fallback rather than adding another guest-command
transport or relaxing freshness checks.

Short successful Windows commands disprove a blanket assertion that Arc cannot
execute on a VM. They do not establish reliable command delivery, explain the
earlier Linux failure, or prove SRE can invoke the same action. Do not introduce
SSH, WinRM, a new control service or broader SRE permissions to hide this gate.

Raw command responses, nonsecret ownership manifests and diagnostics stay under
ignored `.azure/<environment>/`. A command timeout is an unknown outcome, not
cancellation: an accepted remote installation can still execute later.
New commands retain their exact per-command `.request.json`, including the
completion nonce, before submission. Verified results are retained separately.
An authentication failure during polling also does not cancel the guest action.
Completed Run Command resources now remain on the owned fixture until `Down`
deletes the fixture. This removes unnecessary inter-command deletion from the
incident path and preserves Azure-side evidence. It is a lifecycle simplification
being evaluated, not an established explanation of the earlier stalls.
The [Arc Run Command documentation](https://learn.microsoft.com/en-us/azure/azure-arc/servers/run-command)
describes command resources as retained, listable objects and deletion as a
separate operation that can terminate an in-progress script.

### First complete operator-first incident

Fresh `demo04` passed three probes, installation, Doctor and its own independent
canary. Its watchdog recovered the canary at 20:37:32 UTC, about 27 seconds after
the deadline. The original fixture's reboot proof does not transfer to this one.
Provisioning through arming took approximately 28 minutes, including monitoring
warm-up and RBAC propagation. The first private telemetry request returned an
explicit workspace authorization failure immediately after role creation; a
later request succeeded without broadening permissions.

All times below are UTC on 2026-10-08, for run
`920e0b3c-e445-4f40-91be-45ba213d19d8`.

| Time | Verified event |
| --- | --- |
| 20:50:19 | Bounded fault requested; independent recovery deadline was 21:11:50 |
| 20:52:45 | Guest observation showed `R:` at 8% free, with IIS HTTP 200 |
| 20:57:31 | Azure Monitor fired the exact-target disk alert |
| 20:58:28 | SRE automatically created the investigation thread, about 56 seconds after the alert |
| 21:00:31 | SRE had queried private evidence and proposed the supplied operator command with the actual run ID |
| 21:05:26 | The operator script recovered the same run to 99.43% free, before the watchdog deadline; IIS remained HTTP 200 |
| 21:07:55 | In the same thread, SRE verified post-recovery Perf and matching healthy Event evidence and recorded an RCA |
| 21:17:36 | Azure Monitor automatically changed `monitorCondition` to `Resolved`; no forced state change was made |
| 21:18:52 | SRE recorded its final note after another private query: 99.44% free, same-run healthy state, IIS 200 and a fresh watchdog |

Investigation started from the actual alert, not a manually created incident.
After recovery, follow-up messages in that existing thread requested independent
verification and the final note. The recovery actor was **operator-script**,
not SRE or the watchdog. No guest-write permission was granted to SRE.

The monitoring condition resolved, but `alertState` remained `New`; the exact
SRE incident detail reported `AuthorizationBlocked` for acknowledgment and
status `new`. This is a separate incident-workflow limitation, not failed disk
recovery. Automatic acknowledgment/closure is **not** verified. No broader role
was added and no external ITSM incident was fabricated.

Collection responses lagged or omitted material metadata: the SRE incident
query returned a null thread even after automatic investigation, and the Azure
alert list still showed `Fired` after the individual alert had resolved. Inspect
the exact incident and resource-scoped alert, rather than concluding no
investigation or recovery from a list alone.

This run does not pass a twelve-minute demo target: fault request to guest
recovery took about 15 minutes (about 13 minutes from observed full pressure),
including operator observation delays. Automatic alert clearance followed guest
recovery by about 12 minutes. The final note was about 29 minutes after the fault
request. Setup and telemetry warm-up are additional, separately measured work.
One successful fixture is not three fresh cycles or a human rehearsal.

Owned teardown completed at 21:26:35 UTC. Repeat `Down` and an independent read
at 21:28:36 confirmed no fixture resource group or owned live resources, no owned
workspace/bootstrap grants, no scenario investigator or response plan, and the
original foundation-only SRE scope with no incident platform or disk-owner tag.
Retained Run Command resources were removed with their Arc fixture. The
foundation remains intentionally retained and billable. Local incident and
teardown proofs remain under ignored `.azure\demo04`; historical telemetry,
audit records and conversation history are not claimed as erased.

## Fresh deployment repeat, 2026-10-09

Fresh `demo05` repeated the complete operator-first flow without reusing an
earlier fixture's installation, canary or incident proof. Three Arc probes,
installation, Doctor, the independent canary, private monitoring and SRE
configuration passed. Provisioning started at 06:31:36 UTC; arming finished at
07:00:22 UTC. Setup remained approximately 29 minutes, outside incident timing.

| Boundary | Observed UTC time and evidence |
| --- | --- |
| Fault operation started | 07:00:22; fresh telemetry and reset checks precede submission |
| Fault requested | 07:03:14; unique run `f4ba3323-66aa-4269-ac22-7e87dd435b49` |
| Real capacity pressure | Perf dropped at 07:04:54; guest observation at 07:05:13 confirmed 8% free and IIS 200 |
| Alert and automatic investigation | Alert fired at 07:06:21; linked SRE thread started at 07:07:46, without manually starting investigation |
| Operator proposal | 07:10:00; exact current-run recovery command, fresh watchdog and capacity-only impact |
| Operator recovery | 07:12:21; `operator-script` restored 99.43% free, before the 07:24:05 watchdog deadline |
| Independent recovery verification | SRE observed Perf at 99.435998% at 07:15:25 and the matching healthy watchdog at 07:15:30; RCA recorded at 07:16:26 |
| Automatic alert clearance | Individual alert resolved at 07:26:10; SRE independently verified clearance and wrote its final addendum at 07:28:10 |

The new read-only `Incident` operation observed the exact alert and linked
thread. Its first live call exposed a PowerShell JSON-date conversion bug before
querying incidents: reparsing a deserialized DateTime through a culture-specific
string changed October 9 into September 10. Direct DateTimeOffset conversion
fixed the observer; US/Dutch JSON-round-trip checks now cover that path.
The existing fault was not replayed.

Guest recovery and monitoring convergence were separate. Perf still reported
approximately 8% through 07:13:55 despite a healthy guest event; SRE withheld
verification until the counter converged. Alert clearance then lagged guest
recovery by approximately 14 minutes. This rule uses a one-minute evaluation
frequency with automatic mitigation; Microsoft documents a
[ten-minute nonbreaching interval for stateful log-alert resolution](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-overview#alerts-and-state).
That interval follows counter convergence, not the operator command's return.
It is not evidence of failed guest recovery or an Arc command stall.
Acknowledgment remained
`AuthorizationBlocked`, with alert state `New`; no forced acknowledgment,
closure or permission expansion was used. Post-recovery SRE checks and the final
addendum required operator follow-up messages in the original thread.

Fault request to guest recovery was approximately nine minutes, but the full
fault-operation-to-final-note flow took approximately 28 minutes. This is not
a twelve-minute end-to-end presentation or a human rehearsal. Two fresh
successful fixtures do not satisfy the three-fresh-cycle release gate.
The first repeat's asserted proof and raw evidence are preserved under ignored
`.azure\demo05\runs\f4ba3323-66aa-4269-ac22-7e87dd435b49`.

### Same-fixture reset and second incident

After observing the first individual alert as `Resolved`, a second `Fault`
passed the reset guard on the same fixture. Initial observation returned
`awaiting` rather than inheriting the previous alert or thread. The new run,
`e8d402fd-9f38-4b2b-b090-9ed7b903ae32`, produced a distinct alert and an
automatically initiated SRE thread. SRE rejected stale earlier-run recovery
evidence and proposed recovery for the current run.

| Boundary | Observed UTC time and evidence |
| --- | --- |
| Fault operation and request | Operation started at 07:29:07; request recorded at 07:30:55 |
| Real pressure | 07:33:29; 8% free, IIS 200, independent watchdog deadline 07:52:14 |
| Alert and automatic investigation | Alert fired at 07:36:22; distinct linked thread started at 07:37:12 |
| Operator proposal | 07:39:01; exact current-run recovery command |
| Operator recovery | 07:41:49; `operator-script` restored 99.43% free before the watchdog deadline |
| Independent telemetry convergence | Private Perf showed 99.435998% at 07:45:55 with matching healthy guest evidence |
| SRE verification interruption and retry | Internal error at 07:46:22; one bounded read-only retry verified recovery and produced an RCA at 07:48:15 |
| Automatic alert clearance | Individual alert resolved at 07:56:23; observed `Resolved` at 07:58:04 |
| Final SRE addendum | 07:58:52; independently verified the exact resolved alert, 99.435998% private Perf, same-run operator recovery, IIS 200 and a fresh watchdog |

Fault request to guest recovery was approximately eleven minutes; the complete
fault-operation-to-final-note flow took approximately thirty minutes. The
internal-error interruption remains part of the record: a successful retry
does not make this an uninterrupted success. Neither the fault nor recovery
was resubmitted, and permissions were not widened. Monitor condition `Resolved`
remained separate from alert state `New`; no forced closure was used.

This verifies same-fixture reinjection after clearance, with distinct run,
alert and thread identities. It is a third completed incident across two fresh
fixtures, not three fresh deployment/demo/reset/destruction cycles. Asserted
proof and raw evidence are preserved under ignored
`.azure\demo05\runs\e8d402fd-9f38-4b2b-b090-9ed7b903ae32`.

Owned teardown completed at 08:05:58 UTC; repeat `Down` completed at 08:06:15.
An independent read at 08:06:51 confirmed the fixture group absent and zero
owned live resources, including removal of its Arc machine and retained Run
Commands. Owned workspace/bootstrap grants, scenario investigator and response
plan were absent. SRE's foundation-only scope, null incident platform and absent
disk-owner tag were restored. Proof remains under ignored `.azure\demo05`.
The reusable foundation remains intentionally retained and billable;
historical telemetry and conversations are not claimed as erased.

## Timing experiment blocked before injection, 2026-10-09

A fresh `demo06` was provisioned to measure prompt operator recovery after
SRE's real proposal and immediate verification, without changing alert, safety
or permission settings. Three Arc probes, installation, Doctor and independent
canary recovery passed. Monitor completed after the existing bounded
policy-installed AMA preservation/retry path; Connect completed at 08:51:38 UTC.

`Arm` then failed at the private Arc-identity Log Analytics query with
`InsufficientAccessError`. Both recorded workspace grants were present on an
independent scoped role-assignment read. One bounded readiness retry returned
the same explicit access denial. This is not an unexplained command-delivery
timeout: the guest command completed with an HTTP authorization error.
Grant presence does not establish effective data-plane access, and the cause
has not been established. No role was widened, token material exposed or
readiness requirement bypassed.

The alert remained disabled and no fault was injected. Consequently this
attempt provides no fault/proposal/recovery timing and no evidence of improvement.
Do not count it as a successful fresh incident cycle or a rehearsal.
The prior 9-11-minute recoveries and 28-30-minute full flows remain the evidence.
Resolve effective private query access on a fresh identity before another
timing experiment; do not add automatic retries that conceal readiness failures.

Owned `Down` completed at 09:01:44 UTC and repeat teardown at 09:02:18.
Independent reads at 09:03:44 confirmed no fixture group or owned live resources,
no recorded external grants or scenario SRE investigator/plan, and restored
shared SRE settings. Raw failure, timing and teardown evidence remains under
ignored `.azure\demo06`. The reusable foundation remains retained and billable.

## Measured prompt-recovery incident, 2026-10-09

Fresh `demo07` tested prompt operator execution and immediate SRE verification,
not a human rehearsal. The unchanged Arc workspace grant was created during
`Up` at 09:17:14 UTC. However, `Monitor` rewrote that same assignment at 09:28:10;
initial `Arm` still returned `InsufficientAccessError`. A later bounded readiness
retry succeeded before injection. Assignment propagation is a possible
explanation, not an established root cause. This was not uninterrupted readiness.

| Milestone | UTC and evidence |
| --- | --- |
| Fault operation and request | Operation started 09:37:42; request recorded 09:38:47 |
| Actual pressure | 09:39:55, approximately 8% free on disposable `R:`, IIS 200 |
| Alert and automatic SRE thread | Alert 09:43:57; thread 09:44:21 |
| Exact-run proposal | 09:45:31, backed by fresh low-capacity Perf and owned watchdog evidence |
| Operator command and recovery | Command started 09:46:27; actual recovery 09:48:04, 99.43% free, actor `operator-script`; command returned 09:48:32 |
| Conflicting private observations | Healthy same-run events arrived while fresh Perf still reported 7.994115% through 09:52:07; a separate observer also rejected stale evidence |
| Independent private convergence | Captured Perf 99.435998% at 09:54:37 with healthy same-run watchdog, IIS 200 and private query address |
| SRE verified recovery/RCA | 09:56:45, after independently reading healthy Perf and the same-run operator-recovery watchdog; Monitor clearance still pending |
| Automatic clearance and final note | Exact alert resolved 10:04:19; SRE independently verified fresh healthy evidence and automatic resolution in its final addendum at 10:05:45 |

Fault request to guest recovery was **9 minutes 17 seconds**; fault-operation
start to recovery was **10 minutes 22 seconds**. Execution began 56 seconds after
the proposal, but guest recovery still followed 1 minute 37 seconds after command
start. Operator preparation cannot eliminate that lifecycle/Arc execution time.
The captured healthy Perf sample followed guest recovery by 6 minutes 34 seconds;
SRE's verified recovery/RCA came approximately **18 minutes after fault request**.
The counter/event discrepancy was not silently accepted or treated as a
successful four-minute verification. Its underlying cause is not established.
This does **not** demonstrate a faster verified incident or meet the twelve-minute
end-to-end gate.
Fault-operation start to final clearance note was **28 minutes 3 seconds**,
still within the prior 28-30-minute range rather than a material improvement.
Acknowledgment remained `AuthorizationBlocked` and alert state `New`; automatic
monitor resolution is not acknowledgment or closure.

SRE also guessed unsupported alert APIs and a subscription-scoped individual
alert path, then attempted an unsuccessful read with its system identity.
Operator correction to the exact nested Arc alert ID and
`2019-05-05-preview` succeeded using the original configured action identity.
The future `Connect` instructions now prohibit identity switching, provide that
exact validated read shape, distinguish guest recovery from monitor clearance
and keep the note in the existing thread. These instruction changes were not
applied to the already running investigator and do not replace scoped RBAC.
No permissions were expanded, guest mutations delegated or alert closure forced.

`Set-MonitorAccess` now validates and reuses the exact owned assignment without
rewriting it. A live read-only reconciliation of `demo07` verified no write
attempts and unchanged `updatedOn`; offline tests cover grant creation,
ownership/identity drift rejection and early placement in `Up`. The no-rewrite
change was introduced **after** this fixture's `Monitor`, so a complete fresh
`Up` through `Monitor` with both changes is not yet proven.

Owned teardown completed at 10:11:36 UTC and repeat teardown at 10:11:51.
Independent reads at 10:12:22 confirmed the fixture group and all owned live
resources absent, recorded workspace/private-link grants absent, scenario SRE
investigator/plan absent, and exact shared SRE settings restored.
Measured same-run evidence, raw thread, conflicting samples and teardown proof
remain under ignored `.azure\demo07`; the reusable foundation remains retained
and billable.

## Lifecycle commands

The same guarded lifecycle now includes an optional IIS price-dependency
scenario. Its real guest HTTP fault, Event-only alert, operator recovery
commands, and explicit non-customer-impact limitations are documented in the
[Windows Arc price-service scenario](price-service-scenario.md). The code is
not yet live-verified; this document's disk evidence remains the only accepted
live scenario proof.

Use PowerShell 7.2+, Azure CLI and Bicep with the authorized subscription and the
retained foundation manifest. The guest scripts require Windows PowerShell 5.1
and must not be executed on the operator's laptop. The operator needs scoped
deployment, Arc Run Command and role-assignment permissions. SRE gets only
Reader on the fixture, not Arc command-write permissions.

```powershell
$subscription = '<authorized-subscription-guid>'
$environment = 'demo03'

.\scripts\Invoke-DiskScenario.ps1 Up -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-DiskScenario.ps1 Probe -SubscriptionId $subscription -EnvironmentName $environment
# Require three completed Probe operations before installation.
.\scripts\Invoke-DiskScenario.ps1 Install -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-DiskScenario.ps1 Doctor -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-DiskScenario.ps1 SafetyTest -SubscriptionId $subscription -EnvironmentName $environment
# Optional additional safety evidence; this restarts the owned backing VM.
.\scripts\Invoke-DiskScenario.ps1 SafetyTest -SubscriptionId $subscription -EnvironmentName $environment -RebootDuringSafetyTest
```

`Up` never injects a fault. Partial bootstrap is not replayed: inspect evidence
and use owned teardown before a fresh deployment. `Install` refuses to overwrite
an existing controller. Do not retry an uncertain installation blindly, edit a
manifest to pretend it succeeded, or bypass the disk identity checks.
The Windows image must include curl (8.13.0 was observed). Downloads retry at
most twice after the first attempt, with a 180-second per-attempt limit,
HTTPS-only redirects and partial-output removal on failure. Signature errors
remain fatal; the downloader does not disable TLS or Authenticode validation.
For an uncertain installation submitted by the current lifecycle, inspect the
recorded command and run the read-only reconciliation path:

```powershell
.\scripts\Invoke-DiskScenario.ps1 Reconcile -SubscriptionId $subscription -EnvironmentName $environment
```

`Reconcile` requires the recorded intended source digest, that exact installed
revision, fresh owned healthy observations, a current watchdog and no previous
fault run. It updates local installation metadata, not guest files, and never
replays installation. It is not an upgrade or general repair command.

After guest installation and safety validation, the following operations
configure monitoring and inspect real evidence:

```powershell
.\scripts\Invoke-DiskScenario.ps1 Monitor -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-DiskScenario.ps1 Telemetry -SubscriptionId $subscription -EnvironmentName $environment
```

`Up` now records and grants the exact connected Arc principal workspace-scoped
Log Analytics Reader access before probes, installation and safety preparation.
This gives the unchanged permission more lead time before its first query.
`Monitor` reuses that exact recorded assignment and rejects identity drift;
the alert identity's grant remains tied to its monitoring deployment.
Effective private access is still required by `Arm` and `Fault`; assignment
presence is not a readiness substitute. Microsoft documents that
[role-assignment changes can take up to ten minutes to take effect](https://learn.microsoft.com/azure/role-based-access-control/troubleshooting#role-assignment-changes-are-not-being-detected).
Earlier assignment is a mitigation to validate, not a proven diagnosis of the
`demo06` failure. Owned `Down` removes the grant even if monitoring never ran.

`Monitor` leaves the static alert **disabled**. It collects the `R:` free-space
counter and structured Windows events through AMA, the foundation DCE and
private workspace. It records exact workspace-scoped Log Analytics Reader
assignments for the Arc and alert identities before creating them. Teardown
checks assignment identity, scope, role and ownership description before removal.
Reuse of the existing DCE for real Windows Perf and Event ingestion was verified.
An existing Microsoft AMA extension is verified rather than redeployed, so a
policy-installed agent is not removed or unnecessarily updated. If policy wins
the initial installation race, only an exact AMA `HCRP409` deployment failure
allows one retry, after successful extension provisioning and without another
extension write. Other failures and unknown deployment outcomes remain errors.

`Telemetry` queries the exact Arc resource from inside the private network using
Arc managed identity. It rejects missing, stale, future-dated or foreign evidence.
Low free space remains low free space; a returned row or absent alert is not
converted into health. Tokens and challenge secrets remain in guest process memory.

The incident configuration remains separate from injection:

```powershell
.\scripts\Invoke-DiskScenario.ps1 Connect -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-DiskScenario.ps1 Arm -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-DiskScenario.ps1 Fault -SubscriptionId $subscription -EnvironmentName $environment
```

`Connect` creates an owned investigator and disabled, exact-target Review plan.
It preserves shared settings and requires no existing response plans, with one
active disk fixture per SRE agent. A foundation-scoped file lease serializes
these operations across fixtures in this checkout. An ownership tag and
configuration-drift checks additionally reject observed foreign changes.
This is a single-operator lifecycle: do not configure the agent concurrently
from another checkout, machine or portal session. The observed ARM resource
does not expose an ETag for conditional updates, and the local lease is not a
distributed Azure lock. ARM accepting a
configuration change is not immediate data-plane readiness: the lifecycle
waits for actual Azure Monitor connectivity before writing the plan. A pending
platform update can be inspected and completed without replaying that mutation.
A known pre-submission failure or explicit HTTP rejection is recorded separately
and permits owned investigator cleanup after verifying the unchanged baseline.
A transport timeout is not a rejection.

`Arm` requires actual healthy private telemetry and the independent canary
proof. `Fault` rechecks those gates, the owned enabled alert, SRE Review plan
and connection, and at least 25 minutes before the fixture expiry. It records
the exact new run ID before submitting the bounded fault. An uncertain request
blocks further injection and safety tests until that exact run is resolved;
recovering an older healthy run cannot clear the pending-fault gate.

Observe the current fault without submitting another guest command:

```powershell
.\scripts\Invoke-DiskScenario.ps1 Incident -SubscriptionId $subscription -EnvironmentName $environment
```

`Incident` takes one bounded read-only snapshot, rather than polling indefinitely.
It checks the owned fixture, rule and shared SRE configuration, discovers alerts
for the exact Arc target within the last day, and rejects incomplete discovery,
ambiguous matches, foreign IDs and invalid timestamps. Only activations after
the recorded fault request qualify. A separate fault-run binding prevents a
later safety canary from inheriting an earlier incident.

The individual Azure alert is authoritative for `monitorCondition`; the exact
SRE incident keyed by that alert GUID is authoritative for `threadId` and
acknowledgment. The operation does not rely on incident-list thread metadata or
follow response-provided URLs. `awaiting` means no qualifying alert was discovered
in this snapshot, not proof that no alert will arrive. A missing SRE incident or
thread is reported as not yet observed, never as successful investigation.
Failed requests remain errors; they are not converted into absence.

Each snapshot has a unique run-scoped filename under ignored `.azure`.
`resolved` means the monitor condition cleared, not verified guest health or
automatic incident acknowledgment/closure. Continue requiring fresh private
Perf/Event evidence and SRE's actual note. This operation does not inject,
recover, acknowledge, close, widen permissions or start an SRE thread.

After recovery, a repeated `Fault` additionally requires the previous run's
individual alert to be `resolved`. Missing, delayed or still-fired evidence
blocks reinjection, even if the guest is already healthy; otherwise a stateful
alert could stay active and never create a distinct second incident. This check
does not force clearance or require acknowledgment.

These implemented gates do not, by themselves, establish that an alert
automatically started an investigation; verify the actual alert and its linked
thread on every run. That boundary has now passed on two fresh fixtures. The investigator is
instructed to propose the supplied operator command, never execute it, and to
distinguish operator, watchdog and injection-error cleanup actors.

Recovery requires the exact current fault ID from verified guest evidence:

```powershell
.\scripts\Invoke-DiskScenario.ps1 Recover -SubscriptionId $subscription -EnvironmentName $environment -RunId '<current-run-guid>'
.\scripts\Invoke-DiskScenario.ps1 Down -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-DiskScenario.ps1 Down -SubscriptionId $subscription -EnvironmentName $environment
```

`Down` removes the owned response plan and investigator, restores the recorded
shared SRE settings, and removes the fixture and its recorded external
permissions, not the retained foundation. Unexpected shared configuration or
another response plan blocks restoration rather than overwriting another
consumer. `Disconnect` performs only the SRE cleanup when the alert is unarmed.
Expiry tags are reminders, not automated resource deletion.
After a verified teardown, the next `Up` archives the previous ownership
generation's local evidence under `.azure\<environment>\history\<ownerToken>`
before creating a fresh manifest; old SRE or safety state cannot become the new
generation's evidence.
Historical Monitor records and Azure deployment/audit history are not claimed
as erased.

## Repeated same-fixture incident cycle, 2026-10-10

`demo24` is a distinct fixture (its own resource group and VM, separate from
demo05/06/07) that was deployed once and then reused for repeated incident
cycles rather than torn down between runs; its state file records
`probeCount: 3` and `phase: "armed"` at last check. This entry documents the
third of those cycles, run without a human presenter, extending the same-fixture
repeat pattern already established on demo05 rather than demonstrating a fresh
deploy/teardown cycle.

| Milestone | UTC and evidence |
| --- | --- |
| Fault request | 09:49:32.093 (run `01995be3-aeac-478d-b1f4-7c3f3856e3b9`) |
| Guest-observed pressure | 09:51:15.284, 8% free on disposable `R:`, IIS 200, watchdog 09:48:58.403 |
| Alert fired | 09:55:41.928 (Sev2, data volume below 10 percent free) |
| SRE discovery snapshot | 09:57:44.726, status `new`, `monitorCondition: Fired`, `acknowledgementState: AuthorizationBlocked` |
| First recover command submitted | 10:00:28 |
| Guest-side actual recovery | 10:01:14.333, approximately 46 seconds after the first command and before the second was issued |
| Second recover command submitted | 10:02:50; Azure-side executed 10:03:17.232-10:03:38.029, `provisioningState: Succeeded`, `exitCode: 0` |
| Verified healthy | 10:03:36.917, 99.43% free, IIS 200, fresh watchdog 10:03:00.719, `recoveryActor: operator-script`, same `recoveredAt` as the guest-side recovery above |
| SRE re-check | 10:04:36.283, status still `new`/`Fired`, `acknowledgementState: AuthorizationBlocked` |

Fault request to guest recovery was **11 minutes 42 seconds**; fault request to
the final SRE re-check was **15 minutes 4 seconds**. Both remain consistent with
prior runs and do not reopen the twelve-minute end-to-end split already settled
above.

The first recover command's result was not yet visible at 10:00:31, when
tooling logged: "Arc command result is not visible yet; waiting for the same
command, not resubmitting:
/subscriptions/de4195ac-.../runCommands/recover-d139faf8a6664c0d8427447b5df2d575."
Guest-side evidence shows that command had already begun executing and
completed recovery roughly 46 seconds after submission, before the second,
idempotent command was issued at 10:02:50 — the delay was in result
visibility, not guest execution. The second command's output reported the
same `recoveredAt` timestamp as a re-report, not a new recovery event. This is
read as supporting evidence for reliable Arc guest-command delivery, not proof
that the first command never ran.

Acknowledgment state was `AuthorizationBlocked` across every snapshot in this
run, consistent with the pattern already confirmed on demo05 and demo07. This
cycle does not by itself satisfy the fresh deploy/reset/teardown gate: the
fixture was reused across three incident cycles rather than redeployed between
them, and it remained `armed`, not torn down, at last check. It is also not a
human-presented rehearsal. Raw fault, discovery and recovery evidence for all
three cycles remains under ignored `.azure\demo24`.

## Remaining acceptance gates

- Predictably timed safety observation across reboot; recovery itself was observed.
- Repeated incident/reset runs and fresh deploy/teardown cycles without hidden
  repairs, then human rehearsal. Provisioning and warm-up are measured separately.
- **Decided:** split the twelve-minute target instead of forcing it end-to-end.
  Azure Monitor's stateful log alert needs
  [ten continuous nonbreaching minutes](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-overview#alerts-and-state)
  before automatic resolution — platform behavior, not configurable — so no run
  can reach full clearance under roughly that floor even with instant recovery.
  Twelve minutes applies to the **live, presented segment** only: fault through
  visible guest recovery, which measured 9–11 minutes across runs including
  demo07 (9m17s). SRE's independently verified recovery/RCA and the automatic
  monitor clearance are narrated as pending and confirmed afterward, matching
  the clearance handling in [the runsheet](disk-demo-runsheet.md), not watched
  live. This does not resolve demo07's own verified-RCA delay (about 18
  minutes, driven by counter-convergence lag) — that stays open as a
  reliability gap in [implementation-plan.md](implementation-plan.md)'s "Work
  remaining" table, not closed by redefining the target.
- **Decided:** keep the unacknowledged incident boundary in the demo; do not
  widen the SRE identity's role. The exact missing permissions are
  `Microsoft.AlertsManagement/alerts/changestate/action` and
  `Microsoft.AlertsManagement/alerts/read`; the only built-in role that grants
  them is **Monitoring Contributor**, which also grants unrelated write access
  (alert rules, action groups, diagnostic settings, Log Analytics config) and
  does not fit this project's least-privilege precedent. Investigation,
  recovery evidence and automatic monitor-condition clearance already worked
  without widening the role, so the narrative explicitly states "unacknowledged
  by design" rather than fabricating closure. If a future run wants the alert
  to show closed, add a custom role scoped to only those two actions
  (following the pattern in `infra/native-action.bicep`), not Monitoring
  Contributor.
- Verify the post-recovery conversation flow with a human operator; the first
  proof used follow-up messages to request SRE verification and its final note.

Do not make automatic SRE-to-Arc remediation a prerequisite for these gates.
If guest delivery cannot be reliable enough, choose a different supported host
arrangement explicitly rather than claiming this integration works.

## References

- [Evaluate Arc on an Azure VM](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine):
  evaluation/testing only, not a production hybrid architecture.
- [Arc Run Command](https://learn.microsoft.com/azure/azure-arc/servers/run-command):
  supported command surface does not guarantee delivery in this configuration.
- [Arc extension troubleshooting](https://learn.microsoft.com/azure/azure-arc/servers/troubleshoot-vm-extensions):
  Connected status and extension-service health are distinct.
- [AMA private-link configuration](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-private-link).
- [Arc managed identity authentication](https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication).
- [Azure Monitor alerts in SRE Agent](https://learn.microsoft.com/azure/sre-agent/azure-monitor-alerts)
  and [incident response plans](https://learn.microsoft.com/azure/sre-agent/incident-response-plans).
- [Azure Monitor alerts and state](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-overview#alerts-and-state):
  stateful log-alert resolution timing is separate from guest recovery.
- [Get-AzAlert parameters](https://learn.microsoft.com/powershell/module/az.alertsmanagement/get-azalert?view=azps-16.4.0):
  exact target/rule discovery and the distinction between monitor condition
  and acknowledgment state.
- [SRE custom-agent v2 API](https://learn.microsoft.com/azure/sre-agent/tutorial-agent-hooks):
  the documented JSON resource shape is used for the investigator; no hook is
  presented as a pre-execution authorization boundary.
- [curl retry behavior](https://curl.se/docs/manpage.html#--retry-all-errors):
  retries use a regular output file, not redirected stdout, so partial bytes
  from a failed attempt are discarded before a new download.
