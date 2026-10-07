import argparse
import signal
from threading import Event
from time import monotonic, sleep
from types import FrameType

import httpx
import psycopg
from azure.core.exceptions import AzureError
from azure.servicebus import ServiceBusSubQueue

from retailtx import broker, fault
from retailtx.db import connect, migrate
from retailtx.http import client
from retailtx.poster import handle_message
from retailtx.publisher import publish_one
from retailtx.reconciliation import INTERVAL_SECONDS, reconcile, replay_unposted, status
from retailtx.settings import Settings
from retailtx.telemetry import carrier, configure, event


def validate_command(command: str, settings: Settings) -> None:
    if settings.mode == "azure" and command in {"doctor", "drain"}:
        action = "Doctor" if command == "doctor" else "Reset"
        raise ValueError(
            f"Azure {command} requires Invoke-Azure.ps1 {action} for full distributed evidence, "
            "including operator-authorized DLQ checks; runtime identities have host-scoped roles"
        )
    if settings.mode == "azure" and command == "dead-letters" and settings.identity_kind != "arc":
        raise ValueError(
            "Azure cloud identity is send-only; use Invoke-Azure.ps1 Doctor for the "
            "operator-authorized DLQ count, or run dead-letters on the receiving DC host"
        )
    if command == "migrate" and settings.mode == "azure":
        raise ValueError("Azure migrations require the separate migrate-cap or migrate-erp command")
    if command in {
        "migrate",
        "migrate-cap",
        "outbox-publisher",
        "recon-job",
        "reconcile",
        "replay-unposted",
        "doctor",
        "drain",
    }:
        _ = settings.cap_dsn
    if command in {"migrate", "migrate-erp", "erp-poster", "undo"}:
        _ = settings.erp_dsn


def loop(component: str, settings: Settings) -> None:
    stop = Event()

    def stopping(signum: int, frame: FrameType | None) -> None:
        stop.set()

    signal.signal(signal.SIGTERM, stopping)
    signal.signal(signal.SIGINT, stopping)
    failures = 0
    while not stop.is_set():
        try:
            if component == "recon-job":
                with client(settings, settings.erp_url) as http:
                    reconcile(settings.cap_dsn, http)
                stop.wait(INTERVAL_SECONDS)
            elif component == "outbox-publisher":
                with broker.client(settings) as bus, bus.get_queue_sender(broker.QUEUE) as sender:
                    while not stop.is_set():
                        if not publish_one(settings.cap_dsn, sender):
                            stop.wait(1)
            elif component == "erp-poster":
                with (
                    broker.client(settings) as bus,
                    bus.get_queue_receiver(
                        broker.QUEUE, max_wait_time=2, prefetch_count=0
                    ) as receiver,
                    client(settings, settings.erp_url) as http,
                ):
                    while not stop.is_set():
                        if fault.heartbeat(settings.erp_dsn):
                            stop.wait(1)
                            continue
                        # Avoid burning delivery attempts during an ERP outage.
                        http.get("/health").raise_for_status()
                        for message in receiver.receive_messages(
                            max_message_count=1, max_wait_time=2
                        ):
                            if not handle_message(receiver, message, http):
                                stop.wait(5)
            else:
                raise ValueError("Unknown worker")
            failures = 0
        except (AzureError, psycopg.OperationalError, httpx.HTTPError) as exc:
            failures += 1
            delay = min(30, 2 ** min(failures, 5))
            event(
                "worker.retry", component=component, error=type(exc).__name__, delay_seconds=delay
            )
            stop.wait(delay)


def doctor(settings: Settings) -> bool:
    validate_command("doctor", settings)
    with client(settings, settings.cap_url) as http:
        http.get("/health", headers=carrier()).raise_for_status()
    with client(settings, settings.erp_url) as http:
        http.get("/health", headers=carrier()).raise_for_status()
    worker = fault.worker_status(settings.erp_dsn)
    with connect(settings.cap_dsn) as conn:
        blocked = conn.execute(
            "SELECT count(*) AS count FROM outbox WHERE state = 'blocked'"
        ).fetchone()
    with (
        broker.client(settings) as bus,
        bus.get_queue_receiver(broker.QUEUE, sub_queue=ServiceBusSubQueue.DEAD_LETTER) as receiver,
    ):
        dead_letters = receiver.peek_messages(max_message_count=1, timeout=5)
    result = status(settings.cap_dsn)
    healthy = bool(
        worker.get("alive") is True
        and worker.get("paused") is False
        and worker["worker_state"] == "running"
        and blocked is not None
        and blocked["count"] == 0
        and not dead_letters
        and result["status"] == "fresh"
    )
    event(
        "doctor",
        healthy=healthy,
        worker=worker,
        blocked_outbox=blocked,
        has_dead_letters=bool(dead_letters),
        reconciliation=result,
    )
    return healthy


def drain(settings: Settings) -> None:
    validate_command("drain", settings)
    deadline = monotonic() + 120
    with client(settings, settings.erp_url) as http:
        while monotonic() < deadline:
            result = reconcile(settings.cap_dsn, http)
            current = result["current"]
            if (
                result["status"] == "fresh"
                and isinstance(current, dict)
                and current["unposted_count"] == 0
                and doctor(settings)
            ):
                event("recovery.verified", unposted_cents=0)
                return
            sleep(2)
    raise RuntimeError(
        "Backlog did not drain within 120 seconds; inspect outbox/DLQ and dependencies"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command",
        choices=[
            "migrate",
            "migrate-cap",
            "migrate-erp",
            "outbox-publisher",
            "erp-poster",
            "recon-job",
            "reconcile",
            "replay-unposted",
            "doctor",
            "dead-letters",
            "undo",
            "drain",
        ],
    )
    args = parser.parse_args()
    settings = Settings.from_env()
    validate_command(args.command, settings)
    configure(args.command, settings)
    if args.command == "migrate":
        migrate(settings.cap_dsn, "cap")
        migrate(settings.erp_dsn, "erp")
        event("migration.complete")
    elif args.command in {"migrate-cap", "migrate-erp"}:
        component = args.command.removeprefix("migrate-")
        migrate(settings.cap_dsn if component == "cap" else settings.erp_dsn, component)
        event("migration.complete", component=component)
    elif args.command == "doctor":
        raise SystemExit(0 if doctor(settings) else 1)
    elif args.command == "undo":
        fault.backlog(settings.erp_dsn, None)
    elif args.command == "drain":
        drain(settings)
    elif args.command in {"reconcile", "replay-unposted"}:
        with client(settings, settings.erp_url) as http:
            if args.command == "reconcile":
                result = reconcile(settings.cap_dsn, http)
                event("reconciliation.result", **result)
                raise SystemExit(0 if result["status"] == "fresh" else 1)
            replay_unposted(settings.cap_dsn, http)
    elif args.command == "dead-letters":
        with (
            broker.client(settings) as bus,
            bus.get_queue_receiver(
                broker.QUEUE, sub_queue=ServiceBusSubQueue.DEAD_LETTER
            ) as receiver,
        ):
            messages = receiver.peek_messages(max_message_count=100, timeout=5)
            event(
                "dead_letters.peek",
                limit=100,
                messages=[
                    {"message_id": str(m.message_id), "reason": m.dead_letter_reason}
                    for m in messages
                ],
            )
    else:
        loop(args.command, settings)


if __name__ == "__main__":
    main()
