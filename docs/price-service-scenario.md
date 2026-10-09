# Windows Arc price-service scenario

**Implementation status: demo14 verified real HTTP failure and independent
watchdog recovery to HTTP 200 with the seeded JSON and healthy baseline.
Reboot safety also passed after reconciling delayed Arc output. A real incident
reached an SRE recommendation, operator-script recovery and independent SRE
recovery diagnosis and automatic Monitor clearance. A distinct repeat also
recovered, but required correction of SRE's stale-run diagnosis. Owned teardown
and repeated teardown passed; customer-repeatable acceptance remains open.** The existing operator-first
disk scenario remains the verified incident proof. Do not describe the new flow
as a verified retail checkout recovery.

Fresh installation attempts exposed four integration defects: the controller
rejected its own staged directory, recursive ACL setup removed file access, and
IIS anonymous authentication used IUSR rather than the restricted application
pool identity; IIS identity readback also returned a name rather than an integer.
These have dedicated regression checks and code corrections.
Each failed fixture was removed with independently checked absence of its
resource group and owned grants; no incident fault was injected. Successful
private Arc probes in those attempts do not establish pricing, watchdog,
telemetry, alert routing, or incident acceptance.
The fifth fresh fixture installed successfully but its watchdog returned task
result 1, leaving no fresh heartbeat and blocking SafetyTest. Direct invocation
identified an unparenthesized `DateTimeOffset.UtcNow` argument in the Watchdog
dispatch. The corrected dispatch now has an actual Windows PowerShell 5.1
regression test. Demo12 was removed; independent checks found no owned
resource group or grants, and the shared SRE Agent remained in Review. Do not
claim safety recovery or incident completion.

A fresh demo13 installation verified the corrected watchdog heartbeat. Its
bounded safety canary produced actual HTTP 503 with baseline HTTP 200, but
the immediate observation reported IIS pool state `Stopping`, not `Stopped`.
The host correctly rejected incomplete fault evidence. A later read of that
same run confirmed `Stopped`; no second canary was injected. The controller now
waits up to thirty seconds for the asynchronous stop transition and checks the
full stopped-pool failure contract before reporting successful injection.
Demo13 was removed, with independent checks confirming absence of its resource
group and owned principal grants.
Demo14 used the corrected revision and passed the first bounded safety test:
the same run returned HTTP 503 with the pool stopped, then the independent
watchdog restored HTTP 200, a valid response contract, and baseline HTTP 200
after its durable deadline. The reboot test's read-only status command exceeded
the four-minute observer limit. Reading that exact command later, with unchanged
source and nonce validation and without resubmission, established a new guest
boot and independent recovery three seconds after the canary deadline.
The disabled Event-only Monitor rule and owned recommendation-only SRE response
plan were subsequently configured. Private healthy telemetry was verified
after correcting the HIMDS bearer-header construction. Its ingestion lag
exposed a readiness defect: a collected event cannot establish a current
ninety-second watchdog heartbeat when collection itself takes longer.
Arming and injection now require both private healthy telemetry no older than
three minutes and a separately read current guest observation with a watchdog
heartbeat no older than ninety seconds. Both must match the exact owned run
and price contract; neither substitutes for the other. Stale private telemetry,
stale guest heartbeat, mismatched runs and failed current probes remain blocking.
The real incident was injected once at 13:54:46 UTC. The exact Arc-nested alert
was observed fired by 13:57:32 UTC; SRE's automatically created thread proposed
the exact-run operator command at 13:58:53 UTC. Its private workspace query
confirmed the stopped pool, HTTP 503 and healthy baseline without implying
retail or customer impact. The operator ran that command once and the guest
recorded recovery at 14:00:08 UTC, approximately five minutes twenty-one
seconds after injection. Fresh private Monitor evidence subsequently confirmed
HTTP 200, valid seeded JSON, baseline 200 and `operator-script` recovery.
At 14:05:24 UTC, SRE independently refreshed private same-run telemetry and the
exact nested alert, then wrote a recovery incident note in the existing thread.
It correctly reported recovered guest health separately from the still-fired
Monitor alert.
Monitor subsequently cleared automatically at 14:11:07 UTC: approximately
sixteen minutes twenty-one seconds after fault injection and eleven minutes
after guest recovery. No alert write was used. The SRE incident record still
reported `new` with blocked acknowledgement; automatic Monitor resolution is
not evidence that the SRE incident record was closed.
Automatic alert acknowledgement reported `AuthorizationBlocked`; investigation
and recommendation nevertheless completed. No acknowledgement permissions
were broadened and no alert was force-cleared.

