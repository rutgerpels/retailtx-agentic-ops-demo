# RetailTx: staged architecture and implementation plan

**Status:** proposed design; implementation not started.
**Assessment date:** 2026-10-07.
**Scope:** improve the existing project brief and define a reusable demo product,
not deploy Azure resources or implement the application in this change.

## 1. Assessment and recommendation

The checkout contains `.github/copilot-instructions.md`, contributor instructions,
agent and skill definitions, and `.gitignore`. It does not contain the application,
infrastructure, operational documentation, tests, or workflows described in the
brief. No repository issues or pull requests were found during this assessment;
there is no existing Ready queue to sequence.

The strongest part of the design is the connection between a technical incident
and **accepted sales not yet posted to the ERP, expressed in EUR per country**.
Keep that. The weakest part is attempting networking realism, host management,
two overlapping AI experiences, six failure scenarios, and automation together.

Build a reusable, versioned demo with one incident first:

> A posting worker stops. Sales continue to be accepted. Unposted sales increase.
> Azure Monitor alerts. SRE Agent investigates the evidence and proposes a restart.
> An engineer approves. The worker drains the backlog without duplicate postings.
> The agent records the outcome.

The first release does not need two agents to tell this story. It does need
correct transaction state, trustworthy telemetry, constrained actions, and a
repeatable deploy-reset-destroy lifecycle.

### Assumptions

- The first deployments use a dedicated demonstrator-controlled Azure subscription,
  not a customer's production subscription. Customer-tenant deployment is a later,
  separately approved onboarding path.
- Only synthetic stores, brands, transactions, and monetary values are used.
  Committed profiles have generic identifiers, never customer or people names.
- Reliable demonstrations and reproducibility matter more than production HA.
- Recommendations below are proposals for review, not completed capabilities.
  No subscription entitlement, quota, runtime behavior, or deployment duration
  has been tested in this assessment.

## 2. What is the Observability Agent actually for?

The original "analyst versus operator" distinction is useful as a responsibility
model, but inaccurate as a hard product boundary: SRE Agent also investigates,
correlates telemetry, tests hypotheses, and explains impact.

| Capability | Azure Copilot Observability Agent | Azure SRE Agent | RetailTx decision |
| --- | --- | --- | --- |
| Explore logs, metrics, and application evidence | Azure Monitor-native chat and deep investigations | Queries connected telemetry during investigations | Either can explain an incident; do not duplicate the main demo |
| Preserve investigation context | Save investigations as Azure Monitor issues | Incident conversations, knowledge, and follow-up context | Keep one incident owner in the baseline |
| Background triage | Preview autonomous alert correlation and issue creation | Alert-triggered investigation and response plans | Optional comparison when alert noise is the customer problem |
| Change the environment | Autonomous operations do not restart resources or change configuration | Can execute permitted actions with configured approval controls | SRE Agent owns approved remediation |
| Custom operational process | Monitor-scoped instructions for autonomous operations | Runbooks, connectors, custom agents, tasks, and response plans | Start with one SRE Agent and a small knowledge pack |

Microsoft documents on-demand Observability Agent chat and investigation as
requiring no separate agent-resource provisioning. Autonomous operations require
an Observability Agent resource and are preview functionality. Access still
depends on Azure Copilot permissions and supported availability. It is not simply
a switch to enable on a Log Analytics workspace. [S1]

**Recommended narrative:** telemetry foundation -> SRE-led operational loop ->
optional specialists. Observability Agent sits alongside that loop as an
alternative Azure Monitor-native investigation and triage experience.

Include it when demonstrating how a monitoring team explores telemetry or reduces
multiple alerts into issues. Leave it out when the customer wants one incident
handled end to end. Do not promise automatic Observability-to-SRE handoff: that
integration has not been verified here and is not a release dependency.

