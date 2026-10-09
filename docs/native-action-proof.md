# Native SRE action with hybrid evidence

This is a small integration proof, not the completed retail demonstration.
It removes unreliable Arc guest commands from remediation: SRE reads the
retained Arc host's status and private Monitor heartbeat, presents a native
Azure VM-start approval, and starts one deliberately stopped Azure fixture.

The fixture is isolated: one VM, NIC, disk, NSG and VNet; no public IP, peering,
application, Service Bus or database. It has no application network dependency
on the Arc host. Therefore this proves **native Azure recovery with hybrid
visibility**, not transaction recovery, on-premises healing or business impact.
The operator supplies the fault context and permitted action; this is not a
blind root-cause discovery or alert-triggered response-plan test.

## Permission and approval boundaries

The retained SRE Agent configuration stays in `Review`, with the same configured
user-assigned action identity. Deployment adds Reader on the new fixture group
and a custom role containing only
`Microsoft.Compute/virtualMachines/start/action`, assigned at the exact VM.
It does not grant Contributor, guest execution, restart, delete or permission
management. The VM's policy-required system identity receives no workload grants.

The SRE native CLI card must be pending before the decision. The harness checks
both its displayed command and its original `RunAzCliWriteCommands` invocation,
rejecting extra arguments, another operation/target, delegated-user scopes,
expired or already-running cards, and cards from a previous fault. It approves
only that card, with `ApproveScope = none`, never a session or future operations.
These checks supplement RBAC; they are not an agent-wide tool policy.

**Review was exercised on the native action path only.** The private telemetry
query uses the SRE workspace terminal. This proof does not establish that Review
gates every terminal or external-tool write. Prompt instructions are not a
security boundary. Do not describe the agent as universally approval-enforced;
that stronger claim needs a separately verified product/tool policy.

Programmatic decisions are explicitly labeled **automated test authorization**.
The API attributes them to the authenticated operator; that is not evidence of
a person clicking Approve. Azure Activity Log must independently identify the
configured SRE action identity as the caller of the successful VM start.

## Run and recover

Prerequisites: the retained foundation manifest and working SRE/Arc/Monitor
environment, Azure CLI authentication in the authorized tenant, PowerShell 7.2+,
Bicep/AVM access, `ssh-keygen`, and permission to deploy the group, assign roles
and create/remove a custom role. The existing `stage0` name is retained for
compatibility, not used for new resource naming. Generated state, raw thread
evidence and approval attribution stay in ignored `.azure` files.

```powershell
$subscription = '<subscription-guid>'
.\scripts\Invoke-NativeAction.ps1 Up -SubscriptionId $subscription -EnvironmentName demo02
.\scripts\Invoke-NativeAction.ps1 Status -SubscriptionId $subscription -EnvironmentName demo02
```

`Up` is repeatable and ownership-checked before reapplying infrastructure. It
generates an ephemeral SSH key, keeps only its public half, deletes both
temporary key files, disables password login and requests SSH shutdown. The
actual network boundary is the deny-all NSG and absence of public connectivity;
SSH shutdown is not claimed as a guest-verified acceptance check.
Recreating a confirmed deleted fixture renews its four-hour expiry reminder and
clears prior fault results. Reapplying a live fixture does not extend retention.

After an overnight pause, confirm the evaluation host is powered on as well as
checking Arc `Connected` and a fresh private heartbeat. On 2026-10-08, Activity
Log showed an overnight deallocation of the retained backing VM by a different
principal, not the SRE action identity. An ownership-checked operator start
restored Arc connectivity. The initiating automation/policy was not established
or changed. This was preparation, not part of the measured SRE remediation.

For a supervised interactive attempt, keep the fault command running in one
terminal, then create the SRE thread in another:

```powershell
.\scripts\Invoke-NativeAction.ps1 Fault -SubscriptionId $subscription `
    -EnvironmentName demo02 -FaultDurationSeconds 600

# In another terminal, after Fault reports that the owned VM is stopped:
.\scripts\Invoke-SreProof.ps1 Propose -SubscriptionId $subscription -EnvironmentName demo02
.\scripts\Invoke-SreProof.ps1 Read -SubscriptionId $subscription `
    -EnvironmentName demo02 -ThreadId '<returned-thread-guid>'
```

Open the created thread in SRE Agent for a real human decision. For explicitly
automated integration testing only:

```powershell
.\scripts\Invoke-SreProof.ps1 Approve -SubscriptionId $subscription `
    -ThreadId '<returned-thread-guid>' -AutomatedApproval

