# Standalone GitHub intake caller identity and operator CLI

`infra/github-intake-identity.bicep` is a **subscription-scope** entry point for
only the four caller resources specified by
`scripts.github.federation.specifications()`:

1. UAMI `retailtx-github-intake-<environment>` in the **existing agent RG**.
2. FIC `github-intake`, exact verified subject, GitHub issuer and exchange audience.
3. Subscription-level custom role with that RG as its only assignable scope.
4. One assignment at the **exact existing agent**, never at its RG/subscription.

It does not create the SRE agent, Monitor recovery, investigator configuration,
knowledge, trigger, GitHub environment/settings, or workflow readiness. Integrate
it alongside those independently authorized components. No other lifecycle
wrapper is changed by this implementation.

## Operator commands

Use the full owner-reviewed intake configuration and previously authenticated
repository evidence. Keep both intake gates disabled during setup.

```powershell
# Pure: assets plus deterministic deployment ID/name/location and ARM parameters.
python -m scripts.github.federation bicep-spec --config artifacts\github-intake\config.json --location swedencentral --expires-at "<explicit UTC retention expiry>"

# Authorized setup: Bicep deployment control-plane plus independent ARM GETs.
python -m scripts.github.federation deploy-bicep --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json --repository-evidence artifacts\github-intake\repository.json --location swedencentral --expires-at "<same explicit UTC retention expiry>"

# Independent GET-only validation using the existing manifest contract.
python -m scripts.github.federation check --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json
```

`bicep-spec` does not authenticate, read provider settings, compile Bicep, inspect
state, or make Azure/GitHub calls. Its JSON contains `assets` and `deployment`;
`deployment.parameters` is the ARM name-to-`{value: ...}` map. A parent Bicep
wrapper can consume each `.value` as a module parameter. Pure specification
validation is **not** authenticated repository or workflow OIDC evidence.

`deploy-bicep` requires all five flags shown above plus `--config`. The CLI reuses
the existing exclusive state lock, configuration validation, repository evidence
binding, specifications, durable `persist()`, asset validation, identity binding,
manifest parser and independent `check()` helpers. Python does **not** issue
identity/FIC/custom-role/assignment PUTs: only Azure CLI's subscription deployment
control-plane creates them from the compiled Bicep template.

### Submit-once ownership protocol

On a fresh state path, the command:

1. Checks absence by GET at **all four exact asset paths and the deterministic
   subscription deployment receipt path**. Any collision or inconclusive GET
   blocks creation; no state is minted to adopt existing resources.
2. Durably fsyncs all four exact asset intents as `Requested`, with the existing
   `schemaVersion: 1`, owner token, binding hash and `investigator-read-v1` profile.
   Overall phase is `BicepDeploymentRequested`. A `bicepDeployment` journal records
   ID/name/API version/location/parameters, source SHA-256, its own `Requested`
   phase, and `submissionOutcome: NotSubmitted`. This happens **before even the
   local Bicep build call**.
3. Uses the existing absolute Azure CLI executable, fixed argument arrays,
   `shell=False`, and finite waits. It builds the fixed module with
   `az bicep build --no-restore --stdout` (120 seconds), checks the source did not
   change, and durably records the compiled template hash and SHA-256.
4. Rechecks all five collision paths immediately before submission. It writes
   the frozen compiled JSON and ARM parameter document to a temporary directory
   beside the owner state. Before the one possible submission it fsyncs
   `submissionOutcome: Unknown` as a write-ahead journal marker.
5. Calls `az deployment sub create` exactly once (600-second bound), pinned to
   `config.binding.subscriptionId`, deterministic deployment name, explicit
   location, frozen JSON template and parameters. CLI stdout is never treated as
   resource/readiness evidence. A zero/nonzero return records `ReturnedSuccess` /
   `ReturnedFailure`; a timeout, lost response or launch uncertainty retains
   `Unknown`. Even failure to journal a CLI return proceeds to GET reconciliation
   against the already durable `Unknown` marker.
6. Independently GETs the deployment receipt and all four assets. The receipt's
   ID, location, Incremental mode, exact parameter values and frozen template hash
   must match. Provider-added parameter `type` metadata is ignored, not parameter
   names/values. Matching resource tags alone do not substitute for a frozen
   receipt and a journaled submission.