SRE Agent already documents alert investigation, telemetry queries, hypothesis
testing, and proposing or executing fixes. [S2] Its run modes are not a universal
approval boundary: Review applies to Azure infrastructure writes; other tools
need appropriate policies or hooks. Response plans and scheduled tasks have
their own settings, with documented Autonomous defaults. Explicitly configure
Review for every demo remediation trigger instead of relying on an agent-wide
default. [S3]

## 3. Architecture and technology choices

### Alternatives

| Approach | Strength | Trade-off | Decision |
| --- | --- | --- | --- |
| Thin VM-based hybrid simulation | Matches the host/ERP operations story and existing Python stack | Requires disciplined host bootstrap and packaging | Recommended baseline |
| Container Apps for the cloud half | Useful revisions and managed application hosting | Adds platform and image-delivery concepts; does not remove the ERP VM problem | Reconsider only if cloud application operations become the main story |
| Full two-region VPN estate immediately | Highest network realism | Adds slow provisioning, routing, quota, and cleanup failure modes before the transaction works | Optional later profile |

### Smallest useful Azure topology

Use two peered VNets in one region, with explicit private routes, DNS, restricted
service access, and necessary outbound connectivity. Peering is **not a VPN** and
must be described as a simulation of a boundary, not an encrypted hybrid tunnel.
Private networking also does not replace application authentication or TLS.

| Placement | Components |
| --- | --- |
| One cloud VM | `cap-api`, outbox publisher, and scheduled `recon-job` |
| One simulated-datacenter VM | `erp-core`, its PostgreSQL ledger, `erp-poster`, and `pos-sim`, as separate services |
| Azure managed data services | PostgreSQL Flexible Server for accepted cloud transactions; Service Bus queue `IDOC_POSTING` |
| Operations resource group | Log Analytics, workspace-based Application Insights, workbook, alerts, and later SRE Agent |

The poster remains logically on-premises. Co-location is an explicit first-release
compromise: it is suitable for a stopped-worker scenario, not independent host
failure or capacity claims. Split ERP, poster, and simulator hosts before adding
those scenarios. A second cloud VM and load balancer are needed only for the
redundancy scenario.

Configure the simulated-datacenter host through the documented Arc evaluation
pattern after bootstrap. Azure still owns the backing VM's power/network/disk
lifecycle; Arc owns guest operations. Do not describe the hardware lifecycle as
"managed only through Arc." Never install both Azure-VM and Arc variants of the
monitoring extension on that host. [S4]

### Recommended stack

| Concern | Choice | Reason and boundary |
| --- | --- | --- |
| Azure infrastructure | Bicep; pinned Azure Verified Modules where suitable | Fits the Azure-only baseline without adding a second IaC state system |
| Environment orchestration | Azure Developer CLI (`azd`) with explicit hooks; PowerShell 7 lifecycle scripts | Same entry points on the developer machine and in CI; VM application installation needs custom automation |
| Guest bootstrap and processes | Supported Ubuntu LTS, cloud-init bootstrap, systemd services | Simple host/service failure model; later configuration through Arc |
| Application | Python, FastAPI, locked dependencies, versioned Python packages | Keep the existing proposal; reuse the same business code locally and on VMs |
| Local development | Docker Compose for services, PostgreSQL, and the official Service Bus emulator | Fast contract tests without building the Azure estate; not proof of Azure identity, networking, durability, or scale [S8] |
| Data correctness | PostgreSQL, migrations, transactional outbox, idempotent ledger writes | Survive retries, restarts, and temporary broker failures without losing accepted sales |
| Telemetry | OpenTelemetry, Azure Monitor/Application Insights, AMA and DCRs, KQL workbook | Application evidence plus host evidence, without a second observability stack |
| Agent operations | Azure SRE Agent; official IaC/configuration tooling pinned to a reviewed version | Do not build a custom agent framework to duplicate an existing service [S5] |
| Delivery and identity | GitHub Actions with OIDC, scoped Azure roles, managed identities, Key Vault only for unavoidable secrets | No long-lived deployment password in GitHub or committed environment files |
| Application artifacts | Build once, identify by version/digest, distribute through private artifact storage | Do not clone a moving branch or install unpinned packages during demonstrations |

