# Private Azure application deployment

This profile deploys the retail application independently of the retained
[integration proof](deployment-stage0.md). It is the Azure application delivery
stage, not a verified SRE remediation integration. No existing proof resources,
ownership records, policies, or tenant application registrations are changed.

**Validation status: incomplete; not customer-demo-ready.** Private application
readiness and two operator-driven backlog/recovery runs succeeded, but the final
trace gate failed. Its code fixes could not be deployed because Arc guest commands
stalled, including after one bounded backing VM restart. No end-to-end `Verify`
success or approved SRE action is claimed. See the evidence and reliability
assessment below before using this profile.

## Operator commands

Use PowerShell 7.2+, Azure CLI, Python 3.11+, and an authenticated operator in the
explicit target subscription. The operator needs deployment and role-assignment
permissions on the owned groups. The first profile is restricted to Sweden
Central; provider registration and compute quota must already be available.

```powershell
$subscriptionId = '<subscription-guid>'
$environmentName = 'demo01'
.\scripts\Invoke-Azure.ps1 Preflight -SubscriptionId $subscriptionId -EnvironmentName $environmentName
.\scripts\Invoke-Azure.ps1 Up -SubscriptionId $subscriptionId -EnvironmentName $environmentName
.\scripts\Invoke-Azure.ps1 Doctor -SubscriptionId $subscriptionId -EnvironmentName $environmentName
.\scripts\Invoke-Azure.ps1 Verify -SubscriptionId $subscriptionId -EnvironmentName $environmentName
.\scripts\Invoke-Azure.ps1 Scenario -SubscriptionId $subscriptionId -EnvironmentName $environmentName -DurationSeconds 120
.\scripts\Invoke-Azure.ps1 Reset -SubscriptionId $subscriptionId -EnvironmentName $environmentName
.\scripts\Invoke-Azure.ps1 Down -SubscriptionId $subscriptionId -EnvironmentName $environmentName -WhatIf
.\scripts\Invoke-Azure.ps1 Down -SubscriptionId $subscriptionId -EnvironmentName $environmentName
```

`Up` uses subscription-scoped Bicep what-if/create rather than the root `azd`
configuration, which remains the unchanged integration proof. It performs a
foundation pass, renders small public-identifier-only cloud-init scripts, creates
hosts, discovers the exact owned Arc identity, applies runtime permissions,
installs the release, removes setup privileges, and checks real readiness.
Alert creation is deferred until recent authenticated reconciliation telemetry
has populated `AppTraces`; activation must then pass the service's query
validation. Existing rules left by an interrupted attempt are not activation
evidence. Readiness is checked again after activation rather than returning the
pre-deployment observation. Reapplication is not a zero-downtime upgrade promise.
Original customData is preserved on reapplication. Application releases use
guest operations rather than attempting to rerun cloud-init.
Package installation waits up to 600 seconds for the dpkg lock rather than
removing lock files or racing VM extensions. If the cloud host's initial
application bootstrap failed, `Up` waits for cloud-init to finish and reapplies
the current public bootstrap through the owned guest channel. It retains the
initial cloud-init exit code and repair evidence without rewriting customData
or clearing historical cloud-init errors.

The ignored `.azure/<environment>/application-state.json` binds ownership to
subscription, tenant, environment, location, three exact group names, and an
ownership GUID. Keep it for recovery and teardown. Operations are serialized by
an exclusive local file lock; do not copy the state and operate the same
environment from multiple machines simultaneously. A matching name or tag alone
does not authorize adoption. Do not rename the old proof manifest or use it here.

