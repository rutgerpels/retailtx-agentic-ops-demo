"""Host-side acceptance: actual container stops/restarts, never an Azure operation."""

import argparse
import json
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--env-file", required=True)
    args = parser.parse_args()
    if not args.project.startswith("retailtx-test-"):
        parser.error("A dedicated retailtx-test-* project is required")
    root = Path(__file__).resolve().parents[2]
    command = [
        "docker",
        "compose",
        "--project-name",
        args.project,
        "--env-file",
        args.env_file,
        "-f",
        str(root / "compose.local.yaml"),
    ]

    def compose(*arguments, timeout=180):
        result = subprocess.run(
            [*command, *arguments], cwd=root, capture_output=True, text=True, timeout=timeout
        )
        if result.returncode:
            raise RuntimeError(
                f"Compose {arguments[0]} failed ({result.returncode}): "
                f"{result.stdout[-4000:]}\n{result.stderr[-4000:]}"
            )
        return result.stdout

    address = compose("port", "cap-api", "8000").strip()
    url = f"http://{address}/reconciliation"

    def current():
        with urllib.request.urlopen(url, timeout=5) as response:
            return json.load(response)

    def wait_report(predicate, timeout=90):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            try:
                last = current()
                if predicate(last):
                    return last
            except (urllib.error.URLError, TimeoutError) as exc:
                last = {"transport_error": type(exc).__name__}
            time.sleep(1)
        raise AssertionError(f"Reconciliation condition timed out: {last}")

    def fresh(count, unposted):
        return wait_report(
            lambda result: (
                result["status"] == "fresh"
                and result["current"]["accepted_count"] == count
                and result["current"]["unposted_cents"] == unposted
            )
        )["current"]

    def tools(*arguments):
        return compose("run", "--rm", "--no-deps", "tools", "python", *arguments)

    def sql(service, statement):
        return compose(
            "exec",
            "-T",
            service,
            "psql",
            "-U",
            "retailtx",
            "-d",
            "retailtx",
            "-v",
            "ON_ERROR_STOP=1",
            "-Atc",
            statement,
        ).strip()

    evidence = {}
    try:
        fresh(0, 0)
        # Bound the reversible fault and prove it expires without the invoking process.
        tools("chaos/backlog.py", "--duration-seconds", "5")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if sql("erp-db", "SELECT worker_state FROM worker_control") == "paused":
                break
            time.sleep(0.2)
        else:
            raise AssertionError("Poster did not observe the fault")
        time.sleep(6)
        tools("-m", "retailtx.runtime", "doctor")
        tools("chaos/backlog.py", "--undo")
        tools("chaos/backlog.py", "--undo")
        evidence["fault_expiry_and_repeated_undo"] = True

        # Stop the real poster container, not a mocked receiver or a logical pause.
        compose("stop", "erp-poster")
        tools("sim/pos_sim.py", "--seed", "container-stop", "--count", "12", "--interval", "0")
        tools("sim/pos_sim.py", "--seed", "container-stop", "--count", "12", "--interval", "0")
        stopped = fresh(12, 4848)
        assert stopped["posted_count"] == 0
        assert stopped["oldest_unposted_age_seconds"] >= 0
        evidence["poster_stopped"] = stopped
        compose("start", "erp-poster")
        recovered = fresh(12, 0)
        assert recovered["posted_count"] == 12
        evidence["poster_resumed"] = recovered

        compose("stop", "erp-core")
        stale = wait_report(lambda result: result["status"] == "stale")
        assert stale["current"] is None
        assert stale["last_success"]["accepted_count"] == 12
        evidence["erp_unavailable"] = {
            "status": stale["status"],
            "current": stale["current"],
            "last_success_at": stale["last_success_at"],
        }
        compose("start", "erp-core")
        fresh(12, 0)

        # Broker restart loses acknowledged messages; accepted/outbox records remain authoritative.
        compose("stop", "erp-poster")
        tools("sim/pos_sim.py", "--seed", "broker-restart", "--count", "12", "--interval", "0")
        fresh(24, 4848)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if sql("cap-db", "SELECT count(*) FROM outbox WHERE state <> 'sent'") == "0":
                break
            time.sleep(1)
        else:
            raise AssertionError("Publisher did not acknowledge all outbox sends")
        compose("stop", "outbox-publisher", "recon-job")
        compose("restart", "servicebus", "cap-db", "erp-db")
        compose("start", "recon-job")
        fresh(24, 4848)
        assert sql("cap-db", "SELECT count(*) FROM accepted_transactions") == "24"
        assert sql("erp-db", "SELECT count(*) FROM ledger") == "12"
        # Give the empty, recreated emulator a bounded readiness check through its real SDK.
        compose("start", "outbox-publisher", "erp-poster")
        time.sleep(10)
        assert fresh(24, 4848)["posted_count"] == 12
        replayed = tools("-m", "retailtx.runtime", "replay-unposted")
        assert '"transaction_count": 12' in replayed
        recovered = fresh(24, 0)
        assert recovered["posted_count"] == 24
        evidence["database_and_broker_restart_recovered"] = recovered

        # Replaying already-posted work is a no-op and cannot duplicate ledger rows.
        assert '"transaction_count": 0' in tools("-m", "retailtx.runtime", "replay-unposted")
        accepted = json.loads(
            sql(
                "cap-db",
                "SELECT json_agg(posting ORDER BY transaction_id) FROM accepted_transactions",
            )
        )
        ledger = json.loads(
            sql("erp-db", "SELECT json_agg(posting ORDER BY transaction_id) FROM ledger")
        )
        assert accepted == ledger and len(ledger) == 24
        tools("-m", "retailtx.runtime", "doctor")
        evidence["accepted_equals_ledger_exactly"] = True

        time.sleep(2)
        logs = compose(
            "logs", "--no-log-prefix", "cap-api", "erp-core", "outbox-publisher", "erp-poster"
        )
        spans = []
        for line in logs.splitlines():
            if not line.startswith("{"):
                continue
            item = json.loads(line)
            if "context" in item and "name" in item:
                spans.append(item)
        names = ("checkout", "erp.price", "outbox.publish", "posting.consume", "erp.post")
        traces = [{s["context"]["trace_id"] for s in spans if s["name"] == name} for name in names]
        common = set.intersection(*traces)
        assert common, "No end-to-end trace across HTTP, persisted outbox and broker"
        trace_id = sorted(common)[0]
        chain = [s for s in spans if s["context"]["trace_id"] == trace_id]
        by_name = {s["name"]: s for s in chain}
        assert by_name["outbox.publish"]["parent_id"] == by_name["checkout"]["context"]["span_id"]
        assert (
            by_name["posting.consume"]["parent_id"]
            == by_name["outbox.publish"]["context"]["span_id"]
        )
        assert by_name["erp.post"]["parent_id"] == by_name["posting.consume"]["context"]["span_id"]
        evidence["trace_chain"] = {
            "trace_id": trace_id,
            "spans": names,
            "parent_links_verified": True,
        }
        print(json.dumps(evidence, indent=2))
    finally:
        # Independent recovery path on failure; never destroy data to make a failed gate pass.
        compose(
            "start",
            "cap-db",
            "erp-db",
            "servicebus",
            "erp-core",
            "cap-api",
            "outbox-publisher",
            "erp-poster",
            "recon-job",
        )
        tools("chaos/backlog.py", "--undo")


if __name__ == "__main__":
    main()
