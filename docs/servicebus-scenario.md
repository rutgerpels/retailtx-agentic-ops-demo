# Private Service Bus recovery scenario

**Status: feasibility investigation parked; autonomous recovery is not live-verified.**
Partial Azure provisioning was attempted; no live broker fault was injected.
Price-service remains
the primary scenario; Service Bus is secondary. The source includes a private
Premium Service Bus namespace, a dedicated queue, a queue-scoped Entra probe
identity on an owned private Linux runner, a queue-filtered `UserErrors` alert,
a durable runner-local outbox/ledger
probe, and a separate fixed-action executor with an independent deadline
watchdog. This is a broker-delivery and idempotent-posting proof, not the
RetailTx ERP or an end-to-end retail transaction.
Blob-coordination source changes alter the runner/function source digests; they
require a fresh owner manifest and fixture. Do not rewrite an existing source
attestation in place.

## Feasibility decision on 2026-10-09

Stop further deployment and implementation expansion for now. Restoring a
queue's status is plausible, but the private, secretless, bounded autonomous
demo requires substantial custom machinery beyond that write: executor,
watchdog, caller authentication, durable coordination and a publishing/probe
runner. Live Queue GET `2024-01-01` exposed unsupported mock assumptions:
neither queue ETag nor `userMetadata` is available. Blob leases could coordinate
our participating writers, but cannot exclude unrelated ARM administrators.
This is not yet a reliable, repeatable demo path.

Linux authentication and Flex Consumption provisioning also failed. The
offline contract checks are now green: both Python suites pass (61/61), both
PowerShell contract scripts (`Test-ServiceBusScenario.ps1`,
`Test-ServiceBusEntraIdentity.ps1`) pass, and all three Bicep files compile.
Ruff could not be run in this environment (`python -m ruff` unavailable) and
remains unverified. Offline contract passes do not establish runtime
feasibility — the live gates above (queue ETag/`userMetadata`, blob-lease
exclusivity, Linux auth, Flex Consumption) are unchanged and unresolved.
Do not deploy or arm this source until a separately authorized, bounded
follow-up resolves those gates.

The never-faulted `demo15` resource group, executor app/service principal and
external foundation peering were removed. Repeated Down returned `Absent`;
independent Azure and Graph reads confirmed absence. The ownership manifest is
archived locally. The shared foundation remains intentionally retained.

| Alternative | Evidence and trade-off | Decision |
|---|---|---|
| Native Azure VM start | Existing [native-action proof](native-action-proof.md) verifies SRE execution and action identity, with automated test approval. It does **not** prove alert-triggered, approval-free autonomy or application recovery. | Best candidate for a small next feasibility check; preserve the separate Arc guest scenario. |
| Azure-hosted application recovery | Closer to retail operations, but action support, identity, alert routing and workload recovery remain unverified. | Verify a supported native action before building infrastructure. |
| Operator-driven Service Bus restoration | Avoids claiming autonomous execution, but duplicates the recommendation/operator pattern already shown on Arc. | Optional only if broker-specific learning justifies it. |
| Custom autonomous Service Bus executor | Current private design is plausible but has significant coordination, deployment and lifecycle work outstanding. | Park; no further expansion in this iteration. |

## Intended design boundaries (not live acceptance)

- `infra/servicebus-scenario.bicep` pins the Service Bus AVM module to `0.17.1`
  and the private endpoint module to `0.12.1`. It disables local authentication
  and public network access, provisions Premium capacity, links the existing
  Stage 0 VNet to a private DNS zone, and creates a single
  `recovery-<environment-id>` queue inside its separately tagged namespace.
- The private runner VM's system identity receives only the built-in Service
  Bus Data Sender and Data Receiver roles at that queue, plus Storage Blob Data
  Contributor at the exact private `scenario-coordination` container. It receives app-scoped
  Website Contributor on the two Function Apps solely to publish the fixed
  package through their private SCM endpoints; this built-in role is broader
  than publish-only, but is not granted at resource-group or subscription
  scope. The SRE Agent gets no queue mutation role. The metric alert has no
  Azure Monitor action group; the source
  configures the SRE Agent's Azure Monitor incident platform and an exact
  response-plan filter for the namespace and alert title. This is the intended
  alert-routing path, not proof that a live alert starts an SRE incident.
- An existing `privatelink.servicebus.windows.net` zone is accepted only when
  its exact resource ID and owner tags match this scenario's manifest. A zone
  in the same resource group with a foreign owner token is not considered
  owned.
