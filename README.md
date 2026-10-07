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
verification. It does not deploy the application to Azure or establish
approval-gated SRE healing; the Stage 0 approved-action gate remains open.

## Recommended direction

- Build one reliable incident end to end before expanding the topology.
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
current Microsoft documentation. Stages 2 onward remain proposed; the Stage 0
fixture is not the complete retail demo.

All scenarios use synthetic data. Azure-hosted "on-premises" machines are an
explicit evaluation simulation, not a production hybrid deployment.
