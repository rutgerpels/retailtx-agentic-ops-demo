# Azure-lite Bicep interface

These are new, self-contained templates. They do not reference or update the existing proof. `azure-main.bicep` and `azure-bindings.bicep` are subscription-scoped; all other `azure-*.bicep` files are internal resource-group-scoped helpers. Do not invoke helpers against unverified/shared resources.

## Main parameters

| Parameter | Default / contract |
| --- | --- |
| `environmentName` | `demo01`; 2–12 lowercase letters/digits/hyphens. Lifecycle must validate syntax. |
| `location` | `swedencentral`; use the same value on every pass. |
| `ownerToken` | Required lifecycle-owned GUID. Compare ownership on all three RGs before deploying. |
| `expiresAt` | Required ISO-8601 timestamp, report only; no expiry job/budget/policy change. |
| `adminSshPublicKey` | Required public key. No inbound SSH or VM public IP exists. |
| `cloudBootstrapScript`, `dcBootstrapScript` | Required secure **plaintext** strings, max 48,000 characters. Supply empty only for foundation pass. AVM normalizes/encodes customData exactly once. Parent must check decoded UTF-8 size <64 KiB and never embed credentials, tokens, private keys, or SAS. |
| `deployHosts` | `true`; `false` creates foundation and temporary identities without hosts/runtime grants. It does **not** delete existing hosts. |
| `enableBootstrapIdentities` | `true`; controls temporary UAMIs, DC onboarding/releases/scope-reader grants, PostgreSQL administrator declaration, and VM attachments. See cleanup below. |
| `enableArtifactBridge` | Defaults to `enableBootstrapIdentities`; cloud system MI gets temporary Blob Data Contributor on **only** `releases` and `provisioning`. |
| `allowPackageHttpEgress` | `false`; use HTTPS package sources. Enable only if bootstrap needs HTTP, then disable. NSG cannot enforce hostname/package-only HTTP. |
| `enableAlerts` | **`false`**; omit alert rules and their reader-role deployments entirely during foundation/bootstrap. Set `true` only after verified AppTraces ingestion. Omission does not disable/delete pre-existing rules. |
| `backlogThresholdCount` | `0`; latest fresh count must be greater than threshold. |
| `staleAfterMinutes` | `10`, range 5–60; stale/missing/unknown evidence fires a separate alert. |
| `enableCloudVerificationReader` | `true`; optional Log Analytics Reader for cloud private query checks. |
| `verificationReaders` | `[]`; array of `{principalId, principalType}` (`User`, `Group`, or `ServicePrincipal`). Workspace-only Reader; no network access granted. Lifecycle must deduplicate entries. |
| `vmSize` | `Standard_B2s` for both hosts. |
| `vmImageVersion` | `24.04.202609040`, Canonical `ubuntu-24_04-lts:server`, pinned Gen2 proof image. |

Suggested parent sequence (no deployment is performed by this implementation):

1. Validate subscription, three RG ownership tags, naming, region, providers, policy/quota, and parameter safety.
2. Deploy foundation with `deployHosts=false`, `enableAlerts=false`, bootstrap identities enabled, and empty scripts. Obtain non-secret outputs to render the two bootstrap strings.
3. Deploy with `deployHosts=true`, `enableAlerts=false`, same identity/name inputs and rendered scripts. Cloud bootstrap must retry until VM system-MI RBAC propagates; grants necessarily follow VM creation. DC bootstrap must fetch required artifacts from `releases` before disabling VM agent/IMDS and switching to Arc identity.
4. Discover the expected Arc machine and system identity. Verify its ID, tags, and principal ID. Invoke bindings with `BINDINGS_CONFIG` plus the discovered Arc ID/principal ID and `enableProvisioningReader=true`. Cloud creates mTLS keys outside ARM and uploads `provisioning/dc/{ca.crt,host.crt,host.key}`; after enrollment, DC downloads these using its Arc MI. No private key appears in ARM parameters or outputs.
5. Parent uses temporary database UAMI explicitly for migrations and creates PostgreSQL role **`retailtx-cap`** mapped to `CLOUD_PRINCIPAL_ID`. Grant only required schema usage, table SELECT/INSERT/UPDATE, and sequences, not admin/schema creation. Runtime MI is never a PostgreSQL administrator in these templates.
6. Capture temporary IDs, remove setup access, and verify effective permissions/identity state as below. Keep `enableAlerts=false` throughout bootstrap and cleanup.
7. From the private query path, verify actual AppTraces ingestion for this `environment_id`: recent `reconciliation.freshness` with `status=fresh` and recent `reconciliation.observed` with valid `observed_at` and numeric counts. A running exporter/healthy service alone is insufficient.
8. Redeploy main once with `deployHosts=true`, **`enableAlerts=true`**, **`enableBootstrapIdentities=false`**, and **`enableArtifactBridge=false`**, retaining the exact original public bootstrap scripts/customData and SSH public key. Preserve other runtime parameters. Keep bindings `enableProvisioningReader=false`. Alert queries are validated at activation; alert identity reader grants are created only in this pass.
9. Require activation deployment success and verify both expected rules exist/enabled with backlog `PT1M` and staleness `PT5M`, plus reader-grant propagation. Previously created rules from recovery attempts or the predicted `ALERT_IDS` output are not readiness success. Only then run the unchanged **300-second** incident and collect real fired-alert evidence; do not extend the incident or infer a fire from backlog logs alone.