- `scripts/servicebus/probe.py` runs only on the manifest-owned Linux VM inside
  the fixture VNet. Azure VM Run Command transports fixed, schema-validated
  operations; there is no SSH remoting credential, public VM IP, arbitrary
  command channel, or workstation-to-Service-Bus data connection. The runner's system-assigned
  identity authenticates with Entra and AMQP over WebSockets on port 443. It
  refuses public DNS answers for the broker or either SCM endpoint. It writes a
  root-owned SQLite outbox record on the persistent OS disk before sending,
  uses one stable message ID,
  and posts into an idempotent local ledger before completing the queue message.
  A send retry reuses that ID. If completion fails ambiguously after the ledger
  commit, the probe does not issue an abandon against a potentially settled
  message; a later redelivery is recorded as a duplicate and cannot create a
  second ledger posting. This is a small durability demonstration, not a
  distributed transaction between SQLite and Service Bus.
- The runner and Flex integration subnets have default outbound access
  disabled and share one scenario-owned Standard NAT Gateway and static
  Standard public IP. The runner uses it for bootstrap package/tool downloads;
  the Function Apps use it for required public Azure Resource Manager
  control-plane calls. The VM still has no public IP or inbound path. Queue,
  storage, and SCM data/deployment endpoints must continue to resolve privately;
  there is no public broker or SCM fallback. The NAT resources share the exact
  scenario resource group and are removed with that owned fixture. See
  Microsoft's [NAT Gateway](https://learn.microsoft.com/en-us/azure/nat-gateway/manage-nat-gateway)
  and [default outbound access](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access)
  documentation.
- `scripts/Invoke-ServiceBusScenario.ps1 -Operation Doctor` verifies the saved
  manifest and exact resource-group ownership separately from live checks. It
  labels this `ManifestAndGroupVerified`, reports deployment health
  `NotChecked` and keeps `ready: false` when only those ownership checks pass;
  a saved `Ready` status is not live health evidence. With live readbacks it
  checks the queue, executor/watchdog runtime, SRE integration, role assignment,
  and durable watchdog heartbeat. `Up` provisions the isolated fixture and private executor,
  then creates an executor-specific Entra application, `ServiceBus.QueueRestore`
  app role, service principal, and exact grant to the retained Agent's
  **system-assigned identity used by the stdio connector**. It resolves that
  principal's application ID through Microsoft Graph and binds the same
  connector identity to Easy Auth. This identity can differ from the separate
  user-assigned identity in the Agent's native `actionConfiguration`; the
  native action identity remains unchanged. It saves its owner-token manifest before the first Graph write,
  refuses an unowned display-name collision, and removes only that exact
  assignment, service principal, and application during `Down`. `Up` and `Down`
  hold an exclusive shared lock derived from the exact foundation VNet ID across
  DNS checks and changes. `Connect` also takes the per-scenario exclusive
  lifecycle lock so its SRE snapshot and writes cannot race another operation.
  The lockfiles are retained. Fault, reset, and recovery observation code is
  implemented, but it has not been run against Azure.
  `Connect` and `Arm` are implemented but live-unverified; Fault and Incident
  fail closed until connector, private-call, response-plan, and automatic
  alert-routing readbacks pass. No live SRE settings were changed here.
- `infra/servicebus-executor.bicep` provisions separate private Function Apps
  for the fixed HTTP executor and deadline watchdog, their separate managed
  identities, private networking and storage, Easy Auth, and queue-scoped
  management roles. It also provisions the private Linux runner VM in its own
  subnet, with no public IP and a runner-subnet NSG that denies inbound
  traffic. The lifecycle generates an owner-bound SSH keypair in memory and
  persists only its OpenSSH public key in the exact local owner manifest; it
  never writes or retains the private key, and SSH is not a management
  transport. The VM needs this public key for Linux provisioning, while Azure
  VM Run Command remains the only runner operation path. It also has source
  and owner attestations, a durable OS-disk state directory, and a fixed Azure
  VM Run Command protocol.
  Queue Data Sender/Receiver roles are queue-scoped; Function package publisher
  roles are app-scoped and limited to these two apps. The packages publish from
  the VM through private SCM endpoints using managed-identity authentication.
  Azure CLI managed-identity login completes before a publish journal entry is
  written, so an authentication failure can be retried safely. The durable
  `Started` marker is written immediately before the SCM publish call, and an
  uncertain publish outcome is never replayed automatically. Both apps require
  the exact allowed SRE client application
  and executor audience at Easy Auth; executor code additionally checks tenant,
  audience, app ID, principal object ID, and the `ServiceBus.QueueRestore` app
  role. The SRE identity receives no queue management role.
