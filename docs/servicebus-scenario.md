# Private Service Bus recovery scenario

**Status: implementation slice only; autonomous recovery is blocked.** No Azure
deployment or live fault was run for this change. Price-service is the current
priority; this Service Bus scenario remains secondary. It has a private Premium
Service Bus namespace, one dedicated queue, a queue-scoped Entra probe identity, a
queue-filtered `UserErrors` metric alert, and a durable local outbox/ledger
probe. It demonstrates broker delivery and idempotent posting; it is not the
RetailTx ERP, an end-to-end retail transaction, or evidence of successful SRE
remediation.

## Verified design boundaries

- `infra/servicebus-scenario.bicep` pins the Service Bus AVM module to `0.17.1`
  and the private endpoint module to `0.12.1`. It disables local authentication
  and public network access, provisions Premium capacity, links the existing
  Stage 0 VNet to a private DNS zone, and creates a single
  `recovery-<environment-id>` queue inside its separately tagged namespace.
- The supplied probe principal receives only the built-in Service Bus Data
  Sender and Data Receiver roles at that queue. The SRE Agent gets no queue
  mutation role. The metric alert has no action group and therefore does not
  claim to start an SRE incident.
- An existing `privatelink.servicebus.windows.net` zone is accepted only when
  its exact resource ID and owner tags match this scenario's manifest. A zone
  in the same resource group with a foreign owner token is not considered
  owned.
- `scripts/servicebus/probe.py` uses the probe host's system-assigned managed identity and
  AMQP over WebSockets on port 443. Run it only from a private host that resolves
  the namespace to its private endpoint and has the two queue-scoped data roles.
  It writes a SQLite outbox record before sending, uses one stable message ID,
  and posts into an idempotent local ledger before completing the queue message.
  A send retry reuses that ID. If completion fails ambiguously after the ledger
  commit, the probe does not issue an abandon against a potentially settled
  message; a later redelivery is recorded as a duplicate and cannot create a
  second ledger posting. This is a small durability demonstration, not a
  distributed transaction between SQLite and Service Bus.
- `scripts/Invoke-ServiceBusScenario.ps1 -Operation Doctor` verifies the saved
  manifest and exact resource-group ownership only. It labels this
  `ManifestAndGroupVerified`, reports deployment and queue health as
  `NotChecked`, and always returns `ready: false`; a saved `Ready` status is not
  live health evidence. `Up` provisions only the isolated fixture into its own
  tagged resource group. `Down` deletes only that exact owned group after
  rechecking private DNS ownership, then archives its local manifest. `Up` and
  `Down` hold an exclusive shared lock derived from the exact foundation VNet
  resource ID across DNS ownership checks and provisioning or teardown. The
  lockfile is retained; the lifecycle does not delete lockfiles that another
  process may use. `Arm`, `Fault`, `Incident`, `Recover`, and `Reset` deliberately
  fail closed. No operation changes shared SRE settings or approves a plan.