7. Captures canonical UAMI client/principal/tenant IDs from independent GET
   readback, pins them durably, and substitutes the real principal in the frozen
   assignment intent. Each asset must pass the existing exact ID/body validator.
   It polls pending creation by GET for up to 120 seconds; drift, missing previously
   verified resources, or changed pinned identity IDs fail closed.
8. Only a `Succeeded` matching deployment receipt plus four independently verified
   assets can produce `ConfiguredOidcUnverified` and a `Verified` deployment
   journal. The existing independent `check()` runs again. If that final check
   fails, the overall/deployment phases return to pending reconciliation.

The final state has the same ordered four assets and real identity IDs consumed
by existing `check` and `down`, plus the deployment journal. It is **not** runtime,
knowledge-retrieval or actual workflow OIDC proof.

### Uncertainty, retries and no adoption

Repeat the **same** `deploy-bicep` command with the **same** frozen config, state,
evidence, location and expiry to reconcile. For an existing owned Bicep intent,
it does **not** compile, read the current Bicep source, issue another deployment,
or perform resource PUTs. The CLI still acquires the operator ARM token for GETs.
Changed specs, binding hash, role profile, deployment intent, identity IDs or
removed states are rejected. There is no blind replay or automatic recreation.

A failed/canceled deployment stays pending even if some or all assets exist.
Missing receipt/assets, nonzero CLI status and timeouts do not imply absence or
permission to redeploy. Preserve the original state and deployment operation
history. The command must not turn manually created matching assets into owned
resources.

If compilation/storage failed **before** submission, the persisted
`NotSubmitted` intent likewise cannot be automatically replayed or imported.
A repeated command GET-inspects the paths, then reports that no submission was
journaled. This conservative crash boundary requires separate owner-reviewed
resolution; do not delete the journal to force another deployment. There is no
force/adopt/retry-write option.

Legacy `configure` rejects Bicep-owned states, even completed ones, rather than
falling back to Python asset PUTs. `check` rejects the pending overall phase.
Default `down` rejects an incomplete Bicep deployment, avoiding deletion while
creation may still be running. Owner-authorized `down --allow-failed-bicep` adds
only the terminal/local-no-dispatch cleanup path described below; it never
fabricates a verified deployment or permits automatic resubmission.

**Parent integration:** invoke this CLI for a fresh, absent caller before manually
creating its resources. If the parent already deployed the caller independently
without this journal, `deploy-bicep` deliberately rejects the collisions. It is
not a general import/adoption command. Retained Python manifests, explicit subject
transitions and role transitions are not silently migrated to this lifecycle.

## Inputs, UUIDv5 and OIDC subjects

All eleven Bicep inputs are mandatory. The CLI derives them from the full trusted
configuration and `specifications()`:

- `environment`, `location`, `ownerToken`, `agentId`, `repository`, `repositoryId`,
  `repositoryOwnerId`, `verifiedOidcSubject`, `expiresAt`;
- `roleDefinitionName`, `roleAssignmentName`: final UUID segments from the exact
  Python role/assignment IDs.

Bicep `guid()` uses a fixed namespace and cannot reproduce Python's arbitrary
owner-token UUIDv5 namespace. The CLI therefore uses the existing specifications
as the sole source of these two names. Do not change UUID namespaces, normalize
resource ID case, or substitute random names.

The subscription deployment name is `gh-intake-<environment>-<uuid5.hex>`, where
that UUID is `uuid5(ownerToken, "github-intake-bicep:" + agentId)`. It fits Azure's
64-character name limit even at the maximum supported environment length. This
extra deployment ID is not one of the four federation-owned asset IDs.

Only the exact verified classic or immutable forms are supported, verbatim:

- `repo:<owner>/<repo>:environment:sre-github-intake`
- `repo:<owner>@<ownerId>/<repo>@<repoId>:environment:sre-github-intake`

The Azure environment identifier is distinct from the fixed GitHub environment.
The evidence must be authenticated repository GET data with matching `full_name`,
repository ID, owner login and **repository owner's** ID, never issue-actor data.
Retain independent provider OIDC-settings and actual login/subject evidence.

