# Local transaction and recovery slice

This is the Stage 1 **local-only** implementation. It does not deploy to Azure,
modify the retained foundation, establish Arc application identity, or prove an
approval-gated SRE action. Only synthetic transactions are supported.

## Prerequisites and quick start

Use PowerShell 7, Docker Compose with Linux containers, and Python 3.11-3.13
for the host-side acceptance runner. Allow approximately 6 GB of available
container memory and several GB of disk space. The official Service Bus emulator
also needs SQL Server Linux; that is its internal dependency, **not** a third
application database.

Read the [Service Bus emulator license][emulator-license] and
[SQL Server Linux license][sql-license] before passing `-AcceptEmulatorEula`.
Initialization creates an ignored `.env.retailtx-demo01` with random local
database passwords. Nothing is written to Azure and no Azure login is needed.
Do not commit or share this file or run `docker compose config` without `--quiet`
when capturing output: rendered configuration contains local passwords.

```powershell
.\scripts\Invoke-Local.ps1 Init -AcceptEmulatorEula
.\scripts\Invoke-Local.ps1 Up
.\scripts\Invoke-Local.ps1 Doctor
.\scripts\Invoke-Local.ps1 Scenario -DurationSeconds 120
.\scripts\Invoke-Local.ps1 Load -Seed demo01 -Count 12
Invoke-RestMethod http://127.0.0.1:8000/reconciliation
.\scripts\Invoke-Local.ps1 Reset
.\scripts\Invoke-Local.ps1 Down -PurgeData
```

Wait for the poster's `worker_state` to become `paused` before submitting the
dataset if exact stopped-worker totals are needed. At most one already-received
message may finish when a pause is requested. `Status` shows containers; `Doctor`
checks both databases through API health, the poster heartbeat, fault state,
blocked outbox rows, the dead-letter queue, and reconciliation freshness.
Readiness does not mean backlog is zero. `Reset` explicitly waits for zero
unposted transactions as well as healthy dependencies, or fails after 120 seconds.

The checkout API is published only on `127.0.0.1:8000`; its OpenAPI UI is `/docs`.
The ERP, databases, and broker have no published host ports. Containers use an
internal Compose network and non-root application processes. Only `cap-api` also
joins a frontend bridge for loopback port publication. The application
APIs deliberately use unauthenticated HTTP **inside this isolated local fixture**.
Do not expose it on a LAN or reuse this configuration for Azure or production.
The emulator's documented `SAS_KEY_VALUE` is a placeholder, not an Azure key.
The code requires `RETAILTX_MODE=local` and rejects a cloud broker hostname.

Use another `-ProjectName retailtx-demo02` and `Init -Port 8001` for an independent
instance. Always repeat that project name in subsequent commands. Operations and
volumes are scoped to the selected Compose project. The project-specific
environment file is retained after teardown so a retained database remains
accessible. Reusing an environment ID is not a new dataset: change `-Seed` to
generate different transaction IDs.

If an organization requires an approved package mirror, set
`RETAILTX_PACKAGE_INDEX` to its HTTPS index before building. Hash verification
remains enabled. Do not put authenticated index URLs in build arguments; use your
organization's credential-safe build mechanism instead. No TLS bypass is needed.

## Implemented shape

```text
pos-sim -> cap-api -> HTTP price lookup -> erp-core -> erp-db
              |
              +-> cap-db: accepted transaction + outbox (one commit)
                       |
                 outbox-publisher -> IDOC_POSTING -> erp-poster
                                                        |
                                               HTTP ledger commit -> erp-db

recon-job -> cap-db snapshot + paginated ERP ledger lookup -> fresh/stale/unknown report
```

The shared, versioned `retailtx` Python package is under `app/retailtx`; each
component has its own process/module. This avoids duplicating message contracts,
money handling, migrations, and telemetry across component directories.
`sim/pos_sim.py` generates bounded load. `chaos/backlog.py` manages the reversible
local posting pause. Base images are pinned by digest, Python dependencies by
version and SHA-256 hash in `requirements-dev.lock`, and database migrations by
stored checksum. The local image includes verification tools; it is not a
production/Azure application image or release pipeline.

### Acceptance and exact money

`POST /transaction` accepts a stable UUID, one of four countries, one of two
brands, a catalog SKU, and an integer quantity from 1 to 100. The price is read
from ERP rather than trusted from the caller. It stores EUR as integer cents;
decimal EUR strings are presentation only. Floating point, boolean quantities,
unknown dimensions, extra fields, and oversized request bodies are rejected.

