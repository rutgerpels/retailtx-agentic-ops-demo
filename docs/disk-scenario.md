# Windows Arc disk-capacity scenario

**Status: integration work, not a customer-ready incident.** The next milestone
is deliberately operator-first:

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
| Replacement incident preparation | Fresh private Perf/Event queries, SRE connectivity and the exact-target Review plan passed. An initial Fault call stopped before submission because the latest guest event was older than the three-minute limit; missing freshness is not waived to get a demonstration running |
| Cleanup and recreation | Teardown removed the original fixture, external grants and owned SRE configuration, restored the original shared settings, and succeeded again on repetition. Subsequent failed-provisioning fixtures were also removed before recreation; historical success does not count as readiness for a new owner |
| Complete incident | A fired disk alert, automatic SRE investigation, operator-script recovery and SRE resolution are not yet accepted as verified |

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

## Lifecycle commands

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

These implemented gates do not, by themselves, establish that an alert
automatically started an investigation. The complete incident still needs live
acceptance. The investigator is instructed to propose the supplied operator
command, never execute it, and to distinguish operator, watchdog and
injection-error cleanup actors.

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

## Remaining acceptance gates

- Predictably timed safety observation across reboot; recovery itself was observed.
- A real below-threshold allocation and fired static alert from the corrected source.
- A narrowly scoped, explicitly Review-mode SRE response plan triggered by the
  actual alert, with sufficient private read access and no guest-write grant.
- Operator-script recovery for the observed run, fresh healthy telemetry and
  alert recovery, followed by SRE verification and an incident note.
- Repeated incident/reset runs and fresh deploy/teardown cycles without hidden
  repairs, then human rehearsal. Provisioning and warm-up are measured separately.

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
- [SRE custom-agent v2 API](https://learn.microsoft.com/azure/sre-agent/tutorial-agent-hooks):
  the documented JSON resource shape is used for the investigator; no hook is
  presented as a pre-execution authorization boundary.
- [curl retry behavior](https://curl.se/docs/manpage.html#--retry-all-errors):
  retries use a regular output file, not redirected stdout, so partial bytes
  from a failed attempt are discarded before a new download.
