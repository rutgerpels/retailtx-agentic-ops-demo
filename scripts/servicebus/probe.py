"""Durable, identity-only Service Bus probe for the private recovery scenario."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import re
import socket
import sqlite3
import sys
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from azure.core.exceptions import AzureError
from azure.identity import ManagedIdentityCredential
from azure.servicebus import ServiceBusClient, ServiceBusMessage, TransportType
from azure.servicebus.exceptions import ServiceBusError

CONTRACT = "retailtx-servicebus-probe-v1"
NAMESPACE_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{5,49}\.servicebus\.windows\.net$")
QUEUE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,249}$")
PRIVATE_ENDPOINT_NETWORK = ipaddress.ip_network("10.84.1.0/24")


def validate_target(namespace: str, queue: str) -> tuple[str, str]:
    normalized_namespace = namespace.lower().rstrip(".")
    if not NAMESPACE_PATTERN.fullmatch(normalized_namespace):
        raise ValueError("Expected a Service Bus namespace FQDN.")
    if not QUEUE_PATTERN.fullmatch(queue):
        raise ValueError("Invalid queue name.")
    return normalized_namespace, queue


def assert_private_endpoint(namespace: str) -> None:
    try:
        answers = socket.getaddrinfo(namespace, 443, type=socket.SOCK_STREAM)
    except OSError:
        raise RuntimeError("Could not resolve the namespace inside the private network.") from None
    addresses = {ipaddress.ip_address(answer[4][0]) for answer in answers}
    if not addresses or any(address not in PRIVATE_ENDPOINT_NETWORK for address in addresses):
        raise ValueError(
            "Namespace DNS must resolve exclusively to the retained private endpoint subnet."
        )


def open_store(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    if path.is_symlink():
        raise ValueError("State database must not be a symbolic link.")
    connection = sqlite3.connect(path, timeout=10)
    path.chmod(0o600)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=FULL")
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS outbox (
            transaction_id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            payload_hash TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('pending', 'accepted')),
            send_attempts INTEGER NOT NULL DEFAULT 0,
            accepted_at TEXT
        )
        """
    )
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS ledger (
            transaction_id TEXT PRIMARY KEY,
            payload_hash TEXT NOT NULL,
            posted_at TEXT NOT NULL
        )
        """
    )
    return connection


def health(path: Path) -> dict[str, Any]:
    with store(path) as connection:
        check = connection.execute("PRAGMA quick_check").fetchone()[0]
        if check != "ok":
            raise RuntimeError("Durable SQLite state failed its integrity check.")
        return {
            "ready": True,
            "statePath": str(path),
            "mode": oct(path.stat().st_mode & 0o777),
            "outboxCount": connection.execute("SELECT COUNT(*) FROM outbox").fetchone()[0],
            "ledgerCount": connection.execute("SELECT COUNT(*) FROM ledger").fetchone()[0],
        }


@contextmanager
def store(path: Path) -> Iterator[sqlite3.Connection]:
    connection = open_store(path)
    try:
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def _utc_now() -> str:
    return datetime.now(UTC).isoformat()


def _payload_text(transaction_id: str) -> str:
    payload = {
        "contract": CONTRACT,
        "transactionId": transaction_id,
        "country": "NL",
        "amountMinor": 1234,
    }
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def seed(path: Path, transaction_id: str | None = None) -> dict[str, Any]:
    identifier = str(uuid.UUID(transaction_id)) if transaction_id else str(uuid.uuid4())
    payload = _payload_text(identifier)
    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    with store(path) as connection:
        prior = connection.execute(
            "SELECT payload_hash FROM outbox WHERE transaction_id = ?", (identifier,)
        ).fetchone()
        if prior and prior["payload_hash"] != digest:
            raise ValueError("Existing outbox item does not match the requested transaction.")
        connection.execute(
            """
            INSERT OR IGNORE INTO outbox
                (transaction_id, payload, payload_hash, state)
            VALUES (?, ?, ?, 'pending')
            """,
            (identifier, payload, digest),
        )
    return {"transactionId": identifier, "payloadHash": digest, "state": "pending"}


def _client(namespace: str) -> tuple[ManagedIdentityCredential, ServiceBusClient]:
    assert_private_endpoint(namespace)
    credential = ManagedIdentityCredential()
    try:
        client = ServiceBusClient(
            fully_qualified_namespace=namespace,
            credential=credential,
            transport_type=TransportType.AmqpOverWebsocket,
        )
    except Exception:
        credential.close()
        raise
    return credential, client


def send(path: Path, namespace: str, queue: str, transaction_id: str) -> dict[str, Any]:
    namespace, queue = validate_target(namespace, queue)
    identifier = str(uuid.UUID(transaction_id))
    with store(path) as connection:
        row = connection.execute(
            "SELECT * FROM outbox WHERE transaction_id = ?", (identifier,)
        ).fetchone()
        if row is None:
            raise ValueError("Transaction is not present in the durable outbox.")
        if row["state"] == "accepted":
            return {"transactionId": identifier, "state": "accepted", "alreadyAccepted": True}
        body = row["payload"]
        payload_hash = row["payload_hash"]

    credential, client = _client(namespace)
    try:
        with client, client.get_queue_sender(queue_name=queue) as sender:
            sender.send_messages(
                ServiceBusMessage(body, message_id=identifier, content_type="application/json")
            )
    except ServiceBusError as error:
        with store(path) as connection:
            connection.execute(
                "UPDATE outbox SET send_attempts = send_attempts + 1 WHERE transaction_id = ?",
                (identifier,),
            )
        return {
            "transactionId": identifier,
            "state": "pending",
            "accepted": False,
            "errorType": type(error).__name__,
        }
    finally:
        credential.close()

    with store(path) as connection:
        connection.execute(
            """
            UPDATE outbox
            SET state = 'accepted', send_attempts = send_attempts + 1, accepted_at = ?
            WHERE transaction_id = ? AND payload_hash = ?
            """,
            (_utc_now(), identifier, payload_hash),
        )
    return {"transactionId": identifier, "state": "accepted", "accepted": True}


def _message_text(body: Any) -> str:
    try:
        if isinstance(body, str):
            return body
        if isinstance(body, (bytes, bytearray)):
            return bytes(body).decode("utf-8")
        return b"".join(bytes(section) for section in body).decode("utf-8")
    except (AttributeError, TypeError, UnicodeDecodeError) as error:
        raise ValueError("Message body is not valid UTF-8 probe data.") from error


def receive(
    path: Path, namespace: str, queue: str, *, max_messages: int = 10
) -> dict[str, Any]:
    namespace, queue = validate_target(namespace, queue)
    if not 1 <= max_messages <= 50:
        raise ValueError("max_messages must be between 1 and 50.")

    credential, client = _client(namespace)
    completed = 0
    duplicate_deliveries = 0
    try:
        with client, client.get_queue_receiver(
            queue_name=queue, max_wait_time=5
        ) as receiver:
            messages = receiver.receive_messages(
                max_message_count=max_messages, max_wait_time=5
            )
            for message in messages:
                ledger_committed = False
                try:
                    payload = json.loads(_message_text(message.body))
                    if not isinstance(payload, dict) or not isinstance(
                        payload.get("transactionId"), str
                    ):
                        raise ValueError("Message does not match the probe contract.")
                    identifier = str(uuid.UUID(payload["transactionId"]))
                    if payload.get("contract") != CONTRACT or message.message_id != identifier:
                        raise ValueError("Message does not match the probe contract.")
                    canonical = _payload_text(identifier)
                    if json.dumps(payload, sort_keys=True, separators=(",", ":")) != canonical:
                        raise ValueError("Message payload differs from the durable outbox.")
                    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
                    with store(path) as connection:
                        outbox = connection.execute(
                            "SELECT payload_hash FROM outbox WHERE transaction_id = ?",
                            (identifier,),
                        ).fetchone()
                        if outbox is None or outbox["payload_hash"] != digest:
                            raise ValueError("Message has no matching durable outbox record.")
                        inserted = connection.execute(
                            """
                            INSERT OR IGNORE INTO ledger
                                (transaction_id, payload_hash, posted_at)
                            VALUES (?, ?, ?)
                            """,
                            (identifier, digest, _utc_now()),
                        ).rowcount
                    if not inserted:
                        duplicate_deliveries += 1
                    # The ledger commit is durable before settlement. If settlement
                    # fails ambiguously, let the lock expire rather than trying to
                    # abandon a message that may already have been completed.
                    ledger_committed = True
                    receiver.complete_message(message)
                    completed += 1
                except Exception:
                    if not ledger_committed:
                        receiver.abandon_message(message)
                    raise
    finally:
        credential.close()
    return {
        "completed": completed,
        "duplicateDeliveries": duplicate_deliveries,
    }


def verify(path: Path, transaction_id: str) -> dict[str, Any]:
    identifier = str(uuid.UUID(transaction_id))
    with store(path) as connection:
        outbox = connection.execute(
            "SELECT * FROM outbox WHERE transaction_id = ?", (identifier,)
        ).fetchone()
        ledger = connection.execute(
            "SELECT * FROM ledger WHERE transaction_id = ?", (identifier,)
        ).fetchall()
    if outbox is None:
        raise ValueError("Transaction is not present in the durable outbox.")
    if outbox["state"] != "accepted" or len(ledger) != 1:
        raise RuntimeError(
            "Recovery is not verified: the accepted message is not posted exactly once."
        )
    if ledger[0]["payload_hash"] != outbox["payload_hash"]:
        raise RuntimeError("Recovery evidence hash does not match the durable outbox.")
    return {
        "transactionId": identifier,
        "state": "posted",
        "postedCount": len(ledger),
        "payloadHash": outbox["payload_hash"],
        "sendAttempts": outbox["send_attempts"],
    }


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--state", type=Path, required=True, help="Durable SQLite outbox/ledger file"
    )
    subparsers = parser.add_subparsers(dest="operation", required=True)
    subparsers.add_parser("health")
    seed_parser = subparsers.add_parser("seed")
    seed_parser.add_argument("--transaction-id")
    send_parser = subparsers.add_parser("send")
    receive_parser = subparsers.add_parser("receive")
    receive_parser.add_argument("--max-messages", type=int, default=10)
    verify_parser = subparsers.add_parser("verify")
    for child in (send_parser, receive_parser):
        child.add_argument("--namespace", required=True)
        child.add_argument("--queue", required=True)
    send_parser.add_argument("--transaction-id", required=True)
    verify_parser.add_argument("--transaction-id", required=True)
    return parser.parse_args()


def main() -> int:
    args = _arguments()
    try:
        if args.operation == "health":
            result = health(args.state)
        elif args.operation == "seed":
            result = seed(args.state, args.transaction_id)
        elif args.operation == "send":
            result = send(args.state, args.namespace, args.queue, args.transaction_id)
        elif args.operation == "receive":
            result = receive(
                args.state, args.namespace, args.queue, max_messages=args.max_messages
            )
        else:
            result = verify(args.state, args.transaction_id)
    except (ValueError, RuntimeError) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 2
    except (AzureError, OSError, sqlite3.Error) as error:
        print(json.dumps({"errorType": type(error).__name__}), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0 if result.get("accepted", True) else 3


if __name__ == "__main__":
    raise SystemExit(main())