`Status` is inventory, not readiness. `Doctor` checks private endpoints, the
authenticated applications, worker freshness, blocked outbox rows, reconciliation,
actual application/Arc telemetry, and the real queue's dead-letter count.
Missing telemetry fails readiness after a bounded warm-up wait. `Verify` adds a
real stopped-poster incident, exact country totals, actual alert evidence, and
recovery. Operator guest commands are not approval-gated SRE actions.
The generator runs on the DC host, so verification includes DC-to-CAP checkout
traffic. It also requires cloud/Arc business events and all nine expected
parent-child trace links for each of the 12 unique transactions, including the
pinned FastAPI version's `fastapi.endpoint` span between the HTTP server span and
the application checkout span. Transaction UUID properties are plain strings,
not JSON-quoted strings.

`Scenario` creates the existing bounded cooperative posting pause; expiry is
observed by the live worker. `Verify` separately stops the actual service and
arms an independent systemd recovery timer. `Reset` undoes the marker, starts the
poster, and requires reconciliation recovery. It does not delete accepted sales,
purge poison messages, or claim that unposted sales are lost revenue.
Before injecting a new incident, `Verify` separately waits up to 20 minutes for
any previous stateful backlog alert to resolve. That settling time is not part
of the bounded fault window; a timeout fails before stopping the poster.

## Topology and identity

| Boundary | Implementation |
| --- | --- |
| Cloud group | Cloud VM with CAP API, publisher and reconciliation; private PostgreSQL Flexible Server, Service Bus Premium and artifact storage |
| Simulated DC group | VM with ERP API, local PostgreSQL and poster; Arc manages guest operations after Azure IMDS blocking and guest-agent disablement |
| Operations group | Private Log Analytics, Application Insights, AMPLS, DCE/DCR, workbook and static alerts |
| Networks | Two peered VNets, `10.86.0.0/16` and `10.87.0.0/16`; no VM public IP or SSH ingress |
| API transport | Private HTTPS on 8443 with required client certificates, environment-specific CA and hostname verification |
| Cloud database | Entra-only authentication, TLS hostname verification, fresh managed-identity token for each new connection |
| ERP database | Local UNIX socket and PostgreSQL peer authentication; no network database password |
| Broker | Cloud system identity sends; Arc system identity receives; queue-scoped grants, no shared key or SAS |
| Telemetry | Azure Monitor exporters authenticate with the corresponding VM/Arc system identity; local ingestion authentication is disabled |

Peering is not a VPN. The DC is an Azure-hosted evaluation simulation, not a
production on-premises host. Public outbound NAT and required Azure control-plane
access remain; private data access is not an assertion of zero internet egress.

The public PostgreSQL certificate bundle and the private application CA are
separate. Application certificates have both server and client authentication
EKUs and are valid for 30 days. Private keys are generated on the cloud host, not
embedded in ARM, Git, or local ownership state. The temporary provisioning
container carries the DC certificate material over private, Entra-authenticated
storage access; setup cleanup removes those blobs and permissions. Cloud root
retains the environment CA for repeatable installation. This is a disposable
environment trust boundary, not a production PKI/rotation service.

The temporary cloud database-administrator UAMI is used only by provisioning.
Migrations are checksummed and serialized; `retailtx-cap` is mapped to the cloud
system identity with DML/sequence privileges, not schema ownership or admin.
Objects and DML grants belong to the stable `azure_pg_admin` role, not the
temporary Entra login. Before migration, existing objects are reassigned and
remaining temporary-login grants removed in both databases. This permits Azure
to remove the temporary administrator without dropping application data.
The runtime SDK deliberately rejects UAMI overrides and operator credential
fallback. Arc services run in the `himds` group and use the documented local
identity endpoint after Azure IMDS is blocked.
The backing DC VM also retains the system identity required by the enforced
Guest Configuration policy. It has no direct subscription role assignments and
is not the application's Arc identity. Cleanup removes all temporary UAMIs,
not this policy-required backing identity; readiness verifies IMDS blocking
and the inactive Azure guest agent.