The API returns `202` **after** the accepted transaction and outbox entry commit
atomically. It means durable acceptance, not ERP posting. Repeating an identical
request returns the original accepted price and amount, even if ERP is now down.
Reusing its ID for a different request returns `409`. Database uniqueness also
handles concurrent duplicates.

The deterministic 12-transaction dataset totals **4,848 cents / EUR 48.48**:

| Country | Transactions | Unposted cents while poster is stopped | EUR |
| --- | --- | --- | --- |
| NL | 5 | 1,494 | 14.94 |
| BE | 4 | 2,409 | 24.09 |
| DE | 2 | 630 | 6.30 |
| FR | 1 | 315 | 3.15 |

NL and BE dominate the initial signal, but the shared worker affects all four
countries. Each country is additionally split into the bounded `market` and
`fresh` brands. There is no real store/customer data, payment integration, tax,
FX conversion, or claim that unposted sales are lost revenue.

### Publish, post, retry, and recover

| Boundary | Behavior |
| --- | --- |
| Acceptance fails before commit | Neither accepted record nor outbox survives |
| Acceptance response is lost after commit | Same ID returns the existing transaction; no second outbox row |
| Publisher dies after sending but before updating the outbox | Database row lock rolls back; retry can enqueue a duplicate |
| ERP fails before its ledger commit | Message is not completed |
| ERP commits but HTTP response/completion is lost | Message redelivers; identical ledger ID/data is successful, not a second posting |
| Changed data uses an existing ledger ID | `409`, explicit dead letter, and reconciliation refuses mismatched evidence |
| Broker loses previously acknowledged messages | Operator replays accepted-but-not-posted rows from the retained outbox |

The publisher claims one row with `FOR UPDATE SKIP LOCKED` and holds that lock
across a bounded send. A successful send is recorded as `sent`; it is **not**
end-to-end completion. Service Bus SDK retries are bounded. Persisted send
failures back off up to 30 seconds and block after eight attempts. An initial
connection outage is retried by the worker with capped backoff without discarding
pending rows. A blocked row is an explicit readiness failure.

The single poster uses peek-lock receive, no prefetch, a 30-second message lock,
and completes only after the ERP response confirms the exact committed posting.
It checks ERP health before receiving during an outage. Transient processing
failures abandon with a delay; five broker deliveries exhaust to the DLQ.
Invalid messages and ledger conflicts are immediately dead-lettered.
This is **at-least-once transport with an idempotent financial effect**, not
exactly-once messaging. Broker duplicate detection is deliberately disabled so
tests exercise the database invariant.

The [emulator does not retain messages across restart][emulator-overview].
The retained outbox is therefore never deleted just because a send succeeded.
After broker recreation, a blocked send, or exhausted deliveries:

```powershell
.\scripts\Invoke-Local.ps1 Replay
.\scripts\Invoke-Local.ps1 Reset
```

`Replay` requires live ERP evidence, compares immutable posting data, and requeues
only observed unposted accepted transactions. A posting racing that observation
can cause a harmless duplicate. Replay writes a durable recovery event; running
it on a drained estate requeues zero. It also marks fully verified ledger postings
`confirmed` in the outbox, with an audited timestamp. This resolves even a blocked
final send whose acknowledgement was lost but whose message reached ERP.
Only explicit matching IDs from the observation are confirmed; a sequence
watermark alone is not delivery evidence. It does not fabricate accepted transactions
from arbitrary dead-letter payloads, or silently clear the DLQ.

Inspect up to 100 dead letters without consuming them:

```powershell
docker compose --env-file .env.retailtx-demo01 -f compose.local.yaml run --rm --no-deps tools python -m retailtx.runtime dead-letters
```

Review poison/conflicting records before resetting a disposable test environment.
`Doctor` continues to fail while a DLQ entry remains, even if valid accepted
transactions have been recovered. Purging test data is explicit `Down -PurgeData`,
not the normal business recovery path.

### Honest reconciliation

Every five seconds the job takes a PostgreSQL repeatable-read snapshot of accepted
records. It keyset-pages in batches of 100 and asks ERP for precisely those IDs,
comparing the entire immutable posting rather than just counts or summed amounts.
It records its sequence watermark, observation start/completion, last success,
expected lag, unposted count/cents, oldest age, and country/brand breakdown.