The SDK calls follow Microsoft's
[ServiceBusClient Python reference](https://learn.microsoft.com/en-us/python/api/azure-servicebus/azure.servicebus.servicebusclient?view=azure-python),
which documents `AmqpOverWebsocket` for port 443. The metric name and dimension
come from Microsoft's
[Service Bus supported metrics](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/supported-metrics/microsoft-servicebus-namespaces-metrics).
The infrastructure pins the existing repository's
[Service Bus AVM module 0.17.1](https://github.com/Azure/bicep-registry-modules/tree/avm/res/service-bus/namespace/0.17.1/avm/res/service-bus/namespace)
and [Private Endpoint AVM module 0.12.1](https://github.com/Azure/bicep-registry-modules/tree/avm/res/network/private-endpoint/0.12.1/avm/res/network/private-endpoint).

## Blocking product gate

The global SRE Agent configuration must remain in Review. Microsoft documents
per-response-plan Autonomous mode, but that alone does not restrict tool
arguments. Tool access policies are not an argument-level allow-list: a broad
write-command allow rule is not safe, and global deny precedence means
`deny *` plus one allow rule is not a working exception. The documented
`PostToolUse` hook runs after a tool call and cannot prevent the mutation.
See Microsoft's [run modes](https://learn.microsoft.com/en-us/azure/sre-agent/run-modes),
[tool access policies](https://learn.microsoft.com/en-us/azure/sre-agent/tool-access-policies),
and [agent hooks](https://learn.microsoft.com/en-us/azure/sre-agent/agent-hooks)
documentation.

Before enabling `Arm`, verify an actual supported *pre-invocation* enforcement
mechanism that rejects every request except setting the exact manifest-bound
queue from `SendDisabled` to `Active`, for the current durable fault-run ID and
before its independent deadline. Also verify an automatic Azure Monitor to SRE
incident trigger, per-plan Autonomous configuration, execution identity, and
recovery evidence. Until those gates are demonstrated against the live product
schema, no SRE queue-write role, invented request payload, manual thread
injection, or operator command may be presented as autonomous recovery.

An Azure RBAC role limited to the queue resource still permits changes to
properties other than `status`; it does not enforce `Active` as the only value.
That is why this implementation assigns no SRE management-plane role and blocks
arming rather than treating resource scope as an action-level guardrail.

## Offline validation

From the repository root:

```powershell
.venv\Scripts\python.exe -m pytest -s -p no:cacheprovider tests\test_servicebus_probe.py -q
pwsh -NoProfile -File tests\Test-ServiceBusScenario.ps1
.venv\Scripts\python.exe -m ruff check scripts\servicebus\probe.py tests\test_servicebus_probe.py
az bicep build --file infra\servicebus-scenario.bicep --stdout
```

These checks do not connect to Azure. The tests exercise durable outbox
retention after a send error, retry with the same stable message ID, duplicate
delivery, redelivery after an ambiguous completion failure, exact single
posting, the mocked Stage 0 `Microsoft.App/agents` identity contract, and the
blocked SRE action gate.

## Probe commands after deployment and identity setup

Provision only after the product gate and probe identity are reviewed:

```powershell
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Up -SubscriptionId <guid> -EnvironmentName demo01 -ProbePrincipalId <private-host-managed-identity-principal-guid>
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Doctor -SubscriptionId <guid> -EnvironmentName demo01
```

The first command needs the retained `.azure\stage0\retailtx-state.json` and the
principal ID of an existing private host's system-assigned managed identity.
The probe itself must run on that host (or another host with the same identity
and private routing); a developer workstation is not a valid sender/receiver.
The command writes a durable ownership manifest before
creating the resource group. If deployment is interrupted, rerun `Up` to
reconcile or use `Down` to remove only the owned group. `Doctor` reports the
unresolved action gate; it does not enable it.

The following commands are for a later, explicitly authorized private
integration test. They do not configure or establish the blocked SRE integration.
Replace placeholders with the Bicep outputs and use the same persistent state
file for each command:

```powershell
python scripts\servicebus\probe.py --state .azure\demo01\servicebus.sqlite seed
python scripts\servicebus\probe.py --state .azure\demo01\servicebus.sqlite send --namespace <private-namespace>.servicebus.windows.net --queue recovery-demo01 --transaction-id <transaction-id>
python scripts\servicebus\probe.py --state .azure\demo01\servicebus.sqlite receive --namespace <private-namespace>.servicebus.windows.net --queue recovery-demo01
python scripts\servicebus\probe.py --state .azure\demo01\servicebus.sqlite verify --transaction-id <transaction-id>
```

An expected send rejection leaves the outbox item pending and exits with status
`3`; the probe never changes queue state. It reports the exception type without
claiming that an arbitrary `ServiceBusError` proves a `SendDisabled` fault.
Before considering a failed send evidence, independently read back the exact
queue status and correlate the alert's `UserErrors` signal. Neither check has
been live-validated by this implementation.