The template flag disabling setup resources is **not deletion**. Lifecycle
cleanup explicitly detaches temporary identities, removes bootstrap database
administrator/grants/identities, and checks final identity attachments. The
[Bicep interface](../infra/azure-interface.md) documents all cleanup IDs.
Runtime units remain disabled and require a root-controlled startup marker
until cleanup succeeds. Upgrade/retry removes that marker and disables/stops
existing units before reintroducing setup permissions, including recovery from
an interrupted cleanup. The manifest records cleanup as pending before any
bootstrap-enabled deployment, so rolling source back after a failed upgrade
cannot bypass cleanup. A guest reboot does not bypass this startup gate.

## Release delivery

`scripts/azure/package_release.py` packages an explicit allow-list of source,
SQL migrations, pinned requirements, simulator, fault and installer files. It
normalizes archive timestamps, bounds size, excludes local environment files,
and computes a SHA-256 release identity. Dependency downloads require the lock's
hashes; application installation does not follow a moving Git branch.

Because the operator workstation has no assumed private route, an
Entra-authorized ARM guest command transfers the bounded **non-secret** source
archive to the cloud VM. Its temporary container-scoped identity permission
publishes it to private blob storage. The Arc host downloads it using its own
identity and verifies the digest and safe archive paths before installation.
No SAS, storage-account keys, private GitHub tokens, public artifact container,
or inbound management port is introduced.
Evidence is compact JSON bounded below the managed Run Command 4 KB output
limit; oversized results fail instead of being treated as complete evidence.
Successful guest-command resources are deleted after their output is captured,
avoiding Azure's per-host managed-command limit. Failed or interrupted commands
are retained for diagnosis; their exact ID is recorded in the ownership manifest.
Never delete a command that is still executing: deletion terminates its script.

Source releases and operator command payloads may remain in Azure deployment
history. Do not add secrets to any packaged file. Runtime processes run as
`retailtx` with systemd filesystem restrictions; the privileged installer and
certificate authority remain root-owned. Release and bootstrap configuration
are immutable per installation digest; retained releases are removed with the
owned environment.

## Telemetry and incident evidence

Existing HTTP and broker trace context propagation is preserved. Structured
`AppTraces.Properties` includes `event` and `environment_id`:

- `reconciliation.observed`: current observation time, accepted/posted/unposted
  count, exact unposted cents, and bounded country/brand data.
- `reconciliation.country`: per-country current count/cents and the same
  `observed_at` snapshot identifier.
- `reconciliation.freshness`: `fresh`, `stale`, or `unknown`. Unavailable
  reconciliation does not emit a fabricated current zero.
- Checkout, posting, retries, and fault/recovery events preserve trace IDs;
  transaction IDs are not metric dimensions.

The workbook and backlog alert select the latest matching fresh observation,
not a sum of successive backlog snapshots. A separate staleness alert handles
missing/unavailable evidence. Backlog evaluation uses a one-minute interval;
staleness uses five minutes. Ingestion and notification latency must still be
measured. Native queue depth is
queue-wide, not per country. There are no external notification destinations or
remediation actions yet.

The queue's dead-letter count is checked by the authorized lifecycle operator
through ARM. The cloud sender identity is not granted receive permissions just
to perform an operational check. Portal workbook viewing still requires both
workspace RBAC and a private network path; merely opening the portal does not
bypass private query restrictions.

## Teardown and limits

`Down` verifies all ownership records and refuses resource locks. It attempts
guest quiescence, removes the exact recorded DCR/DCE associations from the owned
cloud VM and Arc machine, deletes only the three owned groups, verifies their absence,
and searches for owner-tagged live residuals. If a guest is unreachable, exact
owned VM destruction remains the independent cleanup path and the failed
quiesce is reported. No protected/shared resource or policy exemption is removed.
Cross-group Monitor associations must be removed before the operations group:
otherwise Azure refuses to delete the still-associated rule and endpoint.
Cleanup validates both association names and target IDs and refuses changed
targets rather than deleting an unrelated monitoring configuration.