## Output contract

Outputs contain public IDs, routing configuration, and ownership metadata only; there are no credentials/SAS/private keys/workspace keys. Application Insights connection string is a non-secret routing identifier with local authentication disabled.

- Ownership: `RESOURCE_GROUP_NAMES`, `CLOUD_RESOURCE_GROUP_NAME`, `DC_RESOURCE_GROUP_NAME`, `OPS_RESOURCE_GROUP_NAME`, `OWNERSHIP_TAGS`.
- Hosts: `CLOUD_VM_NAME`, `DC_VM_NAME`, `CLOUD_VM_ID`, `DC_VM_ID`, `CLOUD_PRINCIPAL_ID`, `CLOUD_PRIVATE_IP`, `DC_PRIVATE_IP`. IDs/principal are empty in the foundation-only pass.
- Arc: `ARC_MACHINE_NAME` (`erp-{env}`), `ARC_MACHINE_RESOURCE_ID` (expected ID in DC RG, **not** proof of registration), `ARC_PRIVATE_LINK_SCOPE_ID` (in ops RG).
- PostgreSQL: `POSTGRES_SERVER_NAME`, `POSTGRES_SERVER_ID`, `POSTGRES_FQDN`. Database is `retailtx`; TLS hostname is the public service FQDN which resolves privately, not the `privatelink` alias.
- Broker: `SERVICE_BUS_NAMESPACE_NAME`, `SERVICE_BUS_QUEUE_ID`. Queue is `IDOC_POSTING`; PeekLock is a client receive mode, lock duration 30 seconds, max delivery 5, duplicate detection disabled. Runtime is responsible for selecting PeekLock.
- Artifacts: `STORAGE_ACCOUNT_NAME`, `ARTIFACTS_BLOB_ENDPOINT`, `RELEASE_CONTAINER_ID`, `PROVISIONING_CONTAINER_ID`. The existing output name `RELEASE_CONTAINER_ID` now identifies the **`releases`** container (plural). Both runtime identities have only `releases` Reader permanently. DC bootstrap temporarily has `releases` Reader; the enrolled Arc MI temporarily gets provisioning Reader through bindings for mTLS installation, never write access.
- Monitor: `WORKSPACE_NAME`, `WORKSPACE_ID`, `WORKSPACE_CUSTOMER_ID`, `APP_INSIGHTS_ID`, `DCE_ID`, `DCR_ID`, `WORKBOOK_ID`, `ALERT_IDS` (backlog then staleness; stable **predicted** IDs even with `enableAlerts=false`, not proof of creation/readiness).
- Temporary DB admin: `DATABASE_BOOTSTRAP_NAME`, `DATABASE_BOOTSTRAP_IDENTITY_ID`, `DATABASE_BOOTSTRAP_CLIENT_ID`, `DATABASE_BOOTSTRAP_PRINCIPAL_ID`, `DATABASE_BOOTSTRAP_ADMINISTRATOR_ID`.
- Temporary DC identity: `DC_BOOTSTRAP_IDENTITY_ID`, `DC_BOOTSTRAP_CLIENT_ID`, `DC_BOOTSTRAP_PRINCIPAL_ID`.
- Temporary grants: `BOOTSTRAP_ROLE_ASSIGNMENT_IDS` (DC RG onboarding, releases Reader, Arc scope Reader), `ARTIFACT_BRIDGE_ROLE_ASSIGNMENT_IDS` (releases/provisioning Contributors).
- `RUNTIME_CONFIG`: environment-variable map with `RETAILTX_MODE`, `RETAILTX_ENVIRONMENT_ID`, `BROKER_NAMESPACE` (hostname), `CAP_DB_HOST`, `CAP_DB_USER=retailtx-cap`, `CAP_DB_NAME`, `CAP_DB_SSLROOTCERT=/etc/ssl/certs/ca-certificates.crt`, `ERP_DB_HOST=/var/run/postgresql`, `ERP_DB_USER=retailtx`, `ERP_DB_NAME=retailtx`, HTTPS `CAP_URL`/`ERP_URL` on 8443, `/etc/retailtx/tls/{ca.crt,host.crt,host.key}` TLS paths, `APPLICATIONINSIGHTS_CONNECTION_STRING`. Parent adds `RETAILTX_IDENTITY=vm` or `arc`. The public PostgreSQL CA bundle is distinct from the private app CA. The same host certificate serves both HTTPS and outbound mTLS: parent-generated certificates must include both `serverAuth` and `clientAuth` EKUs. Root-protect `/etc/retailtx/runtime.env` and TLS files; never store certificate private keys in Bicep parameters.
- `BINDINGS_CONFIG`: plain object with required binding parameters except the discovered Arc ID/principal; optional binding flags such as `enableProvisioningReader` can be supplied separately. It contains environment/location/ownership fields, service names, workspace/AppInsights names, DCE/DCR IDs. The parent must convert values to its ARM parameter representation.

