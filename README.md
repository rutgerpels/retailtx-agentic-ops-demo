# RetailTx

A staged, reusable demo of agent-assisted operations for a hybrid retail
transaction chain: cloud checkout, an on-premises ERP, asynchronous posting,
and business impact measured as unposted sales value.

**Status: private Stage 0 foundation deployed and verified.** Infrastructure and
lifecycle commands support a disposable, Entra-only Arc/Monitor/SRE proof.
See the [deployment guide](docs/deployment-stage0.md) for commands and limitations.
The **local transaction slice** is implemented with FastAPI, two PostgreSQL
databases, the official Service Bus emulator, an outbox, idempotent posting,
reconciliation, traces, and a reversible backlog fault. See the
[local guide](docs/local-development.md) for reproducible commands and recovery
verification.

The **private Azure application profile** adds two peered VMs, an Arc-managed
simulated datacenter, Entra-authenticated managed services, mutual TLS, telemetry,
static alerts, and an owned deploy/verify/reset/destroy lifecycle. **It is not
customer-demo-ready:** live acceptance is blocked by intermittent Arc command
delivery, and the final trace fixes have not been verified in Azure. See the
[Azure application guide](docs/azure-deployment.md) for live acceptance status
and commands. Its operator recovery is not approval-gated SRE healing.

A smaller [native-action proof](docs/native-action-proof.md) has verified an
SRE native VM-start approval and execution, denial without execution, and
private Arc heartbeat evidence. Three consecutive automated runs completed in
200-291 seconds, including incident notes, without operator recovery. It uses
a start-only role on one isolated VM. These were not human rehearsals. This is
hybrid visibility plus Azure recovery, not yet retail/business recovery.

An [operator-first Windows Arc disk incident](docs/disk-scenario.md) has now
worked on two fresh fixtures, including a same-fixture reset and second incident:
`R:` reached 8% free, Azure Monitor alerted, SRE automatically
investigated and proposed the supplied script, and operator recovery restored
99.43% free. SRE verified private telemetry and wrote the incident note; the
monitor condition cleared automatically. The second incident needed one
read-only SRE verification retry after an internal error. Acknowledgment remained
permission-blocked.
IIS stayed healthy and the OS disk was never filled. Earlier Arc command stalls
remain unexplained; repeatability, presentation timing and human rehearsal are
not accepted, so retain the native-action fallback. Automatic SRE-to-Arc
remediation is deferred. The test fixture and its external grants were removed;
the foundation remains intentionally retained and billable.

The [disk demo runsheet](docs/disk-demo-runsheet.md) proposes using the walkthrough
for alert waits and later clearance, without changing safety or claiming a
verified shorter runtime.

## Recommended direction

- Prove repeatability of the operator-first disk scenario before attempting
  automatic guest remediation. Keep the proven native Azure action as a fallback;
  successful incidents do not make intermittent Arc delivery customer-ready.
- Use Azure Monitor for evidence and Azure SRE Agent for investigation and
  approval-gated recovery.
- Make Azure Copilot Observability Agent an optional Azure Monitor investigation
  and alert-correlation experience, not a mandatory step before SRE Agent.
- Automate environment creation, configuration, verification, reset, and teardown
  from the first Azure deployment.
- Start with two VMs and two peered networks in one region. Add VPN, a second
  region, additional hosts, and real on-premises hardware only for scenarios
  that require them.

See the [staged architecture and implementation plan](docs/implementation-plan.md)
for the assessment, technology choices, lifecycle contract, delivery gates, and
current Microsoft documentation. The SRE-led incident and customer-repeatable
release remain later stages; the foundation fixture is not the complete demo.

All scenarios use synthetic data. Azure-hosted "on-premises" machines are an
explicit evaluation simulation, not a production hybrid deployment.