Use the emulator's published prerequisites and license terms, including its SQL
dependency. Its data does not persist across container restarts and AMQP WebSockets
are unsupported; local tests must not be presented as cloud-equivalent tests. [S8]
Do not switch to RabbitMQ as an allegedly transparent substitution: broker SDKs,
authentication, delivery behavior, and operations would need an adapter and tests.

Defer AKS, a custom web control plane, Terraform alongside Bicep, Grafana/Zabbix,
ITSM integrations, Foundry/Copilot Studio agents, and multi-agent orchestration.
Each can be added for a distinct customer question, not as a baseline dependency.

## 4. Corrections to the application and incident design

### Transaction and reconciliation contract

Assign stable transaction IDs and store money as decimal values or integer cents.
Persist the accepted transaction and outbox entry in the same database transaction;
publish asynchronously with retries. Enforce a unique ledger transaction ID and
acknowledge the broker message only after the ERP commit. A redelivered message
must not create a second ledger entry.

Compute unposted EUR from authoritative accepted-versus-posted transaction state,
not queue depth multiplied by average basket size. Reconciliation reads must be
paginated/incremental and idempotent. Record their watermark, last successful
observation, and expected lag: unavailable ERP evidence means **unknown/stale**,
not zero unposted sales.

Define `unposted_eur` as sales not yet posted, not lost revenue. Show age of the
oldest unposted transaction, transaction count, and affected countries alongside
the value. Test that the outbox, broker, and ledger can recover from every
acknowledgment/commit boundary.

### Telemetry contract

Propagate trace context through HTTP and message properties. Correlate logs with
transaction and trace IDs, but do not use those high-cardinality IDs as metric
dimensions. Keep country and brand dimensions bounded.

Native Service Bus queue depth is queue-wide; it does not know message countries
or brands. Derive per-country business backlog from transaction state instead.
Calculate checkout p95 from request durations or a suitable histogram/query, not
from an average of precomputed percentiles. Keep error numerator/denominator
counts as well as the displayed ratio.

Use static metric or log-query alerts for the first disposable environment.
Dynamic thresholds require at least three days and 30 samples before firing;
weekly seasonality needs at least three weeks. Native Service Bus message-count
metrics, including `ActiveMessages`, are listed as unsupported for dynamic
thresholds. Therefore do not promise same-day learned promo curves or dynamic
queue-depth alerts. [S6]

Emit an explicit, timestamped demo change event for every fault and recovery.
This guarantees evidence for the first incident; Change Tracking can enrich it
later but is not a substitute for an application audit event.

### Deterministic faults and safe actions

Start with `backlog`: stop only `erp-poster`, leaving checkout healthy. A logged,
reversible configuration marker provides the change breadcrumb; do not introduce
a genuinely invalid configuration and pretend that restarting alone fixes it.
Use a repeatable load profile to make two countries dominate the first signal.
A shared stopped worker eventually affects all countries; say so.

Every scenario needs preconditions, expected evidence, bounded duration,
idempotent `--undo`, an independent cleanup path, and a verified healthy baseline.
Publish proposed thresholds and rehearsal measurements before claiming the
12-minute target. Agent response and telemetry latency are not guaranteed.

Do not fill a root disk or apply unbounded CPU/network pressure. Later headroom
scenarios use capped disposable storage and resource limits. Forecasting requires
enough real samples; otherwise display "insufficient history." Any seeded
historical trend must be visibly labeled synthetic, not a learned live forecast.

## 5. Delivery stages and acceptance gates

These are delivery gates, not calendar promises or filed backlog tickets. Stage 0
and Stage 1 can proceed independently. Stage 2 depends on both; Stage 3 depends on
Stage 2; Stage 4 depends on Stage 3. Stage 5 contains optional, separately scoped
extensions, not a requirement for the first customer demonstration.