ERP postings are append-only through the application. The separate ERP page
reads form an **observation interval**, not a cross-database atomic snapshot.
A posting during the scan may be reflected on this or the next pass. Newly
accepted transactions after the CAP snapshot belong to the next pass, including
late commits below a previous sequence watermark. This implementation rescans
accepted history with bounded database/HTTP pages; it is designed for the local
synthetic dataset, not unbounded production history.

`GET /reconciliation` returns:

- `fresh`: `current` has the observed business totals.
- `stale`: `current` is `null`; `last_success` and its timestamp are explicitly
  historical. This occurs on an unsuccessful scan or after 30 seconds without
  a fresh observation.
- `unknown`: no successful observation exists; `current` and `last_success` are
  `null`, even if CAP currently has no transactions.

An unavailable ERP is not zero posted sales or zero unposted sales. Mismatched,
duplicate, or unrequested ERP IDs also invalidate the observation. An unavailable
CAP database causes a dependency error rather than a success-shaped report.
The watermark is a snapshot boundary, not an exactly-once incremental cursor.

### Fault and telemetry boundaries

The bounded `backlog` button **cooperatively stops consumption**, keeping the
poster process alive to enforce expiry and heartbeat. It stores a reversible
marker in ERP with a maximum duration of 300 seconds; it does not corrupt service
configuration or stop checkout. The worker observes expiry using database time
and resumes independently of the injecting shell. `--undo` is idempotent.
An already-in-flight transaction may finish. The acceptance runner separately
uses actual `docker compose stop/start erp-poster` to prove process-stop recovery.

Direct undo and independent process recovery:

```powershell
docker compose --env-file .env.retailtx-demo01 -f compose.local.yaml run --rm --no-deps tools python chaos/backlog.py --undo
docker compose --env-file .env.retailtx-demo01 -f compose.local.yaml start erp-poster
```

Timestamped `backlog.inject`, `backlog.expired`, and `backlog.undo` events persist
in ERP and appear in JSON logs. Financial transactions and recoveries likewise
emit structured evidence. OpenTelemetry spans propagate W3C trace context through
HTTP, the persisted outbox, and message properties. For local verification, the
SDK exports JSON spans to bounded Docker logs; no second observability service,
Azure exporter, Azure alert, or SRE integration is configured.

Country/brand-dimensioned `checkout.attempt` duration/success events provide raw
latency, error numerator, and request denominator evidence;
calculate p95 from individual durations, never averages of percentiles.
Transaction/trace IDs correlate evidence, not metric dimensions. Country and
brand are bounded. `reconciliation.observed` is the local business metric source;
it is not a claim that an Azure custom metric has been ingested.

## Verification

Create a separate test project and port. `Verify` intentionally truncates only
its local synthetic tables/queues and refuses non-`retailtx-test-*` projects.
Do not run it against a demonstration whose state you want to retain, and do
not run load or other lifecycle commands concurrently.

```powershell
.\scripts\Invoke-Local.ps1 Init -ProjectName retailtx-test-demo01 -Port 18080 -AcceptEmulatorEula
.\scripts\Invoke-Local.ps1 Up -ProjectName retailtx-test-demo01
.\scripts\Invoke-Local.ps1 Verify -ProjectName retailtx-test-demo01
.\scripts\Invoke-Local.ps1 Down -ProjectName retailtx-test-demo01 -PurgeData
```

The first phase runs unit and integration tests against PostgreSQL, HTTP, and
the real emulator, with background workers stopped to control commit/ack
boundaries. It exercises transaction rollback, concurrent idempotency,
ambiguous send/ERP response/completion, real lock expiry/redelivery, bounded
retry, poison/conflict DLQ, multi-page reconciliation, stale/unknown evidence,
fault expiry/undo, and broker trace propagation. Injected boundary failures
are distinguished from actual container kills.

The host-side second phase restarts workers and verifies actual poster stop/start,
the exact known dataset, stale evidence during a real ERP API outage, persistence
after restarting both PostgreSQL containers, queue loss after emulator restart,
explicit replay, complete accepted-versus-ledger equality, healthy empty DLQ,
and a trace spanning HTTP -> outbox -> broker -> ERP with parent links.
Failure exits nonzero and attempts independent fault cleanup; it never deletes
business data just to make a failed gate pass.

