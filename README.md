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
and commands. Operator recovery is not approval-gated SRE healing; that gate
remains open.

## Recommended direction

- Prove one small SRE-led hybrid incident with Azure-side remediation before
  expanding the topology or deployment automation. Keep Arc guest commands off
  the live-demo critical path until separately proven reliable.
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