- The storage account also contains a private `scenario-coordination`
  container with one owner-bound `scenario-state.json` coordination blob.
  Supported Service Bus Queue GET responses expose neither an ETag nor durable
  `userMetadata`; no component fabricates or depends on either property. The
  runner, fixed executor, and watchdog share state through an actual finite
  Blob lease and conditional Blob ETag updates. The runner's Blob role is
  scoped to this container; the SRE Agent receives no Storage role. The
  Function identities retain their separately required host-storage runtime
  roles.
- The FC1 apps use the Flex `functionAppConfig.runtime` (`python` 3.11) and
  `functionAppConfig.deployment.storage` blob-container configuration with
  system-assigned identity. Their host storage uses only
  `AzureWebJobsStorage__accountName` plus managed-identity credentials; legacy
  `FUNCTIONS_WORKER_RUNTIME`, `FUNCTIONS_EXTENSION_VERSION`, Azure Files
  content-share, storage-key, and `WEBSITE_RUN_FROM_PACKAGE` settings are
  omitted. The supported Flex package publishing path is Functions Core Tools
  `func azure functionapp publish` (OneDeploy/Flex package deployment, not ZIP
  Deploy); the runner requests remote build. Runner-to-SCM remains private and
  uses its Entra CLI login. These deployment APIs and identities are documented,
  but live publishing from this private runner is still an acceptance gate.
  See Microsoft's [Flex Consumption infrastructure configuration](https://learn.microsoft.com/en-us/azure/azure-functions/functions-infrastructure-as-code),
  [deployment technologies](https://learn.microsoft.com/en-us/azure/azure-functions/functions-deployment-technologies),
  and [Core Tools reference](https://learn.microsoft.com/en-us/azure/azure-functions/functions-core-tools-reference).
- Before the runner makes the single fault mutation, it commits a `FaultIntent`
  containing the owner, environment, queue, transaction, run, and deadline to
  the leased coordination blob. It then changes only the queue status to
  `SendDisabled` and verifies ARM readback. An ambiguous fault result is never
  replayed; the deadline watchdog uses the durable intent and actual queue
  status to reconcile or recover it.
- The executor accepts only the current `faultRunId`, reads the queue identified
  by the deployment manifest, and requires the owner-bound blob record, current
  `SendDisabled` status, and an unexpired deadline. It records a recovery intent
  under the Blob lease, changes only `status` to `Active`, verifies ARM readback,
  then persists actor and outcome evidence in the coordination blob. An
  ambiguous SRE recovery is not replayed by the request handler; the watchdog
  can reconcile an already-Active queue or take over a still-disabled queue
  after the original deadline. The Blob lease serializes only scenario-owned
  writers; it is not an Azure-wide conditional update and cannot prevent an
  unrelated subscription administrator from changing the queue concurrently.
  Every status mutation therefore requires post-write readback and remains
  fail-closed on conflict. The watchdog independently checks the same durable
  state and records a successful, fresh heartbeat there, including the
  observed queue status. The stdio MCP bridge exposes only `restore_servicebus_queue`;
  it rejects non-private DNS answers and requires a custom executor-audience
  managed-identity token. These are code contracts, not live proof.
- Queue-scoped Azure `Contributor` is broader than an `Active`-only update.
  Therefore the separate executor and watchdog code are the enforcement
  boundary; Azure RBAC itself does **not** constrain queue property values. The
  SRE identity has no queue-management role and cannot bypass the executor by
  issuing a native queue update.

The SDK calls follow Microsoft's
[ServiceBusClient Python reference](https://learn.microsoft.com/en-us/python/api/azure-servicebus/azure.servicebus.servicebusclient?view=azure-python),
which documents `AmqpOverWebsocket` for port 443. The metric name and dimension
come from Microsoft's
[Service Bus supported metrics](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/supported-metrics/microsoft-servicebus-namespaces-metrics).
The infrastructure pins the existing repository's
[Service Bus AVM module 0.17.1](https://github.com/Azure/bicep-registry-modules/tree/avm/res/service-bus/namespace/0.17.1/avm/res/service-bus/namespace)
and [Private Endpoint AVM module 0.12.1](https://github.com/Azure/bicep-registry-modules/tree/avm/res/network/private-endpoint/0.12.1/avm/res/network/private-endpoint).
Coordination follows Microsoft's [Blob lease](https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blob-lease-python)
and [ETag concurrency](https://learn.microsoft.com/en-us/azure/storage/blobs/concurrency-manage)
contracts; these protect scenario state, not the Service Bus queue resource.

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

Microsoft's current SRE Agent MCP connector documentation supports `stdio`
connectors with a command, argument array, and optional environment variables.
It documents Managed Identity for Azure-service authentication from stdio
connectors, and explicitly requires a public HTTPS endpoint for OAuth on
Streamable-HTTP connectors. The Azure MCP Server reference documents `mcp`
connector fields (`type`, `command`, `args`, `envs-json`) and connector
list/get/create operations. These are product-supported configuration
surfaces, not evidence that this repo's custom process can obtain the agent
identity token, reach a private executor endpoint, or be safely configured
against the retained agent's live schema. See Microsoft's
[SRE MCP connectors](https://learn.microsoft.com/en-us/azure/sre-agent/mcp-connectors),
[MCP connector setup](https://learn.microsoft.com/en-us/azure/sre-agent/mcp-connector),
[Azure SRE Agent MCP tool reference](https://learn.microsoft.com/en-us/azure/developer/azure-mcp-server/tools/azure-sre-agent),
and [SRE Agent MCP server](https://learn.microsoft.com/en-us/azure/sre-agent/mcp-server)
documentation.

The Entra helper uses Microsoft's Microsoft Graph
[application registration](https://learn.microsoft.com/en-us/graph/api/application-post-applications),
[service-principal creation](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-serviceprincipals),
[app-role assignment](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-approleassignedto),
and [app-role grant deletion](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-delete-approleassignedto)
operations. It uses an executor-specific `api://<application-id>` audience, not
the Azure Resource Manager audience, and creates no client secret or
certificate.

The current blocker is **live integration and acceptance**, not missing
executor or identity-lifecycle source. A read-only CLI request successfully
listed the retained agent's connectors and found the existing Stage 0
KnowledgeFile connector. This implementation did not create a connector,
change the SRE agent, deploy Azure resources, induce a fault, or run recovery.
`Up` owns creation and teardown of the executor API app registration and the
single application-role assignment to the connector's system-assigned identity.
This is deliberately distinct from the Agent's native action-configuration
user-assigned identity; the latter is read/validated but not changed or granted
executor access. The signed-in Azure CLI identity must
have tenant-approved Microsoft Graph directory permissions to create
applications and service principals and assign/revoke the app role; Graph
failures abort the operation, and this code creates no tenant-wide role or
credential. App-role assignment readback does not prove that the SRE runtime
has refreshed its managed-identity token, so readiness reports
`RoleAssignmentPresentTokenRefreshUnverified` until runtime acceptance.

Function deployment, package publishing, Easy Auth claims, private
DNS/reachability from the SRE connector runtime, automatic Azure Monitor
incident routing, and the matching Autonomous response plan are all
unverified. `Arm` and `Incident` therefore remain blocked until their
readbacks pass. Verify that a real `UserErrors` alert creates the intended
incident and uses a per-response-plan Autonomous mode while the shared global
mode remains Review. Do not describe source code, role assignment, or a
manually initiated tool call as an autonomous alert-driven recovery. No live
deployment, fault, or recovery was performed here.

An Azure RBAC role limited to the queue resource still permits changes to
properties other than `status`; it does not enforce `Active` as the only value.
That is why this implementation assigns no SRE management-plane role and blocks
arming rather than treating resource scope as an action-level guardrail.

## Offline validation

From the repository root:

```powershell
.venv\Scripts\python.exe -m pytest -s -p no:cacheprovider tests\test_servicebus_probe.py -q
.venv\Scripts\python.exe -m pytest -s -p no:cacheprovider tests\test_servicebus_executor.py tests\test_servicebus_mcp_stdio.py tests\test_servicebus_runner.py -q
pwsh -NoProfile -File tests\Test-ServiceBusScenario.ps1
pwsh -NoProfile -File tests\Test-ServiceBusEntraIdentity.ps1
.venv\Scripts\python.exe -m ruff check scripts\servicebus\probe.py tests\test_servicebus_probe.py
.venv\Scripts\python.exe -m ruff check scripts\servicebus\executor tests\test_servicebus_executor.py tests\test_servicebus_mcp_stdio.py
az bicep build --file infra\servicebus-scenario.bicep --stdout
az bicep build --file infra\servicebus-executor.bicep --stdout
az bicep build --file infra\servicebus-executor-foundation-peer.bicep --stdout
```

These checks do not connect to Azure. The tests exercise Blob lease/ETag
conditional state updates and provider-shaped queue GET responses without
queue ETag or `userMetadata`, intent-before-mutation ordering, ambiguous fault
and recovery outcomes, durable outbox retention after a send error, retry with
the same stable message ID, duplicate
delivery, redelivery after an ambiguous completion failure, exact single
posting, fixed executor identity/run/deadline checks, watchdog idempotence,
private MCP endpoint validation, Graph lifecycle ownership/idempotence,
response-loss reconciliation, exact role assignment/removal, and lifecycle
ownership and fail-closed SRE integration gates.

## Probe commands after deployment and identity setup

`Up` is an Azure deployment operation and was not run for this implementation.
It creates the executor-specific Entra API audience and exact SRE role grant
itself; run it only after the infrastructure, Graph permissions, and connector
plan have been reviewed:

```powershell
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Up -SubscriptionId <guid> -EnvironmentName demo01
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Doctor -SubscriptionId <guid> -EnvironmentName demo01
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Connect -SubscriptionId <guid> -EnvironmentName demo01
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Arm -SubscriptionId <guid> -EnvironmentName demo01
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Fault -SubscriptionId <guid> -EnvironmentName demo01
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Incident -SubscriptionId <guid> -EnvironmentName demo01
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Recover -SubscriptionId <guid> -EnvironmentName demo01 -TimeoutSeconds 180
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Reset -SubscriptionId <guid> -EnvironmentName demo01
.\scripts\Invoke-ServiceBusScenario.ps1 -Operation Down -SubscriptionId <guid> -EnvironmentName demo01
```

`Up` requires the retained `.azure\stage0\retailtx-state.json`, Azure CLI, and
Graph permissions for the signed-in operator. It creates the private runner
and its system identity instead of requiring an external probe principal. It
derives the connector identity from the retained Agent's system
identity, independently of the native action UAMI, and saves a
durable ownership manifest before creating resources, and creates its own API
audience and app-role grant. It publishes the same fixed code to both Function
Apps. If a deployment is interrupted, reconcile only after reviewing the
saved manifest.
`Doctor` reports manifest/group ownership and unresolved integration gates. It
checks runner source/owner hashes, private queue and SCM DNS, root-owned SQLite
state, both Function Apps and indexed functions, and the watchdog heartbeat. It
never treats a saved status alone as readiness evidence.
These are lifecycle entry points, not acceptance claims: `Connect` saves and
later restores the SRE baseline while configuring the owned connector and
Review plan; `Arm` enables only that response plan; `Fault` creates the
bounded real send failure only after readiness checks; `Incident` correlates
the exact alert and SRE incident; `Recover` only observes the fixed-tool result
and durable ledger evidence; `Reset` verifies healthy queue/probe state; and
`Down` removes only manifest-owned identities and resources. None was run live
here.
`Connect` creates the owned connector and a disabled **Review** response plan;
`Arm` changes that exact response plan to **Autonomous** while the shared agent
global mode remains **Review**. The metric alert's empty `actions` list means
there is no Azure Monitor action group; the configured SRE Azure Monitor
incident platform is the intended route. Only live alert and incident
readbacks can establish that the route works.

The runner bootstrap installs Azure CLI, Functions Core Tools, and the pinned
Python Azure identity/Service Bus SDKs from their upstream package
repositories. This requires outbound package-repository egress during first
boot. It does not make the broker or SCM public: application data and publish
traffic must resolve to the private endpoints, and the runner fails closed on
public DNS. Run Command operations and output are bounded. A timeout after a
publish begins leaves an ambiguous journal that blocks automatic replay.

These runner, deployment, DNS, authentication, and teardown paths are
implementation contracts only. No Azure write, VM deployment, private
publication, or live Service Bus fault has been run for this change. Live
acceptance must still prove that VM Run Command reaches the private SCM names,
managed-identity package publication succeeds, the exact queue roles work,
the queue send is actually rejected while `SendDisabled`, the watchdog remains
independent, and the alert reaches the intended SRE incident.
