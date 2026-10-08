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

The next milestone is an [operator-first Windows Arc disk incident](docs/disk-scenario.md):
real fault, alert, SRE investigation, supplied operator recovery script, and
evidence-backed resolution. Private Windows telemetry, independent cleanup
(including across reboot), and Review-mode alert routing setup worked.
Command-result timing remains inconsistent, and the complete incident is not
yet verified. The OS disk is never filled. Automatic SRE-to-Arc remediation
is deferred.

## Recommended direction

- Prove the operator-first disk scenario before attempting automatic guest
  remediation. Keep the proven native Azure action as a fallback; do not present
  intermittent Arc command delivery as a customer-ready path.
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
