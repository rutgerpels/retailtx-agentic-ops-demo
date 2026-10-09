# Operator-first disk demo runsheet

**Status: proposed presentation sequence, not a rehearsed twelve-minute demo.**
The verified incidents took approximately 9-11 minutes from fault request to
guest recovery and 28-30 minutes from fault-operation start to final clearance
note. This runsheet reduces idle presentation time and avoidable operator delay;
it does not establish faster Arc delivery, SRE reasoning or telemetry ingestion.

The first attempt to measure this sequence on fresh `demo06` stopped before
injection: private Arc-identity telemetry queries returned an access denial on
initial readiness and one bounded retry despite the recorded grants being
present. The fixture was removed and cleanup verified. No shorter incident was
measured; see the [experiment record](disk-scenario.md#timing-experiment-blocked-before-injection-2026-10-09).

The subsequent [measured `demo07` run](disk-scenario.md#measured-prompt-recovery-incident-2026-10-09)
recovered the guest 9 minutes 17 seconds after fault request, but private counter
convergence delayed SRE's verified recovery/RCA to about 18 minutes. Prompt
operator execution did **not** establish a faster verified live segment.
The full fault-operation-to-final-clearance-note flow remained 28 minutes.
Readiness also required a bounded retry after an access denial. Earlier grant
placement, no-write reconciliation and more precise investigation instructions
are implemented, not a proven fix for ingestion delay or the twelve-minute gate.

Use the [disk lifecycle guide](disk-scenario.md) for installation, ownership,
safety gates and teardown. The scenario is real capacity pressure on a disposable
`R:` volume; IIS remains healthy. It is not a retail outage or autonomous repair.

## Prepare before the session

Deploy a fresh neutral environment, then complete `Probe` three times, `Install`,
`Doctor`, `SafetyTest`, `Monitor`, `Telemetry`, `Connect` and `Arm` using the
lifecycle guide. Do not include provisioning or telemetry warm-up in the live
incident segment, but retain their timings in the acceptance record.

Require the independent canary proof, fresh healthy private telemetry, the exact
enabled alert and Review response plan, and sufficient remaining fixture expiry.
`Fault` rechecks these gates, including at least 25 minutes before expiry. Expiry
tags do not delete resources. Prepare the operator terminal in the repository
root and the SRE incident view; have the native-action recording available.

```powershell
$subscription = '<authorized-subscription-guid>'
$environment = '<prepared-environment>'
```

Do not prefill a recovery run ID from an earlier incident. Do not inject a
practice fault immediately before the presentation: another injection requires
the previous individual alert to have resolved.

## Live sequence

| Step | Operator action and audience view | Required evidence |
| --- | --- | --- |
| Introduce pressure | Run `Fault` once; show the disposable-volume boundary and independent watchdog | Recorded current run ID, actual pressure and deadline; no OS-disk fault |
| Explain the hybrid boundary | While awaiting the real alert, explain Arc guest management, private Monitor ingestion and SRE's read-only scope | Real alert and automatically linked SRE thread; do not manually start investigation |
| Review the proposal | Show SRE's capacity evidence and exact-run recovery proposal; execute promptly once checked | Current owner/run, low free space, fresh watchdog and the supplied fixed command |
| Verify recovery | Show independent private telemetry and ask SRE to verify in the existing thread | Fresh healthy Perf plus same-run Event, recovery actor, IIS 200 and watchdog |
| End the live incident segment | Present SRE's evidence-backed recovery summary and RCA | Say **guest recovery verified; monitor clearance pending** if the alert remains fired |
| Continue the walkthrough | Explain permissions, context and safety while Monitor completes its clearance interval | Later individual alert `Resolved` and SRE's final independent clearance note |

The measured fault-request-to-alert delays were approximately 3-5 minutes, not a
guaranteed arrival window. Explain the architecture during that wait rather than
leaving an idle alert screen open. The earlier proposal-to-recovery gaps were
approximately 2-3 minutes, including operator delay and command delivery;
preparing the terminal does not eliminate Arc execution latency.

```powershell
.\scripts\Invoke-DiskScenario.ps1 Fault -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-DiskScenario.ps1 Incident -SubscriptionId $subscription -EnvironmentName $environment
```

`Incident` is a single read-only snapshot; `awaiting` is not proof that no alert
will arrive. Use its exact linked thread rather than an incident-list guess.
Show SRE's actual proposal before running recovery. Match the proposed GUID to
the current run in verified guest evidence; substitute it below only after that
check. Never execute arbitrary generated cleanup commands.

```powershell
.\scripts\Invoke-DiskScenario.ps1 Recover -SubscriptionId $subscription -EnvironmentName $environment -RunId '<verified-current-run-guid>'
.\scripts\Invoke-DiskScenario.ps1 Telemetry -SubscriptionId $subscription -EnvironmentName $environment
```

After the operator command returns, use this prepared follow-up in the existing
alert-created SRE thread, substituting the verified current run:

> The operator ran the supplied recovery script for run `<verified-current-run-guid>`.
> Independently query the exact Arc host's private Perf and RetailTxDisk events.
> Report observation timestamps, R: free percentage, matching run and owner,
> phase, recovery actor, IIS status and watchdog freshness. Require at least 75%
> free capacity and fresh healthy evidence; report stale or conflicting data
> explicitly. Give a concise recovery summary and RCA when those checks pass.
> The actual alert resource ID from `Incident` is `<verified-nested-alert-id>`.
> Validate it against the exact Arc host, then read that ID using
> `2019-05-05-preview` and only the configured action identity. If still Fired,
> report monitor clearance pending, not resolved. If inaccessible or malformed,
> report the read failure; never fabricate an ID or switch identities.
> Keep the note in this thread. Do not execute recovery, acknowledge, close or
> change permissions.

Once Monitor reports `Resolved`, ask SRE in the same thread to independently
verify that exact alert and fresh private recovery evidence, then record the
final clearance addendum. Alert state `New` and blocked acknowledgment remain
separate from monitor resolution.

## Timing and fallback

The one-minute stateful log alert requires
[ten continuous nonbreaching minutes](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-overview#alerts-and-state)
before automatic resolution, after telemetry convergence. Keep that behavior;
do not force closure, switch to repeated stateless notifications or claim that
faster polling shortens it.

Record setup, fault operation/request, actual pressure, alert, automatic thread,
proposal, recovery, private verification, SRE RCA, automatic clearance and final
note separately. Measure both the live recovery segment and the full lifecycle.
Moving clearance into the walkthrough does not satisfy the existing
twelve-minute end-to-end acceptance gate. Any revised presentation target must
be explicitly agreed; neither target is accepted by this runsheet.

If an Arc mutation times out, treat its outcome as unknown: inspect the same
command and run evidence, never resubmit blindly. If SRE verification errors,
retain that interruption and use at most one read-only retry, as in the prior
proof. If evidence remains stale, delivery stalls or the walkthrough ends before
verification, state the incomplete boundary and switch to the clearly labeled
recording/native-action fallback. The independent watchdog remains the safety
path; watchdog cleanup is not operator or SRE recovery.

## After the session

Retain the actual run evidence and final clearance status. Do not inject again
until the reset guard confirms the previous individual alert resolved.
After outstanding guest command outcomes are established, run owned `Down`,
repeat it and independently verify fixture resources, external grants and SRE
scenario configuration are absent/restored.

```powershell
.\scripts\Invoke-DiskScenario.ps1 Down -SubscriptionId $subscription -EnvironmentName $environment
.\scripts\Invoke-DiskScenario.ps1 Down -SubscriptionId $subscription -EnvironmentName $environment
```

The reusable foundation is intentionally separate and remains billable unless
explicitly destroyed. Historical telemetry and conversation records are not
claimed as erased.
