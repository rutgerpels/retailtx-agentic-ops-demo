# Stage 0 deployment

Stage 0 is the infrastructure and identity integration proof. It is not the
RetailTx application, posting pipeline, or an approval-gated healing demo.

## Deployment contract

Use Sweden Central and an explicitly selected subscription. The deploying account
needs infrastructure and role-assignment permissions, plus permission to administer
the created SRE Agent. Authenticate with Azure CLI in the target tenant. The
wrapper configures Azure Developer CLI to reuse that session in an isolated
environment-local configuration directory; it does not change global azd settings.
The initial proof uses an interactive Entra operator; unattended
CI federation is not implemented yet.

No budgets are created. No storage accounts, Key Vaults, SAS tokens, shared service
keys, or application-registration secrets are used. The target subscription and
tenant IDs are local parameters, not committed customer profiles.

Private connectivity is configured for Arc and Azure Monitor. SRE Agent uses a
dedicated VNet-integrated workspace subnet. Its inbound endpoint and managed
platform dependencies remain public, protected by Entra authentication: the
product does not support inbound private endpoints. Network data-source
connectors are omitted because they do not use the VNet. The uploaded knowledge
file is stored in the agent; it is not a remote telemetry connector.

The VM has no public IP and no inbound access. A NAT Gateway provides outbound
connectivity for package installation, Entra, ARM, and platform dependencies.
This is not an air-gapped deployment or a hostname-filtering firewall.
All resources and DNS zones are isolated in the owned environment resource group;
existing shared DNS and subscription policies are not changed.

## Commands

Run from the repository root in PowerShell 7.2 or later. Install/sign in to Azure
CLI and install Azure Developer CLI; `ssh-keygen` supplies a provisioning-only SSH public
key. Its temporary private key is immediately deleted and SSH is disabled on the
guest. Operational access is through Entra-authenticated Azure/Arc operations,
not that key.

```powershell
$subscriptionId = '<your-subscription-guid>'

.\scripts\Invoke-Stage0.ps1 -Operation Preflight `
    -SubscriptionId $subscriptionId -EnvironmentName stage0

.\scripts\Invoke-Stage0.ps1 -Operation Up `
    -SubscriptionId $subscriptionId -EnvironmentName stage0

.\scripts\Invoke-Stage0.ps1 -Operation Status `
    -SubscriptionId $subscriptionId -EnvironmentName stage0

.\scripts\Invoke-Stage0.ps1 -Operation Verify `
    -SubscriptionId $subscriptionId -EnvironmentName stage0

.\scripts\Invoke-Stage0.ps1 -Operation Down `
    -SubscriptionId $subscriptionId -EnvironmentName stage0 -WhatIf

.\scripts\Invoke-Stage0.ps1 -Operation Down `
    -SubscriptionId $subscriptionId -EnvironmentName stage0
```

`Up` previews infrastructure before provisioning with `azd`, waits for Arc
registration, configures AMA and the DCR/DCE associations, removes temporary Arc
onboarding permissions, uploads the SRE knowledge document, and reads back its
type, filename, content type, and byte count. The SRE GET API returns metadata,
not the original file bytes; this is not a byte-for-byte read-back. Search/retrieval
is a separate check of indexing, not silently assumed from upload success.
Missing prerequisites and failed mandatory configuration terminate with errors.
Do not substitute bare `azd up`: it provisions the infrastructure but does not run
the wrapper's Arc/knowledge configuration and ownership checks.

`Verify` runs a fixed script **as the deploying operator** through Arc Run Command.
It checks the synthetic worker, IMDS blocking, ingestion and query DNS within the
proof VNet, Arc managed identity authentication, and recent AMA Heartbeat for the
specific Arc machine queried through the private workspace endpoint.
Each invocation uses a fresh Run Command resource, retained in the owned group
as execution evidence until teardown. The latest command ID is recorded locally;
failed verification clears current readiness instead of retaining a stale success.
Ingestion and role propagation take time: a missing heartbeat
is reported as a failed verification, not suppressed. Repeat Verify after those
dependencies become ready.

The SRE Agent itself has read-only permissions and Review mode. A successful
operator verification is not proof that the agent can execute a fixed action with
approval; no such permissions are granted in this stage.

## Ownership, retries, and teardown

The wrapper records an ownership GUID, exact subscription/tenant/group, deployment
outputs, and resource inventory in `.azure\<environment>\retailtx-state.json`.
This folder is ignored by Git. Preserve it until teardown is complete; it is the
authority used to reject accidental adoption or deletion of an unrelated group.
Missing/mismatched live tags or a mismatched manifest fail closed. An exclusive
per-environment file lock prevents concurrent local lifecycle commands. Manifest
and ownership checks are repeated under that lock and immediately before provisioning.

The same `Up` operation can be used after provisioning failures; already-created
infrastructure remains tracked in its owned group. However, cloud-init executes
only on the first boot: a failed host bootstrap is not automatically rerun by an
ARM redeployment. Managed boot diagnostics are enabled without a user-managed
storage account. Inspect them and fix the cause; destroy/recreate
only the owned environment if bootstrap cannot be recovered. Never unblock
public Monitor/Arc access or introduce credentials to conceal a bootstrap failure.