The initial recovery verifier queried before the healthy event was ingested
and rejected the still-current fault event. Read-only observation of the same
run then established recovery without repeating the repair. The verifier now
waits up to five minutes for private healthy evidence, retrying only reads of
valid fresh same-run fault events. Unknown, stale, mismatched or malformed
evidence and unexpected recovery actors still fail explicitly. One query may
also incur the existing bounded Arc observer latency.
Customer-repeatable acceptance remains open. Delayed command-result visibility is not evidence that
the guest action did not run.
The first repeat attempt was explicitly rejected by Azure with `HCRP400`:
the host already retained twenty-five Run Command resources. Activity Log
confirmed that exact rejected request, and a fresh read showed the previous
healthy run remained on the guest. This was a provider capacity rejection, not
an ambiguous guest timeout. Its reserved run ID was preserved as rejected and
never replayed; the prior cleared-alert anchor was restored from archived
evidence before reserving a different run.

Price command dispatch now checks retained command capacity. Near the limit,
it retires only a completed owned command whose saved request, saved receipt
and live receipt agree on source, resource ID, successful exit and terminal
nonce. Local proof files remain intact. Commands without complete proof,
pending commands and foreign commands are not deleted. Deletion is separately
verified with a bounded wait; failure blocks new dispatch. This uses the
documented [Arc Run Command lifecycle](https://learn.microsoft.com/en-us/azure/azure-arc/servers/run-command),
not a new guest transport.

The distinct repeat fault was injected at 14:29:33 UTC. Its automatically
created SRE thread initially interpreted the previous run's healthy evidence
as current recovery. No wrong-run repair was executed. An operator follow-up
required a new private query, which confirmed the current stopped pool and
yielded the correct run-specific recommendation at 14:39:14 UTC. The operator
ran that exact command once; guest recovery at 14:40:52 UTC was verified by
fresh private telemetry and an independent SRE recovery note at 14:43:52 UTC.
The recovery verifier completed its guest-to-private readback without replay.
Monitor cleared automatically at 14:52:00 UTC: approximately twenty-two
minutes twenty-seven seconds after injection, versus eleven minutes twenty
seconds to guest repair. The SRE incident record still remained `new`.
The rejected attempt, reservation reconciliation and stale-run correction
do not count as an uninterrupted customer acceptance cycle.

The recommendation instructions now require the exact nested alert's
`properties.essentials.startDateTime`, current UTC freshness within three
minutes, and current-run evidence observed at or after that activation.
Historical healthy events and agent memory cannot establish this incident's
recovery or supply its command's run ID. Missing current evidence permits
bounded read-only retries, then an explicit unknown result. These instruction
guards have offline contract coverage; a fresh live run using them is still
required, and prompt instructions are not an execution security boundary.
The existing controller's exact-run checks remain the repair boundary.

Demo14 was removed after both Monitor alerts had cleared. Repeated `Down`
was idempotent; independent subscription reads found no owned pricing resource
group, Arc/alert/bootstrap grants, or group-scoped grants. The retained
foundation was not deleted.
Host regression checks also exercise the actual
recovery-operation wiring and JSON timestamp deserialization, not just its
callback helper.

## What the fixture represents

The `price-service` scenario reuses the existing isolated Windows Arc host and
lifecycle safeguards. It adds an owned, loopback-only IIS site and application
pool as a small pricing dependency fixture:

| Request | Synthetic response |
| --- | --- |
| `GET http://127.0.0.1:18081/price/basket-a/` | `{"sku":"basket-a","currency":"EUR","unit_price_cents":199}` |
| `GET http://127.0.0.1:18081/price/basket-b/` | `{"sku":"basket-b","currency":"EUR","unit_price_cents":349}` |
| `GET http://127.0.0.1:18081/price/basket-c/` | `{"sku":"basket-c","currency":"EUR","unit_price_cents":105}` |

These fields and values match `retailtx.contracts.Price` and
`app/retailtx/contracts.py`. The scenario does **not** run the real
`erp-core`, database, checkout API, POS load generator, or transaction path.
Requests are generated on the Windows guest itself; the loopback-only binding
does not prove traffic from an external business client. The fixture therefore
does not establish customer reachability, store impact, lost sales, or recovery
of RetailTx transactions.

The fault stops only the uniquely owned price-service application pool. It does
not stop the default IIS site, the Windows service, or all of IIS. A real local
HTTP GET must fail with HTTP 503 while the separate `http://localhost/health.txt`
baseline remains HTTP 200. The owned pool is configured not to auto-start so a
guest reboot cannot silently substitute for the scheduled recovery watchdog.
At startup the watchdog restores a stopped pool when no bounded fault is
active; it leaves a fault or safety canary stopped until its durable deadline.

## Evidence and guardrails

- The controller and IIS fixture live beneath the already protected
  `C:\ProgramData\RetailTxDisk` owner directory. Installation refuses existing
  price directories at the lifecycle wrapper, event sources, task names, IIS
  sites, or pools instead of adopting or overwriting them. The controller
  accepts only the wrapper's fresh controller-only stage: exactly its source,
  digest, and owner/environment/source-bound staging receipt. Unexpected
  content or an absent receipt fails closed. A failed partial installation
  requires teardown and a fresh environment, not adoption or replay.
- Content ACLs are protected separately on each directory and file: SYSTEM and
  administrators receive full access, while only the owned pool receives
  read/execute access. File grants have no inheritance flags; directories use
  child inheritance without removing file access. Failed probes retain bounded
  HTTP error detail, including IIS substatus and HRESULT when returned.
- Anonymous authentication is configured at the owned site's ApplicationHost
  location only: enabled with an empty username, so requests use its dedicated
  `ApplicationPoolIdentity` (identity type 4). Metadata checks reject IUSR,
  disabled anonymous access, or pool identity drift. No IUSR grant or global
  IIS authentication change is used.
- An owner/environment/endpoint manifest binds the site, app pool, scheduled
  task, state file, event provider, and recovery to the fixture. Every Arc
  invocation checks the installed controller SHA-256 against the locally
  recorded source revision.
- Run IDs are reserved for the fixture lifetime. Fault, safety test, and
  recovery reject an empty or different run ID.
- The `RetailTxPrice-<environment>` Application event source writes actual
  request status, response-contract validation, baseline status, pool state,
  owner, run, deadline, watchdog, and recovery actor. Azure Monitor collects
  these events through a separate Event-only DCR. Price readiness and recovery
  do not query or depend on `Perf`.
- The price alert requires a fresh event from the exact Arc resource, owner,
  environment, endpoint, run, and stopped owned pool, with HTTP 503 while
  baseline IIS remains 200. Monitor clearance is separate from guest recovery.
- A SYSTEM scheduled task checks every minute and at startup. It restores only
  the owned pool after the bounded deadline, and restores a healthy-state pool
  stopped by reboot. An unexpired fault or safety canary remains stopped.
  Recovery requires successful endpoint, response-contract, and independent
  baseline probes. Safety testing proves these paths before arming; a reboot
  variant requires recovery after a new boot.
- The supplied recovery remains operator-run. Azure SRE Agent is configured
  in Review mode with no handoffs; it investigates and proposes the exact
  fixed `Recover` command but does not execute guest actions or switch
  identities. Recovery acceptance additionally queries fresh private Monitor
  evidence for the same owner/run and `operator-script` actor.

## Lifecycle

Run these commands from the repository root in an authorized PowerShell 7
session with the retained foundation already available. Use one environment
name of at most ten lowercase letters/digits, distinct from the foundation.
The host and resource-group names remain disk-derived for compatibility with
the existing owned fixture lifecycle; the saved manifest records
`workloadScenario: price-service`, and every command must select that scenario.

```powershell
$subscription = '<authorized-subscription-guid>'
$environment = 'demo03'
$foundation = 'stage0'
```

Create the isolated Arc fixture, then complete its existing guest transition
and baseline probes. Run `Probe` three times successfully before installation:

```powershell
.\scripts\Invoke-DiskScenario.ps1 Up -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 Probe -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 Probe -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 Probe -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 Install -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 Doctor -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
```

Prove independent recovery before enabling the Monitor rule. The reboot test
uses a five-minute bounded canary:

```powershell
.\scripts\Invoke-DiskScenario.ps1 SafetyTest -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 SafetyTest -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service -RebootDuringSafetyTest
```

Deploy the Event-only DCR and disabled alert, confirm private healthy evidence,
create the owned SRE investigator and Review response plan, then arm:

```powershell
.\scripts\Invoke-DiskScenario.ps1 Monitor -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 Telemetry -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 Connect -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 Arm -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
```

Inject one bounded fault, allow the exact Monitor alert to route to SRE, and
wait for its evidence-backed proposal. The operator runs the supplied command
with the exact `runId` shown in the actual alert evidence:

```powershell
.\scripts\Invoke-DiskScenario.ps1 Fault -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 Incident -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 Recover -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service -RunId '<exact-current-run-guid>'
.\scripts\Invoke-DiskScenario.ps1 Telemetry -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
.\scripts\Invoke-DiskScenario.ps1 Incident -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
```

`Recover` refuses a stale run and waits for actual HTTP 200 plus the exact
`Price` payload, then independently waits for a fresh private Monitor event for
the same run with `recoveryActor: operator-script`. If the watchdog wins the
race, report that safety recovery explicitly; it is not operator or SRE
remediation. Wait for alert resolution before another `Fault`. Do not replay an
uncertain Arc command; inspect its recorded request/result and use only a
supported reconciliation operation.

After the incident, remove the owned SRE configuration, workspace grants, and
fixture. Teardown deletes the isolated resource group; it does not delete the
retained foundation:

```powershell
.\scripts\Invoke-DiskScenario.ps1 Down -SubscriptionId $subscription -EnvironmentName $environment -FoundationEnvironment $foundation -Scenario price-service
```

## Acceptance boundary

Offline checks exercise watchdog transitions for healthy reboot, unexpired
fault, and expired fault; exact IIS binding and drift rejection; price fault
dispatch; run/owner/phase/endpoint and freshness validation; controller-digest
rejection; the seeded response contract; recovery actor; and exact-run private
telemetry verification. Live installation and healthy local endpoint checks
passed on demo14, with accepted safety-canary HTTP failure and independent
watchdog recovery. Real incident injection, private DCR ingestion, automatic
alert/SRE investigation, exact-run recommendation and operator-script repair
and independent SRE recovery diagnosis plus automatic Monitor clearance have
been observed once. Owned teardown, repeatability and human rehearsal remain
open. The full customer-demo lifecycle
is not accepted.

The persisted JSON watchdog state is also tested on actual Windows PowerShell
5.1, including healthy reboot, active-fault preservation, expired recovery,
state-property persistence, and execution of the actual Watchdog operation
dispatch AST with mocked dependencies:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests\Test-PriceWatchdog51.ps1
```

## References

- Microsoft Learn, [New-WebAppPool](https://learn.microsoft.com/powershell/module/webadministration/new-webapppool?view=windowsserver2025-ps) and [New-Website](https://learn.microsoft.com/powershell/module/webadministration/new-website?view=windowsserver2025-ps).
- Microsoft Learn, [Default Document Files](https://learn.microsoft.com/iis/configuration/system.webserver/defaultdocument/files/) and [MIME Map](https://learn.microsoft.com/iis/configuration/system.webserver/staticcontent/mimemap/).
- Microsoft Learn, [Stop-WebAppPool](https://learn.microsoft.com/powershell/module/webadministration/stop-webapppool?view=windowsserver2025-ps) and [Start-WebAppPool](https://learn.microsoft.com/powershell/module/webadministration/start-webapppool?view=windowsserver2025-ps).
- Microsoft Learn, [Anonymous Authentication](https://learn.microsoft.com/iis/configuration/system.webserver/security/authentication/anonymousauthentication/) and [Application Pool Process Model](https://learn.microsoft.com/iis/configuration/system.applicationhost/applicationpools/add/processmodel/).