The old integration proof is intentionally outside this deletion set. Local
manifests, subscription deployment records, and service soft-delete/backup
retention are not purged. Zero owned live resources does not guarantee that all
retained data has been purged or all subscription charges have stopped.

`expiresAt` is a retention reminder, not an automatic teardown job. No budgets,
CI/OIDC deployment, customer UI, external TTL scheduler, SRE guest permissions,
or SRE response plan are implemented by this profile. The native Azure VM Guest
Configuration policy can conflict with the intentional Arc evaluation pattern;
no policy bypass or exemption is silently added.

## Evidence

Offline checks cover application identity/TLS selection, token refresh, telemetry
contracts, local-mode compatibility, ownership rejection and source-archive
safety. Those checks do not establish actual Azure availability, identity
propagation, private DNS, telemetry ingestion, alert firing, or teardown.

### Observed live results, 2026-10-07

The previously installed source release was
`bd6c080c9dfa877b43cddca5a6bec55eba54f79238fbe87df23f8be3784ab31f`.
The corrected candidate is
`25058f47267d83333429b0d825c3d8bbbcf46021f83d27f5511d5735ab168b03`;
it passed offline checks but was **not installed or verified in Azure**.

| Gate | Observed result |
| --- | --- |
| Private data access | Approved private endpoints and private DNS; Service Bus and storage shared keys disabled; PostgreSQL password authentication disabled; public data access disabled |
| Application identities | Real cloud system-identity database/broker access and Arc system-identity broker/telemetry access worked after DC IMDS blocking |
| API and host posture | Private mTLS requests succeeded and missing client certificates were rejected; SSH inactive, DC guest agent inactive, no native DC VM extensions |
| Setup privilege retirement | Temporary database administrator, UAMIs and their grants removed; runtime database role remained non-admin; policy-required DC backing identity retained without direct subscription grants |
| Backlog and duplicate handling | Each of two runs submitted 12 unique checkouts twice. Each added exactly 12 accepted sales, with 12 unposted and 4,848 unposted cents while the real poster was stopped |
| Country totals | NL 1,494; BE 2,409; DE 630; FR 315 cents. These are unposted sales, not proven lost revenue |
| Alert and recovery | Actual Azure backlog alert fired; poster restart restored zero unposted sales. The first run exposed a locale-dependent alert timestamp comparison, subsequently fixed; the second passed alert, recovery and queue checks before failing at traces |
| Trace gate | Failed. UUID event properties were JSON-quoted, and the expected direct HTTP-server-to-checkout edge omitted the pinned FastAPI endpoint span. Both defects are fixed in source, with regressions, but live acceptance remains outstanding |
| Infrastructure convergence | Reapplication retained the same 76 stable resource IDs, excluding transient Run Commands. This does not establish a fully successful repeat `Up` lifecycle |
| Teardown | Actual `Down` removed all three owned groups despite failed Arc guest quiescence. Repeated `Down` succeeded, and an independent owner-tag inventory found zero owned live residuals |
| Offline candidate checks | 106 Python tests passed, 18 integration tests deselected; changed-scope Ruff and strict mypy passed; 37 PowerShell checks passed, including the later teardown association fix; dependency consistency passed |

The current session could not rerun the real-container suite because Docker was
unavailable. The separately merged local acceptance evidence remains in the
local guide. One upstream Starlette/httpx deprecation warning remains.

The first teardown exposed missing cross-group DCR/DCE association cleanup.
That defect was fixed before retrying; Azure then removed the environment through
the independent control-plane path. The retained foundation's Arc machine and
SRE Agent remain present and intentionally billable. No original proof resource
was included in the deletion set. Ownership, failed-command and convergence
evidence remain local; service retention and subscription deployment history are
not purged.

### Reliability decision

At approximately 19:12 UTC, a subsequent Arc service-maintenance command remained
`Creating` with execution `Unknown`, despite the machine reporting `Connected`.
It produced no execution result within the 30-minute command timeout plus
three-minute client allowance. A separate read-only status probe also timed out.
The exact outstanding commands were preserved locally and explicitly canceled;
their deletion was confirmed before recovery.