# Once the native action is complete and the thread is idle:
.\scripts\Invoke-SreProof.ps1 Verify -SubscriptionId $subscription `
    -ThreadId '<returned-thread-guid>'

# Reject an exact pending native proposal instead:
.\scripts\Invoke-SreProof.ps1 Deny -SubscriptionId $subscription `
    -ThreadId '<returned-thread-guid>'

# Repeat three supervised faults with programmatic, exact-command approval:
.\tests\Test-SreProof.Live.ps1 -SubscriptionId $subscription `
    -EnvironmentName demo02 -Cycles 3 -AutomatedApproval
```

The test stops at the first failure and does not kill its recovery job.
It saves per-attempt thread IDs, timestamps, durations and recovery attribution.
Inspect saved hybrid evidence and Azure audit identity separately; native card
completion alone is not the whole acceptance gate.
`Verify` explicitly asks the same agent for read-only recovery evidence and an
incident note. Automatic continuation after a completed card was inconsistent
in development; do not assume the card's completion guarantees an agent RCA.

### Independent recovery and teardown

`Fault` schedules operator recovery after 60-600 seconds. Its separate process
checks for a running VM; if SRE has not recovered it, it revalidates ownership,
attempts an idempotent start and explicitly records `operatorRecovery = true`.
Failure to read power state also attempts recovery after ownership validation.
Fault/Reset CLI calls have 90-second process deadlines. This bounds individual
calls, not the Azure server-side operation or the entire recovery duration.
Recovery can extend beyond the scheduled fault interval and can fail if Azure
is unavailable; it must never be counted as SRE success.
An unconfirmed stop outcome stays `recovery-required`, even if a subsequent
snapshot reports running: stopping the CLI does not cancel an Azure operation.
The guard attempts an idempotent start but requires Down/redeployment before
another proof rather than publishing false readiness.

This is a **supervised local guard, not durable cloud-side expiry**. Keep the
guard process/session alive. It holds a mutation lock until its `finally` block
finishes. An interrupted/hung guard must release that lock before Reset/Down:
inspect the specific owning PowerShell process, stop only that verified PID if
necessary, then use the independent recovery command. Do not delete a live lock
or assume killing a CLI client cancels an Azure operation.

```powershell
.\scripts\Invoke-NativeAction.ps1 Reset -SubscriptionId $subscription -EnvironmentName demo02
.\scripts\Invoke-NativeAction.ps1 Down -SubscriptionId $subscription -EnvironmentName demo02
.\scripts\Invoke-NativeAction.ps1 Down -SubscriptionId $subscription -EnvironmentName demo02
```

Down validates all custom-role assignments before any deletion, removes the
VM-start grants and scope-external custom role, then destroys the owned group.
It does not require a healthy SRE Agent and never deletes the retained foundation.
The expiry tag is a reminder, not scheduled cleanup. Foundation resources remain
billable. SRE thread records and ARM deployment history are retained as proof
evidence, not claimed as erased agent memory.

## Observed evidence

On 2026-10-07, initial Up and repeat Up succeeded. Effective target permissions
were group Reader plus the VM-scoped start-only custom role. A pending native
start proposal was canceled; Azure Activity Log contained no start for that
denial window. The first stopped-VM attempt completed native execution in about
15 seconds, and the independent guard observed recovery after about 218 seconds
from fault initiation without intervening. Activity Log confirmed the configured
SRE user-assigned identity, not the operator, executed the successful start.

That first attempt exposed a harness timezone-formatting bug: an ISO timestamp
deserialized to local time was interpolated without its offset. Future prompts
explicitly render UTC and specify the correct VM instance-view property and
case-insensitive exact-resource heartbeat query. The development attempt is not
counted as a clean customer rehearsal.

A second development attempt completed the native start and recovered in about
171 seconds without operator intervention. The repeat-test observer incorrectly
counted completed read-only CLI cards as starts; that filtering is now corrected.
The observer was stopped only after recovery was confirmed. A separate
background CLI startup issue was corrected by explicitly closing redirected
stdin. Regression coverage also addresses foreign-resource adoption, bounded CLI
execution, uncertain-stop recovery and approval checks after confirmation.

### Corrected repeatability gate, 2026-10-08

The overnight fixture deletion converged; the group and custom role were absent,
and repeat Down succeeded before recreation. Fresh Up took 181 seconds and
repeat Up took 153 seconds. A separate 60-second fault exercised the independent
operator recovery, followed by an explicit Reset. Neither is counted as SRE
recovery.

The corrected live harness then completed **three consecutive automated runs
without operator recovery or between-run repairs**, using the same code release:

| Run | Fault start (UTC) | Guard-observed recovery | Full flow, including incident note | Successful SRE start (UTC) |
| --- | --- | --- | --- | --- |
| 1 | 09:02:59 | 198 s | 269 s | 09:05:48 |
| 2 | 09:07:51 | 147 s | 200 s | 09:09:38 |
| 3 | 09:11:33 | 174 s | 291 s | 09:14:02 |