| Stage | Scope | Exit gate |
| --- | --- | --- |
| **0. Prove the risky integrations** | Small disposable proof of agent availability, IaC/data-plane configuration, Arc onboarding, identity, and one approved action | Given the intended subscription and region, agent configuration can be reapplied; an approved fixed-action path works, or the manual fallback is explicitly accepted. All spike resources are removed |
| **1. Local transaction slice** | API, ERP, two databases, outbox, queue, poster, reconciliation, synthetic load, traces, and backlog fault | Given a known dataset, when the poster stops and resumes, expected unposted EUR rises and returns to baseline with no lost or duplicate ledger entries |
| **2. Repeatable Azure foundation** | Two-VM topology, Arc evaluation host, real managed data services, telemetry, workbook, static alert; deploy and destroy automation together | Given a fresh environment, when deployed twice, no duplicate infrastructure/configuration appears; backlog produces the expected signal; after destruction no unexplained owned resources remain |
| **3. One SRE-led incident** | One knowledge pack, alert response plan, evidence-based diagnosis, enforced action boundary, visible approval, recovery verification, RCA | Given the backlog incident, no write occurs before approval; denial causes no write; an approved recovery drains the backlog; audit and RCA identify the action, target, and outcome |
| **4. Customer-repeatable release** | Generic profiles, CI lifecycle, readiness checks, no-terminal scenario trigger, reset, TTL cleanup, fallback recording | Given a new environment ID, deploy -> check -> demonstrate -> reset -> destroy succeeds three times from the same release; the presentation path targets <=12 minutes and lifecycle durations are recorded |
| **5. Targeted realism** | Add latency, then separated-host batch pressure/redundancy; optional VPN, second region, prevention, Observability Agent comparison, and real hybrid | Each extension has a distinct customer outcome, isolated feature/profile selection, fault/recovery evidence, and its own lifecycle gate |

Stage 0 must specifically establish:

- Subscription/region eligibility, providers, quotas, allowed SKUs, outbound access,
  and required operator approvals. Do not discover these during a customer setup.
- Arc bootstrap sequencing after removing VM extensions, disabling the Azure
  guest agent, and persistently blocking Azure IMDS as documented. Fetch required
  artifacts first; subsequent automation must not depend on the disabled VM agent.
- Azure cloud managed identity versus Arc identity behavior for Service Bus and
  application dependencies. Prove SDK token acquisition after Azure IMDS is blocked;
  do not silently substitute a shared broker connection string.
- The precise SRE -> approved action -> Arc execution path. Arc Run Command exists,
  but that alone does not prove SRE integration, approval semantics, or a safe
  command allow-list. [S9] Prefer a verified native path. If broad script execution
  cannot be constrained, retain read-only diagnosis plus a human-run fixed action;
  consider a small authenticated fixed-action adapter only as a separately scoped
  implementation decision.
- SRE ARM deployment **and** data-plane configuration. Official tooling documents
  a second phase for knowledge uploads, hooks, and other extras; skipped mandatory
  extras must fail readiness, not count as successful deployment. [S5]

Before filing implementation work, classify it using the repository taxonomy:
Spikes for Stage 0, Enablers for lifecycle/telemetry, Tasks for technical wiring,
User Stories for operator outcomes, and Bugs for incorrect behavior. No
prioritization model currently exists in the checkout; use WSJF for independent
ready items after dependencies are honored. Every ticket must include priority,
rationale, Given/When/Then criteria, dependencies, estimate, labels, and Definition
of Ready. Missing estimates or scoring inputs remain explicit assumptions with
`needs-po-review`; this plan does not invent a scored Ready backlog.

## 6. Deployment, reset, and teardown are product features

### Configuration, not customer forks

Use a pinned release and a small profile: generic `environmentId`, target
subscription/tenant, workload and agent regions, deployment profile, synthetic
dataset seed, scenario selection, expiry, and resource-size choices. Keep actual
customer association outside the repository.

