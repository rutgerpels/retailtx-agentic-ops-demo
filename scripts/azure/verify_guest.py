"""Live private application checks executed inside the owned cloud host."""

import argparse
import json
import ssl
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from datetime import UTC, datetime, timedelta
from http.client import RemoteDisconnected
from pathlib import Path

from guest_transport import private_addresses, token


class ReadinessPending(RuntimeError):
    pass


def context() -> ssl.SSLContext:
    tls = Path("/etc/retailtx/tls")
    result = ssl.create_default_context(cafile=str(tls / "ca.crt"))
    result.load_cert_chain(tls / "host.crt", tls / "host.key")
    return result


def read_json(url: str) -> dict:
    with urllib.request.urlopen(url, context=context(), timeout=10) as response:
        return json.load(response)


def require_client_certificate(host: str) -> None:
    unauthenticated = ssl.create_default_context(cafile="/etc/retailtx/tls/ca.crt")
    try:
        with urllib.request.urlopen(
            f"https://{host}:8443/health", context=unauthenticated, timeout=10
        ):
            raise RuntimeError("Application accepted HTTPS without a client certificate")
    except RemoteDisconnected:
        return
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, ssl.SSLError) and exc.reason.reason in {
            "TLSV13_ALERT_CERTIFICATE_REQUIRED",
            "SSLV3_ALERT_HANDSHAKE_FAILURE",
        }:
            return
        raise