Each run presented the native card, used exact-command automated authorization,
and ended with a separately observed running VM and an explicit read-only
verification/incident-note exchange. The saved private queries returned the
exact Arc resource's heartbeat within 15 minutes; final query timestamps were
09:04:15, 09:07:15 and 09:15:17 UTC respectively. Independent Azure Activity Log
attributed all three successful starts to the configured SRE action identity.
Missing stop/start audit evidence in an agent note was left explicit; later
operator audit checks are separate evidence, not retroactive agent findings.

Raw evidence remains in ignored `.azure`: rehearsal
`sre-rehearsal-20261008T090240351Z.json`, its three saved thread files,
`native-three-clean-activity.json`, and `native-three-clean-source.json`.
Preparation/deployment and eventual audit availability are not included in the
incident durations.

A separate run exercised the committed Deny command: the native start card was
cancelled at 09:19:53 UTC without starting execution. The VM stayed stopped until
the independent five-minute fault timeout. The guard then restored it and
recorded `operatorRecovery = true`, with confirmed recovery at 09:23:05 UTC.
This demonstrates rejection plus operator safety recovery, not SRE healing.
Independent Activity Log contained only the operator's start after timeout,
and no SRE start in the denial window. Evidence is retained in
`native-current-denial.json`, its saved thread and
`native-current-denial-activity.json`.

Final Down completed in 228 seconds; repeat Down and Status confirmed that the
group and custom role were absent. Independent subscription inventory found
zero owner-tagged live resources or remaining fixture/custom-role grants.
No local recovery guard remains active. The original foundation remains
retained/billable, with Arc still Connected. Cleanup evidence is recorded in
`native-final-cleanup.json` and `native-final-inventory.json`; retained SRE
threads and deployment history are not claimed as erased.

**Assessment:** the smaller native action is a repeatable integration baseline
worth building on, not yet a customer-ready hybrid incident. Three automated
runs on one fixture are not three fresh customer deployments or human rehearsals.
Keep unreliable Arc guest commands off a customer presentation's critical path.
The subsequent user-directed milestone is the
[operator-first disk incident](disk-scenario.md), with automatic guest execution
deferred; this native proof remains a fallback. Do not resume the full deferred
topology solely because this VM-start gate passed.

The subscription's existing Guest Configuration policy attempted an extension
on this deliberately extension-disabled fixture and received HTTP 409. No policy
exemption or policy change was made. That failed policy action is not the cause
of the deliberate VM stop, and this isolated fixture is not evidence of an
accepted production policy posture.

Wrong-target/operation rejection is covered by harness regressions and the live
effective RBAC boundary, not a destructive test against another host.
Human approval, a real hybrid application dependency, business recovery,
alert-triggered initiation, a no-terminal presentation and fresh deployment
repeatability remain separate gates.

## API compatibility and references

Thread operations follow the official Azure MCP implementation. The native CLI
cards use `azCliExecution`, which its simplified thread model did not expose
during this test. The deployed SRE UI's own client revealed:

- `GET /api/v1/azCliExecution/{threadId}/{executionId}/status`
- `POST /api/v1/azCliExecution/{threadId}/{executionId}/action`, with `action`
  `run` or `cancel` and `ApproveScope = none`.

These are observed product UI APIs, **not a published stable SDK contract**.
The harness validates the live HTTPS agent endpoint and payload, disables
redirects when sending authentication, keeps tokens in memory and fails closed
on incompatible shapes. The customer presentation should use the product UI,
not depend on this integration-test approval client.

Azure Activity Log can lag live execution. Microsoft documents 3-20 minutes
for activity-log availability for analysis/alerting; measure audit convergence
separately and do not manufacture a missing stop/change event.

- [SRE Agent execute mitigations](https://learn.microsoft.com/azure/sre-agent/execute-mitigations)
- [SRE Agent run modes](https://learn.microsoft.com/azure/sre-agent/run-modes)
- [Audit SRE Agent actions](https://learn.microsoft.com/azure/sre-agent/audit-agent-actions)
- [Azure custom roles](https://learn.microsoft.com/azure/role-based-access-control/custom-roles)
- [Azure Monitor ingestion time](https://learn.microsoft.com/azure/azure-monitor/logs/data-ingestion-time)
- [Azure MCP SRE thread implementation](https://github.com/microsoft/mcp/blob/64a5c8bf2cab646957661fba4aa33165ac0fc3cb/tools/Azure.Mcp.Tools.SreAgent/src/Services/SreAgentService.cs)
