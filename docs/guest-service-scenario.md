# Native Azure VM guest-service feasibility

**Scope:** a stopped application service inside a running native Azure VM,
not VM start and not the Arc-managed host. Service Bus work remains parked.
This first gate proves a small guest fixture and the Azure VM Agent command
transport before adding an autonomous response plan.

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