One ownership-checked restart of the simulated DC's **Azure backing VM**
succeeded at 19:55 UTC. A fresh read-only Arc probe still timed out afterward.
The underlying cause is not established; a connected agent or a successful
hardware restart is not evidence of working guest commands. The recovery probe
was canceled and further recovery attempts stopped. This was operator
infrastructure recovery, not SRE healing. It does not establish how a real
on-premises host would behave.

The demo goal is an SRE-led hybrid operational flow, not demonstrating the most
complex deployment. The next proof should therefore:

1. Retain real on-premises/Azure dependencies and evidence, but choose a bounded
   Azure-side incident and an independently verified native Azure action.
2. Prove SRE investigation, proposed mitigation, visible approval and denial,
   least-privilege target enforcement, business recovery and an evidence-backed
   RCA before expanding deployment automation.
3. Keep Arc for hybrid identity and observability; defer live guest remediation.
   Do not add another command transport, broaden permissions, or silently replace
   failed automation with presenter terminal commands.
4. Require three consecutive incident/reset rehearsals within the 12-minute
   presentation target, without hidden terminal repairs, before customer use.
   Fresh deployment/teardown repeatability remains a separate release gate.

The subsequent [native-action proof](native-action-proof.md) verified the
built-in Azure CLI path: a pending VM-start card, cancellation without execution,
approved execution by the configured SRE managed identity, and independently
observed recovery. SRE also read the retained Arc host's fresh heartbeat through
private Monitor. The extra permissions are start-only at one disposable VM.
On 2026-10-08, three consecutive automated recoveries and incident notes completed
in 200-291 seconds without operator recovery. Independent Activity Log checks
confirmed the configured SRE identity on every start. These were repeat incidents
on one fixture, not three fresh deployments or customer UI rehearsals.

This changes the recommendation from an unverified native-action candidate to a
working integration path. It does **not** close this application's trace/guest
control gates: the fixture has no retail application or causal dependency on
the Arc host. Decisions were automated authorization, not human rehearsals, and
native Review does not establish approval enforcement across terminal tools.
Use the smaller path to build one genuine hybrid service incident and a product
UI rehearsal; do not resume the larger application deployment merely because a
VM start worked. The stopped-on-prem-poster scenario remains useful correctness
evidence and an explicitly human-run fallback.

## Primary references

- [Azure Arc managed identity](https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication)
- [Azure Identity managed identity credential](https://github.com/Azure/azure-sdk-for-python/blob/main/sdk/identity/azure-identity/azure/identity/_credentials/managed_identity.py)
- [PostgreSQL Entra principal management](https://learn.microsoft.com/azure/postgresql/security/security-manage-entra-users)
- [PostgreSQL role retirement and ownership transfer](https://www.postgresql.org/docs/16/role-removal.html)
- [Azure Monitor Entra authentication](https://learn.microsoft.com/azure/azure-monitor/app/azure-ad-authentication)
- [Azure Monitor private link configuration](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-configure)
- [Managed Run Command output limits](https://learn.microsoft.com/azure/virtual-machines/linux/run-command-managed#get-execution-status-and-results)
- [Azure Arc Run Command preview and execution status](https://learn.microsoft.com/azure/azure-arc/servers/run-command)
- [SRE Agent native Azure mitigations](https://learn.microsoft.com/azure/sre-agent/execute-mitigations)
- [SRE Agent run modes and approval boundaries](https://learn.microsoft.com/azure/sre-agent/run-modes)
- [Remove Monitor data collection associations](https://learn.microsoft.com/azure/azure-monitor/vm/vm-disable-monitoring#remove-dcr-associations)
- [APT bounded dpkg lock handling](https://github.com/Debian/apt/blob/main/apt-pkg/deb/debsystem.cc)