The bootstrap uses its narrowly scoped managed identity to acquire a short-lived
Entra token before disabling the Azure VM guest agent and blocking Azure IMDS.
The Arc installer runs only after IMDS is blocked; its Linux Azure-VM detection
does not accept the evaluation environment variable alone.
The token is never included in Bicep or written to disk by the script. After
connection, the Arc system-assigned identity is the host identity. The onboarding
role is removed after monitoring configuration; if configuration fails earlier,
the role can remain until a successful retry or group teardown.

`Down` prints the live resource inventory, checks ownership and locks, deletes
the disposable group's VM and its Arc registration together, and checks group
absence. It does not disconnect or remove any external host, alter policy, remove
locks, or purge soft-deleted data. Local state and subscription deployment history
remain. Log Analytics deletion/retention follows the Azure service policy.
No scheduled TTL cleanup is installed yet; the final environment remains billable
until explicitly destroyed.

## Deployment evidence and tenant caveats

**Verified on 2026-10-07:** a complete `Up` followed by `Verify` reached
`host-verified-sre-read-only`. The fixed operator check confirmed the active
fixture, blocked Azure IMDS, Arc identity authentication, private ingestion/query
DNS, and a recent heartbeat for the correct Arc machine. A subsequent base
provision reported no changes rather than creating duplicate components.
The onboarding role was removed, workspace local authentication and public
ingestion/query remained disabled, and the knowledge upload metadata matched.
The final proof environment is left running for inspection, not automatically
scheduled for deletion.

The initial Sweden Central deployment exercised real ARM validation and resource
creation, not only Bicep compilation. Both Arc and Monitor private endpoint
connections were approved, and the SRE resource retained its dedicated subnet,
private DNS setting, and Low/Review configuration. The owned group was then
destroyed and an owner-tagged subscription inventory returned no remaining
resources before recreation. Soft-deleted workspace data and deployment records
were not purged.

After recreation with the corrected bootstrap, the Arc machine reported Connected
with its private link scope and system-assigned identity. A bounded, read-only SRE
conversation independently retrieved that machine's Connected status and resource
ID. SRE knowledge search retrieved the uploaded Stage 0 document.

The SRE workspace terminal subsequently queried Heartbeat using its managed
identity: the query endpoint resolved inside the proof VNet and returned the
expected Arc resource's heartbeat. Ask explicitly for **workspace terminal
execution** using installed tools when no specialized Log Analytics query tool
appears; absence of a specialized tool is not proof that private access is
unavailable. Do not substitute a public connector. AMA's first heartbeat took
about 11 minutes after extension enablement in this run; early verification
correctly failed rather than declaring an empty workspace healthy.
AMA installation now depends on both collection associations to avoid beginning
private configuration discovery before its DCE association exists.

These are read-only integration results, not proof of approval-gated healing.

Live deployment exposed issues corrected in this implementation: NSG
`AzurePlatformDNS`/`AzurePlatformIMDS` service tags support Deny rules rather than
the initially attempted Allow rules; and the Arc Linux installer requires IMDS
blocking **before installation**, not only before registration. Neither repair
relaxes private Monitor/Arc access. Same-name workspace recovery also exposed a
table-readiness race. The workspace module now explicitly provisions the built-in
Syslog and Perf table settings before the DCR, without inventing schemas, purging
data, or extending retention.

The target tenant's Guest Configuration policy attempted to install a native
Azure VM extension. That policy deployment failed because extension operations
are intentionally disabled on the Arc evaluation VM. No policy exemptions or
subscription changes were made. This is a known evaluation-host policy conflict,
not evidence of full tenant policy compliance; production hybrid hosts would
not have the duplicate native VM management plane.

## Local checks

```powershell
pwsh -NoProfile -File .\tests\Test-Stage0.ps1
python -m unittest discover -s tests -p 'test_*.py'
bicep build .\infra\main.bicep --outfile .\artifacts\stage0.json
```

The PowerShell and Python checks run without Azure mutations. Infrastructure
preview and live verification are still necessary.

## References

- [SRE Agent network integration](https://learn.microsoft.com/en-us/azure/sre-agent/network-integration)
- [SRE Agent IaC](https://learn.microsoft.com/en-us/azure/sre-agent/deploy-iac)
- [Arc evaluation on Azure VMs](https://learn.microsoft.com/en-us/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)
- [Arc access-token onboarding](https://learn.microsoft.com/en-us/azure/azure-arc/servers/azcmagent-connect)
- [Arc managed identity](https://learn.microsoft.com/en-us/azure/azure-arc/servers/managed-identity-authentication)
- [Arc Run Command](https://learn.microsoft.com/en-us/azure/azure-arc/servers/run-command)

SRE resource/configuration shapes were checked against the official
`microsoft/sre-agent` templates at commit
`25a42306d298c4d28f11dd11ef9bb93cb0393be8`, rather than running their unpinned
deployment scripts. Service-specific typed validation and live API responses
remain authoritative.