For fast development without containers:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install --require-hashes -r requirements-dev.lock
.\.venv\Scripts\python.exe -m pip install --no-deps --no-build-isolation -e .
.\.venv\Scripts\python.exe -m pytest -q -m "not integration"
.\.venv\Scripts\python.exe -m ruff check app sim chaos tests\local
.\.venv\Scripts\python.exe -m mypy
```

Regenerate the lock with uv 0.12.21:
`uv pip compile pyproject.toml --group dev --universal --generate-hashes --no-header --output-file requirements-dev.lock`.
Retain SHA-256 hashes only if a package mirror also emits legacy MD5 hashes.
Rebuild the images after source changes. `Up` can be repeated: migrations verify
checksums and prices are seeded once, not duplicated.

### Recorded local acceptance evidence

Verified on 2026-10-07 with Windows, Docker Desktop's Linux engine, PostgreSQL
17.7, and the official Service Bus emulator 2.0.1 (pinned image digests in Compose):

| Check | Observed outcome |
| --- | --- |
| Unit and real-stack integration suite | 34 tests passed, including real broker lock expiry and deferred PostgreSQL commit failure |
| Actual poster container stopped; 12 checkouts submitted twice | Exactly 12 accepted, zero posted, EUR 48.48 unposted with the country totals above |
| Poster container resumed | Exactly 12 ledger entries; EUR 0.00 unposted |
| ERP API container stopped | `stale`, `current: null`, timestamped last-success evidence retained |
| Both PostgreSQL containers and emulator restarted with 12 further messages in flight | All 24 accepted records and the first 12 postings survived; missing emulator messages required replay |
| Explicit replay after restart | Exactly the 12 unposted transactions requeued; 24 accepted payloads exactly equalled 24 ledger payloads; no duplicate postings |
| Final send acknowledgement lost after retry exhaustion | Matching posted record became audited `confirmed` outbox state without re-enqueue or manual repair |
| Trace evidence | Same trace across checkout, ERP price HTTP call, outbox, broker consume, ERP posting HTTP call; producer/consumer parent links matched |
| Bounded local fault | Pause observed; automatic expiry and repeated undo succeeded; no caller remained running to enforce expiry |
| Lifecycle | Fresh creation and repeated `Up` passed; repeated `Down -PurgeData` left zero owned containers, volumes, or networks |

Strict Python type checking, lint, a local staged-diff secret scan, and the nine
pre-existing Arc-verifier unit tests also passed. The GitHub-hosted secret-scan
tool was unavailable because Advanced Security is not enabled; the local scan
was used instead, without changing repository security settings.

These are local correctness results, not evidence of Azure IAM, private routing,
Application Insights ingestion, or SRE approval/execution. The emulator remains
non-durable, and this version intentionally requires explicit replay following
its restart. The test suite currently emits one upstream Starlette deprecation
warning for its supported HTTPX test-client compatibility path.

## Retention and teardown

`Down` removes this project's containers and network while retaining PostgreSQL
volumes. It lists retained volumes and warns that emulator messages are gone.
After a retained-data restart, run `Replay` then `Reset`. `Down -PurgeData`
explicitly deletes this project's named/anonymous volumes too; repeating it is
safe. Images and the ignored local credential file remain as local artifacts.
No retained Azure resource, Azure ownership manifest, or Azure lifecycle script
is read or changed by these commands.

## Sources and limits

- [Official emulator setup][emulator-setup]: SQL dependency, EULA, static
  emulator-only connection string, AMQP and health endpoint.
- [Emulator limitations][emulator-overview]: local behavior is not cloud durability,
  scale, networking, or identity proof.
- [Psycopg transaction contexts][psycopg-transactions]: commit on normal context
  exit; rollback on exceptional exit.
- [Azure Service Bus Python SDK][servicebus-sdk]: peek-lock settlement and bounded
  SDK operations; application idempotency is still required.
- [OpenTelemetry propagation][otel-propagation]: W3C trace context carriers.

The Azure application rollout, authentication/TLS adapters, managed identity,
private connectivity, Application Insights ingestion, static alerts, CI/release,
and approved SRE healing remain later integration gates.

[emulator-license]: https://github.com/Azure/azure-service-bus-emulator-installer/blob/main/EMULATOR_EULA.txt
[sql-license]: https://go.microsoft.com/fwlink/?LinkId=746388
[emulator-setup]: https://learn.microsoft.com/en-us/azure/service-bus-messaging/test-locally-with-service-bus-emulator
[emulator-overview]: https://learn.microsoft.com/en-us/azure/service-bus-messaging/overview-emulator
[psycopg-transactions]: https://www.psycopg.org/psycopg3/docs/basic/transactions.html
[servicebus-sdk]: https://github.com/Azure/azure-sdk-for-python/tree/main/sdk/servicebus/azure-servicebus
[otel-propagation]: https://opentelemetry.io/docs/languages/python/propagation/