The Bicep module uses exact allowlist-index lookups for the subject and agent ID.
Unsupported subjects or IDs outside the deployment subscription cannot resolve to
a wider scope/alternate subject. Decorators are not a replacement for the CLI's
full canonical UUID, regex, UTC expiry and repository binding validation. Invalid
Bicep parameters can still leave partial resources; preflight must precede writes.

## Outputs and teardown

Bicep outputs include identity/FIC/role/assignment IDs, client/principal/tenant IDs,
`roleProfile`, `ownerBinding`, and ordered Python-compatible `federationAssets`.
They describe expected intent plus provider identifiers, **not** pre-verified
ownership. The CLI does not import outputs as proof: independent GET validation
produces the manifest. The full binding hash comes from
`federation.binding_hash(config)`, never an approximation of the Bicep inputs.

For a completed verified state, the existing separately authorized inverse is:

```powershell
python -m scripts.github.federation down --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json
```

It GET-validates ownership, then deletes assignment, role, FIC and UAMI in that
order. Removing an Incremental deployment record does not delete those assets.
The deployment journal and subscription/RG deployment records are retained;
existing federation teardown does not delete the records. Any later record
cleanup requires separately scoped authorization. A `Removed` state cannot be
reused by `deploy-bicep` for recreation.


### Explicit failed-Bicep cleanup

Only the owner may authorize this opt-in inverse. The parent wrapper may map its
optional `-CleanupFailedGitHub` Down switch to this exact CLI flag; no wrapper
file is changed here:

```powershell
python -m scripts.github.federation down --allow-failed-bicep --config artifacts\github-intake\config.json --state artifacts\github-intake\federation.json
```

Default `down` remains fail-closed for incomplete Bicep journals. The flag is
valid **only** with `down`; passing it to another command fails before token
acquisition. Successful deployments and legacy manifests retain normal teardown
behavior. Normal teardown is repeatable after an identity or role DELETE whose
response was lost; already absent verified assets do not force recreation.

For an incomplete Bicep state, explicit cleanup checks the existing exact manifest
and the saved deployment ID/name/API version/location, complete parameters,
source SHA-256 and ownership profile against the pure plan. It then independently
GETs the receipt and all four assets. Only these two proofs permit cleanup:

- **Terminal deployment:** a receipt with the saved exact binding, parameters and
  frozen template hash, whose provisioning state is **Failed or Canceled**.
  The saved compiled-template SHA-256 must also exist. A CLI failure, timeout or
  nonzero return is not a terminal receipt. Requested resource absence may be
  claimed only after this proof, including on retries after DELETE.
- **Local no-dispatch:** the saved `NotSubmitted` marker proves the dispatch WAL
  was never reached, the exact deployment GET is 404, and **all four assets are
  absent**. This includes pre-submission compiler failures. Any present resource,
  even with matching expected tags/properties, is an unowned late collision and
  blocks cleanup; this branch performs no DELETEs. A bare 404 after `Unknown`,
  `ReturnedFailure`, or `ReturnedSuccess` is **not** local no-dispatch proof.

In-progress, unrecognized, succeeded or missing-after-dispatch receipts are
rejected. Parameters/template drift, uncertain GETs, foreign assets, broad roles,
changed identity IDs and active resource provisioning are rejected before any
DELETE. Every present asset must match the exact saved ID/body. Terminal failed
resource provisioning (`Failed`/`Canceled`) may be accepted **only in this cleanup
path**, provided the complete owned shape and canonical identity IDs are intact;
ordinary validation still requires `Succeeded`. An assignment without retained
identity IDs or an independently readable owned identity is not deleted by
trusting its principal alone.

Before any DELETE, the command durably saves `failedBicepCleanup` with explicit
authorization, the complete original pre-cleanup state, frozen deployment and
four asset readbacks, proof type, and any real identity binding/readback. This
failure evidence is preserved on retries, including after identity/role removal.
It validates all present assets before deleting assignment, role, FIC, identity in
inverse order. All four final absence GETs must succeed before overall `Removed`.