Start with `local` and `azure-lite`. Add `azure-vpn` and `real-hybrid` only when
their stages are implemented. Keep options bounded instead of supporting arbitrary
combinations. Generate agent knowledge and resource references from the same
profile; validate and review the generated context before enabling actions.

Use environment-scoped cloud, simulated-datacenter, and operations resource groups.
Include an environment ID in names, not just a region, to avoid collisions.
Tag resources with `demo=retailtx`, `environmentId`, `profile`, `expiresAt`,
`managedBy`, and generic `site`/`system` values where applicable.

### Proposed operator contract

The following are **future commands**, not scripts that exist today.

| Operation | Required behavior |
| --- | --- |
| `preflight` | Validate identity, target subscription, profile, quota, region support, permissions, and protected/shared-resource boundaries |
| `up` | Build or select pinned artifacts, provision with Bicep, bootstrap hosts, configure Arc/monitoring, seed data, apply agent configuration, and wait for readiness |
| `status` / `doctor` | Check applications, dependency reachability, poster heartbeat, actual telemetry ingestion, alert wiring, context version, and pending/skipped steps |
| `scenario` / `reset` | Apply a selected fault or undo all faults; verify business and technical recovery without destroying the environment |
| `down` | Preview the exact owned deletion set, stop triggers/load, perform pre-delete cleanup, delete owned resources, and report residuals |

Back these with `azd` where it fits, not an assumption that `azd up` automatically
deploys arbitrary VM applications. Use its documented provisioning/deployment and
`predown`/`postdown` hooks for the missing lifecycle steps. [S7]

Idempotency includes data-plane uploads, role assignments, synthetic seed data,
Arc registrations, and alert connections, not just Bicep. Retry transient failures
with bounds; persist phase results so failed setup can be resumed or destroyed.
Serialize operations per environment to prevent deployment racing with TTL cleanup.

### Ownership and deletion safety

Create an external-to-the-target-groups environment manifest containing exact
owned resource IDs, deployed release, registration IDs, and configuration versions.
Protect the manifest and keep it available after partial provisioning failures.
Classify everything as **owned and disposable**, **shared**, or **retained by
policy**. Subscription IDs, group names, and tags must agree before deletion;
tags alone are not sufficient authority.

Disable incident triggers and scheduled tasks, stop the simulator, undo faults,
and export only explicitly retained synthetic rehearsal evidence before removing
resources. Disconnect Arc while machines are reachable; delete orphan Arc records
when a machine is already gone. Remove owned role assignments, connectors,
temporary onboarding credentials, and scope-external artifacts recorded in the
manifest. Never delete shared networks, shared identities, or real customer hosts.

Check soft-deleted resources, purge protection, diagnostic destinations, resource
locks, deployment artifacts, public IPs, disks, and retained workspaces. Do not
promise that deleting resource groups or running `azd down` removes Entra objects,
external integrations, or every retained item. Do not default to force-purging
protected resources. Report retention reason, owner, and remaining cost exposure.

Run `down` again safely after both a successful deletion and a partial failure.
Verify absence of owned live resources and produce an explicit residual inventory;
do not declare zero ongoing cost solely because a delete command returned success.

TTL cleanup must run outside the environment it deletes, using the same scoped
destruction implementation and an independently authenticated identity. Budget
alerts notify; they are not spending caps. Default to full per-demo isolation,
including SRE memory and telemetry. Retaining a shared warmed-up environment is an
explicit alternative with ongoing charges and a data/memory reset obligation,
not the disposable baseline.

### CI and the no-terminal presentation

Use protected GitHub Actions environments, scoped OIDC trust, pinned actions,
explicit environment IDs, and per-environment concurrency. Separate validation,
deploy, scenario/reset, and destroy workflows. Privileged workflows must not execute
untrusted pull-request code. Authentication/bootstrap of the CI trust relationship
is a documented one-time prerequisite, not hidden manual per-demo setup.

Start the presentation from Azure portal and approved agent actions. Before the
customer-repeatable stage exits, provide a protected workflow-dispatch scenario
button and reset button; a custom dashboard is unnecessary. Separate the ability
to inject a fault from the agent's narrow remediation permissions.