## Post-onboarding bindings

`azure-bindings.bicep` requires all `BINDINGS_CONFIG` fields and:

- `arcMachineResourceId`: discovered `Microsoft.HybridCompute/machines` ID. Parent must require exact equality to expected `ARC_MACHINE_RESOURCE_ID` and verify ownership; the template intentionally never creates/replaces an Arc machine.
- `arcPrincipalId`: discovered system-assigned **principal/object ID**, not client ID.
- `grantWorkspaceReader=true`: optional Arc workspace query verification permission.
- `enableProvisioningReader=true`: setup-only Blob Data Reader on the `provisioning` container for the enrolled Arc MI. Download `dc/{ca.crt,host.crt,host.key}`, then explicitly revoke the returned role assignment and use `false` for all steady-state binding deployments. This grants container-wide read access, not only the `dc/` prefix; keep the container limited to intended provisioning material and remove setup artifacts after installation.

It assigns queue-only Data Receiver, releases-container-only Blob Data Reader, AppInsights-only Monitoring Metrics Publisher, and optional workspace-only Log Analytics Reader. It creates Arc DCR and DCE associations before the Arc AMA extension, matching the built-in DINE extension settings. Outputs: `ARC_AMA_EXTENSION_ID`, `ARC_ROLE_ASSIGNMENT_IDS`, `ARC_WORKSPACE_READER_ROLE_ASSIGNMENT_ID`, and **`ARC_PROVISIONING_READER_ROLE_ASSIGNMENT_ID`** (temporary; empty when disabled). `ARC_ROLE_ASSIGNMENT_IDS` intentionally excludes this setup-only grant. Capture the temporary output before disabling it. It installs no Compute extension on DC.

## Idempotence and cleanup boundaries

Resource names and role GUIDs are stable for a fixed environment/subscription/principal. Runtime resources are not renamed/recreated when setup flags change. Incremental ARM deployment **does not delete omitted conditional resources**. Capture cleanup outputs **before** setting flags false (later outputs are empty). Parent must explicitly and idempotently:

1. Redeploy with `enableBootstrapIdentities=false` and `enableArtifactBridge=false`, retaining exactly the original customData strings/public key. Both backing VMs explicitly retain their system-assigned identity. Parent cleanup also PATCHes DC with `{"identity":{"type":"SystemAssigned"}}` and reads back both VMs: require **`SystemAssigned` on both and zero UAMI attachments**. Omit `userAssignedIdentities` from this PATCH; Azure rejects even an empty map for a system-only identity. Do not request or expect `None` for DC.
2. Delete captured bootstrap and artifact-bridge role assignments, the separately captured `ARC_PROVISIONING_READER_ROLE_ASSIGNMENT_ID`, the PostgreSQL administrator child resource, and both UAMIs. Installation must first transfer SQL ownership and create subsequent objects/grants as `azure_pg_admin`: Azure cannot delete an administrator whose SQL role still owns application objects. Redeploy bindings with `enableProvisioningReader=false`; omission alone does not delete that role assignment. Treat already absent resources as success. Retain cloud/Arc releases Reader and runtime sender/receiver/publisher roles.
3. Verify runtime MI is not database admin, setup UAMIs are absent, provisioning writes and Arc provisioning reads are no longer granted, and runtime remains healthy. Parent also rejects **any direct role assignment in the subscription to the DC backing VM system principal**. This is a scoped direct-assignment check, not a claim to have audited every possible inherited/group-based permission. The DC application must use the distinct Arc principal exclusively.

### Policy-aligned backing identity contract

`azure-host.bicep` explicitly sets `systemAssigned: true` for both hosts. With bootstrap enabled, the declared type is `SystemAssigned, UserAssigned`; with bootstrap disabled, the declared type is **`SystemAssigned`** and the UAMI list is empty. Full AVM VM/NIC/disk convergence remains enabled on cleanup and repeated Up. No fallback step after a failing AVM deployment is required, no extra application permissions are granted, and the helper exposes a runtime system-principal output only for cloud.

The DC native system identity is retained solely to align the backing Azure VM with the active Guest Configuration Modify policies. Read-only verification on 2026-10-07 confirmed both built-in identity policies apply through an enforced subscription assignment (`enforcementMode=Default`, no excluded scopes), with equivalent inherited management-group policies. One adds `SystemAssigned` when no identity exists; the other adds it to a UAMI-only identity. The DC already had a native system identity before this fix, and the direct subscription role-assignment query for that principal returned no assignments. Retaining that native identity does **not** authorize application use: guest IMDS stays persistently blocked, the guest agent stays disabled after bootstrap, Compute extension operations remain disabled, and all DC application authentication uses **Arc MI exclusively**. The separate native Guest Configuration extension conflict remains; this is not a policy exemption or a claim of full policy compliance.

The source of pinned VM AVM `0.22.3` emits an invalid null identity type for `systemAssigned=false` with an empty UAMI list. That branch is now avoided by explicitly declaring the policy-required system identity, rather than omitting desired host convergence or retaining a bootstrap UAMI. At verification time, `0.22.3` was still the newest published VM AVM version.

Authoritative sources used for that verification:

- [Pinned VM AVM 0.22.3 source — `var identity` and VM identity serialization](https://raw.githubusercontent.com/Azure/bicep-registry-modules/avm/res/compute/virtual-machine/0.22.3/avm/res/compute/virtual-machine/main.bicep).
- [Official MCR VM AVM version list](https://mcr.microsoft.com/v2/bicep/avm/res/compute/virtual-machine/tags/list).
- [Guest Configuration: add system identity when none exists](https://raw.githubusercontent.com/Azure/azure-policy/master/built-in-policies/policyDefinitions/Guest%20Configuration/AddSystemIdentityWhenNone_Prerequisite.json), definition `3cf2ab00-13f1-4d0c-8971-2ac904541a7e`; `modify` sets `identity.type` to `SystemAssigned`.
- [Guest Configuration: add system identity to UAMI-only VMs](https://raw.githubusercontent.com/Azure/azure-policy/master/built-in-policies/policyDefinitions/Guest%20Configuration/AddSystemIdentityWhenUser_Prerequisite.json), definition `497dff13-db2a-4c0f-8603-28fa3b331ab6`; `modify` appends `SystemAssigned`.

Successful template completion is still not proof of revocation: parent verifies both final VM types and empty UAMI maps, rejects direct subscription grants to DC's native principal, and checks RBAC propagation. Cloud system MI access cannot distinguish root from another local process: root-only deployment bridge and IMDS restrictions are guest/lifecycle responsibilities. Re-enabling bootstrap is explicit maintenance; do not casually restore setup grants on every healthy redeployment.

Application changes must use parent lifecycle installation/update flow, not changed cloud-init/customData. `deployHosts=false` is for a fresh foundation pass, not host deletion. Full destroy should delete only the three verified owned RGs. `expiresAt` is never an automatic delete trigger here.

## Monitoring contract and validation limits

Runtime `AppTraces.Properties` contains `event` and `environment_id`. The backlog query is a **single `AppTraces` pipeline** with one `arg_max(TimeGenerated, Properties)`: it considers `reconciliation.observed` and unhealthy `reconciliation.freshness` markers, selects the latest record, and **only then** filters for a recent observed snapshot with `unposted_count` above threshold. Runtime emits `reconciliation.observed` only for fresh evidence. A newer zero-backlog observation supersedes historical backlog; a newer stale/unknown marker suppresses it. Both record time and `Properties.observed_at` must be within the freshness horizon. No history is summed and no business value is manufactured when evidence is absent. Healthy freshness heartbeats alone cannot resurrect an old snapshot.

The one-minute backlog path contains no `let`, `toscalar`, `print`, `take`/`limit`, `union`, `search`, `ingestion_time()`, joins, or cross-table functions. Microsoft documents one-minute optimizer restrictions and requires data in the referenced table. This removes the scalar/multi-scan query shape and documented unsupported operators from that path; offline checks are not a substitute for ARM activation against ingested data. Staleness retains its no-data-safe scalar query at a separate **five-minute** frequency and alerts on missing/stale/unknown evidence. The workbook remains independent and correlates country records by the latest `observed_at` snapshot.

Backlog evaluation is **`PT1M`**; staleness evaluation is **`PT5M`**. Both use **`PT5M`** aggregation windows and explicit **`PT1H`** query lookbacks, preserving the configurable freshness horizon. The **300-second incident remains unchanged**. Ingestion, identity/RBAC propagation, and alert scheduling still affect actual fire latency; no firing or deadline success has been proven here. Stateful one-minute backlog alerts normally require 10 minutes of healthy evaluations to resolve, so distinguish runtime recovery evidence from alert auto-resolution.

`enableAlerts=false` now omits both alert modules and dependent workspace-reader modules, rather than sending disabled rules through unsupported-query validation. `ALERT_IDS` remains a deterministic prediction with no dependency on conditional module outputs. Incremental omission **does not disable/delete existing alerts or grants** left by an earlier deployment; parent must handle any recovery cleanup explicitly. `enableAlerts=true` creates/enables the stable named rules with **`skipQueryValidation=false`** after ingestion. Final activation must succeed before readiness, regardless of any earlier partial deployment. Follow the exact parent sequence above; do not rely on disabled-rule PUTs or skipped query validation to bootstrap an empty AppTraces table.

Alerts have system MI + workspace Reader, but no external action endpoints or remediation. Workbook queries require the caller's private network path and RBAC; merely opening the Azure portal outside the VNets does not grant private query access. AMA collects Syslog `local0` and Perf; parent must route application/syslog events appropriately. AppTraces comes from the Python authenticated exporter, not the AMA DCR.

AVM versions are pinned. Storage and Service Bus AVMs internally declare **protected** key outputs; no wrapper consumes/re-exports them. Shared-key/local authentication is disabled. The Service Bus default authorization-rule resource remains because the AVM's protected output expressions call `listKeys` on it; SAS clients still cannot authenticate. PostgreSQL and scheduled-query AVMs use documented preview API versions. The pinned Compute AVM uses documented `2025-11-01`; Bicep CLI 0.42.1 emits BCP081 because its local type bundle lacks that schema. Other owned-template lint/type checks pass.

This infrastructure-domain verification comprised offline lint/build/static checks plus read-only checks of the DC VM identity, applicable policies, and direct subscription role assignments. No Azure deployment/what-if, policy exemptions, registrations, or cost/quota mutations were performed by this domain. Parent-owned live lifecycle/deployment results are separate evidence; these checks do not establish live alert firing or end-to-end readiness. Active private DNS policy and the known native guest-configuration/Arc-evaluation conflict require parent preflight; these templates do not bypass policy. Premium Service Bus and two NAT gateways incur ongoing cost. There is no SRE resource, budget, notification destination, or automatic remediation.