The `bicepDeployment` journal is **not** changed to `Verified`; neither are
Requested asset phases. The original failure/intent remains in the journal's
`before` snapshot. No fabricated `ConfiguredOidcUnverified` state is created.
Repeat failed cleanup with the same flag and frozen config; retries revalidate
current terminal/no-dispatch proof and original evidence. Deployment records and
the owner manifest are retained, not deleted. The flag does not authorize
cancellation, import, source/hash replacement or redeployment.

### Subscription-scope resource-ID correction and frozen journals

The module uses the explicit four-argument overload for its RG-bound identity
ID and exact-agent allowlist:

```bicep
resourceId(subscription().subscriptionId, agentGroup.name, '<resource-type>', '<name>')
```

The previous RG-only overload compiled but, at subscription deployment scope,
ARM interpreted the leading RG name as a subscription identifier. The parent
reported pure validation `InvalidTemplate` at `variables.identityId` and exact
deployment GET 404. Compilation alone did not catch that overload error. New
compiled-expression tests apply offline subscription-scope overload semantics,
verify both IDs against the Python specifications, and demonstrate the old
expression's invalid-subscription failure. These are not live ARM validation.

The corrected source has a **different hash**. Existing journals remain frozen
against the old source/compiled hashes. A previously dispatched
`Requested` / `ReturnedFailure` journal with deployment GET 404 remains uncertain:
GET-only reconciliation cannot replace its template hash, redeploy, or call it
`NotSubmitted`; `--allow-failed-bicep` also rejects it. Do not delete or rewrite that
journal to retry the corrected module. A separately designed and explicitly
authorized recovery is required. The parent should report this caller live gate
as blocked rather than automatically redeploying. No live journal was read or
modified, and no live Azure call was made by this implementation session.

## Implementation and permission findings

- AVM UAMI `0.6.0` is pinned, consistent with existing modules, with telemetry off.
  Its identity/FIC creation API is `2024-11-30`; Python GET/manifest versions remain
  `2023-01-31`. Ownership validation compares IDs, tags and properties, not PUT
  API versions.
- Subscription role IDs and RG agent-scoped assignments cannot both be directly
  deployed as typed resources at one Bicep scope (BCP139). To keep the module
  standalone, the role is typed Bicep and the assignment is a tiny inline RG ARM
  deployment **declared in Bicep**, with inner-scope parameters and `json()` to
  preserve ARM expressions. Dependencies include the role and AVM identity/FIC
  deployment. No additional local Bicep file is needed.
- `investigator-read-v1` remains exactly `agents/read` plus data actions
  `agents/threads/read`, `agents/threads/write`, `agents/extendedagents/read`, with
  empty exclusions. Thread creation supports proposal-only investigation. No
  repair, approval, configuration-write, deletion or broad built-in role is added.
- The documented narrow-read issue may still block live use. **SRE Agent Standard
  User is not added.** No permission broadening or live-readiness claim follows
  from deployment success.
- `expiresAt` remains only the caller identity retention tag, not an automatic
  expiry/cleanup policy. Existing retained resource tags are not changed.
- Private config, evidence, state, template/parameter documents and provider
  history must remain in ignored owner-only storage. Do not commit them or tokens.
  The temporary template/parameter directory is removed when the CLI call exits.

## Local validation only

```powershell
az bicep build --file infra\github-intake-identity.bicep --no-restore --stdout
bicep lint infra\github-intake-identity.bicep --no-restore
python -m pytest tests\test_github_federation_bicep.py tests\test_github_intake_identity_bicep.py tests\test_github_federation.py -q
```

The orchestration tests mock all subprocess/API calls, including CLI dispatch and
locking. They cover durable pre-call intents, both absence preflights, every
collision type, uncertain/nonzero/lost responses, partial creation, pinning,
receipt/spec drift, no-replay recovery, pending-schema safety, storage failures,
independent check and exact inverse teardown. Cleanup regressions cover terminal
and no-dispatch proofs, unknown/missing receipts, drift, all-assets-before-delete,
retained failure evidence, failed resource provisioning, lost DELETE responses,
normal repeated teardown, storage failures and CLI flag/locking. The
compiled-contract tests use
existing local tooling/cached AVM only. No installation, module restore, Azure
login, live deployment or provider-side permission validation was performed by
this implementation session.