## 7. Guardrails and evidence

The deployment identity, agent identity, action executor, and presenter are
different roles. Grant only scoped access each requires. A Markdown allow-list
is guidance, not enforcement; resource-level RBAC on Run Command also does not
constrain arbitrary script contents by itself.

Enforce approved targets and fixed actions at the tool/execution boundary, with
action policies or a constrained executor as established by Stage 0. Do not expose
a general root shell as a "restart worker" tool. Test wrong-target requests,
unapproved actions, denial, missing permissions, and attempts to pass arbitrary
commands. Log correlation, approver, action, outcome, and recovery evidence.
Turning off triggers or revoking the action executor must stop future writes.

Operational data is evidence, not instructions: logs and runbook retrieval must
not be allowed to widen tool permissions. Keep secrets and personal data out of
logs, traces, profiles, prompts, and generated documentation.

Local tests prove financial invariants and fault undo. Azure integration tests
prove real broker behavior, identity, private connectivity, Arc host operations,
telemetry arrival, and approval enforcement. End-to-end rehearsal measures the
complete incident and lifecycle, not just API health. Distinguish **infrastructure
provisioned**, **application healthy**, and **demo ready** in every status report.

For real-hybrid Stage 5 work, reuse application packages, telemetry contracts,
and runbooks, but implement separate Proxmox/host and site-to-site VPN lifecycle
adapters. Azure resource teardown must not destroy pre-existing homelab/customer
machines. Keep Service Bus initially; changing the broker is a separate project.

Non-Arc systems can still contribute exported logs or API evidence. Lack of Arc
primarily limits supported host management, not all visibility. Do not claim
complete estate coverage from either agent.

## 8. Sources and unresolved evidence

Product documentation was consulted on the assessment date. Preview surfaces and
APIs may change; pin implementation dependencies and repeat capability checks
before choosing deployment regions or making customer-facing commitments.

- **[S1]** [Azure Copilot Observability Agent](https://learn.microsoft.com/en-us/azure/azure-monitor/aiops/observability-agent-overview):
  chat, investigations, issues, optional agent resource, and non-remediating
  autonomous operations.
- **[S2]** [Automate incident response in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/incident-response):
  telemetry investigation, hypotheses, and response ownership.
- **[S3]** [Run modes in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/run-modes):
  infrastructure-write approvals, response-plan/task modes, and other tool controls.
- **[S4]** [Evaluate Azure Arc-enabled servers on an Azure virtual machine](https://learn.microsoft.com/en-us/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine):
  evaluation-only support, Azure guest-agent/IMDS restrictions, and management split.
- **[S5]** [Deploy with infrastructure as code in Azure SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/deploy-iac):
  official Bicep/azd tooling, ARM phase, data-plane extras, and verification.
- **[S6]** [Alert rules with dynamic thresholds overview](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-dynamic-thresholds):
  minimum history and unsupported Service Bus metrics.
- **[S7]** [Customize Azure Developer CLI workflows using hooks](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/azd-extensibility)
  and [Azure Developer CLI reference](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/reference):
  lifecycle extension points and resource deletion controls.
- **[S8]** [Overview of the Azure Service Bus emulator](https://learn.microsoft.com/en-us/azure/service-bus-messaging/overview-emulator):
  local-development scope and limitations.
- **[S9]** [Cloud-native scripting and task automation with Arc-enabled servers](https://learn.microsoft.com/en-us/azure/azure-arc/servers/cloud-native/scripting-task-automation):
  Arc remote execution, not proof of an integrated SRE remediation path.

**Still to prove in Stage 0:** tenant-specific availability and permissions;
repeatable SRE data-plane authentication in CI; Arc application identity after
IMDS blocking; and an enforceable, approval-gated SRE-to-Arc fixed action.
Until those pass, label the experience "investigate and propose" rather than
claiming fully automated healing.