def query(config: dict, kql: str) -> list:
    private_addresses("api.loganalytics.io")
    request = urllib.request.Request(
        f"https://api.loganalytics.io/v1/workspaces/{config['workspaceId']}/query",
        data=json.dumps({"query": kql}).encode(),
        headers={
            "Authorization": f"Bearer {token('cloud', 'https://api.loganalytics.io')}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        document = json.load(response)
    if document.get("error") or not document.get("tables"):
        raise RuntimeError("Workspace query returned incomplete evidence")
    return document["tables"][0]["rows"]


def host_posture(config: dict) -> dict:
    if not Path("/var/lib/retailtx/bootstrap-complete").is_file():
        raise RuntimeError("Host bootstrap completion marker is missing")
    for unit in ("ssh.service", "ssh.socket"):
        result = subprocess.run(
            ["systemctl", "is-active", "--quiet", unit], check=False, timeout=10
        )
        if result.returncode not in {3, 4}:
            raise RuntimeError(f"SSH exposure check failed for {unit}")
    evidence = {"role": config["role"], "ssh": "inactive"}
    if config["role"] == "dc":
        for address in ("169.254.169.254", "169.254.169.253"):
            subprocess.run(
                ["iptables", "-C", "OUTPUT", "-d", address, "-j", "REJECT"],
                check=True,
                timeout=10,
            )
        enabled = subprocess.run(
            ["systemctl", "is-enabled", "walinuxagent"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        active = subprocess.run(
            ["systemctl", "is-active", "--quiet", "walinuxagent"], check=False, timeout=10
        )
        if enabled.stdout.strip() not in {"disabled", "masked"} or active.returncode != 3:
            raise RuntimeError("The Arc evaluation host still has an active Azure guest agent")
        evidence.update(azure_imds="blocked", azure_guest_agent="disabled and inactive")
    return evidence


def report(config: dict, accepted: int | None = None, cents: int | None = None) -> dict:
    deadline = time.monotonic() + 180
    last = {}
    while time.monotonic() < deadline:
        last = read_json(f"https://{config['capHost']}:8443/reconciliation")
        current = last.get("current")
        if (
            last.get("status") == "fresh"
            and isinstance(current, dict)
            and (accepted is None or current["accepted_count"] == accepted)
            and (cents is None or current["unposted_cents"] == cents)
        ):
            return current
        time.sleep(3)
    raise ReadinessPending(f"Expected fresh reconciliation evidence was not observed: {last}")


def doctor(config: dict) -> dict:
    from retailtx.db import connect
    from retailtx.settings import Settings

    addresses = {
        name: private_addresses(name)
        for name in (
            config["capHost"],
            config["erpHost"],
            config["postgresHost"],
            f"{config['storageAccount']}.blob.core.windows.net",
            config["runtimeEnv"]["BROKER_NAMESPACE"],
        )
    }
    for host in (config["capHost"], config["erpHost"]):
        result = read_json(f"https://{host}:8443/health")
        if result.get("status") != "healthy" or result.get("mode") != "azure":
            raise ReadinessPending("Azure application health evidence is incomplete")
        require_client_certificate(host)
    worker = read_json(f"https://{config['erpHost']}:8443/worker")
    if (
        worker.get("alive") is not True
        or worker.get("paused")
        or worker.get("worker_state") != "running"
    ):
        raise ReadinessPending("Posting worker is not running")
    with connect(Settings.from_env().cap_dsn) as connection:
        row = connection.execute(
            "SELECT count(*) AS count FROM outbox WHERE state = 'blocked'"
        ).fetchone()
        privileges = connection.execute(
            "SELECT rolsuper, rolcreaterole, rolcreatedb, "
            "pg_has_role(current_user, 'azure_pg_admin', 'MEMBER') AS azure_admin, "
            "has_schema_privilege(current_user, 'public', 'CREATE') AS schema_create "
            "FROM pg_roles WHERE rolname = current_user"
        ).fetchone()
    if row is None or row["count"] != 0:
        raise ReadinessPending("Blocked outbox entries prevent readiness")
    if privileges is None or any(privileges.values()):
        raise RuntimeError("Runtime database role retains schema or administrator privileges")
    current = report(config)
    # This is a transport/authentication check, not just a DNS assertion.
    credential = token("cloud", "https://ossrdbms-aad.database.windows.net")
    if not credential:
        raise RuntimeError("Managed identity did not issue a database token")
    return {
        "private_addresses": addresses,
        "mutual_tls": "authenticated; requests without a client certificate rejected",
        "reconciliation": current,
        "worker": worker,
        "database_runtime_privileges": "no schema creation or administrator membership",
        "checked_at": datetime.now(UTC).isoformat(),
    }


def telemetry(config: dict) -> dict:
    environment = config["environment"]
    # Environment identifiers are validated before provisioning and never arbitrary KQL.
    if not environment.isalnum():
        raise ValueError("Invalid environment identifier")
    rows = query(
        config,
        f"AppTraces | where TimeGenerated > datetime({config['installedAt']}) "
        "| where TimeGenerated > ago(10m) and AppRoleName == 'recon-job' "
        f"| where tostring(Properties.environment_id) == '{environment}' "
        "| extend Event=tostring(Properties.event) "
        "| where Event in ('reconciliation.observed', 'reconciliation.freshness') "
        "| summarize arg_max(TimeGenerated, *) by Event "
        "| project Event, tostring(TimeGenerated), tostring(Properties.observed_at), "
        "tostring(Properties.status)",
    )
    evidence = {row[0]: row for row in rows}
    earliest = datetime.now(UTC) - timedelta(minutes=5)
    for name in ("reconciliation.observed", "reconciliation.freshness"):
        row = evidence.get(name)
        if row is None or datetime.fromisoformat(row[1]) < earliest:
            raise ReadinessPending("No recent authenticated reconciliation telemetry")
    if (
        datetime.fromisoformat(evidence["reconciliation.observed"][2]) < earliest
        or evidence["reconciliation.freshness"][3] != "fresh"
    ):
        raise ReadinessPending("Latest reconciliation telemetry is stale or unhealthy")
    heartbeat = query(
        config,
        "Heartbeat | where TimeGenerated > ago(30m) "
        f"| where _ResourceId =~ '{config['arcMachineId']}' | take 1",
    )
    if not heartbeat:
        raise ReadinessPending("No recent Arc AMA heartbeat")
    return {"recent_reconciliation_events": rows, "arc_heartbeat": True}


def backlog(config: dict, seed: str, baseline_accepted: int, baseline_posted: int) -> dict:
    uuid.UUID(seed)
    stopped = report(config, accepted=baseline_accepted + 12, cents=4848)
    if stopped["posted_count"] != baseline_posted:
        raise RuntimeError("Stopped poster unexpectedly committed new postings")
    country_totals = {}
    for bucket in stopped["by_country_brand"]:
        country_totals[bucket["country"]] = (
            country_totals.get(bucket["country"], 0) + bucket["unposted_cents"]
        )
    if country_totals != {"NL": 1494, "BE": 2409, "DE": 630, "FR": 315}:
        raise RuntimeError("Per-country backlog totals differ from the fixed dataset")
    return {"seed": seed, "stopped": stopped, "country_cents": country_totals}


def traces(config: dict, seed: str) -> dict:
    uuid.UUID(seed)
    environment = config["environment"]
    if not environment.isalnum():
        raise ValueError("Invalid environment identifier")
    transactions = [
        str(uuid.uuid5(uuid.NAMESPACE_URL, f"retailtx/{seed}/{index}")) for index in range(12)
    ]
    kql = f"""
let Transactions = dynamic({json.dumps(transactions)});
let E = materialize(
    AppTraces | where TimeGenerated > ago(2h)
    | where tostring(Properties.environment_id) == '{environment}'
    | extend Event=tostring(Properties.event),
             TransactionId=tostring(Properties.transaction_id));
let A = materialize(
    E | where AppRoleName == 'cap-api' and Event == 'checkout.attempt'
    | where tobool(Properties.success) and TransactionId in (Transactions)
    | where isnotempty(OperationId) and OperationId != '00000000000000000000000000000000'
    | distinct TransactionId, OperationId);
let RequiredEvents = datatable(AppRoleName:string, Event:string)
[
    'cap-api', 'checkout.attempt', 'cap-api', 'transaction.accepted',
    'outbox-publisher', 'outbox.sent', 'erp-core', 'ledger.committed',
    'erp-poster', 'posting.completed'
];
let EventCoverage = E | where TransactionId in (Transactions)
    | where Event != 'checkout.attempt' or tobool(Properties.success)
    | join kind=inner RequiredEvents on AppRoleName, Event
    | distinct TransactionId, OperationId, AppRoleName, Event
    | summarize EventKinds=count() by TransactionId, OperationId;
let S = materialize(
    union
        (AppRequests | project TimeGenerated, OperationId, Id, ParentId, AppRoleName, Name),
        (AppDependencies | project TimeGenerated, OperationId, Id, ParentId, AppRoleName, Name)
    | where TimeGenerated > ago(2h) and OperationId in (A | project OperationId));
let RequiredEdges = datatable(
    ParentRole:string, ParentName:string, ChildRole:string, ChildName:string)
[
    'pos-sim', 'pos.checkout', 'cap-api', 'POST /transaction',
    'cap-api', 'POST /transaction', 'cap-api', 'fastapi.endpoint',
    'cap-api', 'fastapi.endpoint', 'cap-api', 'checkout',
    'cap-api', 'checkout', 'cap-api', 'erp.price',
    'cap-api', 'erp.price', 'erp-core', 'GET /price/{{sku}}',
    'cap-api', 'checkout', 'outbox-publisher', 'outbox.publish',
    'outbox-publisher', 'outbox.publish', 'erp-poster', 'posting.consume',
    'erp-poster', 'posting.consume', 'erp-poster', 'erp.post',
    'erp-poster', 'erp.post', 'erp-core', 'POST /ledger'
];
let EdgeCoverage = S
    | project OperationId, ParentId, ChildRole=AppRoleName, ChildName=Name
    | join kind=inner (
        S | project OperationId, ParentId=Id, ParentRole=AppRoleName, ParentName=Name
      ) on OperationId, ParentId
    | join kind=inner RequiredEdges on ParentRole, ParentName, ChildRole, ChildName
    | distinct OperationId, ParentRole, ParentName, ChildRole, ChildName
    | summarize EdgeKinds=count() by OperationId;
A | join kind=inner EventCoverage on TransactionId, OperationId
  | join kind=inner EdgeCoverage on OperationId
  | where EventKinds == 5 and EdgeKinds == 9
  | distinct TransactionId | summarize VerifiedTransactions=count()
"""
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        rows = query(config, kql)
        if rows and rows[0][0] == 12:
            return {"seed": seed, "verified_transactions": 12, "parent_edges_per_trace": 9}
        time.sleep(15)
    raise RuntimeError("Cloud/Arc business events and trace parentage were not fully observed")


def ready(config: dict) -> dict:
    deadline = time.monotonic() + 900
    last_error = None
    while time.monotonic() < deadline:
        try:
            application = doctor(config)
            observed = telemetry(config)
            return {"application": application, "telemetry": observed}
        except (ReadinessPending, urllib.error.URLError, TimeoutError) as exc:
            last_error = exc
            time.sleep(10)
    raise RuntimeError(f"Live readiness did not succeed within 15 minutes: {last_error}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--operation",
        choices=["doctor", "telemetry", "backlog", "recovery", "ready", "traces", "host"],
        required=True,
    )
    parser.add_argument("--seed")
    parser.add_argument("--baseline-accepted", type=int)
    parser.add_argument("--baseline-posted", type=int)
    args = parser.parse_args()
    if args.operation in {"backlog", "traces"} and not args.seed:
        parser.error("--seed is required for backlog and traces")
    if args.operation == "backlog" and (
        args.baseline_accepted is None
        or args.baseline_posted is None
        or args.baseline_accepted < 0
        or args.baseline_posted < 0
    ):
        parser.error("Nonnegative baseline counts are required for backlog")
    config = json.loads(Path("/etc/retailtx/deployment.json").read_text())
    if args.operation == "ready":
        result = ready(config)
    elif args.operation == "backlog":
        result = backlog(config, args.seed, args.baseline_accepted, args.baseline_posted)
    elif args.operation == "traces":
        result = traces(config, args.seed)
    elif args.operation == "recovery":
        current = report(config, cents=0)
        if current["accepted_count"] != current["posted_count"]:
            raise RuntimeError("Recovery did not reconcile all accepted postings")
        result = {"recovered": current}
    elif args.operation == "telemetry":
        result = telemetry(config)
    elif args.operation == "host":
        result = host_posture(config)
    else:
        result = doctor(config)
    encoded = json.dumps(result, default=str, separators=(",", ":"))
    if len(encoded.encode()) > 3900:
        raise RuntimeError("Readiness evidence exceeds the guest command output limit")
    print(encoded)


if __name__ == "__main__":
    main()
